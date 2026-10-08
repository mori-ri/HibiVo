import Foundation

/// Everything one dictation needs, frozen at key-down so a settings change mid-utterance
/// can't produce a half-old, half-new result.
public struct DictationContext: Sendable {
    public struct Cleanup: Sendable {
        public var mode: CleanupMode
        /// nil when cleanup is off or the selected provider has no credentials.
        public var provider: (any TextCleanupProvider)?
        public var model: String
        /// Instructions for `.custom`, frozen with the rest so an edit mid-utterance doesn't apply halfway.
        public var customInstructions: String = ""
        /// Where `mode` came from, kept to pick the mode again if the target changes at stop.
        /// nil when cleanup is off; the mode then stays `.raw`.
        public var appModes: AppModeTable?
    }

    public var target: TargetApplication?
    public var transcriptionProvider: any TranscriptionProvider
    public var transcriptionConfig: TranscriptionConfig
    public var cleanup: Cleanup
    public var vocabulary: [VocabularyEntry]

    /// Sends the text to `app` instead, with that app's cleanup mode from the table frozen at key-down.
    public mutating func retarget(to app: TargetApplication) {
        target = app
        if let appModes = cleanup.appModes { cleanup.mode = appModes.mode(for: app.bundleID) }
    }
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
        var apiKey = ""
        if provider.requiresAPIKey {
            guard let key = secrets.secret(for: provider.id), !key.isEmpty else {
                throw .missingAPIKey(provider: provider.displayName)
            }
            apiKey = key
        }
        let entries = vocabulary()
        let config = TranscriptionConfig(
            apiKey: apiKey,
            // A model saved for another provider falls back to this one's default.
            model: provider.models.contains(settings.transcriptionModel)
                ? settings.transcriptionModel : provider.defaultModel,
            language: settings.language,
            vocabulary: entries.map(\.preferred),
            readings: entries.flatMap(\.readings))

        return DictationContext(
            target: target, transcriptionProvider: provider, transcriptionConfig: config,
            cleanup: cleanup(for: target), vocabulary: entries)
    }

    public func cleanup(for target: TargetApplication?) -> DictationContext.Cleanup {
        let kind = CleanupProviderKind(rawValue: settings.cleanupProviderID) ?? .anthropic
        let appModes =
            settings.cleanupEnabled
            ? AppModeTable(overrides: settings.appModeOverrides, fallback: settings.defaultCleanupMode) : nil
        return DictationContext.Cleanup(
            mode: appModes?.mode(for: target?.bundleID) ?? .raw,
            provider: settings.cleanupEnabled ? kind.makeProvider(settings: settings, secrets: secrets) : nil,
            model: settings.cleanupModel.isEmpty ? kind.defaultModel : settings.cleanupModel,
            customInstructions: settings.customCleanupInstructions, appModes: appModes)
    }
}

extension CleanupProviderKind {
    /// A provider with the credentials from Settings, or nil when they aren't saved.
    /// AI cleanup and meeting minutes share them.
    @MainActor
    public func makeProvider(settings: SettingsStore, secrets: any SecretStore, limits: CleanupLimits = .cleanup)
        -> (any TextCleanupProvider)?
    {
        func secret(_ account: String) -> String? {
            guard let value = secrets.secret(for: account), !value.isEmpty else { return nil }
            return value
        }
        switch self {
        case .anthropic:
            return secret(SecretAccount.anthropic).map { AnthropicCleanupProvider(apiKey: $0, limits: limits) }
        case .openAICompatible:
            guard let url = URL(string: settings.openAIBaseURL), let key = secret(SecretAccount.openAICompatible)
            else { return nil }
            return OpenAICompatibleCleanupProvider(baseURL: url, apiKey: key, limits: limits)
        case .bedrock:
            let region = settings.bedrockRegion.isEmpty ? BedrockCleanupProvider.defaultRegion : settings.bedrockRegion
            switch settings.bedrockAuth {
            case .apiKey:
                return secret(SecretAccount.bedrockAPIKey).map {
                    BedrockCleanupProvider(region: region, authentication: .apiKey($0), limits: limits)
                }
            case .iam:
                guard let keyID = secret(SecretAccount.awsAccessKeyID),
                    let secretKey = secret(SecretAccount.awsSecretAccessKey)
                else { return nil }
                let credentials = AWSCredentials(
                    accessKeyID: keyID, secretAccessKey: secretKey,
                    sessionToken: secret(SecretAccount.awsSessionToken))
                return BedrockCleanupProvider(region: region, authentication: .iam(credentials), limits: limits)
            }
        case .gemini:
            return secret(SecretAccount.gemini).map { GeminiCleanupProvider(apiKey: $0, limits: limits) }
        }
    }
}
