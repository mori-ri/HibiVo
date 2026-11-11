// Ported from the macOS app's DictationControllerTests.swift.

import { describe, expect, it } from "vitest";
import { CleanupCoordinator } from "../src/core/cleanup/coordinator";
import { DictationController } from "../src/core/dictation/controller";
import type {
  AudioCapture,
  AudioChunk,
  DictationContext,
  InsertOutcome,
  TargetApp,
  TextInserter,
} from "../src/core/dictation/types";
import {
  TranscriptionError,
  type TranscriptionConfig,
  type TranscriptionProvider,
  type TranscriptionSession,
} from "../src/core/transcription/types";

const transcript = "今日の15時からAWSのAppSyncについて打ち合わせをします";
const slack: TargetApp = { hwnd: 1, pid: 10, name: "slack", isSelf: false };
const mail: TargetApp = { hwnd: 2, pid: 20, name: "olk", isSelf: false };
const self: TargetApp = { hwnd: 3, pid: 30, name: "hibivo", isSelf: true };

class MockSession implements TranscriptionSession {
  receivedBytes = 0;
  didFinish = false;
  didCancel = false;
  constructor(private readonly result: string | TranscriptionError) {}
  start() {}
  send(pcm16: Uint8Array) {
    this.receivedBytes += pcm16.byteLength;
  }
  async finish() {
    this.didFinish = true;
    if (this.result instanceof TranscriptionError) throw this.result;
    return this.result;
  }
  cancel() {
    this.didCancel = true;
  }
}

class MockProvider implements TranscriptionProvider {
  readonly id = "mock";
  readonly displayName = "Mock";
  readonly sampleRate = 16_000;
  readonly defaultModel = "m";
  sessions: MockSession[] = [];
  lastConfig: TranscriptionConfig | null = null;
  constructor(private readonly result: string | TranscriptionError = transcript) {}
  makeSession(config: TranscriptionConfig) {
    this.lastConfig = config;
    const session = new MockSession(this.result);
    this.sessions.push(session);
    return session;
  }
}

class MockAudio implements AudioCapture {
  startCount = 0;
  failStart = false;
  private onChunk: ((chunk: AudioChunk) => void) | null = null;
  async start(_sampleRate: number, onChunk: (chunk: AudioChunk) => void) {
    this.startCount++;
    if (this.failStart) throw new Error("no microphone");
    this.onChunk = onChunk;
  }
  async stop() {
    this.onChunk = null;
  }
  async speak(level = 0.1) {
    await Promise.resolve(); // Let start() settle, as a real microphone would before delivering audio.
    this.onChunk?.({ pcm16: new Uint8Array(320), level });
  }
}

class MockInserter implements TextInserter {
  inserted: { text: string; target: TargetApp | null }[] = [];
  outcome: InsertOutcome = { kind: "pasted" };
  async insert(text: string, target: TargetApp | null) {
    this.inserted.push({ text, target });
    return this.outcome;
  }
}

function setup(
  options: {
    provider?: MockProvider;
    apiKey?: string;
    cleanupEnabled?: boolean;
    minimumDurationMs?: number;
    holdThresholdMs?: number;
  } = {},
) {
  const provider = options.provider ?? new MockProvider();
  const audio = new MockAudio();
  const inserter = new MockInserter();
  const sut = new DictationController({
    audio,
    inserter,
    cleanup: new CleanupCoordinator(),
    makeContext: (target): DictationContext | { error: { kind: "missingAPIKey"; provider: string } } => {
      const apiKey = options.apiKey ?? "test-key";
      if (!apiKey) return { error: { kind: "missingAPIKey", provider: provider.displayName } };
      return {
        target,
        transcription: { provider, config: { apiKey, model: "m", language: "ja" } },
        cleanup: {
          mode: options.cleanupEnabled ? "natural" : "raw",
          provider: null, // No cleanup key: falls back to the raw transcript.
          model: "m",
          customInstructions: "",
          language: "japanese",
        },
      };
    },
    minimumDurationMs: options.minimumDurationMs ?? 0,
    holdThresholdMs: options.holdThresholdMs ?? 0,
  });
  return { sut, provider, audio, inserter };
}

