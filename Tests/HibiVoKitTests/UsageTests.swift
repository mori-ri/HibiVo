import Foundation
import Testing

@testable import HibiVoKit

@MainActor
@Suite struct UsageStoreTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    func makeStore() -> UsageStore {
        UsageStore(
            file: JSONFileStore(
                url: FileManager.default.temporaryDirectory.appending(path: "hibivo-usage-\(UUID()).json")),
            calendar: calendar)
    }

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func dictation(on date: Date, characters: Int = 10, seconds: Double = 5, tokens: TokenUsage? = nil) -> UsageEvent {
        UsageEvent(
            date: date, dictations: 1, characters: characters,
            transcription: .init(provider: "soniox", model: "stt-rt-v5", seconds: seconds),
            cleanup: tokens.map { .init(provider: "anthropic", model: "claude-opus-5", requests: 1, tokens: $0) })
    }

    @Test func eventsOnTheSameDayAreSummed() {
        let store = makeStore()
        store.record(dictation(on: date(2026, 9, 27, hour: 9), tokens: .init(input: 100, output: 20)))
        store.record(dictation(on: date(2026, 9, 27, hour: 23), tokens: .init(input: 50, output: 10)))
        #expect(store.days.count == 1)
        let day = store.days[0]
        #expect(day.day == "2026-09-27")
        #expect(day.dictations == 2)
        #expect(day.characters == 20)
        #expect(day.audioSeconds == 10)
        #expect(
            day.cleanup == [
                .init(provider: "anthropic", model: "claude-opus-5", requests: 2, tokens: .init(input: 150, output: 30))
            ])
    }

    @Test func differentModelsAreKeptApart() {
        let store = makeStore()
        store.record(dictation(on: date(2026, 9, 27), tokens: .init(input: 1, output: 1)))
        store.record(
            UsageEvent(
                date: date(2026, 9, 27),
                cleanup: .init(
                    provider: "bedrock", model: "zai.glm-4.7", requests: 1, tokens: .init(input: 2, output: 2))))
        #expect(store.days[0].cleanup.count == 2)
        #expect(store.days[0].dictations == 1)
    }

    @Test func bedrockRegionsAreKeptApart() {
        let store = makeStore()
        let tokens = TokenUsage(input: 1, output: 1)
        for region in ["ap-northeast-1", "us-east-1", "ap-northeast-1"] {
            store.record(
                UsageEvent(
                    date: date(2026, 9, 27),
                    cleanup: .init(
                        provider: "bedrock", model: "zai.glm-4.7", region: region, requests: 1, tokens: tokens)))
        }
        #expect(store.days[0].cleanup.map(\.region) == ["ap-northeast-1", "us-east-1"])
        #expect(store.days[0].cleanup.map(\.requests) == [2, 1])
    }

    @Test func cleanupUsageTakesTheRegionFromBedrock() {
        let bedrock = BedrockCleanupProvider(region: "ap-northeast-1", authentication: .apiKey("k"))
        #expect(CleanupUsage(bedrock, model: "zai.glm-4.7", tokens: .zero).region == "ap-northeast-1")
        #expect(
            CleanupUsage(AnthropicCleanupProvider(apiKey: "k"), model: "claude-opus-5", tokens: .zero).region == nil)
    }

    @Test func seriesFillsEmptyDaysOldestFirst() {
        let store = makeStore()
        store.record(dictation(on: date(2026, 9, 25)))
        store.record(dictation(on: date(2026, 9, 27)))
        let series = store.series(days: 4, endingAt: date(2026, 9, 27))
        #expect(series.map(\.usage.day) == ["2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27"])
        #expect(series.map(\.usage.dictations) == [0, 1, 0, 1])
    }

    @Test func oldDaysArePruned() {
        let store = makeStore()
        store.record(dictation(on: date(2025, 1, 1)))
        store.record(dictation(on: date(2026, 9, 27)))
        #expect(store.days.map(\.day) == ["2026-09-27"])
    }

    @Test func removeAllClearsEverything() {
        let store = makeStore()
        store.record(dictation(on: date(2026, 9, 27)))
        store.removeAll()
        #expect(store.days.isEmpty)
    }
}

