import Foundation

/// Wire format for Gemini Live transcription (`gemini-3.5-transcribe-live` over BidiGenerateContent).
///
/// Push-to-talk maps onto manual activity detection: `activityStart` when the session is ready,
/// `activityEnd` on key-up, after which the server emits the finalized `inputTranscription`.
enum GeminiLiveProtocol {
    static let endpoint = URL(
        string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )!
    static let activityStartMessage = #"{"realtimeInput":{"activityStart":{}}}"#
    static let activityEndMessage = #"{"realtimeInput":{"activityEnd":{}}}"#
    /// Best results are reported with up to ~100 terms (the hard limit is 1,000).
    static let vocabularyLimit = 100

    /// The key goes in a header rather than the `?key=` query so it never lands in URLs that
    /// errors, proxies, or server access logs tend to record.
    static func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    struct Setup: Encodable {
        struct Body: Encodable {
            struct GenerationConfig: Encodable {
                var responseModalities = ["TEXT"]
            }
            struct AudioTranscription: Encodable {
                var languageCodes: [String]
                var customVocabulary: [String]?
                /// Verbatim: rewriting is the cleanup step's job, and raw mode must stay raw.
                var mode = "VERBATIM"
            }
            struct RealtimeInputConfig: Encodable {
                struct AutomaticActivityDetection: Encodable {
                    var disabled = true
                }
                var automaticActivityDetection = AutomaticActivityDetection()
            }

            var model: String
            var generationConfig = GenerationConfig()
            var inputAudioTranscription: AudioTranscription
            var realtimeInputConfig = RealtimeInputConfig()
        }

        var setup: Body
    }

    struct Response: Decodable {
        struct Transcription: Decodable {
            var text: String?
        }
        struct ServerContent: Decodable {
            var inputTranscription: Transcription?
            var interimInputTranscription: Transcription?
            var turnComplete: Bool?
        }
        struct SetupComplete: Decodable {}

        var setupComplete: SetupComplete?
        var serverContent: ServerContent?
    }

    /// Maps the app's language setting to BCP-47 codes. English is hinted as well so technical
    /// terms stay in Latin script ("AppSync", not "アップシンク").
    static func languageCodes(for language: String) -> [String] {
        let regional = ["ja": "ja-JP", "en": "en-US"]
        var codes = [regional[language] ?? language]
        if language != "en" { codes.append("en-US") }
        return codes
    }

    static func setup(for config: TranscriptionConfig) throws -> String {
        let terms = Array(config.vocabulary.prefix(vocabularyLimit))
        let payload = Setup(
            setup: .init(
                model: "models/\(config.model)",
                inputAudioTranscription: .init(
                    languageCodes: languageCodes(for: config.language),
                    customVocabulary: terms.isEmpty ? nil : terms)))
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    static func audioMessage(_ pcm16: Data, sampleRate: Double) -> String {
        // Base64 needs no JSON escaping, so skip the encoder on this hot path.
        #"{"realtimeInput":{"audio":{"data":""# + pcm16.base64EncodedString()
            + #"","mimeType":"audio/pcm;rate=\#(Int(sampleRate))"}}}"#
    }
}

/// Folds Gemini Live messages into a transcript.
///
/// Each `inputTranscription` is a finalized segment and is appended; `interimInputTranscription`
/// is a hypothesis for the segment in progress and is replaced by every update.
struct GeminiLiveTranscript: Equatable {
    private(set) var finalText = ""
    private(set) var interimText = ""
    private(set) var didCompleteTurn = false

    var displayText: String { Self.join(finalText, interimText) }

    /// Returns true when the message carried a finalized segment.
    @discardableResult
    mutating func apply(_ content: GeminiLiveProtocol.Response.ServerContent) -> Bool {
        if content.turnComplete == true { didCompleteTurn = true }
        if let interim = content.interimInputTranscription?.text { interimText = interim }
        guard let segment = content.inputTranscription?.text else { return false }
        finalText = Self.join(finalText, segment)
        interimText = ""
        return true
    }

    /// Segments carry no separator of their own. Only Latin text needs a space between them.
    static func join(_ lhs: String, _ rhs: String) -> String {
        guard let last = lhs.last, let first = rhs.first else { return lhs + rhs }
        let endsLatin = last.isASCII && (last.isLetter || last.isNumber || ".,!?:;".contains(last))
        let startsLatin = first.isASCII && (first.isLetter || first.isNumber)
        return endsLatin && startsLatin ? lhs + " " + rhs : lhs + rhs
    }
}
