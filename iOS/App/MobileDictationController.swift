import Foundation
import OSLog
import Observation

/// The dictation state machine of the iOS app:
/// session on (microphone ready) → record (streaming STT) → stop → finish STT → cleanup → hand the
/// text to the keyboard.
///
/// The keyboard drives it with `BridgeCommand`s; the Home screen can turn the session on and off.
@MainActor
@Observable
final class MobileDictationController {
    /// Peak RMS below this means nobody spoke; skip the upload.
    static let silenceThreshold: Float = 0.005
    /// Safety cap in case the user forgets to stop recording.
    static let maximumRecording: Duration = .seconds(600)
    /// The keyboard gets the live transcript at most this often.
    static let partialInterval: Duration = .milliseconds(250)

    private struct Context {
        var provider: any TranscriptionProvider
        var config: TranscriptionConfig
        var cleanupMode: CleanupMode
        var cleanupProvider: (any TextCleanupProvider)?
        var cleanupModel: String
        var customInstructions: String
        var vocabulary: [VocabularyEntry]
    }

    private struct Pumped: Sendable {
        var peak: Float = 0
    }

    private struct Recording {
        var context: Context
        var session: any TranscriptionSession
        /// Forwards audio to STT; returns the peak level seen.
        var pump: Task<Pumped, Never>
        var partials: Task<Void, Never>
        var watchdog: Task<Void, Never>
    }

    private(set) var phase: BridgeState.Phase = .inactive
    /// Live transcript while recording.
    private(set) var partial = ""
    /// Smoothed microphone level (0...1) while recording.
    private(set) var audioLevel: Float = 0
    /// The latest problem, phrased for the user; cleared when the next dictation starts.
    private(set) var lastError: String?
    /// True after the keyboard opened the app, until the user has seen how to go back.
    var showsReturnHint = false

