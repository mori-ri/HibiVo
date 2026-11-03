// Ported from the macOS app's Tests/HibiVoKitTests/CleanupTests.swift.

import { describe, expect, it } from "vitest";
import { CleanupCoordinator } from "../src/core/cleanup/coordinator";
import { cleanupModes, customInstructionsLimit, promptLanguageFor } from "../src/core/cleanup/mode";
import { validateCleanupOutput } from "../src/core/cleanup/outputGuard";
import { systemPrompt, userMessage } from "../src/core/cleanup/promptBuilder";
import {
  AnthropicCleanupProvider,
  CleanupError,
  GeminiCleanupProvider,
  OpenAICompatibleCleanupProvider,
  type FetchLike,
  type TextCleanupProvider,
} from "../src/core/cleanup/provider";
import { trimTrailingPeriod } from "../src/core/cleanup/trailingPeriod";

class MockCleanupProvider implements TextCleanupProvider {
  readonly id = "anthropic" as const;
  readonly displayName = "Mock LLM";
  calls = 0;
  constructor(
    private readonly result: string | CleanupError,
    private readonly delayMs = 0,
  ) {}
  async complete(_system: string, _user: string, _model: string, signal?: AbortSignal) {
    this.calls++;
    if (this.delayMs > 0)
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(resolve, this.delayMs);
        signal?.addEventListener("abort", () => {
          clearTimeout(timer);
          reject(new Error("aborted"));
        });
      });
    if (this.result instanceof CleanupError) throw this.result;
    return { text: this.result };
  }
}

describe("CleanupPromptBuilder", () => {
  it("includes mode rules, vocabulary and app", () => {
    const prompt = systemPrompt({
      mode: "business",
      vocabulary: [{ preferred: "AppSync", spokenForms: ["アップシンク"] }, { preferred: "Bedrock" }],
      appName: "Gmail",
    });
    expect(prompt).toContain("モード: Business");
    expect(prompt).toContain("- AppSync（聞き取り例: アップシンク）");
    expect(prompt).toContain("- Bedrock");
    expect(prompt).toContain("Gmail");
    expect(prompt).toContain("言っていない情報を足さない");
  });

  it("asks for context on contextual forms", () => {
    const prompt = systemPrompt({
      mode: "natural",
      vocabulary: [
        { preferred: "AI", contextualForms: ["あい"] },
        { preferred: "Siri", spokenForms: ["シリちゃん"], contextualForms: ["シリ"] },
      ],
    });
    expect(prompt).toContain(
      "- AI（読み: あい。同じ読みの一般的な言葉もあるため、文脈上この語を指すときだけこの表記にし、それ以外は変えない）",
    );
    expect(prompt).toContain("- Siri（聞き取り例: シリちゃん。読み: シリ。");
  });

  it.each(cleanupModes)("forbids adding meaning in %s mode", (mode) => {
    const prompt = systemPrompt({ mode });
    expect(prompt).toContain("整形した文章だけを返す");
    expect(prompt).not.toContain("ユーザー辞書");
  });

  it("keeps the prompt mode from inventing requirements", () => {
    const prompt = systemPrompt({ mode: "prompt" });
    expect(prompt).toContain("ユーザーが言っていない要件");
    expect(prompt).toContain("語尾・口調は変えない");
    expect(prompt).toContain("\n- 「えー」");
  });

  it("adds the user's instructions in custom mode", () => {
    const prompt = systemPrompt({ mode: "custom", customInstructions: "  英語に翻訳する  \n" });
    expect(prompt).toContain("モード: Custom");
    expect(prompt).toContain("<instructions>\n英語に翻訳する\n</instructions>");
    expect(prompt).toContain("\n- 「えー」");
    expect(prompt).toContain("言っていない情報を足さない");
  });

  it("uses custom instructions only in custom mode, capped", () => {
    expect(systemPrompt({ mode: "natural", customInstructions: "英語に翻訳する" })).not.toContain("英語に翻訳する");
    expect(systemPrompt({ mode: "custom", customInstructions: " \n" })).not.toContain("<instructions>");
    const long = "あ".repeat(customInstructionsLimit + 50);
    const capped = systemPrompt({ mode: "custom", customInstructions: long });
    expect(capped).toContain("あ".repeat(customInstructionsLimit) + "\n</instructions>");
    expect(capped).not.toContain("あ".repeat(customInstructionsLimit + 1));
  });

  it("keeps business wording and breaks lines", () => {
    const business = systemPrompt({ mode: "business" });
    expect(business).toContain("言い回し・語順・語尾は話者のまま残し");
    expect(business).toContain("本文は 1 文ごとに改行");
    expect(business).toContain("「聞いた」→「伺った」");
    expect(systemPrompt({ mode: "natural" })).not.toContain("1 文ごとに改行");
  });

  it("gives English transcription the English prompt", () => {
    expect(promptLanguageFor("en")).toBe("english");
    expect(promptLanguageFor("ja")).toBe("japanese");
    const prompt = systemPrompt({
      mode: "business",
      vocabulary: [
        { preferred: "AppSync", spokenForms: ["アップシンク"] },
        { preferred: "AI", contextualForms: ["あい"] },
      ],
      appName: "Gmail",
      language: "english",
    });
    expect(prompt).toContain("Mode: Business");
    expect(prompt).toContain("Write in the language the user spoke");
    expect(prompt).toContain("- AppSync (sounds like: アップシンク)");
    expect(prompt).toContain("- AI (reading: あい. Everyday words share this reading");
    expect(prompt).toContain("The text will be entered into Gmail");
    expect(prompt).not.toContain("謙譲語");
    expect(prompt).not.toContain("整形した文章だけを返す");
  });

  it.each(cleanupModes)("forbids adding meaning in English %s mode", (mode) => {
    const prompt = systemPrompt({ mode, customInstructions: "Translate into French", language: "english" });
    expect(prompt).toContain("Return only the cleaned-up text");
    expect(prompt).toContain("Do not add anything they did not say");
    expect(prompt.includes("<instructions>")).toBe(mode === "custom");
  });

  it("wraps the transcript", () => {
    expect(userMessage("送って")).toBe("<transcript>\n送って\n</transcript>");
  });
});

