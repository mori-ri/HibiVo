@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

/// macOS's own on-device recognition (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26 and later).
/// Free and needs no API key; the audio never leaves the Mac. It can't tell speakers apart, so a
/// meeting transcribed with it has no speaker labels.
public struct AppleSpeechProvider: MeetingTranscriptionProvider {
    public let id = "apple"
    public let displayName = "macOS 標準"
    public let sampleRate: Double = 16_000
    public let models = [AppleSpeechProvider.model]
    public let defaultModel = AppleSpeechProvider.model
    public let requiresAPIKey = false
    public let identifiesSpeakers = false

    /// Recorded in usage; there is only the system's model.
    static let model = "speech-transcriber"

    public init() {}

    /// Whether this Mac can run the recognizer at all (macOS 26 and supported hardware).
    public static var isSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    public func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession {
        session(config, waitsForModel: false)
    }

    public func makeMeetingSession(_ config: TranscriptionConfig) -> any MeetingTranscriptionSession {
        // A meeting can't be retried like a dictation, so it keeps its audio until the model is ready.
        session(config, waitsForModel: true)
    }

    private func session(_ config: TranscriptionConfig, waitsForModel: Bool) -> any MeetingTranscriptionSession {
        if #available(macOS 26, *) {
            return AppleSpeechSession(config: config, sampleRate: sampleRate, waitsForModel: waitsForModel)
        }
        return UnsupportedSession()
    }

    // MARK: - Model

    public enum ModelStatus: Equatable, Sendable {
        case ready
        case downloading
        /// The language isn't supported, or the download failed.
        case unavailable
    }

    /// Makes sure the speech model for `language` is on this Mac, downloading it if needed, so the
    /// first dictation doesn't have to wait for it.
    @discardableResult
    public static func prepareModel(language: String) async -> ModelStatus {
        guard #available(macOS 26, *), isSupported else { return .unavailable }
        return await AppleSpeechModels.shared.prepare(language: language)
    }
}

/// Recognised text as macOS returns it, tidied for pasting.
enum AppleSpeechText {
    /// Joins two results, adding the space English needs but Japanese doesn't.
    static func join(_ head: String, _ tail: String) -> String {
        head + separator(head, tail) + tail
    }

    static func separator(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first, !last.isWhitespace, !first.isWhitespace,
            last.isASCII, first.isASCII, first.isLetter || first.isNumber
        else { return "" }
        return " "
    }

    /// Drops the space macOS puts before full-width punctuation ("いかがですか ？").
    static func normalized(_ text: String) -> String {
        text.replacing(/[ \t]+(?=[。、？！」』）])/, with: "")
    }
}

/// Stands in on systems without `SpeechAnalyzer`; the provider is never offered there.
private actor UnsupportedSession: MeetingTranscriptionSession {
    nonisolated let partials = AsyncStream<String> { $0.finish() }
    nonisolated let events = AsyncStream<MeetingSessionEvent> { $0.finish() }
    func start() {}
    func send(_ pcm16: Data) {}
    func finish() throws -> String { throw TranscriptionError.server("SpeechAnalyzer is unavailable") }
    func cancel() {}
}

/// Downloads speech models once per language, sharing a download between callers.
@available(macOS 26, *)
actor AppleSpeechModels {
    static let shared = AppleSpeechModels()

    private var installs: [String: Task<Bool, Never>] = [:]
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "apple-speech")

    func locale(for language: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
    }

    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool {
        await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    func prepare(language: String) async -> AppleSpeechProvider.ModelStatus {
        guard let locale = await locale(for: language) else { return .unavailable }
        return await install(locale) ? .ready : .unavailable
    }

    /// True once the model for `locale` is installed.
    func install(_ locale: Locale) async -> Bool {
        let key = locale.identifier
        if let task = installs[key] { return await task.value }
        let task = Task { [log] in
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            do {
                // Keeps the model from being removed while the app uses it; harmless if already reserved.
                if !(await AssetInventory.reservedLocales).contains(locale) {
                    _ = try? await AssetInventory.reserve(locale: locale)
                }
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    log.info("Downloading the speech model for \(key, privacy: .public)")
                    try await request.downloadAndInstall()
                }
            } catch {
                log.error("Speech model install failed: \(String(describing: error), privacy: .public)")
            }
            return await AssetInventory.status(forModules: [transcriber]) == .installed
        }
        installs[key] = task
        let installed = await task.value
        // Let a later call try again after a failure (e.g. offline).
        // Only drop our own task: another caller may already have started a fresh attempt.
        if !installed, installs[key] == task { installs[key] = nil }
        return installed
    }
}

