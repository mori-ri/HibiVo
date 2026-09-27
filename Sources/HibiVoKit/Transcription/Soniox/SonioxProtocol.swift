import Foundation

/// Wire format for Soniox real-time transcription (wss://stt-rt.soniox.com/transcribe-websocket).
enum SonioxProtocol {
    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let finalizeMessage = #"{"type":"finalize"}"#
    static let finalizeMarker = "<fin>"
    static let endMarker = "<end>"

    struct Config: Encodable {
        struct Context: Encodable {
            var terms: [String]
        }

        var apiKey: String
        var model: String
        var audioFormat = "pcm_s16le"
        var sampleRate: Int
        var numChannels = 1
        var languageHints: [String]
        var context: Context?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case model
            case audioFormat = "audio_format"
            case sampleRate = "sample_rate"
            case numChannels = "num_channels"
            case languageHints = "language_hints"
            case context
        }
    }

    struct Response: Decodable {
        struct Token: Decodable {
            var text: String
            var isFinal: Bool
            enum CodingKeys: String, CodingKey {
                case text
                case isFinal = "is_final"
            }
        }

        var tokens: [Token]?
        var finished: Bool?
        var errorCode: Int?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens, finished
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    static func config(for config: TranscriptionConfig, sampleRate: Double) throws -> String {
        // Hint English as well so technical terms stay in Latin script ("AppSync", not "アップシンク").
        var hints = [config.language]
        if config.language != "en" { hints.append("en") }
        let terms = Array(config.vocabulary.prefix(200))
        let payload = Config(
            apiKey: config.apiKey,
            model: config.model,
            sampleRate: Int(sampleRate),
            languageHints: hints,
            context: terms.isEmpty ? nil : .init(terms: terms))
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Folds Soniox token messages into a transcript.
///
/// Final tokens arrive once and never change; non-final tokens are replaced by every message.
struct SonioxTranscript: Equatable {
    private(set) var finalText = ""
    private(set) var tentativeText = ""
    private(set) var didFinalize = false
    private(set) var didFinish = false

    var displayText: String { finalText + tentativeText }

    mutating func apply(_ response: SonioxProtocol.Response) {
        if response.finished == true { didFinish = true }
        guard let tokens = response.tokens else { return }
        var tentative = ""
        for token in tokens {
            switch token.text {
            case SonioxProtocol.finalizeMarker:
                didFinalize = true
            case SonioxProtocol.endMarker:
                continue
            default:
                if token.isFinal { finalText += token.text } else { tentative += token.text }
            }
        }
        tentativeText = tentative
    }
}