@Suite struct UsagePricingTests {
    @Test func sonioxIsBilledPerHourOfAudio() {
        let usd = UsagePricing.transcriptionUSD(.init(provider: "soniox", model: "stt-rt-v5", seconds: 3600))
        #expect(usd == 0.12)
    }

    @Test func claudeRatesMatchTheLongestPrefix() {
        #expect(UsagePricing.rate(provider: "anthropic", model: "claude-opus-5") == .init(input: 5, output: 25))
        #expect(UsagePricing.rate(provider: "anthropic", model: "claude-opus-5-5") == .init(input: 4, output: 20))
        #expect(UsagePricing.rate(provider: "anthropic", model: "claude-fable-5-1") == .init(input: 10, output: 50))
        #expect(
            UsagePricing.rate(provider: "anthropic", model: "claude-haiku-4-5-20251001") == .init(input: 1, output: 5))
    }

    func expectRate(
        _ rate: UsagePricing.TokenRate?, _ input: Double, _ output: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs((rate?.input ?? -1) - input) < 1e-9, sourceLocation: sourceLocation)
        #expect(abs((rate?.output ?? -1) - output) < 1e-9, sourceLocation: sourceLocation)
    }

    @Test func bedrockClaudeCostsTenPercentMoreOutsideGlobalProfiles() {
        expectRate(
            UsagePricing.rate(provider: "bedrock", model: "global.anthropic.claude-haiku-4-5-20251001-v1:0"), 1, 5)
        expectRate(UsagePricing.rate(provider: "bedrock", model: "anthropic.claude-opus-5"), 5.5, 27.5)
        expectRate(UsagePricing.rate(provider: "bedrock", model: "jp.anthropic.claude-sonnet-5"), 2.2, 11)
    }

    @Test func bedrockThirdPartyModelsArePricedByRegion() {
        expectRate(UsagePricing.rate(provider: "bedrock", model: "zai.glm-4.7", region: "us-east-1"), 0.60, 2.20)
        expectRate(UsagePricing.rate(provider: "bedrock", model: "zai.glm-4.7", region: "ap-northeast-1"), 0.72, 2.64)
        expectRate(
            UsagePricing.rate(provider: "bedrock", model: "zai.glm-4.7-flash", region: "ap-northeast-1"), 0.08, 0.48)
        expectRate(
            UsagePricing.rate(provider: "bedrock", model: "minimax.minimax-m2.5", region: "ap-northeast-1"), 0.36, 1.44)
        expectRate(
            UsagePricing.rate(provider: "bedrock", model: "minimax.minimax-m2.5", region: "us-west-2"), 0.30, 1.20)
    }

    @Test func bedrockGPTUsesTheInferenceProfilePrice() {
        expectRate(
            UsagePricing.rate(provider: "bedrock", model: "global.openai.gpt-6-luna", region: "ap-northeast-1"), 0.10,
            0.50)
        expectRate(
            UsagePricing.rate(provider: "bedrock", model: "us.openai.gpt-6-luna", region: "us-east-1"), 0.11, 0.55)
    }

    @Test func unknownModelsHaveNoPrice() {
        #expect(UsagePricing.rate(provider: "bedrock", model: "amazon.nova-pro-v1:0") == nil)
        #expect(UsagePricing.rate(provider: "openai-compatible", model: "gpt-6") == nil)
    }

    @Test func everySuggestedBedrockModelHasAPrice() {
        for model in BedrockCleanupProvider.suggestedModels {
            #expect(UsagePricing.rate(provider: "bedrock", model: model, region: "ap-northeast-1") != nil, "\(model)")
        }
    }

    @Test func yenFormatting() {
        #expect(UsageFormat.yen(0) == "0円")
        #expect(UsageFormat.yen(0.05) == "0.1円未満")
        #expect(UsageFormat.yen(3.14) == "3.1円")
        #expect(UsageFormat.yen(1234.5) == "1,235円")
        #expect(UsageFormat.yen(usd: 0.12, rate: 150) == "18円")
    }

    @Test func estimateSumsPricedUsageAndListsTheRest() {
        var day = DailyUsage(day: "2026-09-27")
        day.transcription = [.init(provider: "soniox", model: "stt-rt-v5", seconds: 1800)]
        day.cleanup = [
            .init(
                provider: "anthropic", model: "claude-opus-5", requests: 10,
                tokens: .init(input: 1_000_000, output: 100_000)),
            .init(provider: "openai-compatible", model: "gpt-6", requests: 1, tokens: .init(input: 10, output: 10)),
        ]
        let estimate = UsagePricing.estimate([day])
        #expect(estimate.transcriptionUSD == 0.06)
        #expect(estimate.cleanupUSD == 7.5)
        #expect(estimate.unpricedModels == ["gpt-6"])
    }
}

