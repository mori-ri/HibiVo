import { describe, expect, it } from "vitest";
import { pcm16Level } from "../src/core/audio";
import { makeContextBuilder } from "../src/core/dictation/context";
import type { FetchLike } from "../src/core/cleanup/provider";
import { cleanupModel, defaultSettings, sanitizeSettings, type Settings } from "../src/core/settings";
import { SonioxProvider } from "../src/core/transcription/soniox";

const noFetch: FetchLike = async () => ({ status: 500, text: async () => "" });

describe("Settings", () => {
  it("falls back to defaults for missing or invalid values", () => {
    expect(sanitizeSettings(undefined)).toEqual(defaultSettings);
    const settings = sanitizeSettings({ trigger: "fn", language: "en", cleanupMode: "business", cleanupEnabled: "yes" });
    expect(settings.trigger).toBe("rightCtrl");
    expect(settings.language).toBe("en");
    expect(settings.cleanupMode).toBe("business");
    expect(settings.cleanupEnabled).toBe(true);
  });

  it("uses the provider's default model unless one is set", () => {
    expect(cleanupModel(defaultSettings)).toBe("claude-haiku-4-5");
    const gemini: Settings = { ...defaultSettings, cleanupProvider: "gemini" };
    expect(cleanupModel(gemini)).toBe("gemini-3.5-flash-lite");
    expect(cleanupModel({ ...gemini, cleanupModels: { ...gemini.cleanupModels, gemini: " gemini-3.8-flash " } })).toBe(
      "gemini-3.8-flash",
    );
  });
});

describe("Dictation context", () => {
  const target = { hwnd: 1, pid: 2, name: "slack", isSelf: false };
  const build = (settings: Settings, secrets: Record<string, string>) =>
    makeContextBuilder({
      settings: () => settings,
      secret: (account) => secrets[account],
      transcription: new SonioxProvider(),
      fetch: noFetch,
    })(target);

  it("needs the Soniox key", () => {
    expect(build(defaultSettings, {})).toEqual({ error: { kind: "missingAPIKey", provider: "Soniox" } });
  });

  it("fixes the transcription and cleanup settings", () => {
    const context = build({ ...defaultSettings, language: "en", cleanupMode: "prompt" }, { soniox: "s", anthropic: "a" });
    if ("error" in context) throw new Error("expected a context");
    expect(context.target).toBe(target);
    expect(context.transcription.config).toEqual({ apiKey: "s", model: "stt-rt-v5", language: "en" });
    expect(context.cleanup.mode).toBe("prompt");
    expect(context.cleanup.language).toBe("english");
    expect(context.cleanup.provider?.id).toBe("anthropic");
  });

  it("skips cleanup when it is off, and has no provider without its key", () => {
    const off = build({ ...defaultSettings, cleanupEnabled: false }, { soniox: "s", anthropic: "a" });
    if ("error" in off) throw new Error("expected a context");
    expect(off.cleanup.mode).toBe("raw");
    const noKey = build(defaultSettings, { soniox: "s" });
    if ("error" in noKey) throw new Error("expected a context");
    expect(noKey.cleanup.provider).toBeNull();
  });
});

describe("pcm16Level", () => {
  it("is 0 for silence and about 0.5 for a half-scale square wave", () => {
    expect(pcm16Level(new Uint8Array(320))).toBe(0);
    const samples = new Int16Array(160).map((_, i) => (i % 2 === 0 ? 16384 : -16384));
    expect(pcm16Level(new Uint8Array(samples.buffer))).toBeCloseTo(0.5, 2);
    // Works on a view that doesn't start at the beginning of its buffer.
    const offset = new Uint8Array(new ArrayBuffer(322), 1, 320);
    expect(pcm16Level(offset)).toBe(0);
  });
});
