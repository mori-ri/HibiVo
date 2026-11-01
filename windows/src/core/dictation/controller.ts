// The dictation state machine: press → record (streaming STT) → stop → finish STT → cleanup → paste.
// Port of DictationController.swift.
//
// A short tap latches recording until the next press; holding the key past `holdThresholdMs`
// works as push-to-talk and stops on release.

import { CleanupCoordinator, type CleanupOutcome } from "../cleanup/coordinator";
import { userFacingMessage, type UserFacingError } from "../errors";
import { TranscriptionError, type TranscriptionSession } from "../transcription/types";
import type {
  AudioCapture,
  AudioChunk,
  ContextBuilder,
  DictationContext,
  DictationSnapshot,
  HistoryRecord,
  HistoryStatus,
  HotkeyAction,
  Phase,
  TargetApp,
  TextInserter,
} from "./types";

/** Peak RMS below this means nobody spoke; skip the upload and the paste. */
export const silenceThreshold = 0.005;
export const defaultHoldThresholdMs = 400;
/** Recordings stopped sooner than this are treated as an accidental double tap. */
export const defaultMinimumDurationMs = 250;
/** Safety cap in case the user forgets to stop recording. */
const maximumRecordingMs = 600_000;
const errorDisplayMs = 2_500;

export interface DictationControllerOptions {
  audio: AudioCapture;
  makeContext: ContextBuilder;
  inserter: TextInserter;
  cleanup?: CleanupCoordinator;
  /** Whether AI cleanup is on, for the HUD's level colour. */
  cleanupEnabled?: () => boolean;
  onChange?: (snapshot: DictationSnapshot) => void;
  onHistory?: (record: HistoryRecord) => void;
  minimumDurationMs?: number;
  holdThresholdMs?: number;
  now?: () => number;
}

interface Recording {
  context: DictationContext;
  session: TranscriptionSession;
  /** Key event time of the press that started it. */
  startedAt: number;
  audioStarted: Promise<void>;
  peak: number;
  bytes: number;
  watchdog: ReturnType<typeof setTimeout>;
  /** Whether the key that started this recording is still down. */
  isHeld: boolean;
}

/** Milliseconds from `a` to `b` on the 32-bit tick clock. */
function elapsed(a: number, b: number): number {
  return (b - a + 2 ** 32) % 2 ** 32;
}

export class DictationController {
  private phase: Phase = { kind: "idle" };
  private level = 0;
  private partialTranscript = "";
  private recording: Recording | null = null;
  private processing: Promise<void> | null = null;
  private errorTimer: ReturnType<typeof setTimeout> | undefined;

  private readonly audio: AudioCapture;
  private readonly makeContext: ContextBuilder;
  private readonly inserter: TextInserter;
  private readonly cleanup: CleanupCoordinator;
  private readonly cleanupEnabled: () => boolean;
  private readonly onChange?: (snapshot: DictationSnapshot) => void;
  private readonly onHistory?: (record: HistoryRecord) => void;
  private readonly minimumDurationMs: number;
  private readonly holdThresholdMs: number;
  private readonly now: () => number;

  constructor(options: DictationControllerOptions) {
    this.audio = options.audio;
    this.makeContext = options.makeContext;
    this.inserter = options.inserter;
    this.cleanup = options.cleanup ?? new CleanupCoordinator();
    this.cleanupEnabled = options.cleanupEnabled ?? (() => true);
    this.onChange = options.onChange;
    this.onHistory = options.onHistory;
    this.minimumDurationMs = options.minimumDurationMs ?? defaultMinimumDurationMs;
    this.holdThresholdMs = options.holdThresholdMs ?? defaultHoldThresholdMs;
    this.now = options.now ?? (() => performance.now());
  }

  get snapshot(): DictationSnapshot {
    return {
      phase: this.phase,
      level: this.level,
      partialTranscript: this.partialTranscript,
      cleanupEnabled: this.cleanupEnabled(),
    };
  }

