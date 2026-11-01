import type { CleanupMode, PromptLanguage } from "../cleanup/mode";
import type { TextCleanupProvider } from "../cleanup/provider";
import type { UserFacingError } from "../errors";
import type { TranscriptionConfig, TranscriptionProvider } from "../transcription/types";

export type HotkeyAction = "pressed" | "released" | "interrupted" | "escape";

/** The window that had focus, as the keyboard hook saw it. */
export interface TargetApp {
  hwnd: number;
  pid: number;
  /** Executable name without extension, e.g. "slack" or "WindowsTerminal". */
  name: string;
  /** One of HibiVo's own windows. */
  isSelf: boolean;
}

export interface HotkeyEvent {
  action: HotkeyAction;
  /** When the key event happened, in milliseconds on the system tick clock (wraps every ~49.7 days). */
  time: number;
  foreground: TargetApp | null;
}

/** 16-bit little-endian mono PCM plus its RMS level in 0...1. */
export interface AudioChunk {
  pcm16: Uint8Array;
  level: number;
}

export interface AudioCapture {
  /** Resolves once the microphone is running; rejects when it can't start. */
  start(sampleRate: number, onChunk: (chunk: AudioChunk) => void): Promise<void>;
  /** Stops and resolves after the last chunk has been delivered. */
  stop(): Promise<void>;
}

export type InsertOutcome = { kind: "pasted" } | { kind: "copiedOnly"; reason: string };

export interface TextInserter {
  insert(text: string, target: TargetApp | null): Promise<InsertOutcome>;
}

/** Everything one utterance needs, fixed when recording starts so a settings change mid-utterance can't mix in. */
export interface DictationContext {
  target: TargetApp | null;
  transcription: { provider: TranscriptionProvider; config: TranscriptionConfig };
  cleanup: {
    mode: CleanupMode;
    /** null when the selected provider has no credentials. */
    provider: TextCleanupProvider | null;
    model: string;
    customInstructions: string;
    language: PromptLanguage;
  };
}

export type ContextBuilder = (target: TargetApp | null) => DictationContext | { error: UserFacingError };

export type Phase =
  | { kind: "idle" }
  | { kind: "recording" }
  | { kind: "processing" }
  | { kind: "error"; message: string };

export interface DictationSnapshot {
  phase: Phase;
  /** Smoothed microphone level while recording. */
  level: number;
  partialTranscript: string;
  cleanupEnabled: boolean;
}

export type HistoryStatus = "pasted" | "pastedRaw" | "copiedOnly" | "failed";

export interface HistoryRecord {
  timestamp: number;
  rawTranscript: string;
  cleanedTranscript: string | null;
  appName: string | null;
  cleanupMode: CleanupMode;
  latencyMs: number;
  status: HistoryStatus;
  errorMessage: string | null;
}
