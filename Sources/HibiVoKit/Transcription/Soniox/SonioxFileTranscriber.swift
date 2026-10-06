import Foundation
import OSLog

/// Transcribes a whole recording after the fact. Diarization is far more accurate this way than in
/// real time, because the model hears the full meeting before it assigns speakers.
///
/// Split into steps so a job already on the provider's side survives a sleep, a shutdown or a lost
/// connection: the caller keeps the `MeetingFileJob` and fetches its result later without uploading
/// the audio again.
public protocol MeetingFileTranscriber: Sendable {
    /// Recorded in usage, which prices async audio separately from real-time.
    var model: String { get }
    /// Uploads the audio and starts transcribing it.
    /// - Parameter pcm16: Mono 16-bit little-endian PCM at `sampleRate`.
    func submit(pcm16: Data, sampleRate: Int, config: TranscriptionConfig) async throws -> MeetingFileJob
    /// Waits for the job and returns every token, final, with speaker labels and times from the start
    /// of the audio. Throws `MeetingFileJobError.gone` when the job no longer exists or failed, in which
    /// case the audio has to be submitted again.
    func result(of job: MeetingFileJob, apiKey: String) async throws -> [MeetingToken]
    /// Deletes the job and its audio from the provider. Best effort.
    func discard(_ job: MeetingFileJob, apiKey: String) async
}

extension MeetingFileTranscriber {
    /// Submits, waits and cleans up in one go.
    public func transcribe(pcm16: Data, sampleRate: Int, config: TranscriptionConfig) async throws -> [MeetingToken] {
        let job = try await submit(pcm16: pcm16, sampleRate: sampleRate, config: config)
        do {
            let tokens = try await result(of: job, apiKey: config.apiKey)
            await discard(job, apiKey: config.apiKey)
            return tokens
        } catch {
            await discard(job, apiKey: config.apiKey)
            throw error
        }
    }
}

/// A transcription running on the provider's side.
public struct MeetingFileJob: Codable, Equatable, Sendable {
    public var fileID: String
    public var transcriptionID: String

    public init(fileID: String, transcriptionID: String) {
        self.fileID = fileID
        self.transcriptionID = transcriptionID
    }
}

public enum MeetingFileJobError: Error, Equatable, Sendable {
    /// The job was deleted, expired or failed on the provider's side.
    case gone
}

/// Soniox async transcription: upload the audio, create a transcription, poll until it completes,
/// fetch the tokens, then delete both so the audio doesn't stay on Soniox's side. Both stay until
/// `discard`, so a job cut off by a sleep can still be fetched afterwards.
///
/// The WAV is built in memory.
public struct SonioxFileTranscriber: MeetingFileTranscriber {
    static let baseURL = URL(string: "https://api.soniox.com/v1")!
    public let model = "stt-async-v5"