describe("CleanupOutputGuard", () => {
  const raw = "えーっと、明日の、いや明後日の会議なんだけど、田中さんに3時からで大丈夫ですかって送って";

  it("accepts normal cleanup", () => {
    const out = "田中さん、明後日の15時からの会議で問題ないでしょうか？";
    expect(validateCleanupOutput(out, raw, "business")).toBe(out);
  });

  it("strips thinking tags and preamble", () => {
    const out = "<think>考え中</think>以下が整形後の文章です：\n明後日の会議の件です。";
    expect(validateCleanupOutput(out, raw, "natural")).toBe("明後日の会議の件です。");
  });

  it("strips transcript tags and code fence", () => {
    expect(validateCleanupOutput("<transcript>\nこんにちは\n</transcript>", "こんにちは", "natural")).toBe("こんにちは");
    expect(validateCleanupOutput("```\nこんにちは\n```", "こんにちは", "natural")).toBe("こんにちは");
  });

  it("rejects empty output", () => {
    expect(validateCleanupOutput("  \n", raw, "natural")).toBeNull();
  });

  it("rejects an answer far longer than the input", () => {
    const answer = "AppSync は AWS のマネージド GraphQL サービスで、".repeat(10);
    expect(validateCleanupOutput(answer, "AppSyncって何？", "natural")).toBeNull();
  });

  it("rejects output that drops most of a long input", () => {
    expect(validateCleanupOutput("了解。", raw, "natural")).toBeNull();
  });

  it("lets custom mode shorten a lot", () => {
    const long = "明日の会議では予算とスケジュールについて話します。".repeat(4);
    expect(validateCleanupOutput("- 予算", long, "natural")).toBeNull();
    expect(validateCleanupOutput("- 予算", long, "custom")).toBe("- 予算");
  });

  it("allows short input to shrink", () => {
    expect(validateCleanupOutput("はい。", "えーと、はい", "natural")).toBe("はい。");
  });
});

