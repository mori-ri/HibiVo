import Foundation

/// Wire format of Azure Speech fast transcription with `enhancedMode`, which is how MAI-Transcribe is served.
/// One multipart POST carries the whole WAV plus a JSON `definition`; the reply is the finished transcript.
enum MAITranscribeProtocol {
    static let apiVersion = "2025-10-15"
    /// Same cap as the Soniox context terms; long phrase lists only dilute the bias.
    static let phraseLimit = 200

    /// The endpoint setting accepts a resource endpoint URL, a bare host, or a region such as `eastus`.
    static func url(endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base: String =
            if trimmed.contains("://") {
                trimmed
            } else if trimmed.contains(".") {
                "https://\(trimmed)"
            } else {
                "https://\(trimmed.lowercased()).api.cognitive.microsoft.com"
            }
        guard var components = URLComponents(string: base), components.scheme == "https", components.host != nil
        else { return nil }
        // Users paste the resource endpoint from the portal ("…/"), sometimes with a path.
        components.path = "/speechtotext/transcriptions:transcribe"
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        return components.url
    }

    static func request(url: URL, apiKey: String, boundary: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    struct Definition: Encodable, Equatable {
        struct EnhancedMode: Encodable, Equatable {
            struct ModelOptions: Encodable, Equatable {
                var transcribeStyle: String
            }
            var enabled = true
            var model: String
            var modelOptions: ModelOptions
        }
        struct PhraseList: Encodable, Equatable {
            var phrases: [String]
        }
        var locales: [String]
        var enhancedMode: EnhancedMode
        var phraseList: PhraseList?
    }

    static func definition(for config: TranscriptionConfig) -> Definition {
        var seen = Set<String>()
        let phrases = Array(
            (config.vocabulary + config.readings).filter { seen.insert($0).inserted }.prefix(phraseLimit))
        return Definition(
            // MAI accepts a single locale. Forcing it keeps short utterances from being detected as another
            // language; English terms inside Japanese still come through via code switching.
            locales: [config.language],
            // Verbatim like the other providers: removing fillers is the cleanup step's job.
            enhancedMode: .init(model: config.model, modelOptions: .init(transcribeStyle: "verbatim")),
            phraseList: phrases.isEmpty ? nil : .init(phrases: phrases))
    }

    /// One allocation for the whole upload.
    static func multipartBody(pcm16: Data, sampleRate: Int, definition: Definition, boundary: String) throws -> Data {
        let json = try JSONEncoder().encode(definition)
        let definitionPart = Data(
            ("--\(boundary)\r\n" + "Content-Disposition: form-data; name=\"definition\"\r\n"
                + "Content-Type: application/json\r\n\r\n").utf8)
        let audioHead = Data(
            ("\r\n--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"audio\"; filename=\"dictation.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n").utf8)
        let tail = Data("\r\n--\(boundary)--\r\n".utf8)
        let header = SonioxFileTranscriber.wavHeader(dataSize: pcm16.count, sampleRate: sampleRate)
        var body = Data(
            capacity: definitionPart.count + json.count + audioHead.count + header.count + pcm16.count + tail.count)
        body.append(definitionPart)
        body.append(json)
        body.append(audioHead)
        body.append(header)
        body.append(pcm16)
        body.append(tail)
        return body
    }

    struct Response: Decodable {
        struct Phrase: Decodable {
            var text: String
        }
        /// The full text; one entry per channel, and we always send one.
        var combinedPhrases: [Phrase]?
    }

    static func transcript(_ response: Response) -> String {
        (response.combinedPhrases ?? []).map(\.text).joined(separator: "\n")
    }

    static func error(status: Int) -> TranscriptionError {
        [401, 403].contains(status) ? .unauthorized : .server("HTTP \(status)")
    }
}