    private let urlSession: URLSession
    private let pollInterval: Duration
    /// An hour of audio typically takes a minute or two; give up well after that.
    private let timeout: Duration
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "soniox-async")

    public init(
        urlSession: URLSession = .shared, pollInterval: Duration = .seconds(3), timeout: Duration = .seconds(1800)
    ) {
        self.urlSession = urlSession
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public func submit(pcm16: Data, sampleRate: Int, config: TranscriptionConfig) async throws -> MeetingFileJob {
        let key = config.apiKey
        let boundary = "HibiVo-\(UUID().uuidString)"
        let upload: FileResponse = try await send(
            Self.uploadRequest(apiKey: key, boundary: boundary),
            body: Self.multipartBody(wav: pcm16, sampleRate: sampleRate, boundary: boundary))
        do {
            let created: TranscriptionResponse = try await send(
                Self.createRequest(fileID: upload.id, model: model, config: config))
            return MeetingFileJob(fileID: upload.id, transcriptionID: created.id)
        } catch {
            // Best effort, detached so a cancelled caller still cleans up.
            let session = urlSession
            Task.detached { _ = try? await session.data(for: Self.deleteRequest("files/\(upload.id)", apiKey: key)) }
            throw error
        }
    }

    public func result(of job: MeetingFileJob, apiKey key: String) async throws -> [MeetingToken] {
        let deadline = ContinuousClock.now + timeout
        let url = Self.baseURL.appending(path: "transcriptions/\(job.transcriptionID)")
        while true {
            let status: TranscriptionResponse = try await send(Self.authorized(URLRequest(url: url), key))
            switch status.status {
            case "completed":
                let transcript: SonioxProtocol.Response = try await send(
                    Self.authorized(URLRequest(url: url.appending(path: "transcript")), key))
                return Self.tokens(transcript)
            case "error":
                log.error("Soniox async failed: \(status.errorMessage ?? "", privacy: .public)")
                throw MeetingFileJobError.gone
            default:
                guard ContinuousClock.now < deadline else { throw TranscriptionError.timedOut }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    public func discard(_ job: MeetingFileJob, apiKey key: String) async {
        _ = try? await urlSession.data(for: Self.deleteRequest("transcriptions/\(job.transcriptionID)", apiKey: key))
        _ = try? await urlSession.data(for: Self.deleteRequest("files/\(job.fileID)", apiKey: key))
    }

    // MARK: - Wire format

    struct FileResponse: Decodable {
        var id: String
    }

    struct TranscriptionResponse: Decodable {
        var id: String
        var status: String?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case id, status
            case errorMessage = "error_message"
        }
    }

    struct CreateRequest: Encodable {
        var model: String
        var fileID: String
        var languageHints: [String]
        var enableSpeakerDiarization = true
        var context: SonioxProtocol.Config.Context?

        enum CodingKeys: String, CodingKey {
            case model, context
            case fileID = "file_id"
            case languageHints = "language_hints"
            case enableSpeakerDiarization = "enable_speaker_diarization"
        }
    }

    static func authorized(_ request: URLRequest, _ apiKey: String) -> URLRequest {
        var request = request
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func uploadRequest(apiKey: String, boundary: String) -> URLRequest {
        var request = authorized(URLRequest(url: baseURL.appending(path: "files")), apiKey)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func createRequest(fileID: String, model: String, config: TranscriptionConfig) throws -> URLRequest {
        var request = authorized(URLRequest(url: baseURL.appending(path: "transcriptions")), config.apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let terms = SonioxProtocol.terms(for: config)
        request.httpBody = try JSONEncoder().encode(
            CreateRequest(
                model: model, fileID: fileID, languageHints: SonioxProtocol.languageHints(config.language),
                context: terms.isEmpty ? nil : .init(terms: terms)))
        return request
    }

    static func deleteRequest(_ path: String, apiKey: String) -> URLRequest {
        var request = authorized(URLRequest(url: baseURL.appending(path: path)), apiKey)
        request.httpMethod = "DELETE"
        return request
    }

    /// One allocation for the whole upload: the audio can be hundreds of megabytes.
    static func multipartBody(wav pcm16: Data, sampleRate: Int, boundary: String) -> Data {
        let head = Data(
            ("--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n").utf8)
        let tail = Data("\r\n--\(boundary)--\r\n".utf8)
        let header = wavHeader(dataSize: pcm16.count, sampleRate: sampleRate)
        var body = Data(capacity: head.count + header.count + pcm16.count + tail.count)
        body.append(head)
        body.append(header)
        body.append(pcm16)
        body.append(tail)
        return body
    }

    /// Canonical 44-byte header for mono 16-bit PCM.
    static func wavHeader(dataSize: Int, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)  // PCM
        append16(1)  // mono
        append32(sampleRate)
        append32(sampleRate * 2)  // byte rate
        append16(2)  // block align
        append16(16)  // bits per sample
        append("data")
        append32(dataSize)
        return data
    }

    /// Async tokens carry no `is_final`: everything in a finished transcript is final.
    static func tokens(_ transcript: SonioxProtocol.Response) -> [MeetingToken] {
        (transcript.tokens ?? []).map {
            MeetingToken(text: $0.text, isFinal: true, speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs)
        }
    }

    // MARK: - HTTP

    private func send<T: Decodable>(_ request: URLRequest, body: Data? = nil) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) =
                if let body {
                    try await urlSession.upload(for: request, from: body)
                } else {
                    try await urlSession.data(for: request)
                }
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            log.error(
                "Soniox async HTTP \(status): \(String(decoding: data.prefix(500), as: UTF8.self), privacy: .public)")
            switch status {
            case 401: throw TranscriptionError.unauthorized
            case 404: throw MeetingFileJobError.gone
            default: throw TranscriptionError.server("HTTP \(status)")
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TranscriptionError.server("invalid response")
        }
    }
}
