import AppKit
import OSLog

/// Composition root: builds every service once and wires them together.
@MainActor
public final class AppEnvironment {
    public let state = AppState()
    public let settings: SettingsStore
    public let hotkey: HotkeyMonitor
    public let secrets: any SecretStore = KeychainService()
    public let transcriptionProviders: [any TranscriptionProvider] = [SonioxProvider(), GeminiLiveProvider()]
    public let vocabulary = VocabularyStore()
    public let history = HistoryStore()
    public let usage = UsageStore()
    private let inserter = TextInsertionService()
    private let contextBuilder: DictationContextBuilder
    let dictation: DictationController
    private let hud: HUDController
    private var permissionPollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "app")

    public init() {
        settings = SettingsStore()
        hotkey = HotkeyMonitor(trigger: settings.hotkey)
        let settings = settings
        let vocabulary = vocabulary
        contextBuilder = DictationContextBuilder(
            settings: settings, secrets: secrets, transcriptionProviders: transcriptionProviders,
            vocabulary: { vocabulary.activeEntries })
        dictation = DictationController(
            state: state,
            audio: AudioCaptureService(),
            contextBuilder: contextBuilder,
            activeApp: ActiveApplicationService(),
            inserter: inserter,
            history: history,
            historyEnabled: { settings.historyEnabled },
            usage: usage,
            microphoneUID: { settings.microphoneUID },
            ducker: SystemVolumeDucker(),
            duckingEnabled: { settings.duckOutputWhileRecording })
        let dictation = dictation
        hud = HUDController(state: state, settings: settings, onClick: { dictation.toggleCleanup() })

        hotkey.onAction = { [weak self] action in
            // Handle outside the tap callback: starting the audio engine can take a while (Bluetooth
            // mics), and a slow callback makes the system disable the event tap.
            Task { @MainActor [weak self] in
                guard let self else { return }
                dictation.handle(action)
                hotkey.isRecording = state.phase == .recording
            }
        }
    }

    /// Called once the app has finished launching.
    public func start() {
        Task { await requestMicrophoneIfNeeded() }
        state.hasAccessibilityPermission = Permissions.isAccessibilityTrusted
        if !state.hasAccessibilityPermission { Permissions.promptForAccessibility() }
        startHotkeyWhenTrusted()
    }

    public func applyHotkey(_ trigger: HotkeyTrigger) {
        settings.hotkey = trigger
        hotkey.trigger = trigger
    }

    // MARK: - History actions

    /// Pastes a previous result into whatever app is frontmost.
    /// When called from our own window, hide it first so focus returns to the previous app.
    public func pasteAgain(_ text: String) {
        Task {
            if NSApp.isActive {
                NSApp.hide(nil)
                try? await Task.sleep(for: .milliseconds(250))
            }
            if case .copiedOnly(let reason) = await inserter.insert(text, into: nil) {
                state.phase = .error(UserFacingError.copiedOnly(reason: reason).message)
                try? await Task.sleep(for: .seconds(2.5))
                state.phase = .idle
            }
        }
    }

    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Re-runs cleanup on a record's raw transcript with the current settings and updates it in place.
    public func retryCleanup(_ record: HistoryRecord) async -> Bool {
        guard !record.rawTranscript.isEmpty else { return false }
        let cleanup = contextBuilder.cleanup(for: nil)
        let mode = record.cleanupMode == .raw ? settings.defaultCleanupMode : record.cleanupMode
        let outcome = await CleanupCoordinator(timeout: .seconds(20)).run(
            .init(
                raw: record.rawTranscript, mode: mode,
                vocabulary: vocabulary.activeEntries.map(\.promptTerm), appName: record.appName),
            provider: cleanup.provider, model: cleanup.model)
        if let tokens = outcome.usage, let provider = cleanup.provider {
            usage.record(UsageEvent(cleanup: CleanupUsage(provider, model: cleanup.model, tokens: tokens)))
        }
        guard outcome.didCleanup else { return false }
        var updated = record
        updated.cleanedTranscript = outcome.text
        updated.cleanupMode = mode
        updated.errorMessage = nil
        if updated.status == .pastedRaw { updated.status = .pasted }
        history.update(updated)
        return true
    }

    private func requestMicrophoneIfNeeded() async {
        switch AudioCaptureService.permissionStatus {
        case .authorized: state.hasMicrophonePermission = true
        case .notDetermined: state.hasMicrophonePermission = await AudioCaptureService.requestPermission()
        default: state.hasMicrophonePermission = false
        }
    }

    /// The tap can only be created after Accessibility is granted, so poll until then.
    private func startHotkeyWhenTrusted() {
        if hotkey.start() {
            state.hasAccessibilityPermission = true
            return
        }
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if Permissions.isAccessibilityTrusted, hotkey.start() {
                    state.hasAccessibilityPermission = true
                    log.info("Accessibility granted; hotkey active")
                    return
                }
            }
        }
    }
}
