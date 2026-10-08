import Foundation
import Testing

@testable import HibiVoKit

struct MockCleanupProvider: TextCleanupProvider {
    let id = "mock-llm"
    let displayName = "Mock LLM"
    let defaultModel = "mock-model"
    var result: Result<String, CleanupError>
    var delay: Duration = .zero
    var usage: TokenUsage? = nil

    func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
        if delay > .zero { try await Task.sleep(for: delay) }
        return CleanupCompletion(text: try result.get(), usage: usage)
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

    @Test func contextualFormsAskForContext() {
        let prompt = CleanupPromptBuilder.systemPrompt(
            mode: .natural,
            vocabulary: [
                .init(preferred: "AI", contextualForms: ["あい"]),
                .init(preferred: "Siri", spokenForms: ["シリちゃん"], contextualForms: ["シリ"]),
            ],
            appName: nil)
        #expect(prompt.contains("- AI（読み: あい。同じ読みの一般的な言葉もあるため、文脈上この語を指すときだけこの表記にし、それ以外は変えない）"))
        #expect(prompt.contains("- Siri（聞き取り例: シリちゃん。読み: シリ。"))
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
        #expect(prompt.contains("語尾・口調は変えない"))
        #expect(prompt.contains("\n- 「えー」"))
    }

    @Test func customModeAddsTheUserInstructions() {
        let prompt = CleanupPromptBuilder.systemPrompt(
            mode: .custom, customInstructions: "  英語に翻訳する  \n", vocabulary: [], appName: nil)
        #expect(prompt.contains("モード: Custom"))
        #expect(prompt.contains("<instructions>\n英語に翻訳する\n</instructions>"))
        #expect(prompt.contains("\n- 「えー」"))
        #expect(prompt.contains("言っていない情報を足さない"))
    }

    @Test func customInstructionsAreOnlyUsedByCustomModeAndCapped() {
        let natural = CleanupPromptBuilder.systemPrompt(
            mode: .natural, customInstructions: "英語に翻訳する", vocabulary: [], appName: nil)
        #expect(!natural.contains("英語に翻訳する"))
        let blank = CleanupPromptBuilder.systemPrompt(
            mode: .custom, customInstructions: " \n", vocabulary: [], appName: nil)
        #expect(!blank.contains("<instructions>"))
        let long = String(repeating: "あ", count: CleanupMode.customInstructionsLimit + 50)
        let capped = CleanupPromptBuilder.systemPrompt(
            mode: .custom, customInstructions: long, vocabulary: [], appName: nil)
        #expect(
            capped.contains(String(repeating: "あ", count: CleanupMode.customInstructionsLimit) + "\n</instructions>"))
        #expect(!capped.contains(String(repeating: "あ", count: CleanupMode.customInstructionsLimit + 1)))
    }

    @Test func everyBuiltInModeHasADistinctSample() {
        // Custom has none: its output depends on the user's instructions.
        #expect(CleanupMode.custom.sampleOutput == nil)
        let outputs = CleanupMode.allCases.compactMap(\.sampleOutput)
        #expect(Set(outputs).count == CleanupMode.allCases.count - 1)
        // Raw doesn't call the model, so its sample is the utterance itself.
        #expect(CleanupMode.raw.sampleOutput == CleanupSample.spoken)
        #expect(CleanupMode.allCases.allSatisfy { !$0.summary.isEmpty })
        // The cleaned samples drop the filler and the self-correction.
        for mode in CleanupMode.allCases where mode != .raw {
            guard let output = mode.sampleOutput else { continue }
            #expect(!output.contains("えーと"))
            #expect(!output.contains("ボタン"))
        }
    }

    @Test func businessKeepsWordingAndBreaksLines() {
        let business = CleanupPromptBuilder.systemPrompt(mode: .business, vocabulary: [], appName: nil)
        #expect(business.contains("言い回し・語順・語尾は話者のまま残し"))
        #expect(business.contains("本文は 1 文ごとに改行"))
        #expect(business.contains("「聞いた」→「伺った」"))
        #expect(business.contains("\n- 「えー」"))
        let natural = CleanupPromptBuilder.systemPrompt(mode: .natural, vocabulary: [], appName: nil)
        #expect(!natural.contains("1 文ごとに改行"))
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
        #expect(
            CleanupOutputGuard.validate("<transcript>\nこんにちは\n</transcript>", raw: "こんにちは", mode: .natural) == "こんにちは")
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

    @Test func customModeMayShortenALot() {
        let raw = String(repeating: "明日の会議では予算とスケジュールについて話します。", count: 4)
        #expect(CleanupOutputGuard.validate("- 予算", raw: raw, mode: .natural) == nil)
        #expect(CleanupOutputGuard.validate("- 予算", raw: raw, mode: .custom) == "- 予算")
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
        let out = await CleanupCoordinator().run(request(), provider: provider, model: "m")
        #expect(out == .init(text: "今日の15時から、AWSのAppSyncについて打ち合わせをします。", didCleanup: true, failure: nil))
    }

    @Test func rawModeSkipsProvider() async {
        let provider = MockCleanupProvider(result: .failure(.http(500)))
        let out = await CleanupCoordinator().run(request(.raw), provider: provider, model: "m")
        #expect(out.text == request().raw)
        #expect(out.failure == nil)
    }

    @Test(arguments: [CleanupError.http(500), .unauthorized, .refused, .invalidResponse])
    func providerErrorFallsBackToRaw(error: CleanupError) async {
        let out = await CleanupCoordinator().run(
            request(), provider: MockCleanupProvider(result: .failure(error)), model: "m")
        #expect(out == .init(text: request().raw, didCleanup: false, failure: error))
    }

    @Test func timeoutFallsBackToRaw() async {
        let provider = MockCleanupProvider(result: .success("遅い"), delay: .seconds(5))
        let clock = ContinuousClock()
        let start = clock.now
        let out = await CleanupCoordinator(baseTimeout: .milliseconds(100), maxTimeout: .milliseconds(100)).run(
            request(), provider: provider, model: "m")
        #expect(out.failure == .timedOut)
        #expect(out.text == request().raw)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func timeoutGrowsWithTranscriptLength() {
        let coordinator = CleanupCoordinator()
        #expect(coordinator.timeout(for: "") == .seconds(5))
        #expect(coordinator.timeout(for: String(repeating: "あ", count: 500)) == .seconds(15))
        #expect(coordinator.timeout(for: String(repeating: "あ", count: 5_000)) == .seconds(30))
    }

    @Test func longTranscriptGetsMoreThanTheBaseTimeout() async {
        let raw = String(repeating: "今日は打ち合わせをします。", count: 20)
        let provider = MockCleanupProvider(result: .success(raw), delay: .milliseconds(300))
        let out = await CleanupCoordinator(baseTimeout: .milliseconds(100)).run(
            .init(raw: raw, mode: .natural, vocabulary: [], appName: nil), provider: provider, model: "m")
        #expect(out.didCleanup)
    }

    @Test func missingProviderFallsBackToRaw() async {
        let out = await CleanupCoordinator().run(request(), provider: nil, model: "m")
        #expect(out.failure == .missingAPIKey)
        #expect(out.text == request().raw)
    }

    @Test func guardRejectionFallsBackToRaw() async {
        let out = await CleanupCoordinator().run(
            request(), provider: MockCleanupProvider(result: .success(String(repeating: "あ", count: 500))),
            model: "m")
        #expect(out.failure == .rejectedByGuard)
    }
}