describe("CleanupCoordinator", () => {
  const request = (mode: (typeof cleanupModes)[number] = "natural") => ({
    raw: "えーと今日の15時からAWSのAppSyncについて打ち合わせをします",
    mode,
    appName: "Slack",
  });

  it("returns cleaned text", async () => {
    const provider = new MockCleanupProvider("今日の15時から、AWSのAppSyncについて打ち合わせをします。");
    const out = await new CleanupCoordinator().run(request(), provider, "m");
    expect(out).toEqual({
      text: "今日の15時から、AWSのAppSyncについて打ち合わせをします。",
      didCleanup: true,
      failure: null,
      usage: undefined,
    });
  });

  it("skips the provider in raw mode", async () => {
    const provider = new MockCleanupProvider(new CleanupError("http", 500));
    const out = await new CleanupCoordinator().run(request("raw"), provider, "m");
    expect(out.text).toBe(request().raw);
    expect(out.failure).toBeNull();
    expect(provider.calls).toBe(0);
  });

  it.each([
    new CleanupError("http", 500),
    new CleanupError("unauthorized"),
    new CleanupError("refused"),
    new CleanupError("invalidResponse"),
  ])("falls back to raw on %s", async (error) => {
    const out = await new CleanupCoordinator().run(request(), new MockCleanupProvider(error), "m");
    expect(out.text).toBe(request().raw);
    expect(out.didCleanup).toBe(false);
    expect(out.failure).toEqual({ code: error.code, status: error.status });
  });

  it("falls back to raw on timeout", async () => {
    const start = performance.now();
    const out = await new CleanupCoordinator(100, 100).run(request(), new MockCleanupProvider("遅い", 5_000), "m");
    expect(out.failure?.code).toBe("timedOut");
    expect(out.text).toBe(request().raw);
    expect(performance.now() - start).toBeLessThan(1_000);
  });

  it("grows the timeout with transcript length", () => {
    const coordinator = new CleanupCoordinator();
    expect(coordinator.timeoutFor("")).toBe(5_000);
    expect(coordinator.timeoutFor("あ".repeat(500))).toBe(15_000);
    expect(coordinator.timeoutFor("あ".repeat(5_000))).toBe(30_000);
  });

  it("gives a long transcript more than the base timeout", async () => {
    const raw = "今日は打ち合わせをします。".repeat(20);
    const out = await new CleanupCoordinator(100).run(
      { raw, mode: "natural" },
      new MockCleanupProvider(raw, 300),
      "m",
    );
    expect(out.didCleanup).toBe(true);
  });

  it("falls back to raw without a provider or model", async () => {
    expect((await new CleanupCoordinator().run(request(), null, "m")).failure?.code).toBe("missingAPIKey");
    expect((await new CleanupCoordinator().run(request(), new MockCleanupProvider("x"), "")).failure?.code).toBe(
      "missingModel",
    );
  });

  it("falls back to raw when the guard rejects the output", async () => {
    const out = await new CleanupCoordinator().run(request(), new MockCleanupProvider("あ".repeat(500)), "m");
    expect(out.failure?.code).toBe("rejectedByGuard");
  });

  it("drops the period after a lone word on the dictation path", async () => {
    const coordinator = new CleanupCoordinator();
    const raw = await coordinator.runForDictation({ raw: "AppSync。", mode: "raw" }, null, "m");
    expect(raw.text).toBe("AppSync");
    const cleaned = await coordinator.runForDictation(
      { raw: "えーとアップシンク", mode: "natural" },
      new MockCleanupProvider("AppSync。"),
      "m",
    );
    expect(cleaned.text).toBe("AppSync");
    expect(cleaned.didCleanup).toBe(true);
  });
});

describe("TrailingPeriod", () => {
  it.each([
    ["AppSync。", "AppSync"],
    ["会議資料。", "会議資料"],
    ["AWS Lambda。", "AWS Lambda"],
    ["Lambda.", "Lambda"],
    ["テスト。\n", "テスト"],
    ["会議の資料。", "会議の資料"],
    ["お客様。", "お客様"],
  ])("drops the period after %s", (input, expected) => {
    expect(trimTrailingPeriod(input)).toBe(expected);
  });

  it.each([
    "了解しました。",
    "ありがとう。",
    "明日、会議資料。",
    "資料を確認。次は会議。",
    "This is Lambda.",
    "3.14.",
    "本日の議題は来期の予算計画と人員配置の見直しについて。",
    "改行\nあり。",
    "AppSync",
    "次回は来週。",
    "今日は雨。",
    "東京で開催。",
  ])("keeps the sentence %s", (input) => {
    expect(trimTrailingPeriod(input)).toBe(input);
  });
});

