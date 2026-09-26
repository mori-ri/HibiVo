import Foundation
import Testing

@testable import HibiVoKit

struct MockCleanupProvider: TextCleanupProvider {
    let id = "mock-llm"
    let displayName = "Mock LLM"
    let defaultModel = "mock-model"
    var result: Result<String, CleanupError>
    var delay: Duration = .zero

    func complete(system: String, user: String, model: String, apiKey: String) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

@Suite struct CleanupPromptBuilderTests {
    @Test func includesModeRulesVocabularyAndApp() {
        let prompt = CleanupPromptBuilder.systemPrompt(
            mode: .business,
            vocabulary: [.init(preferred: "AppSync", spokenForms: ["アップシンク"]), .init(preferred: "Bedrock")],
            appName: "Gmail")
        #expect(prompt.contains("モード: Business"))
        #expect(prompt.contains("- AppSync（聞き取り例: アップシンク）"))
        #expect(prompt.contains("- Bedrock"))
        #expect(prompt.contains("Gmail"))
        #expect(prompt.contains("言っていない情報を足さない"))
    }

    @Test(arguments: CleanupMode.allCases)
    func everyModeForbidsAddingMeaning(mode: CleanupMode) {
        let prompt = CleanupPromptBuilder.systemPrompt(mode: mode, vocabulary: [], appName: nil)
        #expect(prompt.contains("整形した文章だけを返す"))
        #expect(!prompt.contains("ユーザー辞書"))
    }

    @Test func promptModeForbidsInventedRequirements() {
        let prompt = CleanupPromptBuilder.systemPrompt(mode: .prompt, vocabulary: [], appName: nil)
        #expect(prompt.contains("ユーザーが言っていない要件"))
    }

    @Test func userMessageWrapsTranscript() {
        #expect(CleanupPromptBuilder.userMessage(transcript: "送って") == "<transcript>\n送って\n</transcript>")
    }
}

@Suite struct CleanupOutputGuardTests {
    let raw = "えーっと、明日の、いや明後日の会議なんだけど、田中さんに3時からで大丈夫ですかって送って"

    @Test func acceptsNormalCleanup() {
        let out = "田中さん、明後日の15時からの会議で問題ないでしょうか？"
        #expect(CleanupOutputGuard.validate(out, raw: raw, mode: .business) == out)
    }

    @Test func stripsThinkingTagsAndPreamble() {
        let out = "<think>考え中</think>以下が整形後の文章です：\n明後日の会議の件です。"
        #expect(CleanupOutputGuard.validate(out, raw: raw, mode: .natural) == "明後日の会議の件です。")
    }

    @Test func stripsTranscriptTagsAndCodeFence() {
        #expect(CleanupOutputGuard.validate("<transcript>\nこんにちは\n</transcript>", raw: "こんにちは", mode: .natural) == "こんにちは")
        #expect(CleanupOutputGuard.validate("```\nこんにちは\n```", raw: "こんにちは", mode: .natural) == "こんにちは")
    }

    @Test func rejectsEmptyOutput() {
        #expect(CleanupOutputGuard.validate("  \n", raw: raw, mode: .natural) == nil)
    }

    @Test func rejectsAnswerThatIsFarLongerThanInput() {
        let answer = String(repeating: "AppSync は AWS のマネージド GraphQL サービスで、", count: 10)
        #expect(CleanupOutputGuard.validate(answer, raw: "AppSyncって何？", mode: .natural) == nil)
    }

    @Test func rejectsOutputThatDropsMostOfALongInput() {
        #expect(CleanupOutputGuard.validate("了解。", raw: raw, mode: .natural) == nil)
    }

    @Test func allowsShortInputToShrink() {
        #expect(CleanupOutputGuard.validate("はい。", raw: "えーと、はい", mode: .natural) == "はい。")
    }
}

@Suite struct CleanupCoordinatorTests {
    func request(_ mode: CleanupMode = .natural) -> CleanupCoordinator.Request {
        .init(raw: "えーと今日の15時からAWSのAppSyncについて打ち合わせをします", mode: mode, vocabulary: [], appName: "Slack")
    }

    @Test func returnsCleanedText() async {
        let provider = MockCleanupProvider(result: .success("今日の15時から、AWSのAppSyncについて打ち合わせをします。"))
        let out = await CleanupCoordinator().run(request(), provider: provider, model: "m", apiKey: "k")
        #expect(out == .init(text: "今日の15時から、AWSのAppSyncについて打ち合わせをします。", didCleanup: true, failure: nil))
    }

