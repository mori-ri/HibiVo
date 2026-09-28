import Foundation
import OSLog

/// Meeting transcription: trigger+M starts a recording that runs until the trigger is tapped again,
/// transcribed with speaker labels and saved to a Markdown file as it goes.
///
/// When enabled, the system audio (the remote side of an online meeting) is mixed into the
/// microphone so one diarized STT session hears everyone: people in the room and online alike get
/// their own speaker number, at the cost of one stream. Unlike dictation nothing is pasted. The file
/// is rewritten every few seconds so a crash loses at most the last moments, and a dropped STT
/// connection is re-opened without stopping the recording.
@MainActor
public final class MeetingController {
    /// Stops a meeting that was forgotten, so it doesn't bill for hours.
    static let maximumDuration: Duration = .seconds(4 * 3600)
    public static let defaultReconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30),
    ]
    /// Seconds one source may run ahead of the other before it is sent alone (the other counts as silent).
    static let maximumMixLag = 0.3

    @MainActor
    private final class Meeting {
        let config: TranscriptionConfig
        let startedAt: Date
        let fileURL: URL
        let vocabulary: [VocabularyEntry]
        var transcript = MeetingTranscript()
        var session: any MeetingTranscriptionSession
        /// Bumped per STT session so events from a replaced session are ignored.
        var generation = 0
        var events: Task<Void, Never>?
        var pumps: [Task<Void, Never>] = []
        /// Audio ready for STT, in order. One sender drains it so the two sources can't reorder chunks.
        let outgoing: AsyncStream<Data>
        let outgoingContinuation: AsyncStream<Data>.Continuation
        var sender: Task<Void, Never>?
        var reconnect: Task<Void, Never>?
        var reconnectAttempts = 0
        /// Whether the current session produced any final text, i.e. its speaker labels were used.
        var sessionHadSpeech = false
        /// nil while only the microphone is recorded.
        var mixer: PCMMixer?
        /// System audio was asked for but could not be started.
        var systemAudioUnavailable = false
        /// Loudest system-audio chunk; exactly 0 suggests the permission is missing.
        var systemPeak: Float = 0
        var systemBytes = 0
        /// Audio sent to STT so far (PCM16 mono), which is also the meeting clock for new sessions.
        var bytes = 0
        var isDirty = false
        var isStopping = false
        /// Shown after the meeting ends, e.g. the API key was rejected mid-meeting.
        var failure: UserFacingError?
        var activity: NSObjectProtocol?

        init(
            config: TranscriptionConfig, startedAt: Date, fileURL: URL, vocabulary: [VocabularyEntry],
            session: any MeetingTranscriptionSession
        ) {
            self.config = config
            self.startedAt = startedAt
            self.fileURL = fileURL
            self.vocabulary = vocabulary
            self.session = session
            (outgoing, outgoingContinuation) = AsyncStream.makeStream()
        }
    }

    private let state: AppState
    private let audio: any AudioCapturing
    private let systemAudio: (any AudioCapturing)?
    private let settings: SettingsStore
    private let secrets: any SecretStore
    private let provider: any MeetingTranscriptionProvider
    private let vocabulary: @MainActor () -> [VocabularyEntry]
    private let usage: UsageStore?
    private let directory: URL
    private let saveInterval: Duration
    private let reconnectDelays: [Duration]
    private let onSaved: @MainActor (URL) -> Void
    private let writer = MeetingFileWriter()
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "meeting")

    private var meeting: Meeting?
    private var saver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var errorDismiss: Task<Void, Never>?

    /// - Parameter systemAudio: Captures the remote side of an online meeting; nil where unsupported.
    ///   Used only while `settings.meetingCapturesSystemAudio` is on.
    public init(
        state: AppState,
        audio: any AudioCapturing,
        systemAudio: (any AudioCapturing)? = nil,
        settings: SettingsStore,
        secrets: any SecretStore,
        provider: any MeetingTranscriptionProvider,
        vocabulary: @escaping @MainActor () -> [VocabularyEntry] = { [] },
        usage: UsageStore? = nil,
        directory: URL = MeetingController.defaultDirectory,
        saveInterval: Duration = .seconds(5),
        reconnectDelays: [Duration] = MeetingController.defaultReconnectDelays,
        onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.state = state
        self.audio = audio
        self.systemAudio = systemAudio
        self.settings = settings
        self.secrets = secrets
        self.provider = provider
        self.vocabulary = vocabulary
        self.usage = usage
        self.directory = directory
        self.saveInterval = saveInterval
        self.reconnectDelays = reconnectDelays.isEmpty ? [.zero] : reconnectDelays
        self.onSaved = onSaved
    }

    /// `~/Library/Application Support/HibiVo/Meetings`
    public static var defaultDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "HibiVo").appending(path: "Meetings")
    }

    /// True from start until the file has been saved after stopping.
    public var isActive: Bool { meeting != nil }

    /// Hotkey actions while a meeting runs. Stopping on release rather than press means a trigger
    /// used together with another key (Fn+←, Fn+F …) is an interruption and keeps the meeting going.
    public func handle(_ action: HotkeyAction) {
        switch action {
        case .released, .meeting: stop()
        case .pressed, .interrupted, .escape: break
        }
    }

    /// Waits for a stopping meeting to be saved. Used by tests.
    func waitUntilIdle() async {
        await stopping?.value
    }

    public func start() {
        guard meeting == nil, !state.phase.isActive else { return }
        errorDismiss?.cancel()

        guard let apiKey = secrets.secret(for: provider.id), !apiKey.isEmpty else {
            show(.meetingRequiresAPIKey(provider: provider.displayName))
            return
        }
        let entries = vocabulary()
        let config = TranscriptionConfig(
            apiKey: apiKey,
            model: provider.models.contains(settings.transcriptionModel)
                ? settings.transcriptionModel : provider.defaultModel,
            language: settings.language,
            vocabulary: entries.map(\.preferred),
            speakerDiarization: true)

        let microphone: AsyncStream<AudioChunk>
        do {
            microphone = try audio.start(sampleRate: provider.sampleRate, deviceUID: settings.microphoneUID)
        } catch {
            log.error("Audio start failed: \(String(describing: error), privacy: .public)")
            show(.microphoneUnavailable)
            return
        }

        var system: AsyncStream<AudioChunk>?
        var systemAudioUnavailable = false
        if settings.meetingCapturesSystemAudio {
            do {
                guard let systemAudio else { throw AudioCaptureError.engineFailed("unsupported") }
                system = try systemAudio.start(sampleRate: provider.sampleRate, deviceUID: nil)
            } catch {
                // The microphone alone still makes a useful record; the file says what is missing.
                log.error("System audio start failed: \(String(describing: error), privacy: .public)")
                systemAudioUnavailable = true
            }
        }

        let startedAt = Date()
        let meeting = Meeting(
            config: config, startedAt: startedAt,
            fileURL: directory.appending(path: MeetingDocument.fileName(startedAt: startedAt)),
            vocabulary: entries, session: provider.makeMeetingSession(config))
        meeting.systemAudioUnavailable = systemAudioUnavailable
        meeting.activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Meeting transcription")
        self.meeting = meeting
        open(meeting.session, in: meeting)
        meeting.sender = Task {
            for await pcm16 in meeting.outgoing {
                meeting.bytes += pcm16.count
                // Read the session each time: a reconnect swaps it while audio keeps flowing.
                await meeting.session.send(pcm16)
            }
        }

        if let system {
            meeting.mixer = PCMMixer(maximumLag: Int(provider.sampleRate * Self.maximumMixLag))
            meeting.pumps = [
                pump(microphone, as: .microphone, into: meeting), pump(system, as: .system, into: meeting),
            ]
        } else {
            meeting.pumps = [pump(microphone, as: .microphone, into: meeting)]
        }

        saver = Task { [weak self, saveInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: saveInterval)
                guard !Task.isCancelled else { return }
                await self?.saveIfDirty()
            }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }

        state.phase = .meeting
        state.meetingStartedAt = startedAt
        state.meetingReconnecting = false
        state.audioLevel = 0
        state.partialTranscript = ""
        log.info("Meeting started (system audio: \(system != nil))")
    }

    public func stop() {
        guard let meeting, !meeting.isStopping else { return }
        meeting.isStopping = true
        watchdog?.cancel()
        saver?.cancel()
        meeting.reconnect?.cancel()
        // Finishes the audio streams, which lets the pumps drain.
        audio.stop()
        if meeting.mixer != nil { systemAudio?.stop() }
        state.phase = .processing
        state.meetingReconnecting = false
        stopping = Task { await finish(meeting) }
    }

    // MARK: - Audio

    /// Forwards one source to STT, through the mixer when there are two. Runs on the main actor, so
    /// the two pumps never touch the mixer at the same time.
    private func pump(_ stream: AsyncStream<AudioChunk>, as input: PCMMixer.Input, into meeting: Meeting) -> Task<
        Void, Never
    > {
        Task { [state] in
            for await chunk in stream {
                switch input {
                case .microphone:
                    // The meter follows the microphone: that is the one the user controls.
                    state.audioLevel = state.audioLevel * 0.5 + chunk.level * 0.5
                case .system:
                    meeting.systemPeak = max(meeting.systemPeak, chunk.level)
                    meeting.systemBytes += chunk.pcm16.count
                }
                let ready = meeting.mixer == nil ? chunk.pcm16 : meeting.mixer?.push(chunk.pcm16, from: input)
                if let ready { meeting.outgoingContinuation.yield(ready) }
            }
        }
    }

    // MARK: - Sessions

    private func open(_ session: any MeetingTranscriptionSession, in meeting: Meeting) {
        meeting.generation += 1
        let generation = meeting.generation
        Task { await session.start() }
        meeting.events = Task { [weak self] in
            for await event in session.events {
                self?.handle(event, generation: generation, in: meeting)
            }
        }
    }

    private func handle(_ event: MeetingSessionEvent, generation: Int, in meeting: Meeting) {
        guard generation == meeting.generation else { return }
        switch event {
        case .tokens(let tokens):
            meeting.transcript.apply(tokens)
            if tokens.contains(where: \.isFinal) {
                meeting.isDirty = true
                meeting.reconnectAttempts = 0
                meeting.sessionHadSpeech = true
            }
            // Any reply means the session is up, even while nobody is talking.
            if state.meetingReconnecting { state.meetingReconnecting = false }
            if state.phase == .meeting { state.partialTranscript = meeting.transcript.liveTail }
        case .ended(let error):
            guard !meeting.isStopping else { return }
            if error == .unauthorized {
                log.error("Meeting STT rejected the API key")
                meeting.failure = .invalidAPIKey(provider: provider.displayName)
                stop()
                return
            }
            log.notice(
                "Meeting STT session ended (\(String(describing: error), privacy: .public)); reconnecting")
            scheduleReconnect(meeting)
        }
    }

    private func scheduleReconnect(_ meeting: Meeting) {
        state.meetingReconnecting = true
        let delay = reconnectDelays[min(meeting.reconnectAttempts, reconnectDelays.count - 1)]
        meeting.reconnectAttempts += 1
        meeting.reconnect?.cancel()
        meeting.reconnect = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !meeting.isStopping else { return }
            let old = meeting.session
            Task { await old.cancel() }
            let now = self.milliseconds(meeting.bytes)
            // Note the relabelled speakers once per outage, not once per failed attempt.
            if meeting.sessionHadSpeech {
                meeting.transcript.markReconnect(atMs: now)
                meeting.isDirty = true
            } else {
                meeting.transcript.offsetMs = now
            }
            meeting.sessionHadSpeech = false
            meeting.session = provider.makeMeetingSession(meeting.config)
            open(meeting.session, in: meeting)
        }
    }

    // MARK: - Finishing

    private func finish(_ meeting: Meeting) async {
        for pump in meeting.pumps { await pump.value }
        if let tail = meeting.mixer?.flush() { meeting.outgoingContinuation.yield(tail) }
        meeting.outgoingContinuation.finish()
        await meeting.sender?.value
        // Finalizes the tail of the audio; the resulting tokens arrive through `events` before it closes.
        _ = try? await meeting.session.finish()
        await meeting.events?.value
        // An autosave already under way must land before the final write, or it would overwrite it.
        await saver?.value
        if let activity = meeting.activity { ProcessInfo.processInfo.endActivity(activity) }
        recordUsage(meeting)

        var saved = false
        if meeting.transcript.isEmpty {
            await writer.remove(meeting.fileURL)
        } else {
            saved = await writer.write(markdown(meeting, ended: true), to: meeting.fileURL)
        }
        self.meeting = nil
        state.meetingStartedAt = nil
        state.partialTranscript = ""
        log.info("Meeting stopped (\(meeting.transcript.segments.count) segments)")

        if saved { onSaved(meeting.fileURL) }
        if let failure = meeting.failure {
            show(failure)
        } else if meeting.transcript.isEmpty {
            show(.nothingRecognized)
        } else if !saved {
            show(.meetingSaveFailed)
        } else {
            state.phase = .idle
        }
    }

    private func saveIfDirty() async {
        guard let meeting, meeting.isDirty, !meeting.isStopping, !meeting.transcript.isEmpty else { return }
        meeting.isDirty = false
        if !(await writer.write(markdown(meeting, ended: false), to: meeting.fileURL)) {
            meeting.isDirty = true
        }
    }

    private func markdown(_ meeting: Meeting, ended: Bool) -> String {
        var notices: [MeetingDocument.Notice] = []
        if meeting.systemAudioUnavailable { notices.append(.systemAudioUnavailable) }
        // A denied permission yields exact digital silence rather than an error. Only judge at the end:
        // the other side may simply not have spoken yet.
        if ended, meeting.mixer != nil, meeting.systemBytes > 0, meeting.systemPeak == 0 {
            notices.append(.systemAudioSilent)
        }
        return MeetingDocument.markdown(
            meeting.transcript, startedAt: meeting.startedAt, endedAt: ended ? Date() : nil,
            includesSystemAudio: meeting.mixer != nil, notices: notices, vocabulary: meeting.vocabulary)
    }

    private func milliseconds(_ bytes: Int) -> Int {
        // Mono PCM16: two bytes per sample.
        Int(Double(bytes) / (provider.sampleRate * 2) * 1000)
    }

    private func recordUsage(_ meeting: Meeting) {
        guard let usage, meeting.bytes > 0 else { return }
        usage.record(
            UsageEvent(
                transcription: TranscriptionUsage(
                    provider: provider.id, model: meeting.config.model,
                    seconds: Double(milliseconds(meeting.bytes)) / 1000)))
    }

    private func show(_ error: UserFacingError) {
        state.phase = .error(error.message)
        errorDismiss?.cancel()
        errorDismiss = Task { [state] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, case .error = state.phase else { return }
            state.phase = .idle
        }
    }
}

/// Writes meeting files off the main actor, atomically so a crash mid-write keeps the previous version.
actor MeetingFileWriter {
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "meeting")

    func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: [.atomic])
            return true
        } catch {
            log.error("Could not save meeting: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
