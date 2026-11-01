// Cleanup providers: an LLM that rewrites text from one system + user message.
// Ports of the macOS app's Anthropic, OpenAI-compatible and Gemini providers.

export type CleanupErrorCode =
  | "missingAPIKey"
  | "missingModel"
  | "unauthorized"
  | "http"
  | "refused"
  | "invalidResponse"
  | "rejectedByGuard"
  | "timedOut";

export class CleanupError extends Error {
  constructor(
    readonly code: CleanupErrorCode,
    readonly status?: number,
  ) {
    super(status === undefined ? code : `${code}(${status})`);
    this.name = "CleanupError";
  }
}

export interface TokenUsage {
  input: number;
  output: number;
}

export interface CleanupCompletion {
  text: string;
  usage?: TokenUsage;
  /** True when the model stopped at the output cap, so `text` is cut off. */
  truncated?: boolean;
}

export interface TextCleanupProvider {
  readonly id: CleanupProviderKind;
  readonly displayName: string;
  complete(system: string, user: string, model: string, signal?: AbortSignal): Promise<CleanupCompletion>;
}

/** The subset of `fetch` the providers use, so the app can pass Tauri's HTTP client and tests a fake. */
export type FetchLike = (
  url: string,
  init: { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal },
) => Promise<{ status: number; text(): Promise<string> }>;

export const cleanupProviderKinds = ["anthropic", "openai-compatible", "gemini"] as const;
export type CleanupProviderKind = (typeof cleanupProviderKinds)[number];

export const cleanupProviderInfo: Record<CleanupProviderKind, { name: string; defaultModel: string }> = {
  anthropic: { name: "Anthropic (Claude)", defaultModel: "claude-haiku-4-5" },
  "openai-compatible": { name: "OpenAI 互換", defaultModel: "" },
  gemini: { name: "Google Gemini", defaultModel: "gemini-3.5-flash-lite" },
};

export const openAIDefaultBaseURL = "https://api.openai.com/v1";

export interface ProviderCredentials {
  apiKey: string;
  /** OpenAI-compatible only. */
  baseURL?: string;
}

export function makeCleanupProvider(
  kind: CleanupProviderKind,
  credentials: ProviderCredentials,
  fetch: FetchLike,
): TextCleanupProvider {
  switch (kind) {
    case "anthropic":
      return new AnthropicCleanupProvider(credentials.apiKey, fetch);
    case "openai-compatible":
      return new OpenAICompatibleCleanupProvider(credentials.baseURL || openAIDefaultBaseURL, credentials.apiKey, fetch);
    case "gemini":
      return new GeminiCleanupProvider(credentials.apiKey, fetch);
  }
}

// MARK: - HTTP

async function postJSON(
  fetch: FetchLike,
  url: string,
  headers: Record<string, string>,
  body: unknown,
  signal?: AbortSignal,
): Promise<{ status: number; body: string }> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
    signal,
  });
  return { status: response.status, body: await response.text() };
}

function checkStatus(status: number, body: string): void {
  if (status >= 200 && status < 300) return;
  // The status code alone rarely says what to fix, so keep the provider's message in the log.
  const message = errorMessage(body);
  if (message) console.warn(`Cleanup HTTP ${status}: ${message}`);
  if (status === 401 || status === 403) throw new CleanupError("unauthorized");
  throw new CleanupError("http", status);
}

/** The `message` of an error body: top-level or under `error`. Describes the request, not its content. */
function errorMessage(body: string): string | null {
  try {
    const json = JSON.parse(body) as { message?: unknown; error?: { message?: unknown } };
    const message = typeof json.message === "string" ? json.message : json.error?.message;
    return typeof message === "string" ? message.slice(0, 300) : null;
  } catch {
    return null;
  }
}

function parseJSON<T>(body: string): T {
  try {
    return JSON.parse(body) as T;
  } catch {
    throw new CleanupError("invalidResponse");
  }
}

function joinURL(base: string, path: string): string {
  return base.replace(/\/+$/, "") + "/" + path;
}

// MARK: - Anthropic

interface AnthropicRequest {
  model: string;
  max_tokens: number;
  system: string;
  messages: { role: "user"; content: string }[];
  output_config?: { effort: string };
  fallbacks?: string;
}

export class AnthropicCleanupProvider implements TextCleanupProvider {
  readonly id = "anthropic" as const;
  readonly displayName = cleanupProviderInfo.anthropic.name;
  static readonly endpoint = "https://api.anthropic.com/v1/messages";

  constructor(
    private readonly apiKey: string,
    private readonly fetch: FetchLike,
  ) {}

  static makeRequest(system: string, user: string, model: string): AnthropicRequest {
    const marker = model.indexOf("anthropic.");
    const name = marker >= 0 ? model.slice(marker + "anthropic.".length) : model;
    // Haiku 4.5 rejects effort; Haiku 5.5 takes it (and defaults to medium, so low is worth sending).
    const supportsEffort = !name.startsWith("claude-haiku-4");
    // Server-side fallback when a safety classifier declines (Opus 5 and later, Fable 5, Sonnet 5.5).
    const supportsFallbacks = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5-5"].some((p) => name.startsWith(p));
    const request: AnthropicRequest = {
      model,
      max_tokens: 4_000,
      system,
      messages: [{ role: "user", content: user }],
    };
    // Cleanup is a light rewrite; low effort keeps latency down on models that think adaptively.
    if (supportsEffort) request.output_config = { effort: "low" };
    if (supportsFallbacks) request.fallbacks = "default";
    return request;
  }

