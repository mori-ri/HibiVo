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
    public let meetings = MeetingArchive()
    private let inserter = TextInsertionService()
    private let contextBuilder: DictationContextBuilder
    let dictation: DictationController
    public let meeting: MeetingController
    private let hud: HUDController
    private var permissionPollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "app")

    public init() {
        settings = SettingsStore()
        hotkey = HotkeyMonitor(trigger: settings.hotkey)
        let settings = settings
        let vocabulary = vocabulary
        let meetings = meetings
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
        meeting = MeetingController(
            state: state,
            audio: AudioCaptureService(),
            systemAudio: SystemAudioCaptureService.isSupported ? SystemAudioCaptureService() : nil,
            settings: settings,
            secrets: secrets,
            provider: SonioxProvider(),
            fileTranscriber: SonioxFileTranscriber(),
            minutesWriter: {
                ClaudeCodeMinutesWriter.locate(configuredPath: settings.claudeCodePath).map {
                    ClaudeCodeMinutesWriter(executable: $0)
                }
            },
            vocabulary: { vocabulary.activeEntries },
            usage: usage,
            onSaved: {
                meetings.refresh()
                NSWorkspace.shared.activateFileViewerSelecting([$0])
            })
        let dictation = dictation
        let meeting = meeting
        hud = HUDController(state: state, settings: settings, onClick: { dictation.toggleCleanup() })

        hotkey.onAction = { action, occurredAt in
            // Handle outside the tap callback: starting the audio engine can take a while (Bluetooth
            // mics), and a slow callback makes the system disable the event tap.
            Task { @MainActor in
                if meeting.isActive {
                    meeting.handle(action)
                } else if action == .meeting {
                    // The trigger press already began a dictation; drop it and record the meeting instead.
                    dictation.handle(action, at: occurredAt)
                    meeting.start()
                } else {
                    dictation.handle(action, at: occurredAt)
                }
            }
        }
        observeRecording()
    }

    /// Keeps Esc capture in sync with the phase, including stops the hotkey didn't cause
    /// (the recording time cap), so a stale flag never swallows the user's next Esc.
    private func observeRecording() {
        hotkey.isRecording = state.phase == .recording
        withObservationTracking {
            _ = state.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRecording() }
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

    /// Shows the saved meeting transcripts in Finder.
    public func openMeetingsFolder() {
        let url = MeetingController.defaultDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - History actions

    /// Opens a saved meeting file in the default app for Markdown.
    public func openMeetingFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func revealMeetingFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

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
