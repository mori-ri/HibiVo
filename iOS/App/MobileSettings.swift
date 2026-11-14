import Foundation
import Observation

/// Non-secret preferences of the iOS app, persisted in UserDefaults. API keys live in `KeychainService`.
@MainActor
@Observable
final class MobileSettings {
    static let standbyChoices = [1, 5, 15, 30]

    @ObservationIgnored private let defaults: UserDefaults

    var transcriptionProviderID: String {
        didSet { defaults.set(transcriptionProviderID, forKey: "transcriptionProviderID") }
    }
    /// BCP-47 primary language of what the user says, e.g. "ja".
    var language: String { didSet { defaults.set(language, forKey: "language") } }

    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    var cleanupProviderID: String { didSet { defaults.set(cleanupProviderID, forKey: "cleanupProviderID") } }
    /// Empty means the provider's default model.
    var cleanupModel: String { didSet { defaults.set(cleanupModel, forKey: "cleanupModel") } }
    var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    var bedrockRegion: String { didSet { defaults.set(bedrockRegion, forKey: "bedrockRegion") } }
    /// iOS doesn't tell a keyboard which app it is typing into, so there is one mode for every app.
    var cleanupMode: CleanupMode { didSet { defaults.set(cleanupMode.rawValue, forKey: "cleanupMode") } }
    /// What the Custom mode asks the model to do. Use `setCustomCleanupInstructions` to keep it within the limit.
    private(set) var customCleanupInstructions: String {
        didSet { defaults.set(customCleanupInstructions, forKey: "customCleanupInstructions") }
    }
    /// Whether dictation results are kept in the local history.
    var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }
    /// How long the microphone stays ready after the last dictation before the session ends by itself.
    var standbyMinutes: Int { didSet { defaults.set(standbyMinutes, forKey: "standbyMinutes") } }

    /// - Parameter defaultTranscriptionProviderID: Used until the user picks a provider.
    init(defaults: UserDefaults = .standard, defaultTranscriptionProviderID: String) {
        self.defaults = defaults
        transcriptionProviderID =
            defaults.string(forKey: "transcriptionProviderID") ?? defaultTranscriptionProviderID
        language = defaults.string(forKey: "language") ?? "ja"
        // Off until the user adds a key: without one every dictation would report a failed cleanup.
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        cleanupProviderID =
            defaults.string(forKey: "cleanupProviderID") ?? CleanupProviderKind.anthropic.rawValue
        cleanupModel = defaults.string(forKey: "cleanupModel") ?? ""
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? OpenAICompatibleCleanupProvider.defaultBaseURL
        bedrockRegion = defaults.string(forKey: "bedrockRegion") ?? ""
        cleanupMode = defaults.string(forKey: "cleanupMode").flatMap(CleanupMode.init(rawValue:)) ?? .natural
        customCleanupInstructions = String(
            (defaults.string(forKey: "customCleanupInstructions") ?? "").prefix(CleanupMode.customInstructionsLimit))
        historyEnabled = defaults.object(forKey: "historyEnabled") as? Bool ?? true
        let standby = defaults.integer(forKey: "standbyMinutes")
        standbyMinutes = Self.standbyChoices.contains(standby) ? standby : 5
    }

    func setCustomCleanupInstructions(_ text: String) {
        customCleanupInstructions = String(text.prefix(CleanupMode.customInstructionsLimit))
    }

    var cleanupProviderKind: CleanupProviderKind {
        CleanupProviderKind(rawValue: cleanupProviderID) ?? .anthropic
    }
}

extension CleanupProviderKind {
    /// Where this provider's API key is kept. On iOS, Bedrock takes its API key only (no IAM key pair).
    var secretAccount: String {
        switch self {
        case .anthropic: SecretAccount.anthropic
        case .openAICompatible: SecretAccount.openAICompatible
        case .bedrock: SecretAccount.bedrockAPIKey
        case .gemini: SecretAccount.gemini
        }
    }

    /// A provider with the credentials from Settings, or nil when they aren't saved.
    @MainActor
    func makeProvider(settings: MobileSettings, secrets: any SecretStore) -> (any TextCleanupProvider)? {
        guard let key = secrets.secret(for: secretAccount), !key.isEmpty else { return nil }
        switch self {
        case .anthropic:
            return AnthropicCleanupProvider(apiKey: key)
        case .openAICompatible:
            guard let url = URL(string: settings.openAIBaseURL) else { return nil }
            return OpenAICompatibleCleanupProvider(baseURL: url, apiKey: key)
        case .bedrock:
            let region = settings.bedrockRegion.isEmpty ? BedrockCleanupProvider.defaultRegion : settings.bedrockRegion
            return BedrockCleanupProvider(region: region, authentication: .apiKey(key))
        case .gemini:
            return GeminiCleanupProvider(apiKey: key)
        }
    }
}
