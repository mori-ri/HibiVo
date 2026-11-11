// Runs one cleanup with a hard timeout and falls back to the raw transcript on any problem.
// Cleanup must never cost the user their utterance. Port of CleanupCoordinator.swift.

import { charCount } from "../text";
import type { CleanupMode, PromptLanguage } from "./mode";
import { validateCleanupOutput } from "./outputGuard";
import { systemPrompt, userMessage, type PromptTerm } from "./promptBuilder";
import { CleanupError, type CleanupErrorCode, type TextCleanupProvider, type TokenUsage } from "./provider";
import { trimTrailingPeriod } from "./trailingPeriod";

export interface CleanupFailure {
  code: CleanupErrorCode;
  status?: number;
}

export interface CleanupOutcome {
  /** What should be pasted: the cleaned text, or the raw transcript as a fallback. */
  text: string;
  didCleanup: boolean;
  /** Set when cleanup was attempted and failed; the raw transcript is used instead. */
  failure: CleanupFailure | null;
  /** Tokens billed for the request, even when its output was rejected. */
  usage?: TokenUsage;
}

export interface CleanupRequest {
  raw: string;
  mode: CleanupMode;
  vocabulary?: PromptTerm[];
  appName?: string | null;
  /** Used only by `custom`. */
  customInstructions?: string;
  language?: PromptLanguage;
}

/** 1 s per 50 characters: well under typical output speeds, so only a stalled request hits the limit. */
const timeoutPerCharacterMs = 20;

export class CleanupCoordinator {
  readonly maxTimeoutMs: number;

  /** @param baseTimeoutMs Time allowed for an empty transcript; each character adds 20 ms. */
  constructor(
    readonly baseTimeoutMs = 5_000,
    maxTimeoutMs = 30_000,
  ) {
    this.maxTimeoutMs = Math.max(baseTimeoutMs, maxTimeoutMs);
  }

  /** The model has to write roughly as much as it reads, so the deadline grows with the transcript. */
  timeoutFor(raw: string): number {
    return Math.min(this.maxTimeoutMs, this.baseTimeoutMs + timeoutPerCharacterMs * charCount(raw));
  }

  /** @param provider null when the selected provider has no credentials configured. */
  async run(request: CleanupRequest, provider: TextCleanupProvider | null, model: string): Promise<CleanupOutcome> {
    const raw = request.raw;
    if (request.mode === "raw") return { text: raw, didCleanup: false, failure: null };
    if (!provider) return fallback(raw, { code: "missingAPIKey" });
    if (!model) return fallback(raw, { code: "missingModel" });

    const system = systemPrompt({
      mode: request.mode,
      customInstructions: request.customInstructions,
      vocabulary: request.vocabulary,
      appName: request.appName,
      language: request.language,
    });
    const user = userMessage(raw);

    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new CleanupError("timedOut"));
      }, this.timeoutFor(raw));
    });
    try {
      const output = await Promise.race([provider.complete(system, user, model, controller.signal), deadline]);
      const text = validateCleanupOutput(output.text, raw, request.mode);
      if (text === null) return fallback(raw, { code: "rejectedByGuard" }, output.usage);
      return { text, didCleanup: true, failure: null, usage: output.usage };
    } catch (error) {
      if (error instanceof CleanupError) return fallback(raw, { code: error.code, status: error.status });
      console.error("Cleanup failed", error);
      return fallback(raw, { code: "invalidResponse" });
    } finally {
      clearTimeout(timer);
    }
  }

  /** What dictation does with a finished transcript: clean up, then drop the period after a lone word. */
  async runForDictation(
    request: CleanupRequest,
    provider: TextCleanupProvider | null,
    model: string,
  ): Promise<CleanupOutcome> {
    const outcome = await this.run(request, provider, model);
    return { ...outcome, text: trimTrailingPeriod(outcome.text) };
  }
}

function fallback(raw: string, failure: CleanupFailure, usage?: TokenUsage): CleanupOutcome {
  console.info(`Cleanup fell back to raw transcript: ${failure.code}${failure.status ? ` ${failure.status}` : ""}`);
  return { text: raw, didCleanup: false, failure, usage };
}