@MainActor
@Suite struct DictationUsageTests {
    let state = AppState()
    let settings: SettingsStore
    let audio = MockAudio()
    let usage = UsageStore(
        file: JSONFileStore(url: FileManager.default.temporaryDirectory.appending(path: "hibivo-usage-\(UUID()).json")))

    init() {
        settings = SettingsStore(defaults: UserDefaults(suiteName: "DictationUsageTests-\(UUID())")!)
        settings.transcriptionProviderID = "mock"
        settings.cleanupEnabled = false
    }

    func makeController(minimumDuration: Duration = .zero) -> DictationController {
        DictationController(
            state: state, audio: audio,
            contextBuilder: DictationContextBuilder(
                settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()]),
            activeApp: MockActiveApp(), inserter: MockInserter(), usage: usage, minimumDuration: minimumDuration,
            holdThreshold: .zero)
    }

    @Test func dictationRecordsCountCharactersAndAudio() async {
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak(bytes: 16_000)
        audio.speak(bytes: 16_000)
        sut.handle(.released)
        await sut.waitUntilIdle()

        let day = usage.days.first
        #expect(day?.dictations == 1)
        #expect(day?.characters == "今日の15時からAWSのAppSyncについて打ち合わせをします".count)
        // 32,000 bytes of 16 kHz mono PCM16 is one second.
        #expect(day?.transcription == [.init(provider: "mock", model: "m1", seconds: 1)])
        #expect(day?.cleanup.isEmpty == true)
    }

    @Test func silenceRecordsAudioButNoDictation() async {
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak(level: 0, bytes: 32_000)
        sut.handle(.released)
        await sut.waitUntilIdle()

        #expect(usage.days.first?.dictations == 0)
        #expect(usage.days.first?.audioSeconds == 1)
    }

    @Test func cancelledRecordingStillCountsStreamedAudio() async {
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak(bytes: 32_000)
        await Task.yield()
        sut.handle(.escape)
        await sut.waitUntilIdle()

        #expect(usage.days.first?.dictations == 0)
        #expect((usage.days.first?.audioSeconds ?? 0) <= 1)
    }
}

@Suite struct CleanupUsageTests {
    let request = CleanupCoordinator.Request(raw: "えーと明日の会議は10時からです", mode: .natural, vocabulary: [], appName: nil)

    @Test func successReportsTokens() async {
        let provider = MockCleanupProvider(result: .success("明日の会議は10時からです。"), usage: .init(input: 300, output: 12))
        let out = await CleanupCoordinator().run(request, provider: provider, model: "m")
        #expect(out.didCleanup)
        #expect(out.usage == TokenUsage(input: 300, output: 12))
    }

    @Test func rejectedOutputStillReportsBilledTokens() async {
        let provider = MockCleanupProvider(
            result: .success(String(repeating: "全く関係のない長い回答です。", count: 20)), usage: .init(input: 300, output: 200))
        let out = await CleanupCoordinator().run(request, provider: provider, model: "m")
        #expect(out.failure == .rejectedByGuard)
        #expect(out.usage == TokenUsage(input: 300, output: 200))
    }
}
