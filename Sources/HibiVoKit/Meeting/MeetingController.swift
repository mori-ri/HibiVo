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
///
/// macOS's own recognizer can't tell speakers apart, so its meetings have no speaker numbers, and it
/// has no after-meeting mode: it always transcribes as the meeting runs.
///
/// In after-meeting mode (`MeetingTranscriptionTiming.afterMeeting`) there is no STT session while
/// recording: the mixed audio is kept in memory and sent to the file transcriber once the meeting
/// ends, which separates speakers far better. That runs in the background, so dictation and the next
/// meeting are available right away.
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
        let provider: any MeetingTranscriptionProvider
        /// Set in after-meeting mode only.
        let fileTranscriber: (any MeetingFileTranscriber)?
        let config: TranscriptionConfig
        let startedAt: Date
        let fileURL: URL
        let vocabulary: [VocabularyEntry]
        var transcript = MeetingTranscript()
        /// nil in after-meeting mode.
        var session: (any MeetingTranscriptionSession)?
        /// The whole meeting's audio, kept in memory (never on disk) in after-meeting mode.
        var recorded: Data?
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
        var microphoneUnavailable = false
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
        /// When recording stopped; transcription may finish minutes later.
        var endedAt: Date?
        /// The user's notes (`AppState.meetingNotes`) as of the last save, final once stopping.
        var notes = ""

        var hasNotes: Bool { MeetingDocument.notesSection(notes) != nil }
        /// Kept even without speech: it records a capture failure or holds the user's notes.
        var keepsDocument: Bool { microphoneUnavailable || hasNotes }

        init(
            provider: any MeetingTranscriptionProvider, fileTranscriber: (any MeetingFileTranscriber)?,
            config: TranscriptionConfig, startedAt: Date, fileURL: URL, vocabulary: [VocabularyEntry],
            session: (any MeetingTranscriptionSession)?
        ) {
            self.provider = provider
            self.fileTranscriber = fileTranscriber
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
    /// Read when a meeting starts, so a changed setting applies from the next meeting.
    private let transcriber: @MainActor () -> MeetingTranscriber
    /// Built when a meeting is saved, so a changed Claude Code path or setting takes effect; nil when
    /// minutes are off or Claude Code can't be found.
    private let minutesWriter: @MainActor () -> (any MeetingMinutesWriting)?
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
    /// After-meeting transcriptions and minutes still running.
    private var transcriptions: [Task<Void, Never>] = []

    /// - Parameter systemAudio: Captures the remote side of an online meeting; nil where unsupported.
    ///   Used only while `settings.meetingCapturesSystemAudio` is on.
    public init(
        state: AppState,
        audio: any AudioCapturing,
        systemAudio: (any AudioCapturing)? = nil,
        settings: SettingsStore,
        secrets: any SecretStore,
        transcriber: @escaping @MainActor () -> MeetingTranscriber,
        minutesWriter: @escaping @MainActor () -> (any MeetingMinutesWriting)? = { nil },
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
        self.transcriber = transcriber
        self.minutesWriter = minutesWriter
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

    /// Waits for a stopping meeting to be saved, including after-meeting transcription and minutes.
    /// Used by tests.
    func waitUntilIdle() async {
        await stopping?.value
        // Transcriptions append their minutes task while running, so loop until nothing is left.
        var index = 0
        while index < transcriptions.count {
            await transcriptions[index].value
            index += 1
        }
    }

    public func start() {
        guard meeting == nil, !state.phase.isActive else { return }
        errorDismiss?.cancel()

        let stt = transcriber()
        let provider = stt.provider
        var apiKey = ""
        if provider.requiresAPIKey {
            guard let key = secrets.secret(for: provider.id), !key.isEmpty else {
                show(.meetingRequiresAPIKey(provider: provider.displayName))
                return
            }
            apiKey = key
        }
        guard provider.isReady(language: settings.language) else {
            show(.speechModelNotReady)
            return
        }
        let entries = vocabulary()
        let config = TranscriptionConfig(
            apiKey: apiKey,
            model: provider.models.contains(settings.transcriptionModel)
                ? settings.transcriptionModel : provider.defaultModel,
            language: settings.language,
            vocabulary: entries.map(\.preferred),
            readings: entries.flatMap(\.readings),
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

        let fileTranscriber = settings.meetingTranscriptionTiming == .afterMeeting ? stt.fileTranscriber : nil
        let afterMeeting = fileTranscriber != nil
        let startedAt = Date()
        let meeting = Meeting(
            provider: provider, fileTranscriber: fileTranscriber, config: config, startedAt: startedAt,
            fileURL: directory.appending(path: MeetingDocument.fileName(startedAt: startedAt)),
            vocabulary: entries, session: afterMeeting ? nil : provider.makeMeetingSession(config))
        meeting.systemAudioUnavailable = systemAudioUnavailable
        meeting.activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Meeting transcription")
        self.meeting = meeting
        if let session = meeting.session {
            open(session, in: meeting)
        } else {
            meeting.recorded = Data()
        }
        meeting.sender = Task {
            for await pcm16 in meeting.outgoing {
                meeting.bytes += pcm16.count
                if meeting.recorded != nil {
                    meeting.recorded?.append(pcm16)
                } else {
                    // Read the session each time: a reconnect swaps it while audio keeps flowing.
                    await meeting.session?.send(pcm16)
                }
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

        // In after-meeting mode this only saves the notes; the transcript comes at the end.
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
        state.meetingNotes = ""
        log.info("Meeting started (system audio: \(system != nil), after meeting: \(afterMeeting))")
    }

    public func stop() {
        guard let meeting, !meeting.isStopping else { return }
        meeting.isStopping = true
        meeting.endedAt = Date()
        // The notes window closes with the meeting; what was typed so far is final.
        meeting.notes = state.meetingNotes
        state.meetingNotes = ""
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
        Task { [weak self, state] in
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
            guard input == .microphone, !meeting.isStopping, let self, self.meeting === meeting else { return }
            meeting.microphoneUnavailable = true
            meeting.failure = .meetingMicrophoneLost
            self.stop()
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
                meeting.failure = .invalidAPIKey(provider: meeting.provider.displayName)
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
            Task { await old?.cancel() }
            let now = self.milliseconds(meeting.bytes, in: meeting)
            // Note the relabelled speakers once per outage, not once per failed attempt.
            if meeting.sessionHadSpeech {
                meeting.transcript.markReconnect(atMs: now)
                meeting.isDirty = true
            } else {
                meeting.transcript.offsetMs = now
            }
            meeting.sessionHadSpeech = false
            let session = meeting.provider.makeMeetingSession(meeting.config)
            meeting.session = session
            open(session, in: meeting)
        }
    }

    // MARK: - Finishing

    private func finish(_ meeting: Meeting) async {
        for pump in meeting.pumps { await pump.value }
        if let tail = meeting.mixer?.flush() { meeting.outgoingContinuation.yield(tail) }
        meeting.outgoingContinuation.finish()
        await meeting.sender?.value
        // An autosave already under way must land before the final write, or it would overwrite it.
        await saver?.value
        if meeting.recorded != nil {
            handOffForTranscription(meeting)
            return
        }
        // Finalizes the tail of the audio; the resulting tokens arrive through `events` before it closes.
        _ = try? await meeting.session?.finish()
        await meeting.events?.value
        if let activity = meeting.activity { ProcessInfo.processInfo.endActivity(activity) }
        recordUsage(meeting)

        var saved = false
        let document = markdown(meeting, ended: true)
        if meeting.transcript.isEmpty && !meeting.keepsDocument {
            await writer.remove(meeting.fileURL)
        } else {
            saved = await writer.write(document, to: meeting.fileURL)
        }
        self.meeting = nil
        state.meetingStartedAt = nil
        state.partialTranscript = ""
        log.info("Meeting stopped (\(meeting.transcript.segments.count) segments)")

        if let failure = meeting.failure {
            show(failure)
        } else if meeting.transcript.isEmpty {
            show(.nothingRecognized)
        } else if !saved {
            show(.meetingSaveFailed)
        } else {
            state.phase = .idle
        }
        // After leaving .processing, so a problem with the minutes can still be shown.
        // A document that only holds the microphone notice has nothing to write minutes from.
        if saved {
            if meeting.transcript.isEmpty {
                onSaved(meeting.fileURL)
            } else {
                didSave(document, to: meeting.fileURL, vocabulary: meeting.vocabulary)
            }
        }
    }

    /// Ends the recording part of an after-meeting meeting and transcribes it in the background.
    private func handOffForTranscription(_ meeting: Meeting) {
        if let activity = meeting.activity { ProcessInfo.processInfo.endActivity(activity) }
        self.meeting = nil
        state.meetingStartedAt = nil
        state.partialTranscript = ""
        if let failure = meeting.failure { show(failure) } else { state.phase = .idle }
        guard meeting.bytes > 0, let fileTranscriber = meeting.fileTranscriber else {
            if meeting.keepsDocument {
                let document = markdown(meeting, ended: true)
                transcriptions.append(
                    Task {
                        if await writer.write(document, to: meeting.fileURL) {
                            onSaved(meeting.fileURL)
                        } else {
                            showUnlessBusy(.meetingSaveFailed)
                        }
                    })
            } else {
                // An autosave may have written notes that the user deleted before stopping.
                transcriptions.append(Task { await writer.remove(meeting.fileURL) })
                show(.nothingRecognized)
            }
            return
        }
        state.meetingTranscriptionsInProgress += 1
        log.info("Meeting stopped; transcribing \(self.milliseconds(meeting.bytes, in: meeting) / 1000) s of audio")
        transcriptions.append(
            Task {
                // Preserve the capture failure and the notes even if the later API request cannot
                // transcribe the audio.
                if meeting.keepsDocument {
                    if !(await writer.write(markdown(meeting, ended: true), to: meeting.fileURL)) {
                        showUnlessBusy(.meetingSaveFailed)
                    }
                } else {
                    // An autosave may have written notes that the user deleted before stopping; the
                    // transcript, if any, is written afresh below.
                    await writer.remove(meeting.fileURL)
                }
                await transcribe(meeting, with: fileTranscriber)
            })
    }

    private func transcribe(_ meeting: Meeting, with transcriber: any MeetingFileTranscriber) async {
        let audio = meeting.recorded ?? Data()
        meeting.recorded = nil
        var tokens: [MeetingToken]?
        var failure: UserFacingError = .meetingTranscriptionFailed
        // Retry transient failures: this is the only copy of the meeting's audio.
        for attempt in 0..<3 {
            do {
                tokens = try await transcriber.transcribe(
                    pcm16: audio, sampleRate: Int(meeting.provider.sampleRate), config: meeting.config)
                break
            } catch TranscriptionError.unauthorized {
                failure = .invalidAPIKey(provider: meeting.provider.displayName)
                break
            } catch {
                log.error("Meeting transcription failed (\(String(describing: error), privacy: .public))")
                if attempt < 2 { try? await Task.sleep(for: reconnectDelays[min(attempt, reconnectDelays.count - 1)]) }
            }
        }
        state.meetingTranscriptionsInProgress -= 1

        guard let tokens else {
            showUnlessBusy(failure)
            return
        }
        usage?.record(
            UsageEvent(
                transcription: TranscriptionUsage(
                    provider: meeting.provider.id, model: transcriber.model,
                    seconds: Double(milliseconds(audio.count, in: meeting)) / 1000)))
        meeting.transcript.apply(tokens)
        guard !meeting.transcript.isEmpty || meeting.keepsDocument else {
            showUnlessBusy(.nothingRecognized)
            return
        }
        let document = markdown(meeting, ended: true)
        if await writer.write(document, to: meeting.fileURL) {
            log.info("Meeting transcribed (\(meeting.transcript.segments.count) segments)")
            if meeting.transcript.isEmpty {
                onSaved(meeting.fileURL)
            } else {
                didSave(document, to: meeting.fileURL, vocabulary: meeting.vocabulary)
            }
        } else {
            showUnlessBusy(.meetingSaveFailed)
        }
    }

    /// Hands a saved transcript to Claude Code for minutes, or shows it right away when minutes are off.
    /// With minutes, Finder shows the minutes once they exist (or the transcript if they fail), so the
    /// user isn't pulled to Finder twice.
    /// The user's notes reach the minutes through the transcript document, where Claude reads them.
    private func didSave(_ document: String, to url: URL, vocabulary: [VocabularyEntry]) {
        guard settings.meetingMinutesEnabled else {
            onSaved(url)
            return
        }
        guard let writer = minutesWriter() else {
            onSaved(url)
            showUnlessBusy(.claudeCodeNotFound)
            return
        }
        state.meetingMinutesInProgress += 1
        let model = settings.meetingMinutesModel.rawValue
        transcriptions.append(
            Task {
                await writeMinutes(
                    from: document, transcriptURL: url, vocabulary: vocabulary.map(\.promptTerm), model: model,
                    with: writer)
            })
    }

    private func writeMinutes(
        from document: String, transcriptURL: URL, vocabulary: [CleanupPromptBuilder.Term], model: String,
        with minutesWriter: any MeetingMinutesWriting
    ) async {
        defer { state.meetingMinutesInProgress -= 1 }
        let minutes: String
        do {
            minutes = try await minutesWriter.writeMinutes(transcript: document, vocabulary: vocabulary, model: model)
        } catch {
            // `.failed` carries Claude Code's own output, which can quote the meeting; keep it out of public logs.
            if case .failed(let text) = error as? MeetingMinutesError {
                log.error("Minutes failed: \(text, privacy: .private)")
            } else {
                log.error("Minutes failed: \(String(describing: error), privacy: .public)")
            }
            onSaved(transcriptURL)
            showUnlessBusy(
                error as? MeetingMinutesError == .claudeCodeNotFound ? .claudeCodeNotFound : .meetingMinutesFailed)
            return
        }
        let (title, body) = MeetingMinutesTitle.split(minutes)
        let url = Self.minutesURL(for: transcriptURL, title: title)
        let text = MeetingDocument.minutes(
            title: title, body: body, transcriptFileName: transcriptURL.lastPathComponent)
        if await writer.write(text, to: url) {
            log.info("Minutes saved")
            onSaved(url)
        } else {
            onSaved(transcriptURL)
            showUnlessBusy(.meetingSaveFailed)
        }
    }

    /// `2026-09-27_14-00-05.md` → `2026-09-27_14-00-05_新機能のリリース日程.md`, next to the transcript.
    /// The date stays in front so meetings sort by time and two with the same title never collide.
    nonisolated static func minutesURL(for transcriptURL: URL, title: String?) -> URL {
        let name = transcriptURL.deletingPathExtension().lastPathComponent + "_\(title ?? "議事録").md"
        return transcriptURL.deletingLastPathComponent().appending(path: name)
    }

    /// Background results must not cover up a dictation or meeting in progress.
    private func showUnlessBusy(_ error: UserFacingError) {
        guard !state.phase.isActive else {
            log.error("Not shown while busy: \(error.message, privacy: .public)")
            return
        }
        show(error)
    }

    private func saveIfDirty() async {
        guard let meeting, !meeting.isStopping else { return }
        if meeting.notes != state.meetingNotes {
            meeting.notes = state.meetingNotes
            meeting.isDirty = true
        }
        guard meeting.isDirty, !meeting.transcript.isEmpty || meeting.hasNotes else { return }
        meeting.isDirty = false
        if !(await writer.write(markdown(meeting, ended: false), to: meeting.fileURL)) {
            meeting.isDirty = true
        }
    }

    private func markdown(_ meeting: Meeting, ended: Bool) -> String {
        var notices: [MeetingDocument.Notice] = []
        if meeting.systemAudioUnavailable { notices.append(.systemAudioUnavailable) }
        if meeting.microphoneUnavailable { notices.append(.microphoneUnavailable) }
        // A denied permission yields exact digital silence rather than an error. Only judge at the end:
        // the other side may simply not have spoken yet.
        if ended, meeting.mixer != nil, meeting.systemBytes > 0, meeting.systemPeak == 0 {
            notices.append(.systemAudioSilent)
        }
        return MeetingDocument.markdown(
            meeting.transcript, startedAt: meeting.startedAt, endedAt: ended ? (meeting.endedAt ?? Date()) : nil,
            includesSystemAudio: meeting.mixer != nil, identifiesSpeakers: meeting.provider.identifiesSpeakers,
            notices: notices, notes: meeting.notes, vocabulary: meeting.vocabulary)
    }

    private func milliseconds(_ bytes: Int, in meeting: Meeting) -> Int {
        // Mono PCM16: two bytes per sample.
        Int(Double(bytes) / (meeting.provider.sampleRate * 2) * 1000)
    }

    private func recordUsage(_ meeting: Meeting) {
        guard let usage, meeting.bytes > 0 else { return }
        usage.record(
            UsageEvent(
                transcription: TranscriptionUsage(
                    provider: meeting.provider.id, model: meeting.config.model,
                    seconds: Double(milliseconds(meeting.bytes, in: meeting)) / 1000)))
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
