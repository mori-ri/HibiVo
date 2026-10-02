import Foundation
import OSLog

/// Microsoft MAI-Transcribe through Azure Speech fast transcription. The API is batch only, so a session
/// keeps the utterance in memory and uploads it once on `finish()`. There is no live transcript.
/// The endpoint (a Speech resource URL or region) comes from `TranscriptionConfig.endpoint`.
public struct MAITranscribeProvider: TranscriptionProvider {
    public let id = "mai-transcribe"
    public let displayName = "Microsoft MAI-Transcribe"
    public let sampleRate: Double = 16_000
    public let models = ["MAI-Transcribe-2", "MAI-Transcribe-1.5"]
    public let defaultModel = "MAI-Transcribe-2"
    public let requiresEndpoint = true

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession {
        MAITranscribeSession(config: config, sampleRate: sampleRate, urlSession: urlSession)
    }
}

actor MAITranscribeSession: TranscriptionSession {
    /// Fast transcription runs well ahead of real time; this covers uploading a long dictation as well.
    static let requestTimeout: TimeInterval = 60

    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    private let config: TranscriptionConfig
    private let sampleRate: Double
    private let urlSession: URLSession
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "mai-transcribe")

    private var audio = Data()
    private var isClosed = false
    private var upload: Task<String, Error>?

    init(config: TranscriptionConfig, sampleRate: Double, urlSession: URLSession) {
        self.config = config
        self.sampleRate = sampleRate
        self.urlSession = urlSession
        (partials, partialsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() async {}

    func send(_ pcm16: Data) {
        guard !isClosed else { return }
        audio.append(pcm16)
    }

    func finish() async throws -> String {
        guard !isClosed else { throw TranscriptionError.cancelled }
        defer { close() }
        guard !audio.isEmpty else { return "" }
        guard let url = MAITranscribeProtocol.url(endpoint: config.endpoint) else {
            throw TranscriptionError.server("invalid endpoint")
        }
        let boundary = "HibiVo-\(UUID().uuidString)"
        let request = MAITranscribeProtocol.request(
            url: url, apiKey: config.apiKey, boundary: boundary, timeout: Self.requestTimeout)
        let body = try MAITranscribeProtocol.multipartBody(
            pcm16: audio, sampleRate: Int(sampleRate), definition: MAITranscribeProtocol.definition(for: config),
            boundary: boundary)
        audio = Data()

        let urlSession = urlSession
        let log = log
        let task = Task { try await Self.post(request, body: body, urlSession: urlSession, log: log) }
        upload = task
        // `cancel()` can run while we wait here and cancels the upload.
        return try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        upload?.cancel()
        close()
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        audio = Data()
        partialsContinuation.finish()
    }

    private static func post(_ request: URLRequest, body: Data, urlSession: URLSession, log: Logger) async throws
        -> String
    {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.upload(for: request, from: body)
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw TranscriptionError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.timedOut
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            log.error("HTTP \(status): \(String(decoding: data.prefix(500), as: UTF8.self), privacy: .public)")
            throw MAITranscribeProtocol.error(status: status)
        }
        do {
            return MAITranscribeProtocol.transcript(
                try JSONDecoder().decode(MAITranscribeProtocol.Response.self, from: data))
        } catch {
            throw TranscriptionError.server("invalid response")
        }
    }
}