  async complete(system: string, user: string, model: string, signal?: AbortSignal): Promise<CleanupCompletion> {
    const body = AnthropicCleanupProvider.makeRequest(system, user, model);
    const headers: Record<string, string> = { "x-api-key": this.apiKey, "anthropic-version": "2023-06-01" };
    if (body.fallbacks !== undefined) headers["anthropic-beta"] = "server-side-fallback-2026-07-01";
    const response = await postJSON(this.fetch, AnthropicCleanupProvider.endpoint, headers, body, signal);
    checkStatus(response.status, response.body);
    return AnthropicCleanupProvider.parse(response.body);
  }

  static parse(body: string): CleanupCompletion {
    const response = parseJSON<{
      content?: { type: string; text?: string }[];
      stop_reason?: string;
      usage?: {
        input_tokens: number;
        output_tokens: number;
        cache_creation_input_tokens?: number;
        cache_read_input_tokens?: number;
      };
    }>(body);
    if (response.stop_reason === "refusal") throw new CleanupError("refused");
    const text = (response.content ?? [])
      .filter((block) => block.type === "text")
      .map((block) => block.text ?? "")
      .join("");
    if (!text) throw new CleanupError("invalidResponse");
    const usage = response.usage;
    return {
      text,
      usage: usage && {
        input:
          usage.input_tokens + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0),
        output: usage.output_tokens,
      },
      truncated: response.stop_reason === "max_tokens",
    };
  }
}

// MARK: - OpenAI compatible

/** Any `/chat/completions` endpoint: OpenAI, Groq, OpenRouter, an in-house gateway, etc. */
export class OpenAICompatibleCleanupProvider implements TextCleanupProvider {
  readonly id = "openai-compatible" as const;
  readonly displayName = cleanupProviderInfo["openai-compatible"].name;

  constructor(
    private readonly baseURL: string,
    private readonly apiKey: string,
    private readonly fetch: FetchLike,
  ) {}

  async complete(system: string, user: string, model: string, signal?: AbortSignal): Promise<CleanupCompletion> {
    // No output cap is sent: endpoints disagree on its name and reject the one they don't know.
    const body = {
      model,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      temperature: 0,
    };
    const response = await postJSON(
      this.fetch,
      joinURL(this.baseURL, "chat/completions"),
      { Authorization: `Bearer ${this.apiKey}` },
      body,
      signal,
    );
    checkStatus(response.status, response.body);
    return OpenAICompatibleCleanupProvider.parse(response.body);
  }

  static parse(body: string): CleanupCompletion {
    const response = parseJSON<{
      choices?: { message?: { content?: string | null }; finish_reason?: string }[];
      usage?: { prompt_tokens: number; completion_tokens: number };
    }>(body);
    const choice = response.choices?.[0];
    const text = choice?.message?.content;
    if (!text) throw new CleanupError("invalidResponse");
    return {
      text,
      usage: response.usage && { input: response.usage.prompt_tokens, output: response.usage.completion_tokens },
      truncated: choice.finish_reason === "length",
    };
  }
}

// MARK: - Gemini

/** Gemini via the Interactions API (POST /v1beta/interactions). */
export class GeminiCleanupProvider implements TextCleanupProvider {
  readonly id = "gemini" as const;
  readonly displayName = cleanupProviderInfo.gemini.name;
  static readonly endpoint = "https://generativelanguage.googleapis.com/v1beta/interactions";

  constructor(
    private readonly apiKey: string,
    private readonly fetch: FetchLike,
  ) {}

  static makeRequest(system: string, user: string, model: string) {
    return {
      model,
      input: user,
      system_instruction: system,
      // Dictated text must not be kept server-side for later retrieval.
      store: false,
      // Cleanup is a light rewrite, so keep thinking low. Pre-3 models don't take `thinking_level` at all.
      ...(model.startsWith("gemini-3") ? { generation_config: { thinking_level: "low" } } : {}),
    };
  }

  async complete(system: string, user: string, model: string, signal?: AbortSignal): Promise<CleanupCompletion> {
    const response = await postJSON(
      this.fetch,
      GeminiCleanupProvider.endpoint,
      { "x-goog-api-key": this.apiKey },
      GeminiCleanupProvider.makeRequest(system, user, model),
      signal,
    );
    // A bad key comes back as 400 API_KEY_INVALID rather than 401.
    if (response.status === 400 && response.body.includes("API_KEY_INVALID")) throw new CleanupError("unauthorized");
    checkStatus(response.status, response.body);
    return GeminiCleanupProvider.parse(response.body);
  }

  static parse(body: string): CleanupCompletion {
    const response = parseJSON<{
      steps?: { type: string; content?: { type: string; text?: string }[] }[];
      usage?: { total_input_tokens?: number; total_output_tokens?: number; total_thought_tokens?: number };
    }>(body);
    const text = (response.steps ?? [])
      .filter((step) => step.type === "model_output")
      .flatMap((step) => step.content ?? [])
      .filter((content) => content.type === "text")
      .map((content) => content.text ?? "")
      .join("");
    if (!text) throw new CleanupError("invalidResponse");
    const usage = response.usage;
    return {
      text,
      // Thinking tokens are billed at the output rate.
      usage: usage && {
        input: usage.total_input_tokens ?? 0,
        output: (usage.total_output_tokens ?? 0) + (usage.total_thought_tokens ?? 0),
      },
    };
  }
}