    @Test func rawModeSkipsProvider() async {
        let provider = MockCleanupProvider(result: .failure(.http(500)))
        let out = await CleanupCoordinator().run(request(.raw), provider: provider, model: "m", apiKey: "k")
        #expect(out.text == request().raw)
        #expect(out.failure == nil)
    }

    @Test(arguments: [CleanupError.http(500), .unauthorized, .refused, .invalidResponse])
    func providerErrorFallsBackToRaw(error: CleanupError) async {
        let out = await CleanupCoordinator().run(
            request(), provider: MockCleanupProvider(result: .failure(error)), model: "m", apiKey: "k")
        #expect(out == .init(text: request().raw, didCleanup: false, failure: error))
    }

    @Test func timeoutFallsBackToRaw() async {
        let provider = MockCleanupProvider(result: .success("遅い"), delay: .seconds(5))
        let clock = ContinuousClock()
        let start = clock.now
        let out = await CleanupCoordinator(timeout: .milliseconds(100)).run(request(), provider: provider, model: "m", apiKey: "k")
        #expect(out.failure == .timedOut)
        #expect(out.text == request().raw)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func missingKeyFallsBackToRaw() async {
        let out = await CleanupCoordinator().run(
            request(), provider: MockCleanupProvider(result: .success("x")), model: "m", apiKey: nil)
        #expect(out.failure == .missingAPIKey)
    }

    @Test func guardRejectionFallsBackToRaw() async {
        let out = await CleanupCoordinator().run(
            request(), provider: MockCleanupProvider(result: .success(String(repeating: "あ", count: 500))),
            model: "m", apiKey: "k")
        #expect(out.failure == .rejectedByGuard)
    }
}

@Suite struct CleanupProviderWireTests {
    @Test func anthropicRequestShape() throws {
        let body = AnthropicCleanupProvider.makeRequest(system: "sys", user: "usr", model: "claude-opus-5")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5")
        #expect(json["system"] as? String == "sys")
        #expect(json["max_tokens"] as? Int != nil)
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["temperature"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
    }

    @Test func haikuRequestOmitsEffortAndFallbacks() throws {
        let body = AnthropicCleanupProvider.makeRequest(system: "s", user: "u", model: "claude-haiku-4-5")
        #expect(body.outputConfig == nil)
        #expect(body.fallbacks == nil)
    }

    @Test func anthropicParsesTextAndSkipsThinkingBlocks() throws {
        let data = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"整形済み"}],"stop_reason":"end_turn"}"#.utf8)
        #expect(try AnthropicCleanupProvider.parse(data) == "整形済み")
    }

    @Test func anthropicRefusalThrows() {
        let data = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
        #expect(throws: CleanupError.refused) { try AnthropicCleanupProvider.parse(data) }
    }

    @Test func openAIParsesFirstChoice() throws {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"整形済み"}}]}"#.utf8)
        #expect(try OpenAICompatibleCleanupProvider.parse(data) == "整形済み")
    }
}

@Suite struct VocabularyReplacerTests {
    let entries = [
        VocabularyEntry(preferred: "AppSync", spoken: "アップシンク", aliases: ["アップ シンク"]),
        VocabularyEntry(preferred: "AWS Lambda", spoken: "AWSラムダ"),
        VocabularyEntry(preferred: "Claude Code", spoken: "クロードコード"),
        VocabularyEntry(preferred: "Bedrock"),
    ]

    @Test func replacesSpokenFormsAndAliases() {
        #expect(VocabularyReplacer.apply(entries, to: "今日の15時からAWSのアップシンクについて打ち合わせ")
            == "今日の15時からAWSのAppSyncについて打ち合わせ")
        #expect(VocabularyReplacer.apply(entries, to: "アップ シンクとクロードコード") == "AppSyncとClaude Code")
    }

    @Test func longerFormWins() {
        #expect(VocabularyReplacer.apply(entries, to: "AWSラムダを使う") == "AWS Lambdaを使う")
    }

    @Test func textWithoutMatchesIsUnchanged() {
        #expect(VocabularyReplacer.apply(entries, to: "特に何もなし😀") == "特に何もなし😀")
        #expect(VocabularyReplacer.apply([], to: "abc") == "abc")
    }
}
