export const cleanupModes = ["raw", "natural", "business", "prompt", "custom"] as const;
export type CleanupMode = (typeof cleanupModes)[number];

/**
 * Most characters the custom instructions may have. Keeps the system prompt, sent with every utterance, small:
 * about as long as the longest built-in mode's own rules (Business, ~460 characters).
 */
export const customInstructionsLimit = 500;

export const cleanupModeInfo: Record<CleanupMode, { name: string; summary: string }> = {
  raw: {
    name: "Raw（そのまま）",
    summary: "AI を使わず、文字起こしの結果をそのまま入力します。フィラーや言い直しも残ります。",
  },
  natural: {
    name: "Natural（自然な文章）",
    summary: "フィラーと言い直しを除き、話した口調のまま読みやすく整えます。",
  },
  business: {
    name: "Business（丁寧な文章）",
    summary: "敬語に直し、メールやチャットでそのまま送れる丁寧な文章にします。",
  },
  prompt: {
    name: "Prompt（AI への指示）",
    summary: "AI への指示として整えます。口調は変えず、列挙した項目は箇条書きにします。",
  },
  custom: {
    name: "Custom（カスタム指示）",
    summary: "Natural と同じ基本の整形に加えて、設定に書いた指示に従います。",
  },
};

/**
 * Which prompts cleanup uses, chosen by the transcription language in Settings.
 * Japanese keeps a prompt written in Japanese: an English prompt cleaned Japanese up less faithfully in evals.
 */
export type PromptLanguage = "japanese" | "english";

/** @param transcriptionLanguage The setting's language code, e.g. "ja" or "en". */
export function promptLanguageFor(transcriptionLanguage: string): PromptLanguage {
  return transcriptionLanguage === "en" ? "english" : "japanese";
}
