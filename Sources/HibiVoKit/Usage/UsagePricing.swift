import Foundation

/// Rough API cost from published list prices, in USD. Real bills can differ (discounts, regions not
/// listed here, Soniox output tokens, price changes), so the UI always labels these as estimates.
public enum UsagePricing {
    /// When the prices below were last checked. Shown next to estimates.
    public static let pricesAsOf = "2026年9月"
    /// USD/JPY around the time the prices were checked; users can change it in the usage page.
    public static let defaultUSDJPYRate = 157.0

    /// USD per 1M tokens.
    public struct TokenRate: Equatable, Sendable {
        public var input: Double
        public var output: Double

        func scaled(_ factor: Double) -> TokenRate {
            TokenRate(input: input * factor, output: output * factor)
        }
    }

    /// Soniox real-time: $0.12 per hour of audio.
    static let sonioxRealtimePerHour = 0.12
    /// Gemini 3.5 Transcribe Live: Google's blended estimate of $0.009 per minute of audio
    /// (audio input tokens plus transcript output tokens).
    static let geminiLiveTranscribePerMinute = 0.009

    /// Anthropic list prices. Checked in order, so longer IDs come before their prefixes.
    static let claudeRates: [(prefix: String, rate: TokenRate)] = [
        ("claude-fable-5-1", .init(input: 10, output: 50)),
        ("claude-fable-5", .init(input: 10, output: 50)),
        ("claude-opus-5-5", .init(input: 4, output: 20)),
        ("claude-opus-5", .init(input: 5, output: 25)),
        ("claude-opus-4-8", .init(input: 5, output: 25)),
        ("claude-opus-4-7", .init(input: 5, output: 25)),
        ("claude-opus-4-6", .init(input: 5, output: 25)),
        ("claude-sonnet-5", .init(input: 2, output: 10)),
        ("claude-sonnet-4-6", .init(input: 3, output: 15)),
        ("claude-haiku-4-5", .init(input: 1, output: 5)),
    ]

    /// Bedrock charges Claude at Anthropic's rates on global inference profiles, and 10% more for
    /// in-Region and geographic (`us.`, `jp.`, …) inference.
    static let bedrockRegionalPremium = 1.1

    /// A non-Claude Bedrock model. `standard` is the US-Region / geographic price, `global` the
    /// `global.` inference profile price, and `regions` the Regions that are priced differently.
    struct BedrockModel {
        var id: String
        var standard: TokenRate
        var global: TokenRate? = nil
        var regions: [String: TokenRate] = [:]
    }

    /// From the Amazon Bedrock pricing page and model cards. Longer IDs come before their prefixes.
    static let bedrockModels: [BedrockModel] = {
        let glmHigherRegions = ["ap-northeast-1", "ap-south-1", "ap-southeast-3", "sa-east-1", "eu-north-1"]
        let minimaxHigherRegions = ["ap-northeast-1", "ap-south-1", "sa-east-1", "eu-west-1"]
        func regions(_ names: [String], _ rate: TokenRate) -> [String: TokenRate] {
            Dictionary(uniqueKeysWithValues: names.map { ($0, rate) })
        }
        return [
            BedrockModel(
                id: "zai.glm-4.7-flash", standard: .init(input: 0.07, output: 0.40),
                regions: regions(glmHigherRegions, .init(input: 0.08, output: 0.48))),
            BedrockModel(
                id: "zai.glm-4.7", standard: .init(input: 0.60, output: 2.20),
                regions: regions(glmHigherRegions, .init(input: 0.72, output: 2.64))
                    .merging(["ap-southeast-2": .init(input: 0.618, output: 2.266)]) { $1 }),
            BedrockModel(
                id: "minimax.minimax-m2.5", standard: .init(input: 0.30, output: 1.20),
                regions: regions(minimaxHigherRegions, .init(input: 0.36, output: 1.44))
                    .merging(["ap-southeast-2": .init(input: 0.31, output: 1.24)]) { $1 }),
            BedrockModel(
                id: "openai.gpt-6-luna", standard: .init(input: 0.11, output: 0.55),
                global: .init(input: 0.10, output: 0.50)),
        ]
    }()

    /// A Gemini API model. `intro` applies through `introEndsOn` (a `yyyy-MM-dd` day), `standard` after.
    struct GeminiModel {
        var id: String
        var standard: TokenRate
        var intro: TokenRate? = nil
    }

