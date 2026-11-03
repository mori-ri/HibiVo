// Fixes everything one utterance needs when recording starts. Port of DictationContextBuilder.swift.

import { promptLanguageFor } from "../cleanup/mode";
import { makeCleanupProvider, type FetchLike } from "../cleanup/provider";
import { cleanupModel, secretAccount, type SecretAccount, type Settings } from "../settings";
import type { TranscriptionProvider } from "../transcription/types";
import type { ContextBuilder } from "./types";

export function makeContextBuilder(deps: {
  settings: () => Settings;
  secret: (account: SecretAccount) => string | undefined;
  transcription: TranscriptionProvider;
  fetch: FetchLike;
}): ContextBuilder {
  return (target) => {
    const settings = deps.settings();
    const apiKey = deps.secret("soniox");
    if (!apiKey) return { error: { kind: "missingAPIKey", provider: deps.transcription.displayName } };

    const kind = settings.cleanupProvider;
    const cleanupKey = deps.secret(secretAccount(kind));
    return {
      target,
      transcription: {
        provider: deps.transcription,
        config: { apiKey, model: settings.sonioxModel, language: settings.language },
      },
      cleanup: {
        mode: settings.cleanupEnabled ? settings.cleanupMode : "raw",
        provider: cleanupKey
          ? makeCleanupProvider(kind, { apiKey: cleanupKey, baseURL: settings.openAIBaseURL.trim() }, deps.fetch)
          : null,
        model: cleanupModel(settings),
        customInstructions: settings.customInstructions,
        language: promptLanguageFor(settings.language),
      },
    };
  };
}
