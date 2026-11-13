import Foundation

/// Wire format for ElevenLabs Scribe realtime transcription (`/v1/speech-to-text/realtime`).
///
/// Session options go in the URL query; the key goes in the `xi-api-key` header. With the `manual`
/// commit strategy the server only finalizes text when we send a chunk with `commit: true`, which
/// maps onto toggle dictation: audio streams while recording, one commit when it stops.
enum ElevenLabsProtocol {
    static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    /// Realtime keyterms: at most 50, each at most 20 characters.
    static let keytermLimit = 50
    static let keytermMaxLength = 20
    /// Characters the API rejects in keyterms.
    static let unsupportedKeytermCharacters = Set("<>{}[]\\")

    static func request(for config: TranscriptionConfig, sampleRate: Double) -> URLRequest {
        var items: [(String, String)] = [
            ("model_id", config.model),
            ("audio_format", "pcm_\(Int(sampleRate))"),
            ("language_code", config.language),
            ("commit_strategy", "manual"),
        ]
        items += keyterms(for: config).map { ("keyterms", $0) }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        // Encoded by hand: URLComponents leaves "+" as is, which servers read as a space ("C++").
        components.percentEncodedQuery = items.map { "\($0)=\(encode($1))" }.joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    /// Spellings first, then readings, without duplicates, dropping terms the API would reject.
    static func keyterms(for config: TranscriptionConfig) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for term in config.vocabulary + config.readings {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidKeyterm(term), seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == keytermLimit { break }
        }
        return terms
    }

    static func isValidKeyterm(_ term: String) -> Bool {
        !term.isEmpty && term.count <= keytermMaxLength && !term.contains(where: unsupportedKeytermCharacters.contains)
    }

    static func audioMessage(_ pcm16: Data, sampleRate: Double) -> String {
        // Base64 needs no JSON escaping, so skip the encoder on this hot path.
        #"{"message_type":"input_audio_chunk","audio_base_64":""# + pcm16.base64EncodedString()
            + #"","commit":false,"sample_rate":\#(Int(sampleRate))}"#
    }

    /// An empty chunk that commits everything sent so far.
    static func commitMessage(sampleRate: Double) -> String {
        #"{"message_type":"input_audio_chunk","audio_base_64":"","commit":true,"sample_rate":\#(Int(sampleRate))}"#
    }

    struct Response: Decodable {
        var messageType: String
        var text: String?
        /// Set on every error message (`auth_error`, `quota_exceeded`, `input_error`, …).
        var error: String?

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case text
            case error
        }
    }

    enum MessageType {
        static let sessionStarted = "session_started"
        static let partialTranscript = "partial_transcript"
        /// Settled text for a segment that is not committed yet.
        static let finalTranscript = "final_transcript"
        static let committedTranscript = "committed_transcript"
        static let authError = "auth_error"
        /// Sent instead of a transcript when the committed audio held no speech.
        static let insufficientAudioActivity = "insufficient_audio_activity"
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}

/// Folds Scribe realtime messages into a transcript.
///
/// `partial_transcript` and `final_transcript` describe the uncommitted segment and replace each other;
/// `committed_transcript` is a finished segment and is appended.
struct ElevenLabsTranscript: Equatable {
    private(set) var committedText = ""
    private(set) var interimText = ""

    var displayText: String { GeminiLiveTranscript.join(committedText, interimText) }

    /// Returns true when the message committed a segment.
    @discardableResult
    mutating func apply(_ response: ElevenLabsProtocol.Response) -> Bool {
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch response.messageType {
        case ElevenLabsProtocol.MessageType.partialTranscript, ElevenLabsProtocol.MessageType.finalTranscript:
            interimText = text
            return false
        case ElevenLabsProtocol.MessageType.committedTranscript:
            committedText = GeminiLiveTranscript.join(committedText, text)
            interimText = ""
            return true
        default:
            return false
        }
    }
}