/// One utterance (or one meeting) through `SpeechAnalyzer`.
///
/// Setting up the analyzer is asynchronous, so audio sent before it is ready is buffered, as with the
/// network providers. Results come in as volatile (tentative) text that is replaced until the
/// recognizer finalizes a stretch of audio.
@available(macOS 26, *)
actor AppleSpeechSession: MeetingTranscriptionSession {
    static let finishTimeout: Duration = .seconds(10)

    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    nonisolated let events: AsyncStream<MeetingSessionEvent>
    private let eventsContinuation: AsyncStream<MeetingSessionEvent>.Continuation
    private let config: TranscriptionConfig
    private let sampleRate: Double
    private let waitsForModel: Bool
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "apple-speech")

    private var setup: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AnalyzerBufferConverter?
    private var results: Task<Void, Never>?
    private var pending: [Data] = []
    /// Everything finalized so far. Only kept for dictation: a meeting reads `events` instead.
    private var finalText = ""
    /// The latest finalized result, for spacing the next one.
    private var lastFinal = ""
    private var volatileText = ""
    private var failure: TranscriptionError?
    private var isClosed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var timedOut = false

    init(config: TranscriptionConfig, sampleRate: Double, waitsForModel: Bool) {
        self.config = config
        self.sampleRate = sampleRate
        self.waitsForModel = waitsForModel
        (partials, partialsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (events, eventsContinuation) = AsyncStream.makeStream()
        if !config.speakerDiarization { eventsContinuation.finish() }
    }

    func start() async {
        if setup == nil { setup = Task { await prepare() } }
        await setup?.value
    }

    func send(_ pcm16: Data) {
        guard !isClosed, failure == nil else { return }
        if let input, let converter {
            if let buffer = converter.buffer(from: pcm16) { input.yield(AnalyzerInput(buffer: buffer)) }
        } else {
            pending.append(pcm16)
        }
    }

    func finish() async throws -> String {
        await start()
        if failure == nil, let analyzer, let results {
            input?.finish()
            await withCheckedContinuation { continuation in
                waiter = continuation
                Task {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                    await results.value
                    self.resume()
                }
                Task {
                    try? await Task.sleep(for: Self.finishTimeout)
                    self.resume(timedOut: true)
                }
            }
        }
        close()
        let text = AppleSpeechText.normalized(AppleSpeechText.join(finalText, volatileText))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let error = failure ?? (timedOut ? .timedOut : nil) { throw error }
        return text
    }

    func cancel() {
        guard !isClosed else { return }
        fail(.cancelled)
        close()
    }

    // MARK: - Private

    private func prepare() async {
        guard !isClosed else { return }
        let models = AppleSpeechModels.shared
        guard let locale = await models.locale(for: config.language) else {
            fail(.server("Unsupported language: \(config.language)"))
            return
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        if !(await models.isInstalled(transcriber)) {
            if waitsForModel {
                guard await models.install(locale) else {
                    fail(.modelUnavailable)
                    return
                }
            } else {
                // Downloading can take minutes; fetch it in the background and let the user retry.
                Task { await models.install(locale) }
                fail(.modelUnavailable)
                return
            }
        }
        guard !isClosed else { return }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
            let converter = AnalyzerBufferConverter(sampleRate: sampleRate, to: format)
        else {
            fail(.server("No compatible audio format"))
            return
        }
        if !config.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = config.vocabulary
            try? await analyzer.setContext(context)
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        results = Task { await collect(transcriber) }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            fail(.server(error.localizedDescription))
            return
        }
        guard !isClosed else {
            await analyzer.cancelAndFinishNow()
            return
        }
        self.analyzer = analyzer
        self.converter = converter
        self.input = input
        // Flush without suspending so later `send` calls stay in order.
        for chunk in pending {
            if let buffer = converter.buffer(from: chunk) { input.yield(AnalyzerInput(buffer: buffer)) }
        }
        pending.removeAll()
    }

    private func collect(_ transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                handle(result)
            }
        } catch {
            if !isClosed { fail(.server(error.localizedDescription)) }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            // Keep the joining space with the token so meeting paragraphs read the same.
            let token = AppleSpeechText.separator(lastFinal, text) + text
            lastFinal = text.isEmpty ? lastFinal : text
            volatileText = ""
            if config.speakerDiarization {
                yieldTokens([meetingToken(token, isFinal: true, range: result.range)])
                return
            }
            finalText += token
        } else {
            volatileText = text
            if config.speakerDiarization {
                yieldTokens([meetingToken(text, isFinal: false, range: result.range)])
                return
            }
        }
        partialsContinuation.yield(AppleSpeechText.join(finalText, volatileText))
    }

    private func meetingToken(_ text: String, isFinal: Bool, range: CMTimeRange) -> MeetingToken {
        func milliseconds(_ time: CMTime) -> Int? {
            time.isNumeric ? Int(time.seconds * 1000) : nil
        }
        return MeetingToken(
            text: AppleSpeechText.normalized(text), isFinal: isFinal, speaker: nil,
            startMs: milliseconds(range.start), endMs: milliseconds(range.end))
    }

    private func yieldTokens(_ tokens: [MeetingToken]) {
        guard config.speakerDiarization, !isClosed else { return }
        eventsContinuation.yield(.tokens(tokens))
    }

    private func resume(timedOut: Bool = false) {
        guard let waiter else { return }
        self.waiter = nil
        if timedOut {
            self.timedOut = true
            log.notice("Finalizing timed out; returning what was recognised")
        }
        waiter.resume()
    }

    private func fail(_ error: TranscriptionError) {
        if failure == nil { failure = error }
        resume()
        // A cancel comes from the owner, which doesn't need to be told.
        if !isClosed, error != .cancelled {
            log.error("Speech recognition failed: \(String(describing: error), privacy: .public)")
            eventsContinuation.yield(.ended(error))
            eventsContinuation.finish()
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        input?.finish()
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        partialsContinuation.finish()
        eventsContinuation.finish()
    }
}

/// Turns our mono PCM16 chunks into buffers in the format the analyzer asked for.
final class AnalyzerBufferConverter: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// nil when the analyzer takes our format as is (16 kHz mono Int16 on current systems).
    private let converter: AVAudioConverter?

    init?(sampleRate: Double, to outputFormat: AVAudioFormat) {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
            self.converter = converter
        }
    }

    func buffer(from pcm16: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm16.count / MemoryLayout<Int16>.size)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
            let samples = input.int16ChannelData?[0]
        else { return nil }
        pcm16.withUnsafeBytes { raw in
            _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: Int(frames) * 2))
        }
        input.frameLength = frames
        guard let converter else { return input }

        let capacity = AVAudioFrameCount(Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        // The input block runs synchronously inside convert(), so this is never shared across threads.
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
