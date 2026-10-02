import Foundation
import Testing

@testable import HibiVoKit

@Suite struct MAITranscribeProtocolTests {
    let path = "/speechtotext/transcriptions:transcribe?api-version=\(MAITranscribeProtocol.apiVersion)"

    @Test func endpointAcceptsURLHostOrRegion() {
        #expect(
            MAITranscribeProtocol.url(endpoint: "https://my-speech.cognitiveservices.azure.com/")?.absoluteString
                == "https://my-speech.cognitiveservices.azure.com\(path)")
        #expect(
            MAITranscribeProtocol.url(endpoint: " my-speech.cognitiveservices.azure.com ")?.absoluteString
                == "https://my-speech.cognitiveservices.azure.com\(path)")
        #expect(
            MAITranscribeProtocol.url(endpoint: "EastUS")?.absoluteString
                == "https://eastus.api.cognitive.microsoft.com\(path)")
    }

    @Test func endpointRejectsEmptyAndPlainHTTP() {
        #expect(MAITranscribeProtocol.url(endpoint: "  ") == nil)
        #expect(MAITranscribeProtocol.url(endpoint: "http://my-speech.cognitiveservices.azure.com") == nil)
    }

    @Test func requestSendsKeyAsHeader() throws {
        let url = try #require(MAITranscribeProtocol.url(endpoint: "eastus"))
        let request = MAITranscribeProtocol.request(url: url, apiKey: "abc", boundary: "B", timeout: 10)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "abc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        #expect(request.url?.absoluteString.contains("abc") == false)
    }

    @Test func definitionSelectsModelLocaleAndPhrases() throws {
        let definition = MAITranscribeProtocol.definition(
            for: .init(
                apiKey: "k", model: "MAI-Transcribe-2", language: "ja", vocabulary: ["AppSync", "Claude Code"],
                readings: ["アップシンク", "AppSync"]))
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        #expect(json["locales"] as? [String] == ["ja"])
        let enhanced = try #require(json["enhancedMode"] as? [String: Any])
        #expect(enhanced["enabled"] as? Bool == true)
        #expect(enhanced["model"] as? String == "MAI-Transcribe-2")
        #expect((enhanced["modelOptions"] as? [String: Any])?["transcribeStyle"] as? String == "verbatim")
        #expect(
            (json["phraseList"] as? [String: Any])?["phrases"] as? [String] == ["AppSync", "Claude Code", "アップシンク"])
        #expect(!String(decoding: try JSONEncoder().encode(definition), as: UTF8.self).contains("\"k\""))
    }

    @Test func definitionOmitsEmptyPhrasesAndCapsLongLists() {
        let none = MAITranscribeProtocol.definition(for: .init(apiKey: "k", model: "m", language: "en"))
        #expect(none.phraseList == nil)
        let many = MAITranscribeProtocol.definition(
            for: .init(apiKey: "k", model: "m", language: "ja", vocabulary: (0..<300).map { "term\($0)" }))
        #expect(many.phraseList?.phrases.count == MAITranscribeProtocol.phraseLimit)
    }

    @Test func multipartBodyCarriesDefinitionThenWav() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let definition = MAITranscribeProtocol.definition(for: .init(apiKey: "k", model: "m", language: "ja"))
        let body = try MAITranscribeProtocol.multipartBody(
            pcm16: pcm, sampleRate: 16_000, definition: definition, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"definition\""))
        #expect(text.contains("name=\"audio\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"))
        #expect(text.hasSuffix("\r\n--B--\r\n"))
        let wav = SonioxFileTranscriber.wavHeader(dataSize: pcm.count, sampleRate: 16_000) + pcm
        #expect(body.range(of: wav) != nil)
    }

    @Test func decodesCombinedTranscript() throws {
        let json = #"""
            {"durationMilliseconds":1200,"combinedPhrases":[{"text":"今日はAppSyncの話です。"}],
             "phrases":[{"offsetMilliseconds":0,"durationMilliseconds":1200,"text":"今日はAppSyncの話です。","locale":"ja-JP","confidence":0.9}]}
            """#
        let response = try JSONDecoder().decode(MAITranscribeProtocol.Response.self, from: Data(json.utf8))
        #expect(MAITranscribeProtocol.transcript(response) == "今日はAppSyncの話です。")
        let silent = try JSONDecoder().decode(
            MAITranscribeProtocol.Response.self, from: Data(#"{"durationMilliseconds":1000,"phrases":[]}"#.utf8))
        #expect(MAITranscribeProtocol.transcript(silent).isEmpty)
    }

    @Test func badKeyIsUnauthorized() {
        #expect(MAITranscribeProtocol.error(status: 401) == .unauthorized)
        #expect(MAITranscribeProtocol.error(status: 403) == .unauthorized)
        #expect(MAITranscribeProtocol.error(status: 404) == .server("HTTP 404"))
    }

    @Test func sessionWithoutAudioSkipsTheUpload() async throws {
        let session = MAITranscribeProvider().makeSession(
            .init(apiKey: "k", model: "MAI-Transcribe-2", language: "ja", endpoint: "eastus"))
        await session.start()
        #expect(try await session.finish() == "")
    }

    @Test func cancelledSessionDoesNotUpload() async {
        let session = MAITranscribeProvider().makeSession(
            .init(apiKey: "k", model: "MAI-Transcribe-2", language: "ja", endpoint: "eastus"))
        await session.send(Data(count: 3_200))
        await session.cancel()
        await #expect(throws: TranscriptionError.cancelled) { try await session.finish() }
    }

    @Test func pricedPerHourOfAudio() {
        #expect(
            UsagePricing.transcriptionUSD(.init(provider: "mai-transcribe", model: "MAI-Transcribe-2", seconds: 3600))
                == 0.10)
        #expect(
            UsagePricing.transcriptionUSD(.init(provider: "mai-transcribe", model: "MAI-Transcribe-1.5", seconds: 3600))
                == 0.36)
    }
}

@MainActor
@Suite struct MAITranscribeContextTests {
    func builder(endpoint: String) -> DictationContextBuilder {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "MAITranscribeContextTests-\(UUID())")!)
        settings.transcriptionProviderID = "mai-transcribe"
        settings.azureSpeechEndpoint = endpoint
        return DictationContextBuilder(
            settings: settings, secrets: MockSecrets(values: ["mai-transcribe": "key"]),
            transcriptionProviders: [MAITranscribeProvider()])
    }

    @Test func missingEndpointIsReportedBeforeRecording() {
        #expect(throws: UserFacingError.missingEndpoint(provider: "Microsoft MAI-Transcribe")) {
            try builder(endpoint: " ").make(target: nil)
        }
    }

    @Test func endpointIsFrozenIntoTheConfig() throws {
        let context = try builder(endpoint: " eastus ").make(target: nil)
        #expect(context.transcriptionConfig.endpoint == "eastus")
        #expect(context.transcriptionConfig.model == "MAI-Transcribe-2")
    }
}
