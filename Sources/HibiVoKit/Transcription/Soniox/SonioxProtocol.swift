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
        /// Omitted (nil) for dictation so the request stays as it was.
        var enableSpeakerDiarization: Bool?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case model
            case audioFormat = "audio_format"
            case sampleRate = "sample_rate"
            case numChannels = "num_channels"
            case languageHints = "language_hints"
            case context
            case enableSpeakerDiarization = "enable_speaker_diarization"
        }
    }

    struct Response: Decodable {
        struct Token: Decodable {
            var text: String
            var isFinal: Bool
            /// Present only with speaker diarization, e.g. "1".
            var speaker: String?
            /// Offsets from the start of the stream's audio.
            var startMs: Int?
            var endMs: Int?

            enum CodingKeys: String, CodingKey {
                case text, speaker
                case isFinal = "is_final"
                case startMs = "start_ms"
                case endMs = "end_ms"
            }

            init(text: String, isFinal: Bool, speaker: String? = nil, startMs: Int? = nil, endMs: Int? = nil) {
                self.text = text
                self.isFinal = isFinal
                self.speaker = speaker
                self.startMs = startMs
                self.endMs = endMs
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                text = try c.decode(String.self, forKey: .text)
                isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
                // Documented as a string, but accept a number too rather than dropping the whole message.
                speaker =
                    (try? c.decodeIfPresent(String.self, forKey: .speaker))
                    ?? (try? c.decodeIfPresent(Int.self, forKey: .speaker)).flatMap { $0.map(String.init) }
                startMs = try? c.decodeIfPresent(Int.self, forKey: .startMs)
                endMs = try? c.decodeIfPresent(Int.self, forKey: .endMs)
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

    /// Preferred spellings first, then readings, without duplicates, within Soniox's 200-term budget.
    static func terms(for config: TranscriptionConfig) -> [String] {
        var seen = Set<String>()
        return Array((config.vocabulary + config.readings).filter { seen.insert($0).inserted }.prefix(200))
    }

    /// Hint English as well so technical terms stay in Latin script ("AppSync", not "アップシンク").
    static func languageHints(_ language: String) -> [String] {
        language == "en" ? ["en"] : [language, "en"]
    }

    static func config(for config: TranscriptionConfig, sampleRate: Double) throws -> String {
        let hints = languageHints(config.language)
        let terms = terms(for: config)
        let payload = Config(
            apiKey: config.apiKey,
            model: config.model,
            sampleRate: Int(sampleRate),
            languageHints: hints,
            context: terms.isEmpty ? nil : .init(terms: terms),
            enableSpeakerDiarization: config.speakerDiarization ? true : nil)
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
