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
/// recording: the mixed audio is recorded and sent to the file transcriber once the meeting ends, which
/// separates speakers far better. That runs in the background, so dictation and the next meeting are
/// available right away. The audio is also kept on disk (`MeetingRecordingStore`) until the transcript
/// is saved, so a shutdown, a sleep or a lost connection only delays it: unfinished recordings are
/// picked up again at launch, after waking and when the network comes back.
///
/// Sleep ends a meeting: the recording stops as the Mac goes to sleep, and transcription and minutes,
/// which need the network, wait until it has woken up.
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
        /// The start stamp shared by the transcript file and the saved recording.
        let id: String
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
        /// The whole meeting's audio in after-meeting mode.
        var recorded: Data?
        /// Whether `recorded` is also kept by the recording store, so a failed transcription can be retried.
        var isSavedOnDisk = false
        /// The after-meeting transcription on the provider's side, once submitted.
        var job: MeetingFileJob?
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
        var includesSystemAudio = false
        /// The notices of a meeting resumed from disk, whose capture details are gone.
        var restoredNotices: [MeetingDocument.Notice]?
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
            id = fileURL.deletingPathExtension().lastPathComponent
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
    /// Every provider, to resume a saved recording with the one it was recorded for.
    private let transcribers: @MainActor () -> [MeetingTranscriber]
    /// Built when a meeting is saved, so a changed Claude Code path or setting takes effect; nil when
    /// minutes are off or Claude Code can't be found.
    private let minutesWriter: @MainActor () -> (any MeetingMinutesWriting)?
    private let vocabulary: @MainActor () -> [VocabularyEntry]
    private let usage: UsageStore?
    private let directory: URL
    private let saveInterval: Duration
    private let reconnectDelays: [Duration]
    /// How long after waking to wait for the network before using it.
    private let wakeDelay: Duration
    private let onSaved: @MainActor (URL) -> Void
    private let writer = MeetingFileWriter()
    private let recordings: MeetingRecordingStore
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "meeting")

    private var meeting: Meeting?
    private var saver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var errorDismiss: Task<Void, Never>?
    /// After-meeting transcriptions and minutes still running.
    private var transcriptions: [Task<Void, Never>] = []
    /// Saved recordings being transcribed, so a resume doesn't start them twice.
    private var transcribing: Set<String> = []
    /// From going to sleep until the network has had `wakeDelay` to come back.
    private var isAsleep = false
    /// Bumped on every sleep, to tell a failure caused by sleeping.
    private var sleepCount = 0
    private var wakeWaiters: [CheckedContinuation<Void, Never>] = []
    private var waking: Task<Void, Never>?
    private var stopGesture = MeetingStopGesture()

    /// - Parameter systemAudio: Captures the remote side of an online meeting; nil where unsupported.
    ///   Used only while `settings.meetingCapturesSystemAudio` is on.
    /// - Parameter transcribers: Every provider; defaults to the one `transcriber` returns.
    public init(
        state: AppState,
        audio: any AudioCapturing,
        systemAudio: (any AudioCapturing)? = nil,
        settings: SettingsStore,
        secrets: any SecretStore,
        transcriber: @escaping @MainActor () -> MeetingTranscriber,
        transcribers: (@MainActor () -> [MeetingTranscriber])? = nil,
        minutesWriter: @escaping @MainActor () -> (any MeetingMinutesWriting)? = { nil },
        vocabulary: @escaping @MainActor () -> [VocabularyEntry] = { [] },
        usage: UsageStore? = nil,
        directory: URL = MeetingController.defaultDirectory,
        saveInterval: Duration = .seconds(5),
        reconnectDelays: [Duration] = MeetingController.defaultReconnectDelays,
        wakeDelay: Duration = .seconds(10),
        onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.state = state
        self.audio = audio
        self.systemAudio = systemAudio
        self.settings = settings
        self.secrets = secrets
        self.transcriber = transcriber
        self.transcribers = transcribers ?? { [transcriber()] }
        self.minutesWriter = minutesWriter
        self.vocabulary = vocabulary
        self.usage = usage
        self.directory = directory
        self.saveInterval = saveInterval
        self.reconnectDelays = reconnectDelays.isEmpty ? [.zero] : reconnectDelays
        self.wakeDelay = wakeDelay
        self.onSaved = onSaved
        // Hidden inside the Meetings folder, which the archive lists, so it never shows up there.
        recordings = MeetingRecordingStore(directory: directory.appending(path: ".recordings"))
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

    /// Hotkey actions while a meeting runs. Only a double tap of the trigger (or trigger+M) stops it,
    /// so a trigger used for another shortcut (Fn+←, Fn+volume …) keeps the meeting going.
    public func handle(_ action: HotkeyAction, at time: ContinuousClock.Instant) {
        if stopGesture.handle(action, at: time) { stop() }
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
        stopGesture.reset()

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
        meeting.includesSystemAudio = system != nil
        meeting.activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Meeting transcription")
        self.meeting = meeting
        if let session = meeting.session {
            open(session, in: meeting)
        } else {
            meeting.recorded = Data()
        }
        meeting.sender = Task { [recordings] in
            if afterMeeting {
                meeting.isSavedOnDisk = await recordings.save(recordingInfo(meeting), id: meeting.id)
            }
            for await pcm16 in meeting.outgoing {
                meeting.bytes += pcm16.count
                if meeting.recorded != nil {
                    meeting.recorded?.append(pcm16)
                    if meeting.isSavedOnDisk, !(await recordings.append(pcm16, id: meeting.id)) {
                        // A partial file would be transcribed as the whole meeting; keep memory only.
                        meeting.isSavedOnDisk = false
                        await recordings.remove(id: meeting.id)
                    }
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
            if meeting.isSavedOnDisk {
                await recordings.closeAudio(id: meeting.id)
                await saveRecordingInfo(meeting)
            }
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
            transcriptions.append(Task { [recordings] in await recordings.remove(id: meeting.id) })
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
        transcribing.insert(meeting.id)
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

    /// Expects `meetingTranscriptionsInProgress` to count this meeting and `transcribing` to hold it.
    private func transcribe(_ meeting: Meeting, with transcriber: any MeetingFileTranscriber) async {
        defer { transcribing.remove(meeting.id) }
        let audio = meeting.recorded ?? Data()
        meeting.recorded = nil
        let apiKey = meeting.config.apiKey
        var tokens: [MeetingToken]?
        var failure: UserFacingError = .meetingTranscriptionFailed
        // Retry transient failures. Once submitted, the job is fetched again rather than re-uploaded.
        var attempt = 0
        while tokens == nil, attempt < 3 {
            attempt += 1
            await untilAwake()
            do {
                let job: MeetingFileJob
                if let submitted = meeting.job {
                    job = submitted
                } else {
                    job = try await transcriber.submit(
                        pcm16: audio, sampleRate: Int(meeting.provider.sampleRate), config: meeting.config)
                    meeting.job = job
                    await saveRecordingInfo(meeting)
                }
                tokens = try await transcriber.result(of: job, apiKey: apiKey)
            } catch TranscriptionError.unauthorized {
                failure = .invalidAPIKey(provider: meeting.provider.displayName)
                break
            } catch MeetingFileJobError.gone {
                log.notice("Meeting transcription job is gone; submitting the audio again")
                if let job = meeting.job { await transcriber.discard(job, apiKey: apiKey) }
                meeting.job = nil
                await saveRecordingInfo(meeting)
            } catch {
                log.error("Meeting transcription failed (\(String(describing: error), privacy: .public))")
                if attempt < 3 {
                    try? await Task.sleep(for: reconnectDelays[min(attempt - 1, reconnectDelays.count - 1)])
                }
            }
        }
        state.meetingTranscriptionsInProgress -= 1

        guard let tokens else {
            if meeting.isSavedOnDisk {
                // The recording and the job stay on disk to be tried again later.
                showUnlessBusy(failure == .meetingTranscriptionFailed ? .meetingTranscriptionDeferred : failure)
            } else {
                await discardRecording(meeting, with: transcriber)
                showUnlessBusy(failure)
            }
            return
        }
        meeting.transcript.apply(tokens)
        usage?.record(
            UsageEvent(
                meetings: 1, characters: meeting.transcript.characters,
                transcription: TranscriptionUsage(
                    provider: meeting.provider.id, model: transcriber.model,
                    seconds: Double(milliseconds(audio.count, in: meeting)) / 1000)))
        guard !meeting.transcript.isEmpty || meeting.keepsDocument else {
            await discardRecording(meeting, with: transcriber)
            showUnlessBusy(.nothingRecognized)
            return
        }
        let document = markdown(meeting, ended: true)
        if await writer.write(document, to: meeting.fileURL) {
            await discardRecording(meeting, with: transcriber)
            log.info("Meeting transcribed (\(meeting.transcript.segments.count) segments)")
            if meeting.transcript.isEmpty {
                onSaved(meeting.fileURL)
            } else {
                didSave(document, to: meeting.fileURL, vocabulary: meeting.vocabulary)
            }
        } else {
            // With the recording on disk, the next resume fetches the result again and retries the save.
            if !meeting.isSavedOnDisk { await discardRecording(meeting, with: transcriber) }
            showUnlessBusy(.meetingSaveFailed)
        }
    }

    /// Deletes the audio from the provider and from disk once it is no longer needed.
    private func discardRecording(_ meeting: Meeting, with transcriber: any MeetingFileTranscriber) async {
        if let job = meeting.job {
            await transcriber.discard(job, apiKey: meeting.config.apiKey)
            meeting.job = nil
        }
        if meeting.isSavedOnDisk {
            await recordings.remove(id: meeting.id)
            meeting.isSavedOnDisk = false
        }
    }

    private func saveRecordingInfo(_ meeting: Meeting) async {
        guard meeting.isSavedOnDisk else { return }
        await recordings.save(recordingInfo(meeting), id: meeting.id)
    }

    private func recordingInfo(_ meeting: Meeting) -> MeetingRecordingInfo {
        MeetingRecordingInfo(
            startedAt: meeting.startedAt, endedAt: meeting.endedAt, providerID: meeting.provider.id,
            model: meeting.config.model, language: meeting.config.language, vocabulary: meeting.vocabulary,
            includesSystemAudio: meeting.includesSystemAudio, notices: notices(meeting, ended: meeting.endedAt != nil),
            notes: meeting.notes, job: meeting.job)
    }

    // MARK: - Sleep, shutdown and saved recordings

    /// The Mac is going to sleep. A meeting ends here; transcription and minutes, which need the
    /// network, wait until it has woken up.
    public func systemWillSleep() {
        isAsleep = true
        sleepCount += 1
        waking?.cancel()
        if let meeting, !meeting.isStopping {
            log.info("Stopping the meeting for sleep")
            stop()
        }
    }

    public func systemDidWake() {
        waking?.cancel()
        waking = Task { [weak self, wakeDelay] in
            try? await Task.sleep(for: wakeDelay)
            guard !Task.isCancelled, let self else { return }
            self.isAsleep = false
            let waiters = self.wakeWaiters
            self.wakeWaiters = []
            for waiter in waiters { waiter.resume() }
            self.resumeSavedRecordings()
        }
    }

    /// The app is quitting, including for a shutdown or logout. Ends a meeting so its file is complete
    /// and an after-meeting recording is saved to be transcribed at the next launch.
    public func prepareForTermination() async {
        stop()
        await stopping?.value
    }

    /// Transcribes after-meeting recordings left unfinished by a shutdown, a sleep or a failed request.
    /// Called at launch, after waking and when the network comes back.
    public func resumeSavedRecordings() {
        guard !isAsleep else { return }
        transcriptions.append(Task { await resumeSaved() })
    }

    private func resumeSaved() async {
        for listed in await recordings.pending() {
            let id = listed.id
            guard !transcribing.contains(id), meeting?.id != id else { continue }
            transcribing.insert(id)
            // The listing may be stale: another resume may have finished this recording or updated its
            // job while this loop was waiting, so read it again now that it is claimed.
            guard let pending = await recordings.pending(id: id) else {
                transcribing.remove(id)
                continue
            }
            let info = pending.info
            let stt = transcribers().first { $0.provider.id == info.providerID }
            var apiKey = ""
            if stt?.provider.requiresAPIKey ?? true {
                apiKey = secrets.secret(for: info.providerID) ?? ""
            }
            if Date().timeIntervalSince(info.startedAt) > MeetingRecordingStore.lifetime {
                log.notice("Dropping a meeting recording that could not be transcribed in time")
                if let job = info.job, !apiKey.isEmpty { await stt?.fileTranscriber?.discard(job, apiKey: apiKey) }
                await recordings.remove(id: id)
                transcribing.remove(id)
                continue
            }
            // Left for later: the key may be added back, or the recording expires.
            guard let stt, let fileTranscriber = stt.fileTranscriber, !stt.provider.requiresAPIKey || !apiKey.isEmpty
            else {
                transcribing.remove(id)
                continue
            }

            let meeting = Meeting(
                provider: stt.provider, fileTranscriber: fileTranscriber,
                config: TranscriptionConfig(
                    apiKey: apiKey, model: info.model, language: info.language,
                    vocabulary: info.vocabulary.map(\.preferred), readings: info.vocabulary.flatMap(\.readings),
                    speakerDiarization: true),
                startedAt: info.startedAt, fileURL: directory.appending(path: "\(id).md"), vocabulary: info.vocabulary,
                session: nil)
            // A recording the app never got to stop ends where its audio does.
            meeting.endedAt = info.endedAt ?? pending.lastWrittenAt ?? info.startedAt
            meeting.notes = info.notes
            meeting.includesSystemAudio = info.includesSystemAudio
            meeting.restoredNotices = info.notices
            meeting.microphoneUnavailable = info.notices.contains(.microphoneUnavailable)
            meeting.job = info.job
            meeting.isSavedOnDisk = true
            if info.endedAt == nil { await saveRecordingInfo(meeting) }
            let audio = await recordings.audio(id: id) ?? Data()
            guard !audio.isEmpty || meeting.job != nil else {
                // Nothing was recorded; only the notes, if any, are left to keep.
                if meeting.keepsDocument, await writer.write(markdown(meeting, ended: true), to: meeting.fileURL) {
                    onSaved(meeting.fileURL)
                }
                await recordings.remove(id: id)
                transcribing.remove(id)
                continue
            }
            meeting.recorded = audio
            meeting.bytes = audio.count
            log.info("Resuming a saved meeting recording")
            state.meetingTranscriptionsInProgress += 1
            transcriptions.append(Task { await transcribe(meeting, with: fileTranscriber) })
        }
    }

    private func untilAwake() async {
        guard isAsleep else { return }
        await withCheckedContinuation { wakeWaiters.append($0) }
    }

    /// Hands a saved transcript to Claude Code or a cleanup provider for minutes, or shows it right away when minutes are off.
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
            let engine = settings.meetingMinutesEngine
            showUnlessBusy(
                engine == .claudeCode
                    ? .claudeCodeNotFound : .minutesProviderNotConfigured(provider: engine.displayName))
            return
        }
        state.meetingMinutesInProgress += 1
        let model = settings.resolvedMeetingMinutesModel
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
        var minutes: String?
        var failure: Error?
        // A sleep in the middle cuts the writer off from the network; try once more after waking.
        for _ in 0..<2 where minutes == nil {
            await untilAwake()
            let sleeps = sleepCount
            do {
                minutes = try await minutesWriter.writeMinutes(
                    transcript: document, vocabulary: vocabulary, model: model)
            } catch {
                failure = error
                if sleepCount == sleeps { break }
            }
        }
        guard let minutes else {
            let error = failure ?? MeetingMinutesError.failed("")
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
            await saveRecordingInfo(meeting)
        }
        guard meeting.isDirty, !meeting.transcript.isEmpty || meeting.hasNotes else { return }
        meeting.isDirty = false
        if !(await writer.write(markdown(meeting, ended: false), to: meeting.fileURL)) {
            meeting.isDirty = true
        }
    }

    private func markdown(_ meeting: Meeting, ended: Bool) -> String {
        MeetingDocument.markdown(
            meeting.transcript, startedAt: meeting.startedAt, endedAt: ended ? (meeting.endedAt ?? Date()) : nil,
            includesSystemAudio: meeting.includesSystemAudio, identifiesSpeakers: meeting.provider.identifiesSpeakers,
            notices: notices(meeting, ended: ended), notes: meeting.notes, vocabulary: meeting.vocabulary)
    }

    private func notices(_ meeting: Meeting, ended: Bool) -> [MeetingDocument.Notice] {
        if let restored = meeting.restoredNotices { return restored }
        var notices: [MeetingDocument.Notice] = []
        if meeting.systemAudioUnavailable { notices.append(.systemAudioUnavailable) }
        if meeting.microphoneUnavailable { notices.append(.microphoneUnavailable) }
        // A denied permission yields exact digital silence rather than an error. Only judge at the end:
        // the other side may simply not have spoken yet.
        if ended, meeting.mixer != nil, meeting.systemBytes > 0, meeting.systemPeak == 0 {
            notices.append(.systemAudioSilent)
        }
        return notices
    }

    private func milliseconds(_ bytes: Int, in meeting: Meeting) -> Int {
        // Mono PCM16: two bytes per sample.
        Int(Double(bytes) / (meeting.provider.sampleRate * 2) * 1000)
    }

    private func recordUsage(_ meeting: Meeting) {
        guard let usage, meeting.bytes > 0 else { return }
        usage.record(
            UsageEvent(
                meetings: 1, characters: meeting.transcript.characters,
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
