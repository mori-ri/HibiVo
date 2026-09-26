import Foundation

/// Everything one dictation needs, frozen at key-down so a settings change mid-utterance
/// can't produce a half-old, half-new result.
public struct DictationContext: Sendable {
    public struct Cleanup: Sendable {
        public var mode: CleanupMode
        public var provider: (any TextCleanupProvider)?
        public var model: String
        public var apiKey: String?
    }

    public var target: TargetApplication?
    public var transcriptionProvider: any TranscriptionProvider
    public var transcriptionConfig: TranscriptionConfig
    public var cleanup: Cleanup
    public var vocabulary: [VocabularyEntry]
}

/// Builds a `DictationContext` from the current settings, secrets and dictionary.
@MainActor
public struct DictationContextBuilder {
    let settings: SettingsStore
    let secrets: any SecretStore
    let transcriptionProviders: [any TranscriptionProvider]
    let vocabulary: @MainActor () -> [VocabularyEntry]

    public init(
        settings: SettingsStore,
        secrets: any SecretStore,
        transcriptionProviders: [any TranscriptionProvider],
        vocabulary: @escaping @MainActor () -> [VocabularyEntry] = { [] }
    ) {
        self.settings = settings
        self.secrets = secrets
        self.transcriptionProviders = transcriptionProviders
        self.vocabulary = vocabulary
    }

    public var transcriptionProvider: (any TranscriptionProvider)? {
        transcriptionProviders.first { $0.id == settings.transcriptionProviderID } ?? transcriptionProviders.first
    }

    public func make(target: TargetApplication?) throws(UserFacingError) -> DictationContext {
        guard let provider = transcriptionProvider else { throw .transcriptionFailed }
        guard let apiKey = secrets.secret(for: provider.id), !apiKey.isEmpty else {
            throw .missingAPIKey(provider: provider.displayName)
        }
        let entries = vocabulary()
        let config = TranscriptionConfig(
            apiKey: apiKey,
            model: settings.transcriptionModel.isEmpty ? provider.defaultModel : settings.transcriptionModel,
            language: settings.language,
            vocabulary: entries.map(\.preferred))

        return DictationContext(
            target: target, transcriptionProvider: provider, transcriptionConfig: config,
            cleanup: cleanup(for: target), vocabulary: entries)
    }

    public func cleanup(for target: TargetApplication?) -> DictationContext.Cleanup {
        let provider = settings.cleanupEnabled ? makeCleanupProvider() : nil
        return DictationContext.Cleanup(
            mode: settings.cleanupEnabled ? settings.cleanupMode(for: target?.bundleID) : .raw,
            provider: provider,
            model: settings.cleanupModel.isEmpty ? (provider?.defaultModel ?? "") : settings.cleanupModel,
            apiKey: provider.flatMap { secrets.secret(for: $0.id) })
    }

    private func makeCleanupProvider() -> (any TextCleanupProvider)? {
        switch settings.cleanupProviderID {
        case "openai-compatible":
            guard let url = URL(string: settings.openAIBaseURL) else { return nil }
            return OpenAICompatibleCleanupProvider(baseURL: url)
        default:
            return AnthropicCleanupProvider()
        }
    }
}