    @ObservationIgnored private let settings: MobileSettings
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let transcriptionProviders: [any TranscriptionProvider]
    @ObservationIgnored private let vocabulary: VocabularyStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let microphone: MicrophoneSession
    @ObservationIgnored private let store: BridgeStore?
    @ObservationIgnored private let cleanup = CleanupCoordinator()
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "dictation")

    @ObservationIgnored private var commands: DarwinNotificationObserver?
    @ObservationIgnored private var lastCommand: UUID?
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var processing: Task<Void, Never>?
    @ObservationIgnored private var standby: Task<Void, Never>?
    @ObservationIgnored private var result: BridgeResult?
    @ObservationIgnored private var notice: BridgeNotice?
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?

    init(
        settings: MobileSettings, secrets: any SecretStore, transcriptionProviders: [any TranscriptionProvider],
        vocabulary: VocabularyStore, history: HistoryStore, microphone: MicrophoneSession, store: BridgeStore?
    ) {
        self.settings = settings
        self.secrets = secrets
        self.transcriptionProviders = transcriptionProviders
        self.vocabulary = vocabulary
        self.history = history
        self.microphone = microphone
        self.store = store

        microphone.onLost = { [weak self] in self?.microphoneLost() }
        commands = DarwinNotificationObserver(name: KeyboardBridge.commandSent) { [weak self] in
            self?.commandSent()
        }
        // A command the keyboard sent while the app wasn't running must not run when it starts.
        lastCommand = store?.command().flatMap { $0.kind == .activate ? nil : $0.id }
        // Replaces whatever a previous run left behind (it may have been stopped mid-session).
        publish()
    }

    var transcriptionProvider: (any TranscriptionProvider)? {
        transcriptionProviders.first { $0.id == settings.transcriptionProviderID } ?? transcriptionProviders.first
    }

    // MARK: - Session

    /// The app was opened through `KeyboardBridge.sessionURL`. Any app can open that URL, so the
    /// microphone is only turned on when the keyboard left its command in the shared container.
    func openedFromKeyboard() async {
        guard let command = store?.command(), command.kind == .activate,
            command.isCurrent(lastHandled: lastCommand)
        else { return }
        lastCommand = command.id
        await startSession()
        showsReturnHint = phase == .ready
    }

    /// Turns the microphone on so the keyboard can start dictations. Must be called in the foreground.
    func startSession() async {
        guard phase == .inactive else {
            publish()
            return
        }
        switch MicrophoneSession.permission {
        case .granted: break
        case .undetermined:
            guard await MicrophoneSession.requestPermission() else {
                report(UserFacingError.microphoneUnavailable.message)
                return
            }
        case .denied:
            report(UserFacingError.microphoneUnavailable.message)
            return
        }
        // Asking for permission suspends; another call may have started the session meanwhile.
        guard phase == .inactive else { return }
        do {
            try microphone.activate()
        } catch {
            report(UserFacingError.microphoneUnavailable.message)
            return
        }
        phase = .ready
        lastError = nil
        restartStandby()
        publish()
    }

    func endSession() {
        guard phase != .inactive else { return }
        dropRecording()
        processing?.cancel()
        standby?.cancel()
        microphone.deactivate()
        becomeInactive()
    }

    private func microphoneLost() {
        dropRecording()
        processing?.cancel()
        standby?.cancel()
        becomeInactive()
    }

    private func becomeInactive() {
        phase = .inactive
        partial = ""
        audioLevel = 0
        // Nothing of what was said stays in the shared container once the session is over.
        result = nil
        showsReturnHint = false
        publish()
    }

    /// Ends the session after a stretch without dictations, so the microphone isn't left on all day.
    private func restartStandby() {
        standby?.cancel()
        let minutes = settings.standbyMinutes
        standby = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60 * minutes))
            guard !Task.isCancelled else { return }
            self?.endSession()
        }
    }

    // MARK: - Commands

    private func commandSent() {
        guard let command = store?.command(), command.isCurrent(lastHandled: lastCommand) else { return }
        // Only acted on when the app is opened through the URL; see `openedFromKeyboard`. It must stay
        // unhandled here: a notification queued while the app was suspended can arrive before the URL.
        guard command.kind != .activate else { return }
        lastCommand = command.id
        switch command.kind {
        case .ping: publish()
        case .activate: break
        case .start: begin()
        case .stop: end()
        case .cancel: cancel()
        }
    }

    // MARK: - Recording

    private func begin() {
        guard phase == .ready else {
            publish()
            return
        }
        let context: Context
        do {
            context = try makeContext()
        } catch {
            report(error.message)
            return
        }
        standby?.cancel()
        lastError = nil
        notice = nil
        result = nil

        let stream = microphone.beginCapture(sampleRate: context.provider.sampleRate)
        let session = context.provider.makeSession(context.config)
        Task { await session.start() }

        phase = .recording
        partial = ""
        audioLevel = 0

        let pump = Task { [weak self] in
            var pumped = Pumped()
            for await chunk in stream {
                pumped.peak = max(pumped.peak, chunk.level)
                // Light smoothing so the meter doesn't flicker.
                if let self { self.audioLevel = self.audioLevel * 0.5 + chunk.level * 0.5 }
                await session.send(chunk.pcm16)
            }
            return pumped
        }
        let partials = Task { [weak self] in
            for await text in session.partials {
                guard let self, self.phase == .recording else { continue }
                self.partial = text
                if let last = self.lastPublish, self.clock.now - last < Self.partialInterval { continue }
                self.publish()
            }
        }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumRecording)
            guard !Task.isCancelled else { return }
            self?.end()
        }
        recording = Recording(context: context, session: session, pump: pump, partials: partials, watchdog: watchdog)
        publish()
    }

    private func end() {
        guard phase == .recording, let recording else {
            publish()
            return
        }
        self.recording = nil
        recording.watchdog.cancel()
        microphone.endCapture()  // Finishes the audio stream, which lets `pump` drain and return.
        phase = .processing
        audioLevel = 0
        publish()
        let stoppedAt = clock.now
        processing = Task { await process(recording, stoppedAt: stoppedAt) }
    }

    private func cancel() {
        switch phase {
        case .recording:
            dropRecording()
        case .processing:
            // The task notices and leaves without a result.
            processing?.cancel()
        case .inactive, .ready:
            publish()
            return
        }
        backToReady()
    }

    /// Stops the recording in progress, if any, and throws its audio away.
    private func dropRecording() {
        guard let recording else { return }
        self.recording = nil
        recording.watchdog.cancel()
        recording.pump.cancel()
        recording.partials.cancel()
        microphone.endCapture()
        Task { await recording.session.cancel() }
    }

    private func backToReady() {
        phase = .ready
        partial = ""
        audioLevel = 0
        restartStandby()
        publish()
    }

    // MARK: - Processing

    private func process(_ recording: Recording, stoppedAt: ContinuousClock.Instant) async {
        let context = recording.context
        let pumped = await recording.pump.value
        recording.partials.cancel()

        guard pumped.peak >= Self.silenceThreshold else {
            await recording.session.cancel()
            log.info("Silence detected (peak \(pumped.peak)); nothing to transcribe")
            if !Task.isCancelled { backToReady() }
            return
        }

        let transcript: String
        do {
            transcript = try await recording.session.finish()
        } catch {
            guard !Task.isCancelled else { return }
            log.error("Transcription failed: \(String(describing: error), privacy: .public)")
            let message = Self.message(for: error, provider: context.provider)
            record(context, raw: "", cleaned: nil, stoppedAt: stoppedAt, status: .failed, error: message)
            fail(message)
            return
        }
        guard !Task.isCancelled else { return }
        guard !transcript.isEmpty else {
            fail(UserFacingError.nothingRecognized.message)
            return
        }

        let (raw, cleaned) = await cleanup.run(
            transcript: transcript, vocabulary: context.vocabulary, mode: context.cleanupMode, appName: nil,
            customInstructions: context.customInstructions,
            language: PromptLanguage(transcriptionLanguage: context.config.language),
            provider: context.cleanupProvider, model: context.cleanupModel)
        guard !Task.isCancelled else { return }

        result = BridgeResult(text: cleaned.text)
        if cleaned.failure != nil {
            lastError = UserFacingError.cleanupFellBack.message
            notice = BridgeNotice(message: UserFacingError.cleanupFellBack.message)
        }
        record(
            context, raw: raw, cleaned: cleaned.didCleanup ? cleaned.text : nil, stoppedAt: stoppedAt,
            status: cleaned.failure == nil ? .pasted : .pastedRaw,
            error: cleaned.failure.map { String(describing: $0) })
        backToReady()
    }

    private func makeContext() throws(UserFacingError) -> Context {
        guard let provider = transcriptionProvider else { throw .transcriptionFailed }
        var apiKey = ""
        if provider.requiresAPIKey {
            guard let key = secrets.secret(for: provider.id), !key.isEmpty else {
                throw .missingAPIKey(provider: provider.displayName)
            }
            apiKey = key
        }
        let entries = vocabulary.activeEntries
        let config = TranscriptionConfig(
            apiKey: apiKey, model: provider.defaultModel, language: settings.language,
            vocabulary: entries.map(\.preferred), readings: entries.flatMap(\.readings))
        let kind = settings.cleanupProviderKind
        return Context(
            provider: provider, config: config, cleanupMode: settings.cleanupEnabled ? settings.cleanupMode : .raw,
            cleanupProvider: settings.cleanupEnabled ? kind.makeProvider(settings: settings, secrets: secrets) : nil,
            cleanupModel: settings.cleanupModel.isEmpty ? kind.defaultModel : settings.cleanupModel,
            customInstructions: settings.customCleanupInstructions, vocabulary: entries)
    }

    private func record(
        _ context: Context, raw: String, cleaned: String?, stoppedAt: ContinuousClock.Instant,
        status: HistoryRecord.Status, error: String?
    ) {
        guard settings.historyEnabled else { return }
        let elapsed = clock.now - stoppedAt
        history.append(
            HistoryRecord(
                timestamp: Date(), rawTranscript: raw, cleanedTranscript: cleaned, appName: nil, bundleID: nil,
                provider: context.provider.displayName, cleanupMode: context.cleanupMode,
                latencyMs: Int(
                    elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
                status: status, errorMessage: error))
    }

    private static func message(for error: Error, provider: any TranscriptionProvider) -> String {
        switch error as? TranscriptionError {
        case .unauthorized: UserFacingError.invalidAPIKey(provider: provider.displayName).message
        case .timedOut: UserFacingError.transcriptionTimedOut.message
        case .modelUnavailable: String(localized: "音声認識モデルを準備しています。少し待ってからもう一度お試しください")
        case .network: UserFacingError.network.message
        default: UserFacingError.transcriptionFailed.message
        }
    }

    // MARK: - Reporting

    /// A dictation failed: back to ready, with the reason shown in the keyboard and the app.
    private func fail(_ message: String) {
        lastError = message
        notice = BridgeNotice(message: message)
        backToReady()
    }

    /// Something couldn't start; the phase stays as it is.
    private func report(_ message: String) {
        lastError = message
        notice = BridgeNotice(message: message)
        publish()
    }

    /// Writes the state for the keyboard and tells it to look.
    private func publish() {
        lastPublish = clock.now
        let state = BridgeState(phase: phase, partial: partial, result: result, notice: notice)
        do {
            try store?.write(state)
        } catch {
            log.error("Could not write the keyboard state: \(error.localizedDescription, privacy: .public)")
        }
        DarwinNotification.post(KeyboardBridge.stateChanged)
    }
}
