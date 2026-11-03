// Settings that aren't secrets. API keys live in Windows Credential Manager (see `SecretAccount`).

import { cleanupModes, type CleanupMode } from "./cleanup/mode";
import { cleanupProviderInfo, cleanupProviderKinds, type CleanupProviderKind } from "./cleanup/provider";

export const triggers = ["rightCtrl", "convert", "nonConvert"] as const;
export type TriggerId = (typeof triggers)[number];

export const triggerInfo: Record<TriggerId, { name: string; note: string }> = {
  rightCtrl: { name: "右 Ctrl", note: "右 Ctrl だけを押したときに反応します。ほかのキーと一緒に押すとショートカットとして通ります。" },
  convert: { name: "変換", note: "日本語キーボードの変換キー。押しても IME の再変換は起きなくなります。" },
  nonConvert: { name: "無変換", note: "日本語キーボードの無変換キー。押しても IME の切り替えは起きなくなります。" },
};

export const languages = ["ja", "en"] as const;
export type Language = (typeof languages)[number];
export const languageNames: Record<Language, string> = { ja: "日本語", en: "English" };

export type SecretAccount = "soniox" | "anthropic" | "openai-compatible" | "gemini";

export interface Settings {
  trigger: TriggerId;
  /** Transcription language; also picks the cleanup prompt's language. */
  language: Language;
  sonioxModel: string;
  cleanupEnabled: boolean;
  cleanupMode: CleanupMode;
  customInstructions: string;
  cleanupProvider: CleanupProviderKind;
  /** Per provider; empty means the provider's default. */
  cleanupModels: Record<CleanupProviderKind, string>;
  openAIBaseURL: string;
}

export const defaultSettings: Settings = {
  trigger: "rightCtrl",
  language: "ja",
  sonioxModel: "stt-rt-v5",
  cleanupEnabled: true,
  cleanupMode: "natural",
  customInstructions: "",
  cleanupProvider: "anthropic",
  cleanupModels: { anthropic: "", "openai-compatible": "", gemini: "" },
  openAIBaseURL: "",
};

/** Settings read back from disk: unknown or invalid values fall back to the defaults. */
export function sanitizeSettings(value: unknown): Settings {
  const raw = (typeof value === "object" && value !== null ? value : {}) as Partial<Record<keyof Settings, unknown>>;
  const pick = <T>(candidate: unknown, allowed: readonly T[], fallback: T): T =>
    allowed.includes(candidate as T) ? (candidate as T) : fallback;
  const text = (candidate: unknown, fallback: string) => (typeof candidate === "string" ? candidate : fallback);
  const models = (typeof raw.cleanupModels === "object" && raw.cleanupModels !== null ? raw.cleanupModels : {}) as
    Record<string, unknown>;
  return {
    trigger: pick(raw.trigger, triggers, defaultSettings.trigger),
    language: pick(raw.language, languages, defaultSettings.language),
    sonioxModel: text(raw.sonioxModel, defaultSettings.sonioxModel) || defaultSettings.sonioxModel,
    cleanupEnabled: typeof raw.cleanupEnabled === "boolean" ? raw.cleanupEnabled : defaultSettings.cleanupEnabled,
    cleanupMode: pick(raw.cleanupMode, cleanupModes, defaultSettings.cleanupMode),
    customInstructions: text(raw.customInstructions, ""),
    cleanupProvider: pick(raw.cleanupProvider, cleanupProviderKinds, defaultSettings.cleanupProvider),
    cleanupModels: {
      anthropic: text(models.anthropic, ""),
      "openai-compatible": text(models["openai-compatible"], ""),
      gemini: text(models.gemini, ""),
    },
    openAIBaseURL: text(raw.openAIBaseURL, ""),
  };
}

/** The model cleanup uses: the user's choice, or the provider's default. */
export function cleanupModel(settings: Settings): string {
  return settings.cleanupModels[settings.cleanupProvider].trim() || cleanupProviderInfo[settings.cleanupProvider].defaultModel;
}

/** The Credential Manager account holding the key for a cleanup provider. Gemini's is shared with Gemini STT. */
export function secretAccount(kind: CleanupProviderKind): SecretAccount {
  return kind;
}