describe("DictationController", () => {
  it("starts recording on press and transcribes on release", async () => {
    const { sut, provider, audio, inserter } = setup();
    sut.handle("pressed", 0, slack);
    expect(sut.snapshot.phase.kind).toBe("recording");
    await audio.speak();
    await audio.speak();
    sut.handle("released", 10, slack);
    expect(sut.snapshot.phase.kind).toBe("processing");
    await sut.waitUntilIdle();

    const session = provider.sessions[0]!;
    expect(session.receivedBytes).toBe(640);
    expect(session.didFinish).toBe(true);
    expect(sut.snapshot.phase.kind).toBe("idle");
    expect(provider.lastConfig?.apiKey).toBe("test-key");
    expect(inserter.inserted).toEqual([{ text: transcript, target: slack }]);
  });

  it("pastes into the app in front when recording stops", async () => {
    const { sut, audio, inserter } = setup();
    sut.handle("pressed", 0, slack); // Reading something in Slack…
    await audio.speak();
    sut.handle("released", 10, mail); // …then moving to the reply before stopping.
    await sut.waitUntilIdle();
    expect(inserter.inserted[0]?.target).toEqual(mail);
  });

  it("keeps the starting app when its own window is in front at stop", async () => {
    const { sut, audio, inserter } = setup();
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 10, self);
    await sut.waitUntilIdle();
    expect(inserter.inserted[0]?.target).toEqual(slack);
  });

  it("explains a copied-only outcome", async () => {
    const { sut, audio, inserter } = setup();
    inserter.outcome = { kind: "copiedOnly", reason: "管理者として実行中のアプリには貼り付けできません" };
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 10, slack);
    await sut.waitUntilIdle();
    expect(sut.snapshot.phase).toEqual({
      kind: "error",
      message: "管理者として実行中のアプリには貼り付けできません。クリップボードにコピーしました",
    });
  });

  it("cancels a short tap", async () => {
    const { sut, provider, audio } = setup({ minimumDurationMs: 10_000 });
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 50, slack);
    expect(sut.snapshot.phase.kind).toBe("idle");
    await sut.waitUntilIdle();
    expect(provider.sessions[0]?.didCancel).toBe(true);
    expect(provider.sessions[0]?.didFinish).toBe(false);
  });

  it("measures the hold by event time, so a late release stays latched", async () => {
    const { sut } = setup({ holdThresholdMs: 200 });
    sut.handle("pressed", 1_000, slack);
    sut.handle("released", 1_050, slack);
    expect(sut.snapshot.phase.kind).toBe("recording");
    sut.handle("escape", 1_400, slack);
    await sut.waitUntilIdle();
  });

  it("handles the tick clock wrapping around", async () => {
    const { sut } = setup({ holdThresholdMs: 200 });
    sut.handle("pressed", 2 ** 32 - 100, slack);
    sut.handle("released", 50, slack); // 150 ms later: still a tap.
    expect(sut.snapshot.phase.kind).toBe("recording");
  });

  it("cancels on Esc, and ignores the late release", async () => {
    const { sut } = setup();
    sut.handle("pressed", 0, slack);
    sut.handle("escape", 5, slack);
    expect(sut.snapshot.phase.kind).toBe("idle");
    sut.handle("released", 10, slack);
    expect(sut.snapshot.phase.kind).toBe("idle");
  });

  it("keeps recording after a short tap until the next press", async () => {
    const { sut, provider, audio, inserter } = setup({ holdThresholdMs: 10_000 });
    sut.handle("pressed", 0, slack);
    sut.handle("released", 100, slack);
    expect(sut.snapshot.phase.kind).toBe("recording");
    await audio.speak();
    sut.handle("pressed", 3_000, slack);
    expect(sut.snapshot.phase.kind).toBe("processing");
    sut.handle("released", 3_100, slack); // The release after the stopping press is a no-op.
    await sut.waitUntilIdle();
    expect(provider.sessions[0]?.didFinish).toBe(true);
    expect(audio.startCount).toBe(1);
    expect(inserter.inserted).toHaveLength(1);
  });

  it("stops on release after a long hold", async () => {
    const { sut, audio, inserter } = setup({ holdThresholdMs: 400 });
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 900, slack);
    expect(sut.snapshot.phase.kind).toBe("processing");
    await sut.waitUntilIdle();
    expect(inserter.inserted).toHaveLength(1);
  });

  it("cancels an interrupted hold", () => {
    const { sut } = setup({ holdThresholdMs: 10_000 });
    sut.handle("pressed", 0, slack);
    sut.handle("interrupted", 10, slack);
    expect(sut.snapshot.phase.kind).toBe("idle");
  });

  it("ignores a press while processing", async () => {
    const { sut, audio } = setup();
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 10, slack);
    sut.handle("pressed", 20, slack);
    expect(audio.startCount).toBe(1);
    await sut.waitUntilIdle();
  });

  it("uses a separate session per dictation", async () => {
    const { sut, provider, audio } = setup();
    for (let i = 0; i < 3; i++) {
      sut.handle("pressed", i * 1_000, slack);
      await audio.speak();
      sut.handle("released", i * 1_000 + 10, slack);
      await sut.waitUntilIdle();
    }
    expect(provider.sessions).toHaveLength(3);
    expect(sut.snapshot.phase.kind).toBe("idle");
  });

  it("skips transcription when it hears only silence", async () => {
    const { sut, provider, audio, inserter } = setup();
    sut.handle("pressed", 0, slack);
    await audio.speak(0.0001);
    sut.handle("released", 10, slack);
    await sut.waitUntilIdle();
    expect(provider.sessions[0]?.didFinish).toBe(false);
    expect(sut.snapshot.phase.kind).toBe("idle");
    expect(inserter.inserted).toHaveLength(0);
  });

  it("shows a missing key without recording", () => {
    const { sut, audio } = setup({ apiKey: "" });
    sut.handle("pressed", 0, slack);
    expect(audio.startCount).toBe(0);
    expect(sut.snapshot.phase).toEqual({ kind: "error", message: "Mock の API Key が未設定です" });
  });

  it("shows a microphone failure", async () => {
    const { sut, audio } = setup();
    audio.failStart = true;
    sut.handle("pressed", 0, slack);
    await sut.waitUntilIdle();
    await Promise.resolve();
    expect(sut.snapshot.phase).toEqual({ kind: "error", message: "マイクを使用できません" });
  });

  it.each([
    [new TranscriptionError("network", "offline"), "ネットワークに接続できません"],
    [new TranscriptionError("timedOut"), "文字起こしがタイムアウトしました"],
    [new TranscriptionError("unauthorized"), "Mock の API Key が正しくありません"],
    [new TranscriptionError("server", "500"), "文字起こしに失敗しました"],
  ])("explains %s", async (error, message) => {
    const { sut, audio } = setup({ provider: new MockProvider(error) });
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 10, slack);
    await sut.waitUntilIdle();
    expect(sut.snapshot.phase).toEqual({ kind: "error", message });
  });

  it("shows nothing recognized for an empty transcript", async () => {
    const { sut, audio } = setup({ provider: new MockProvider("") });
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 10, slack);
    await sut.waitUntilIdle();
    expect(sut.snapshot.phase).toEqual({ kind: "error", message: "音声を認識できませんでした" });
  });

  it("still pastes the raw transcript when cleanup fails", async () => {
    const { sut, audio, inserter } = setup({ cleanupEnabled: true });
    sut.handle("pressed", 0, slack);
    await audio.speak();
    sut.handle("released", 10, slack);
    await sut.waitUntilIdle();
    expect(inserter.inserted.map((i) => i.text)).toEqual([transcript]);
    expect(sut.snapshot.phase).toEqual({
      kind: "error",
      message: "整形できなかったため、文字起こしをそのまま入力しました",
    });
  });
});