  /**
   * @param time When the key event happened. Holds are measured between event times, not handling times,
   *   because a release can wait behind a slow microphone start.
   * @param foreground The window in front when the key event happened.
   */
  handle(action: HotkeyAction, time: number, foreground: TargetApp | null): void {
    switch (action) {
      case "pressed":
        if (this.phase.kind === "recording") this.end(time, foreground);
        else this.begin(time, foreground);
        return;
      case "released":
        this.releaseKey(time, foreground);
        return;
      case "interrupted":
      case "escape":
        this.cancel();
        return;
    }
  }

  /** Waits for the current utterance to be fully processed. Used by tests. */
  async waitUntilIdle(): Promise<void> {
    await this.processing;
  }

  // MARK: - Recording

  private begin(pressedAt: number, foreground: TargetApp | null): void {
    // A press while processing is ignored so pastes never interleave.
    if (this.phase.kind === "recording" || this.phase.kind === "processing") return;
    clearTimeout(this.errorTimer);

    const target = foreground && !foreground.isSelf ? foreground : null;
    const made = this.makeContext(target);
    if ("error" in made) {
      this.show(made.error);
      return;
    }
    const context = made;
    const { provider, config } = context.transcription;
    const session = provider.makeSession(config, (text) => {
      if (this.recording?.session !== session) return;
      this.partialTranscript = text;
      this.changed();
    });

    const recording: Recording = {
      context,
      session,
      startedAt: pressedAt,
      audioStarted: Promise.resolve(),
      peak: 0,
      bytes: 0,
      watchdog: setTimeout(() => {
        // Not the user's stop: whatever is in front ten minutes on isn't where they meant to write.
        if (this.recording === recording) this.end(undefined, null);
      }, maximumRecordingMs),
      isHeld: true,
    };
    const onChunk = (chunk: AudioChunk) => {
      recording.peak = Math.max(recording.peak, chunk.level);
      recording.bytes += chunk.pcm16.byteLength;
      session.send(chunk.pcm16);
      if (this.recording === recording) {
        // Light smoothing so the meter doesn't flicker.
        this.level = this.level * 0.5 + chunk.level * 0.5;
        this.changed();
      }
    };
    recording.audioStarted = this.audio.start(provider.sampleRate, onChunk).catch((error: unknown) => {
      console.error("Audio start failed", error);
      if (this.recording !== recording) return;
      this.discard(recording);
      this.show({ kind: "microphoneUnavailable" });
    });
    session.start();

    this.recording = recording;
    this.level = 0;
    this.partialTranscript = "";
    this.setPhase({ kind: "recording" });
  }

  /** Ends a push-to-talk hold; a short tap leaves recording running until the next press. */
  private releaseKey(time: number, foreground: TargetApp | null): void {
    const recording = this.recording;
    if (this.phase.kind !== "recording" || !recording?.isHeld) return;
    if (elapsed(recording.startedAt, time) >= this.holdThresholdMs) this.end(time, foreground);
    else recording.isHeld = false;
  }

  /** @param time undefined when the stop wasn't the user's (the watchdog). */
  private end(time: number | undefined, foreground: TargetApp | null): void {
    const recording = this.recording;
    if (this.phase.kind !== "recording" || !recording) return;
    if (time !== undefined && elapsed(recording.startedAt, time) < this.minimumDurationMs) {
      this.cancel();
      return;
    }
    if (time !== undefined) this.retarget(recording.context, foreground);
    this.recording = null;
    clearTimeout(recording.watchdog);
    this.setPhase({ kind: "processing" });
    const stoppedAt = this.now();
    this.processing = this.process(recording, stoppedAt);
  }

  /**
   * The text goes where the caret is when recording stops: people often start talking while reading something and
   * only then move to the field they are writing in. HibiVo's own windows don't count, so the app from key-down is
   * kept when one of them is in front.
   */
  private retarget(context: DictationContext, foreground: TargetApp | null): void {
    if (!foreground || foreground.isSelf || foreground.hwnd === context.target?.hwnd) return;
    context.target = foreground;
  }

