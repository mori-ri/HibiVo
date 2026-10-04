import Foundation
import OSLog

/// The dictation state machine:
/// press → record (streaming STT) → stop → finish STT → cleanup → paste.
///
/// A short tap latches recording until the next press; holding the key past `holdThreshold`
/// works as push-to-talk and stops on release.
@MainActor
public final class DictationController {
    /// Peak RMS below this means nobody spoke; skip the upload and the paste.
    static let silenceThreshold: Float = 0.005
    /// Safety cap in case the user forgets to stop recording.
    static let maximumRecording: Duration = .seconds(600)

    private struct Pumped {
        var peak: Float = 0
        var bytes = 0
    }

    private struct Recording {
        var context: DictationContext
        var session: any TranscriptionSession
        var startedAt: ContinuousClock.Instant
        /// Forwards audio to STT; returns the peak level seen and how much audio was sent.
        var pump: Task<Pumped, Never>
        var partials: Task<Void, Never>
        var watchdog: Task<Void, Never>
        /// Whether the key that started this recording is still down.
        var isHeld = true
    }

    private let state: AppState
    private let audio: any AudioCapturing
    private let contextBuilder: DictationContextBuilder
    private let activeApp: any ActiveApplicationProviding
    private let inserter: any TextInserting
    private let correctionWatcher: (any CorrectionWatching)?
    private let cleanup: CleanupCoordinator
    private let history: HistoryStore?
    private let historyEnabled: @MainActor () -> Bool
    private let usage: UsageStore?
    private let microphoneUID: @MainActor () -> String?
    private let ducker: (any OutputDucking)?
    private let duckingEnabled: @MainActor () -> Bool
    /// Recordings stopped sooner than this are treated as an accidental double tap.
    private let minimumDuration: Duration
    /// Releasing the key after holding it at least this long stops recording (push-to-talk).
    /// A shorter press keeps recording until the next press.
    private let holdThreshold: Duration
    private let clock = ContinuousClock()
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "dictation")

    private var recording: Recording?
    private var processing: Task<Void, Never>?
    private var errorDismiss: Task<Void, Never>?

    public init(
        state: AppState,
        audio: any AudioCapturing,
        contextBuilder: DictationContextBuilder,
        activeApp: any ActiveApplicationProviding,
        inserter: any TextInserting,
        correctionWatcher: (any CorrectionWatching)? = nil,
        cleanup: CleanupCoordinator = CleanupCoordinator(),
        history: HistoryStore? = nil,
        historyEnabled: @escaping @MainActor () -> Bool = { true },
        usage: UsageStore? = nil,
        microphoneUID: @escaping @MainActor () -> String? = { nil },
        ducker: (any OutputDucking)? = nil,
        duckingEnabled: @escaping @MainActor () -> Bool = { true },
        minimumDuration: Duration = .milliseconds(250),
        holdThreshold: Duration = .milliseconds(400)
    ) {
        self.state = state
        self.audio = audio
        self.contextBuilder = contextBuilder
        self.activeApp = activeApp
        self.inserter = inserter
        self.correctionWatcher = correctionWatcher
        self.cleanup = cleanup
        self.history = history
        self.historyEnabled = historyEnabled
        self.usage = usage
        self.microphoneUID = microphoneUID
        self.ducker = ducker
        self.duckingEnabled = duckingEnabled
        self.minimumDuration = minimumDuration
        self.holdThreshold = holdThreshold
    }

    /// - Parameter time: When the key event happened. Holds are measured between event times, not
    ///   handling times, because a release can wait behind a slow audio engine start.
    public func handle(_ action: HotkeyAction, at time: ContinuousClock.Instant? = nil) {
        let time = time ?? clock.now
        switch action {
        case .pressed where state.phase == .recording: end(at: time)
        case .pressed: begin(pressedAt: time)
        case .released: releaseKey(at: time)
        case .interrupted, .escape, .meeting: cancel()
        }
    }

    /// Flips AI cleanup from the HUD while recording. The HUD reflects the new setting at once,
    /// so the utterance in progress switches too instead of keeping the value frozen at the start.
    public func toggleCleanup() {
        guard state.phase == .recording, let recording else { return }
        contextBuilder.settings.cleanupEnabled.toggle()
        self.recording?.context.cleanup = contextBuilder.cleanup(for: recording.context.target)
    }

    /// Waits for the current utterance to be fully processed. Used by tests.
    func waitUntilIdle() async {
        await processing?.value
    }

    // MARK: - Recording

    private func begin(pressedAt: ContinuousClock.Instant) {
        // A press while processing is ignored so pastes never interleave.
        guard !state.phase.isActive else { return }
        errorDismiss?.cancel()
        // Starting again means the user is done fixing the last text.
        correctionWatcher?.stop()

        let context: DictationContext
        do {
            context = try contextBuilder.make(target: activeApp.frontmostApplication())
        } catch {
            show(error)
            return
        }

        let stream: AsyncStream<AudioChunk>
        do {
            stream = try audio.start(sampleRate: context.transcriptionProvider.sampleRate, deviceUID: microphoneUID())
        } catch {
            log.error("Audio start failed: \(String(describing: error), privacy: .public)")
            show(.microphoneUnavailable)
            return
        }

        let session = context.transcriptionProvider.makeSession(context.transcriptionConfig)
        Task { await session.start() }
        if duckingEnabled() { ducker?.duck() }

        state.phase = .recording
        state.audioLevel = 0
        state.partialTranscript = ""

        let pump = Task { [state] in
            var pumped = Pumped()
            for await chunk in stream {
                pumped.peak = max(pumped.peak, chunk.level)
                // Light smoothing so the meter doesn't flicker.
                state.audioLevel = state.audioLevel * 0.5 + chunk.level * 0.5
                await session.send(chunk.pcm16)
                pumped.bytes += chunk.pcm16.count
            }
            return pumped
        }
        let partials = Task { [state] in
            for await text in session.partials where state.phase == .recording {
                state.partialTranscript = text
            }
        }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumRecording)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.end(at: self.clock.now)
        }
        recording = Recording(
            context: context, session: session, startedAt: pressedAt, pump: pump, partials: partials,
            watchdog: watchdog)
    }

    /// Ends a push-to-talk hold; a short tap leaves recording running until the next press.
    private func releaseKey(at time: ContinuousClock.Instant) {
        guard state.phase == .recording, let recording, recording.isHeld else { return }
        if time - recording.startedAt >= holdThreshold {
            end(at: time)
        } else {
            self.recording?.isHeld = false
        }
    }

    private func end(at time: ContinuousClock.Instant) {
        guard state.phase == .recording, var recording else { return }
        if time - recording.startedAt < minimumDuration {
            cancel()
            return
        }
        retargetToFrontmost(&recording.context)
        self.recording = nil
        recording.watchdog.cancel()
        audio.stop()  // Finishes the audio stream, which lets `pump` drain and return.
        ducker?.restore()
        state.phase = .processing
        let stoppedAt = clock.now
        processing = Task { await process(recording, stoppedAt: stoppedAt) }
    }

    /// The text goes where the caret is when recording stops: people often start talking while
    /// reading something and only then move to the field they are writing in. HibiVo's own
    /// windows don't count, so the app from key-down is kept when one of them is in front.
    private func retargetToFrontmost(_ context: inout DictationContext) {
        guard let app = activeApp.frontmostApplication(),
            app.processID != ProcessInfo.processInfo.processIdentifier,
            app.processID != context.target?.processID
        else { return }
        log.info("Paste target moved to \(app.bundleID ?? app.name, privacy: .public) while recording")
        context.retarget(to: app)
    }

    private func cancel() {
        guard state.phase == .recording, let recording else { return }
        self.recording = nil
        recording.watchdog.cancel()
        audio.stop()
        ducker?.restore()
        recording.pump.cancel()
        recording.partials.cancel()
        processing = Task {
            await recording.session.cancel()
            // Audio already streamed is billed even though the utterance was dropped.
            recordUsage(recording.context, audio: await recording.pump.value)
        }
        state.phase = .idle
    }

    // MARK: - Processing

    private func process(_ recording: Recording, stoppedAt: ContinuousClock.Instant) async {
        let context = recording.context
        let pumped = await recording.pump.value
        recording.partials.cancel()

        guard pumped.peak >= Self.silenceThreshold else {
            await recording.session.cancel()
            recordUsage(context, audio: pumped)
            log.info("Silence detected (peak \(pumped.peak)); nothing to transcribe")
            state.phase = .idle
            return
        }

        let transcript: String
        do {
            transcript = try await recording.session.finish()
        } catch {
            log.error("Transcription failed: \(String(describing: error), privacy: .public)")
            recordUsage(context, audio: pumped)
            let message = Self.userFacing(error, provider: context.transcriptionProvider)
            record(context, raw: "", cleaned: nil, stoppedAt: stoppedAt, status: .failed, error: message.message)
            show(message)
            return
        }
        let sttDone = clock.now
        guard !transcript.isEmpty else {
            recordUsage(context, audio: pumped)
            show(.nothingRecognized)
            return
        }

        let (raw, cleaned) = await cleanup.run(
            transcript: transcript, vocabulary: context.vocabulary, mode: context.cleanup.mode,
            appName: context.target?.name, customInstructions: context.cleanup.customInstructions,
            provider: context.cleanup.provider, model: context.cleanup.model)
        let cleanupDone = clock.now

        let outcome = await inserter.insert(cleaned.text, into: context.target)
        recordUsage(context, audio: pumped, inserted: cleaned.text, cleanup: cleaned)
        log.info(
            "Stop→STT \(sttDone - stoppedAt), cleanup \(cleanupDone - sttDone), paste \(self.clock.now - cleanupDone)"
        )

        let status: HistoryRecord.Status =
            switch outcome {
            case .copiedOnly: .copiedOnly
            case .pasted: cleaned.failure == nil ? .pasted : .pastedRaw
            }
        record(
            context, raw: raw, cleaned: cleaned.didCleanup ? cleaned.text : nil, stoppedAt: stoppedAt,
            status: status, error: cleaned.failure.map { String(describing: $0) })

        switch outcome {
        case .copiedOnly(let reason): show(.copiedOnly(reason: reason))
        case .pasted where cleaned.failure != nil: show(.cleanupFellBack)
        case .pasted: state.phase = .idle
        }
        if outcome == .pasted { correctionWatcher?.watch(inserted: cleaned.text, target: context.target) }
    }

    private func record(
        _ context: DictationContext, raw: String, cleaned: String?, stoppedAt: ContinuousClock.Instant,
        status: HistoryRecord.Status, error: String?
    ) {
        guard historyEnabled() else { return }
        let elapsed = clock.now - stoppedAt
        history?.append(
            HistoryRecord(
                timestamp: Date(),
                rawTranscript: raw,
                cleanedTranscript: cleaned,
                appName: context.target?.name,
                bundleID: context.target?.bundleID,
                provider: context.transcriptionProvider.displayName,
                cleanupMode: context.cleanup.mode,
                latencyMs: Int(
                    elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
                status: status,
                errorMessage: error))
    }

    private func recordUsage(
        _ context: DictationContext, audio: Pumped, inserted: String? = nil, cleanup outcome: CleanupOutcome? = nil
    ) {
        guard let usage else { return }
        let provider = context.transcriptionProvider
        // Mono PCM16: two bytes per sample.
        let seconds = Double(audio.bytes) / (provider.sampleRate * 2)
        usage.record(
            UsageEvent(
                dictations: inserted == nil ? 0 : 1,
                characters: inserted?.count ?? 0,
                transcription: TranscriptionUsage(
                    provider: provider.id, model: context.transcriptionConfig.model, seconds: seconds),
                cleanup: outcome?.usage.flatMap { tokens in
                    context.cleanup.provider.map { CleanupUsage($0, model: context.cleanup.model, tokens: tokens) }
                }))
    }

    private static func userFacing(_ error: Error, provider: any TranscriptionProvider) -> UserFacingError {
        switch error as? TranscriptionError {
        case .unauthorized: .invalidAPIKey(provider: provider.displayName)
        case .timedOut: .transcriptionTimedOut
        case .modelUnavailable: .speechModelNotReady
        case .network: .network
        default: .transcriptionFailed
        }
    }

    private func show(_ error: UserFacingError) {
        state.phase = .error(error.message)
        errorDismiss?.cancel()
        errorDismiss = Task { [state] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, case .error = state.phase else { return }
            state.phase = .idle
        }
    }
}
