import Foundation

/// Non-secret preferences, persisted in UserDefaults. API keys live in `KeychainService`.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var hotkey: HotkeyTrigger { didSet { save(hotkey, "hotkey") } }
    /// CoreAudio device UID; nil means the system default input.
    public var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }

    public var transcriptionProviderID: String {
        didSet { defaults.set(transcriptionProviderID, forKey: "transcriptionProviderID") }
    }
    /// Empty means the provider's default model.
    public var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    public var language: String { didSet { defaults.set(language, forKey: "language") } }

    public var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    public var cleanupProviderID: String { didSet { defaults.set(cleanupProviderID, forKey: "cleanupProviderID") } }
    /// Empty means the provider's default model.
    public var cleanupModel: String { didSet { defaults.set(cleanupModel, forKey: "cleanupModel") } }
    public var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    public var defaultCleanupMode: CleanupMode { didSet { save(defaultCleanupMode, "defaultCleanupMode") } }
    /// Whether dictation results are kept in the local history.
    public var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }
    public var appModeOverrides: [AppModeOverride] { didSet { save(appModeOverrides, "appModeOverrides") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = Self.load("hotkey", from: defaults) ?? .default
        microphoneUID = defaults.string(forKey: "microphoneUID")
        transcriptionProviderID = defaults.string(forKey: "transcriptionProviderID") ?? "soniox"
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? ""
        language = defaults.string(forKey: "language") ?? "ja"
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        cleanupProviderID = defaults.string(forKey: "cleanupProviderID") ?? "anthropic"
        cleanupModel = defaults.string(forKey: "cleanupModel") ?? ""
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? OpenAICompatibleCleanupProvider.defaultBaseURL
        defaultCleanupMode = Self.load("defaultCleanupMode", from: defaults) ?? .natural
        historyEnabled = defaults.object(forKey: "historyEnabled") as? Bool ?? true
        appModeOverrides = Self.load("appModeOverrides", from: defaults) ?? []
    }

    /// Cleanup mode for the app that will receive the text.
    public func cleanupMode(for bundleID: String?) -> CleanupMode {
        AppModeRules.mode(for: bundleID, overrides: appModeOverrides, default: defaultCleanupMode)
    }

    public func setMode(_ mode: CleanupMode?, bundleID: String, name: String) {
        appModeOverrides.removeAll { $0.bundleID == bundleID }
        if let mode { appModeOverrides.append(AppModeOverride(bundleID: bundleID, name: name, mode: mode)) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