@Suite struct CleanupProviderWireTests {
    @Test func anthropicRequestShape() throws {
        let body = AnthropicCleanupProvider.makeRequest(system: "sys", user: "usr", model: "claude-opus-5-5")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["system"] as? String == "sys")
        #expect(json["max_tokens"] as? Int != nil)
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["temperature"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
    }

    // Short dictations need a fast reply, so every provider defaults to its lightweight model.
    @Test func defaultModelsFavorLatency() {
        #expect(CleanupProviderKind.anthropic.defaultModel == "claude-haiku-4-5")
        #expect(AnthropicCleanupProvider(apiKey: "k").defaultModel == "claude-haiku-4-5")
        #expect(CleanupProviderKind.bedrock.defaultModel == "global.anthropic.claude-haiku-4-5-20251001-v1:0")
        #expect(CleanupProviderKind.gemini.defaultModel == "gemini-3.5-flash-lite")
    }

    @Test(arguments: ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"])
    func requestAsksForServerSideFallbacks(model: String) {
        #expect(AnthropicCleanupProvider.makeRequest(system: "s", user: "u", model: model).fallbacks == "default")
    }

    @Test func olderSonnetOmitsFallbacks() {
        #expect(AnthropicCleanupProvider.makeRequest(system: "s", user: "u", model: "claude-sonnet-5").fallbacks == nil)
    }

    @Test func haikuRequestOmitsEffortAndFallbacks() throws {
        let body = AnthropicCleanupProvider.makeRequest(system: "s", user: "u", model: "claude-haiku-4-5")
        #expect(body.outputConfig == nil)
        #expect(body.fallbacks == nil)
    }

    @Test func haiku55RequestSendsLowEffortWithoutFallbacks() {
        let body = AnthropicCleanupProvider.makeRequest(system: "s", user: "u", model: "claude-haiku-5-5")
        #expect(body.outputConfig?.effort == "low")
        #expect(body.fallbacks == nil)
    }

    @Test func anthropicParsesTextAndSkipsThinkingBlocks() throws {
        let data = Data(
            #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"整形済み"}],"stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":0}}"#
                .utf8)
        let completion = try AnthropicCleanupProvider.parse(data)
        #expect(completion.text == "整形済み")
        #expect(completion.usage == TokenUsage(input: 120, output: 30))
    }

    @Test func anthropicRefusalThrows() {
        let data = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
        #expect(throws: CleanupError.refused) { try AnthropicCleanupProvider.parse(data) }
    }

    @Test func openAIParsesFirstChoice() throws {
        let data = Data(
            #"{"choices":[{"message":{"role":"assistant","content":"整形済み"}}],"usage":{"prompt_tokens":80,"completion_tokens":20,"total_tokens":100}}"#
                .utf8)
        let completion = try OpenAICompatibleCleanupProvider.parse(data)
        #expect(completion.text == "整形済み")
        #expect(completion.usage == TokenUsage(input: 80, output: 20))
    }

    @Test func openAIWithoutUsageStillParses() throws {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"整形済み"}}]}"#.utf8)
        #expect(try OpenAICompatibleCleanupProvider.parse(data).usage == nil)
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
        #expect(
            VocabularyReplacer.apply(entries, to: "今日の15時からAWSのアップシンクについて打ち合わせ")
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

    @Test func hiraganaSpokenFormMatchesKatakanaOutput() {
        let hibivo = [VocabularyEntry(preferred: "HibiVo", spoken: "ひびぼ")]
        #expect(VocabularyReplacer.apply(hibivo, to: "ヒビボの進捗です") == "HibiVoの進捗です")
        #expect(VocabularyReplacer.apply(hibivo, to: "ひびぼの進捗です") == "HibiVoの進捗です")
        // Mixed scripts within one word, as STT sometimes splits a name.
        #expect(VocabularyReplacer.apply(hibivo, to: "ヒビぼ") == "HibiVo")
    }

    @Test func katakanaSpokenFormMatchesHiraganaOutput() {
        #expect(VocabularyReplacer.apply(entries, to: "くろーどこーどで書く") == "Claude Codeで書く")
    }

    @Test func fullAndHalfWidthFormsMatch() {
        // Full-width Latin letters and half-width katakana fold to the registered form.
        #expect(VocabularyReplacer.apply(entries, to: "ＡＷＳラムダ") == "AWS Lambda")
        #expect(VocabularyReplacer.apply(entries, to: "ｱｯﾌﾟｼﾝｸに聞く") == "AppSyncに聞く")
        // A half-width voiced mark joins the kana before it into one Character, so "ﾄﾞ" folds to "ド".
        #expect(VocabularyReplacer.apply(entries, to: "ｸﾛｰﾄﾞｺｰﾄﾞ") == "Claude Code")
    }

    @Test func unreplacedTextKeepsItsScript() {
        // Folding is only for comparison; the surrounding text is never rewritten to katakana.
        #expect(VocabularyReplacer.apply(entries, to: "ひらがなとＡＢＣはそのまま、アップシンク") == "ひらがなとＡＢＣはそのまま、AppSync")
    }

    @Test func sameSoundingKanaMatch() {
        let entries = [VocabularyEntry(preferred: "Kanazuchi", spoken: "カナヅチ")]
        #expect(VocabularyReplacer.apply(entries, to: "カナズチを使う") == "Kanazuchiを使う")
        #expect(VocabularyReplacer.apply(entries, to: "かなづち") == "Kanazuchi")
    }

    @Test func spaceBetweenLatinAndKanaIsOptional() {
        #expect(VocabularyReplacer.apply(entries, to: "AWS ラムダも使う") == "AWS Lambdaも使う")
        #expect(VocabularyReplacer.apply(entries, to: "ＡＷＳ　ラムダ") == "AWS Lambda")
        let spaced = [VocabularyEntry(preferred: "Zip AI", spoken: "ジップ AI")]
        #expect(VocabularyReplacer.apply(spaced, to: "ジップAIとジップ AI") == "Zip AIとZip AI")
    }

    @Test func otherSpacesAndLineBreaksAreNotSkipped() {
        #expect(VocabularyReplacer.apply(entries, to: "A WSラムダ") == "A WSラムダ")
        #expect(VocabularyReplacer.apply(entries, to: "AWS\nラムダ") == "AWS\nラムダ")
        #expect(VocabularyReplacer.apply(entries, to: "クロード コード") == "クロード コード")
    }

    @Test(arguments: [
        ("バッター", "バッタが跳ぶ"), ("ヒビボー", "ヒビボ"), ("ハートマーク", "ハトマーク"), ("サーバー", "サバ"),
        ("ソニックス", "ゾニックス"), ("アマゾン", "アマ・ゾン"),
    ])
    func longVowelsMarksAndVoicingStillTellWordsApart(spoken: String, text: String) {
        #expect(VocabularyReplacer.apply([VocabularyEntry(preferred: "X", spoken: spoken)], to: text) == text)
    }

    @Test func fourKanaFormWithLongVowelIsReplaced() {
        let server = [VocabularyEntry(preferred: "Server", spoken: "サーバー")]
        #expect(VocabularyReplacer.apply(server, to: "サーバーを再起動") == "Serverを再起動")
        #expect(server[0].readings == ["サーバー"])
    }

    @Test func readingsAreKatakanaSpokenForms() {
        let entry = VocabularyEntry(preferred: "HibiVo", spoken: "ひびぼ", aliases: ["日比保"])
        #expect(entry.readings == ["ヒビボ", "日比保"])
    }

    @Test func shortKanaFormsAreLeftToCleanup() {
        let ai = [VocabularyEntry(preferred: "AI", spoken: "あい")]
        #expect(VocabularyReplacer.apply(ai, to: "あいさつに会いたい、あいの新曲") == "あいさつに会いたい、あいの新曲")
        #expect(ai[0].contextualForms == ["あい"])
        #expect(ai[0].readings.isEmpty)
        #expect(ai[0].promptTerm == .init(preferred: "AI", contextualForms: ["あい"]))
    }

    @Test(arguments: ["あい", "シリ", "ｼﾘ", "ジー", "ア"])
    func shortKanaNeedsContext(form: String) {
        #expect(VocabularyEntry.needsContext(form))
    }

    @Test(arguments: ["ひびぼ", "ジェイ", "会期", "ai", "AI", "Aい"])
    func longerOrNonKanaFormsAreReplaced(form: String) {
        #expect(!VocabularyEntry.needsContext(form))
    }

    @Test func shortAndLongFormsSplitWithinOneEntry() {
        let entry = VocabularyEntry(preferred: "AI", spoken: "エーアイ", aliases: ["あい"])
        #expect(entry.replaceableForms == ["エーアイ"])
        #expect(entry.contextualForms == ["あい"])
        #expect(VocabularyReplacer.apply([entry], to: "エーアイとあい") == "AIとあい")
    }
}