    static let geminiIntroEndsOn = "2026-12-31"

    /// Gemini API list prices. Longer IDs come before their prefixes.
    static let geminiModels: [GeminiModel] = [
        GeminiModel(
            id: "gemini-3.8-flash", standard: .init(input: 1.50, output: 7.50), intro: .init(input: 0.75, output: 3.75)),
        GeminiModel(id: "gemini-3.5-flash-lite", standard: .init(input: 0.30, output: 2.50)),
    ]

    /// Leading inference-profile scopes on Bedrock model IDs.
    static let inferenceProfileScopes: Set<String> = ["global", "us", "us-gov", "eu", "apac", "jp", "au", "ca"]

    public static func transcriptionUSD(_ usage: TranscriptionUsage) -> Double? {
        switch usage.provider {
        case "soniox": usage.seconds / 3600 * sonioxRealtimePerHour
        case "gemini": usage.seconds / 60 * geminiLiveTranscribePerMinute
        default: nil
        }
    }

    /// nil for models without a built-in price (OpenAI-compatible endpoints, unlisted Bedrock models).
    /// `day` (`yyyy-MM-dd`) picks time-limited prices; nil means today.
    public static func rate(provider: String, model: String, region: String? = nil, day: String? = nil) -> TokenRate? {
        switch CleanupProviderKind(rawValue: provider) {
        case .anthropic: claudeRate(model)
        case .bedrock: bedrockRate(model: model, region: region)
        case .gemini: geminiRate(model, day: day ?? Date().formatted(.iso8601.year().month().day()))
        case .openAICompatible, nil: nil
        }
    }

    static func claudeRate(_ name: String) -> TokenRate? {
        claudeRates.first { name.hasPrefix($0.prefix) }?.rate
    }

    static func geminiRate(_ model: String, day: String) -> TokenRate? {
        guard let entry = geminiModels.first(where: { model.hasPrefix($0.id) }) else { return nil }
        if let intro = entry.intro, day <= geminiIntroEndsOn { return intro }
        return entry.standard
    }

    static func bedrockRate(model: String, region: String?) -> TokenRate? {
        let parts = model.split(separator: ".", maxSplits: 1).map(String.init)
        let scope = parts.count == 2 && inferenceProfileScopes.contains(parts[0]) ? parts[0] : nil
        let name = scope == nil ? model : parts[1]

        if name.hasPrefix("anthropic.") {
            guard let rate = claudeRate(String(name.dropFirst("anthropic.".count))) else { return nil }
            return scope == "global" ? rate : rate.scaled(bedrockRegionalPremium)
        }
        guard let entry = bedrockModels.first(where: { name.hasPrefix($0.id) }) else { return nil }
        if scope == "global", let global = entry.global { return global }
        if scope == nil, let region, let regional = entry.regions[region] { return regional }
        return entry.standard
    }

    public static func cleanupUSD(_ usage: CleanupUsage, day: String? = nil) -> Double? {
        guard let rate = rate(provider: usage.provider, model: usage.model, region: usage.region, day: day) else {
            return nil
        }
        return (Double(usage.tokens.input) * rate.input + Double(usage.tokens.output) * rate.output) / 1_000_000
    }

    public struct Estimate: Equatable, Sendable {
        public var transcriptionUSD: Double = 0
        public var cleanupUSD: Double = 0
        /// Models that were used but have no known price, so they are missing from the total.
        public var unpricedModels: [String] = []

        public var totalUSD: Double { transcriptionUSD + cleanupUSD }
    }

    public static func estimate(_ days: some Sequence<DailyUsage>) -> Estimate {
        var estimate = Estimate()
        var unpriced = Set<String>()
        for day in days {
            for stt in day.transcription {
                if let usd = transcriptionUSD(stt) {
                    estimate.transcriptionUSD += usd
                } else {
                    unpriced.insert(stt.model)
                }
            }
            for llm in day.cleanup {
                if let usd = cleanupUSD(llm, day: day.day) {
                    estimate.cleanupUSD += usd
                } else {
                    unpriced.insert(llm.model)
                }
            }
        }
        estimate.unpricedModels = unpriced.sorted()
        return estimate
    }
}
