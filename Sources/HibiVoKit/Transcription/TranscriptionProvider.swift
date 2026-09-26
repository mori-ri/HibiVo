import Foundation

/// Everything a provider needs to open one streaming session.
public struct TranscriptionConfig: Sendable {
    public var apiKey: String
    public var model: String
    /// BCP-47 primary language, e.g. "ja".
    public var language: String
    /// Preferred spellings to bias recognition toward (e.g. "AppSync", "Claude Code").
    public var vocabulary: [String]

    public init(apiKey: String, model: String, language: String, vocabulary: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case unauthorized
    case network(String)
    case server(String)
    case timedOut
    case cancelled
}

/// A speech-to-text service. Stateless: each utterance gets its own `TranscriptionSession`,
/// so back-to-back dictations can never mix audio.
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Sample rate of the mono PCM16 audio this provider expects.
    var sampleRate: Double { get }
    var models: [String] { get }
    var defaultModel: String { get }

    func makeSession(_ config: TranscriptionConfig) -> any TranscriptionSession
}

/// One utterance of streaming recognition.
public protocol TranscriptionSession: Sendable {
    /// Running transcript (final + tentative text) for live display. Optional for providers.
    var partials: AsyncStream<String> { get }
    /// Starts connecting. Audio may be sent immediately; it is buffered until the connection is ready.
    func start() async
    func send(_ pcm16: Data) async
    /// Flushes the remaining audio and returns the final transcript.
    func finish() async throws -> String
    func cancel() async
}