describe("Cleanup provider wire format", () => {
  it("shapes the Anthropic request by model", () => {
    const haiku = AnthropicCleanupProvider.makeRequest("s", "u", "claude-haiku-4-5");
    expect(haiku.output_config).toBeUndefined();
    expect(haiku.fallbacks).toBeUndefined();
    const haiku55 = AnthropicCleanupProvider.makeRequest("s", "u", "claude-haiku-5-5");
    expect(haiku55.output_config).toEqual({ effort: "low" });
    expect(haiku55.fallbacks).toBeUndefined();
    for (const model of ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]) {
      expect(AnthropicCleanupProvider.makeRequest("s", "u", model).fallbacks).toBe("default");
    }
    expect(AnthropicCleanupProvider.makeRequest("s", "u", "claude-sonnet-4-5").fallbacks).toBeUndefined();
  });

  it("sends the Anthropic beta header only with fallbacks", async () => {
    const sent: Record<string, string>[] = [];
    const fetch: FetchLike = async (_url, init) => {
      sent.push(init.headers);
      return { status: 200, text: async () => JSON.stringify({ content: [{ type: "text", text: "ok" }] }) };
    };
    await new AnthropicCleanupProvider("k", fetch).complete("s", "u", "claude-opus-5");
    await new AnthropicCleanupProvider("k", fetch).complete("s", "u", "claude-haiku-4-5");
    expect(sent[0]?.["anthropic-beta"]).toBe("server-side-fallback-2026-07-01");
    expect(sent[1]?.["anthropic-beta"]).toBeUndefined();
    expect(sent[1]?.["x-api-key"]).toBe("k");
  });

  it("parses Anthropic text and skips thinking blocks", () => {
    const out = AnthropicCleanupProvider.parse(
      JSON.stringify({
        content: [
          { type: "thinking", thinking: "…" },
          { type: "text", text: "整形済み" },
        ],
        stop_reason: "end_turn",
        usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 2 },
      }),
    );
    expect(out).toEqual({ text: "整形済み", usage: { input: 12, output: 5 }, truncated: false });
  });

  it("throws on an Anthropic refusal", () => {
    expect(() => AnthropicCleanupProvider.parse(JSON.stringify({ content: [], stop_reason: "refusal" }))).toThrow(
      CleanupError,
    );
  });

  it("parses the first OpenAI choice", () => {
    const out = OpenAICompatibleCleanupProvider.parse(
      JSON.stringify({
        choices: [{ message: { content: "整形済み" }, finish_reason: "length" }],
        usage: { prompt_tokens: 3, completion_tokens: 4 },
      }),
    );
    expect(out).toEqual({ text: "整形済み", usage: { input: 3, output: 4 }, truncated: true });
  });

  it("posts OpenAI-compatible requests under the base URL", async () => {
    const urls: string[] = [];
    const fetch: FetchLike = async (url) => {
      urls.push(url);
      return { status: 200, text: async () => JSON.stringify({ choices: [{ message: { content: "ok" } }] }) };
    };
    await new OpenAICompatibleCleanupProvider("https://example.com/v1/", "k", fetch).complete("s", "u", "m");
    expect(urls).toEqual(["https://example.com/v1/chat/completions"]);
  });

  it("maps HTTP errors", async () => {
    const respond =
      (status: number, body = "{}"): FetchLike =>
      async () => ({ status, text: async () => body });
    await expect(new AnthropicCleanupProvider("k", respond(401)).complete("s", "u", "m")).rejects.toMatchObject({
      code: "unauthorized",
    });
    await expect(new AnthropicCleanupProvider("k", respond(529)).complete("s", "u", "m")).rejects.toMatchObject({
      code: "http",
      status: 529,
    });
    await expect(
      new GeminiCleanupProvider("k", respond(400, '{"error":{"status":"API_KEY_INVALID"}}')).complete("s", "u", "m"),
    ).rejects.toMatchObject({ code: "unauthorized" });
  });

  it("shapes and parses Gemini interactions", () => {
    expect(GeminiCleanupProvider.makeRequest("s", "u", "gemini-3.5-flash-lite")).toEqual({
      model: "gemini-3.5-flash-lite",
      input: "u",
      system_instruction: "s",
      store: false,
      generation_config: { thinking_level: "low" },
    });
    expect(GeminiCleanupProvider.makeRequest("s", "u", "gemini-2.5-flash")).not.toHaveProperty("generation_config");
    const out = GeminiCleanupProvider.parse(
      JSON.stringify({
        steps: [
          { type: "thought", content: [{ type: "text", text: "x" }] },
          { type: "model_output", content: [{ type: "text", text: "整形済み" }] },
        ],
        usage: { total_input_tokens: 5, total_output_tokens: 2, total_thought_tokens: 3 },
      }),
    );
    expect(out).toEqual({ text: "整形済み", usage: { input: 5, output: 5 } });
  });
});