@MainActor
@Suite struct VocabularyHintTests {
    @Test func dictationHintsSpellingsAndReadings() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "VocabularyHintTests-\(UUID())")!)
        settings.transcriptionProviderID = "mock"
        let builder = DictationContextBuilder(
            settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()],
            vocabulary: {
                [
                    VocabularyEntry(preferred: "HibiVo", spoken: "ひびぼ"), VocabularyEntry(preferred: "Bedrock"),
                    VocabularyEntry(preferred: "AI", spoken: "あい"),
                ]
            })
        let config = try builder.make(target: nil).transcriptionConfig
        #expect(config.vocabulary == ["HibiVo", "Bedrock", "AI"])
        #expect(config.readings == ["ヒビボ"])
    }
}

@Suite struct TrailingPeriodTests {
    @Test(arguments: [
        ("AppSync。", "AppSync"), ("会議資料。", "会議資料"), ("AWS Lambda。", "AWS Lambda"), ("Lambda.", "Lambda"),
        ("テスト。\n", "テスト"), ("会議の資料。", "会議の資料"), ("お客様。", "お客様"),
    ])
    func dropsPeriodAfterLoneWord(input: String, expected: String) {
        #expect(TrailingPeriod.trimmed(input) == expected)
    }

    @Test(arguments: [
        "了解しました。", "ありがとう。", "明日、会議資料。", "資料を確認。次は会議。", "This is Lambda.", "3.14.",
        "本日の議題は来期の予算計画と人員配置の見直しについて。", "改行\nあり。", "AppSync", "次回は来週。", "今日は雨。",
        "東京で開催。",
    ])
    func keepsSentences(input: String) {
        #expect(TrailingPeriod.trimmed(input) == input)
    }

    @Test func dictationPathDropsPeriodInEveryMode() async {
        let coordinator = CleanupCoordinator()
        let raw = await coordinator.run(
            transcript: "AppSync。", vocabulary: [], mode: .raw, appName: nil, customInstructions: "",
            provider: nil, model: "m")
        #expect(raw.raw == "AppSync。")
        #expect(raw.outcome.text == "AppSync")
        let cleaned = await coordinator.run(
            transcript: "えーとアップシンク", vocabulary: [], mode: .natural, appName: nil, customInstructions: "",
            provider: MockCleanupProvider(result: .success("AppSync。")), model: "m")
        #expect(cleaned.outcome.text == "AppSync")
        #expect(cleaned.outcome.didCleanup)
    }
}