  private cancel(): void {
    const recording = this.recording;
    if (this.phase.kind !== "recording" || !recording) return;
    this.discard(recording);
    this.setPhase({ kind: "idle" });
  }

  private discard(recording: Recording): void {
    this.recording = null;
    clearTimeout(recording.watchdog);
    recording.session.cancel();
    this.processing = this.stopAudio(recording);
  }

  private async stopAudio(recording: Recording): Promise<void> {
    await recording.audioStarted;
    await this.audio.stop().catch((error: unknown) => console.error("Audio stop failed", error));
  }

  // MARK: - Processing

  private async process(recording: Recording, stoppedAt: number): Promise<void> {
    // Stopping drains the last chunks into the session, so finish() sees all the audio.
    await this.stopAudio(recording);
    const { context, session } = recording;

    if (recording.peak < silenceThreshold) {
      session.cancel();
      console.info(`Silence detected (peak ${recording.peak}); nothing to transcribe`);
      this.setPhase({ kind: "idle" });
      return;
    }

    let transcript: string;
    try {
      transcript = await session.finish();
    } catch (error) {
      console.error("Transcription failed", error);
      const userError = userFacingTranscriptionError(error, context.transcription.provider.displayName);
      this.record(context, "", null, stoppedAt, "failed", userFacingMessage(userError));
      this.show(userError);
      return;
    }
    if (!transcript) {
      this.show({ kind: "nothingRecognized" });
      return;
    }

    const { cleanup } = context;
    const cleaned: CleanupOutcome = await this.cleanup.runForDictation(
      {
        raw: transcript,
        mode: cleanup.mode,
        appName: context.target?.name,
        customInstructions: cleanup.customInstructions,
        language: cleanup.language,
      },
      cleanup.provider,
      cleanup.model,
    );

    const outcome = await this.inserter.insert(cleaned.text, context.target);
    const status: HistoryStatus =
      outcome.kind === "copiedOnly" ? "copiedOnly" : cleaned.failure ? "pastedRaw" : "pasted";
    this.record(
      context,
      transcript,
      cleaned.didCleanup ? cleaned.text : null,
      stoppedAt,
      status,
      cleaned.failure ? cleaned.failure.code : null,
    );

    if (outcome.kind === "copiedOnly") this.show({ kind: "copiedOnly", reason: outcome.reason });
    else if (cleaned.failure) this.show({ kind: "cleanupFellBack" });
    else this.setPhase({ kind: "idle" });
  }

  private record(
    context: DictationContext,
    raw: string,
    cleaned: string | null,
    stoppedAt: number,
    status: HistoryStatus,
    errorMessage: string | null,
  ): void {
    this.onHistory?.({
      timestamp: Date.now(),
      rawTranscript: raw,
      cleanedTranscript: cleaned,
      appName: context.target?.name ?? null,
      cleanupMode: context.cleanup.mode,
      latencyMs: Math.round(this.now() - stoppedAt),
      status,
      errorMessage,
    });
  }

  private show(error: UserFacingError): void {
    this.setPhase({ kind: "error", message: userFacingMessage(error) });
    clearTimeout(this.errorTimer);
    this.errorTimer = setTimeout(() => {
      if (this.phase.kind === "error") this.setPhase({ kind: "idle" });
    }, errorDisplayMs);
  }

  private setPhase(phase: Phase): void {
    this.phase = phase;
    this.changed();
  }

  private changed(): void {
    this.onChange?.(this.snapshot);
  }
}

function userFacingTranscriptionError(error: unknown, provider: string): UserFacingError {
  if (!(error instanceof TranscriptionError)) return { kind: "transcriptionFailed" };
  switch (error.code) {
    case "unauthorized":
      return { kind: "invalidAPIKey", provider };
    case "timedOut":
      return { kind: "transcriptionTimedOut" };
    case "network":
      return { kind: "network" };
    default:
      return { kind: "transcriptionFailed" };
  }
}
