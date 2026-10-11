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
    /// The STT meetings use. Separate from dictation's: only some providers can transcribe a meeting.
    public var meetingTranscriptionProviderID: String {
        didSet { defaults.set(meetingTranscriptionProviderID, forKey: "meetingTranscriptionProviderID") }
    }
    /// Empty means the provider's default model.
    public var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    public var language: String { didSet { defaults.set(language, forKey: "language") } }

    public var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    /// Opt-in: read the text around the paste target and send it with the transcript to cleanup.
    public var usesScreenContext: Bool { didSet { defaults.set(usesScreenContext, forKey: "usesScreenContext") } }
    public var cleanupProviderID: String { didSet { defaults.set(cleanupProviderID, forKey: "cleanupProviderID") } }
    /// Empty means the provider's default model.
    public var cleanupModel: String { didSet { defaults.set(cleanupModel, forKey: "cleanupModel") } }
    public var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    public var bedrockRegion: String { didSet { defaults.set(bedrockRegion, forKey: "bedrockRegion") } }
    public var bedrockAuth: BedrockAuthMethod { didSet { save(bedrockAuth, "bedrockAuth") } }
    public var defaultCleanupMode: CleanupMode { didSet { save(defaultCleanupMode, "defaultCleanupMode") } }
    /// What the Custom mode asks the model to do. Use `setCustomCleanupInstructions` to keep it within the limit.
    public private(set) var customCleanupInstructions: String {
        didSet { defaults.set(customCleanupInstructions, forKey: "customCleanupInstructions") }
    }
    /// Whether dictation results are kept in the local history.
    public var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }
    /// Whether words the user fixes after a paste are added to the dictionary.
    public var learnsFromCorrections: Bool {
        didSet { defaults.set(learnsFromCorrections, forKey: "learnsFromCorrections") }
    }
    /// Whether speaker volume is lowered while recording.
    public var duckOutputWhileRecording: Bool {
        didSet { defaults.set(duckOutputWhileRecording, forKey: "duckOutputWhileRecording") }
    }
    /// Whether the HUD shows the streaming transcript while recording.
    public var showLiveTranscript: Bool { didSet { defaults.set(showLiveTranscript, forKey: "showLiveTranscript") } }
    /// Whether meetings also record what the Mac plays, i.e. the other side of an online meeting.
    public var meetingCapturesSystemAudio: Bool {
        didSet { defaults.set(meetingCapturesSystemAudio, forKey: "meetingCapturesSystemAudio") }
    }
    public var meetingTranscriptionTiming: MeetingTranscriptionTiming {
        didSet { save(meetingTranscriptionTiming, "meetingTranscriptionTiming") }
    }
    /// Whether minutes are written from each saved meeting.
    public var meetingMinutesEnabled: Bool {
        didSet { defaults.set(meetingMinutesEnabled, forKey: "meetingMinutesEnabled") }
    }
    public var meetingMinutesEngine: MeetingMinutesEngine {
        didSet { save(meetingMinutesEngine, "meetingMinutesEngine") }
    }
    /// Claude Code's model alias for minutes.
    public var meetingMinutesModel: MeetingMinutesModel { didSet { save(meetingMinutesModel, "meetingMinutesModel") } }
    /// Model ID for minutes from a cleanup provider; empty means the engine's default.
    /// Settings clears it when the engine changes, since model names differ per provider.
    public var meetingMinutesAPIModel: String {
        didSet { defaults.set(meetingMinutesAPIModel, forKey: "meetingMinutesAPIModel") }
    }
    /// The model the configured engine writes minutes with. Empty when an OpenAI-compatible model isn't entered.
    public var resolvedMeetingMinutesModel: String {
        switch meetingMinutesEngine {
        case .claudeCode: meetingMinutesModel.rawValue
        default: meetingMinutesAPIModel.isEmpty ? meetingMinutesEngine.defaultModel : meetingMinutesAPIModel
        }
    }
    /// The editable part of the minutes prompt; nil means the built-in default, so improvements to it
    /// reach everyone who hasn't customized it. Use `setMeetingMinutesInstructions` to change it.
    public private(set) var meetingMinutesInstructions: String? {
        didSet { defaults.set(meetingMinutesInstructions, forKey: "meetingMinutesInstructions") }
    }
    /// Path to the `claude` executable; empty means look in the standard install locations.
    public var claudeCodePath: String { didSet { defaults.set(claudeCodePath, forKey: "claudeCodePath") } }
    public var appModeOverrides: [AppModeOverride] { didSet { save(appModeOverrides, "appModeOverrides") } }
    /// Yen per US dollar, for showing estimated API cost in yen.
    public var usdJPYRate: Double { didSet { defaults.set(usdJPYRate, forKey: "usdJPYRate") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = Self.load("hotkey", from: defaults) ?? .default
        microphoneUID = defaults.string(forKey: "microphoneUID")
        transcriptionProviderID =
            defaults.string(forKey: "transcriptionProviderID") ?? Self.defaultTranscriptionProviderID
        meetingTranscriptionProviderID =
            defaults.string(forKey: "meetingTranscriptionProviderID") ?? Self.defaultTranscriptionProviderID
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? ""
        language = defaults.string(forKey: "language") ?? "ja"
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        usesScreenContext = defaults.bool(forKey: "usesScreenContext")
        cleanupProviderID = defaults.string(forKey: "cleanupProviderID") ?? "anthropic"
        cleanupModel = defaults.string(forKey: "cleanupModel") ?? ""
        bedrockRegion = defaults.string(forKey: "bedrockRegion") ?? BedrockCleanupProvider.defaultRegion
        bedrockAuth = Self.load("bedrockAuth", from: defaults) ?? .apiKey
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? OpenAICompatibleCleanupProvider.defaultBaseURL
        defaultCleanupMode = Self.load("defaultCleanupMode", from: defaults) ?? .natural
        customCleanupInstructions = String(
            (defaults.string(forKey: "customCleanupInstructions") ?? "").prefix(CleanupMode.customInstructionsLimit))
        historyEnabled = defaults.object(forKey: "historyEnabled") as? Bool ?? true
        learnsFromCorrections = defaults.object(forKey: "learnsFromCorrections") as? Bool ?? true
        duckOutputWhileRecording = defaults.object(forKey: "duckOutputWhileRecording") as? Bool ?? true
        showLiveTranscript = defaults.object(forKey: "showLiveTranscript") as? Bool ?? false
        meetingCapturesSystemAudio = defaults.object(forKey: "meetingCapturesSystemAudio") as? Bool ?? true
        meetingTranscriptionTiming = Self.load("meetingTranscriptionTiming", from: defaults) ?? .realtime
        // On by default only where Claude Code is installed, so nobody else gets an error per meeting.
        meetingMinutesEnabled =
            defaults.object(forKey: "meetingMinutesEnabled") as? Bool
            ?? (ClaudeCodeMinutesWriter.locate(configuredPath: "") != nil)
        meetingMinutesEngine = Self.load("meetingMinutesEngine", from: defaults) ?? .claudeCode
        meetingMinutesModel = Self.load("meetingMinutesModel", from: defaults) ?? .sonnet
        meetingMinutesAPIModel = defaults.string(forKey: "meetingMinutesAPIModel") ?? ""
        meetingMinutesInstructions = defaults.string(forKey: "meetingMinutesInstructions")
            .map { String($0.prefix(MeetingMinutesPrompt.instructionsLimit)) }
        claudeCodePath = defaults.string(forKey: "claudeCodePath") ?? ""
        appModeOverrides = Self.load("appModeOverrides", from: defaults) ?? []
        usdJPYRate = defaults.object(forKey: "usdJPYRate") as? Double ?? UsagePricing.defaultUSDJPYRate
        seedAppModeOverrides()
    }

    /// macOS's own recognizer where the system has it: free, private and needs no setup.
    nonisolated static var defaultTranscriptionProviderID: String {
        AppleSpeechProvider.isSupported ? AppleSpeechProvider().id : SonioxProvider().id
    }

    /// Soniox was the default before macOS's recognizer. Someone who already set up a Soniox key keeps
    /// using it rather than being switched silently. Runs once; choices the user made are left alone.
    public func keepSonioxForExistingUsers(hasSonioxKey: () -> Bool) {
        guard !defaults.bool(forKey: "transcriptionDefaultsMigrated") else { return }
        defaults.set(true, forKey: "transcriptionDefaultsMigrated")
        let unset = ["transcriptionProviderID", "meetingTranscriptionProviderID"].filter {
            defaults.string(forKey: $0) == nil
        }
        guard !unset.isEmpty, hasSonioxKey() else { return }
        let soniox = SonioxProvider().id
        if unset.contains("transcriptionProviderID") { transcriptionProviderID = soniox }
        if unset.contains("meetingTranscriptionProviderID") { meetingTranscriptionProviderID = soniox }
    }

    /// Cleanup mode for the app that will receive the text.
    public func cleanupMode(for bundleID: String?) -> CleanupMode {
        AppModeRules.mode(for: bundleID, overrides: appModeOverrides, default: defaultCleanupMode)
    }

    /// Stores the Custom mode's instructions, cut to `CleanupMode.customInstructionsLimit` characters.
    public func setCustomCleanupInstructions(_ text: String) {
        customCleanupInstructions = String(text.prefix(CleanupMode.customInstructionsLimit))
    }

    /// Stores the minutes prompt's editable part, cut to `MeetingMinutesPrompt.instructionsLimit` characters.
    /// nil, blank or the default text goes back to following the default.
    public func setMeetingMinutesInstructions(_ text: String?) {
        let text = text.map { String($0.prefix(MeetingMinutesPrompt.instructionsLimit)) }
        let isDefault =
            text.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0 == MeetingMinutesPrompt.defaultInstructions
            } ?? true
        meetingMinutesInstructions = isDefault ? nil : text
    }

    public func setMode(_ mode: CleanupMode?, bundleID: String, name: String) {
        appModeOverrides.removeAll { $0.bundleID == bundleID }
        if let mode { appModeOverrides.append(AppModeOverride(bundleID: bundleID, name: name, mode: mode)) }
    }

    /// Adds the initial per-app modes once, keeping any the user already set. Earlier versions applied them as
    /// fixed rules that couldn't be removed; seeding them makes them ordinary, deletable entries.
    private func seedAppModeOverrides() {
        guard !defaults.bool(forKey: "appModeOverridesSeeded") else { return }
        let existing = Set(appModeOverrides.map { $0.bundleID.lowercased() })
        let missing = AppModeRules.initialOverrides.filter { !existing.contains($0.bundleID.lowercased()) }
        if !missing.isEmpty { appModeOverrides += missing }
        defaults.set(true, forKey: "appModeOverridesSeeded")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

public enum BedrockAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey
    case iam

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apiKey: "Bedrock API キー"
        case .iam: "IAM アクセスキー"
        }
    }
}
