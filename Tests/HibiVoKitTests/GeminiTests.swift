import Foundation
import Testing

@testable import HibiVoKit

@Suite struct GeminiLiveProtocolTests {
    typealias Content = GeminiLiveProtocol.Response.ServerContent

    private func json(_ string: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    @Test func setupUsesManualActivityDetectionAndVerbatimMode() throws {
        let setup = try json(
            GeminiLiveProtocol.setup(
                for: .init(
                    apiKey: "k", model: "gemini-3.5-transcribe-live", language: "ja", vocabulary: ["AppSync"])))
        let body = try #require(setup["setup"] as? [String: Any])
        #expect(body["model"] as? String == "models/gemini-3.5-transcribe-live")
        #expect((body["generationConfig"] as? [String: Any])?["responseModalities"] as? [String] == ["TEXT"])
        let transcription = try #require(body["inputAudioTranscription"] as? [String: Any])
        #expect(transcription["languageCodes"] as? [String] == ["ja-JP", "en-US"])
        #expect(transcription["customVocabulary"] as? [String] == ["AppSync"])
        #expect(transcription["mode"] as? String == "VERBATIM")
        let realtime = try #require(body["realtimeInputConfig"] as? [String: Any])
        #expect((realtime["automaticActivityDetection"] as? [String: Any])?["disabled"] as? Bool == true)
        #expect(!setup.description.contains("\"k\""))  // The key goes in the URL, not the setup message.
    }

    @Test func setupOmitsEmptyVocabularyAndCapsLongOnes() throws {
        let none = try json(GeminiLiveProtocol.setup(for: .init(apiKey: "k", model: "m", language: "en")))
        let transcription = (none["setup"] as? [String: Any])?["inputAudioTranscription"] as? [String: Any]
        #expect(transcription?["customVocabulary"] == nil)
        #expect(transcription?["languageCodes"] as? [String] == ["en-US"])

        let many = (0..<300).map { "term\($0)" }
        let capped = try json(
            GeminiLiveProtocol.setup(for: .init(apiKey: "k", model: "m", language: "ja", vocabulary: many)))
        let terms =
            ((capped["setup"] as? [String: Any])?["inputAudioTranscription"] as? [String: Any])?[
                "customVocabulary"] as? [String]
        #expect(terms?.count == GeminiLiveProtocol.vocabularyLimit)
    }

    @Test func urlCarriesKeyAsQuery() {
        let url = GeminiLiveProtocol.url(apiKey: "abc")
        #expect(url.absoluteString.hasPrefix("wss://generativelanguage.googleapis.com/ws/"))
        #expect(url.absoluteString.hasSuffix("BidiGenerateContent?key=abc"))
    }

    @Test func audioMessageIsBase64PCM() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let message = try json(GeminiLiveProtocol.audioMessage(pcm, sampleRate: 16_000))
        let audio = try #require((message["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])
        #expect(audio["data"] as? String == pcm.base64EncodedString())
        #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test func controlMessagesAreValidJSON() throws {
        _ = try json(GeminiLiveProtocol.activityStartMessage)
        _ = try json(GeminiLiveProtocol.activityEndMessage)
    }

    @Test func decodesServerMessages() throws {
        let decoder = JSONDecoder()
        let setup = try decoder.decode(GeminiLiveProtocol.Response.self, from: Data(#"{"setupComplete":{}}"#.utf8))
        #expect(setup.setupComplete != nil)
        let content = try decoder.decode(
            GeminiLiveProtocol.Response.self,
            from: Data(
                #"{"serverContent":{"inputTranscription":{"text":"こんにちは","languageCode":"ja-JP"},"turnComplete":true},"usageMetadata":{"totalTokenCount":3}}"#
                    .utf8))
        #expect(content.serverContent?.inputTranscription?.text == "こんにちは")
        #expect(content.serverContent?.turnComplete == true)
    }

    @Test func interimIsReplacedAndFinalSegmentsAppend() {
        var t = GeminiLiveTranscript()
        t.apply(Content(interimInputTranscription: .init(text: "明日の")))
        t.apply(Content(interimInputTranscription: .init(text: "明日の会議")))
        #expect(t.displayText == "明日の会議")
        let gotSegment = t.apply(Content(inputTranscription: .init(text: "明日の会議は")))
        #expect(gotSegment)
        #expect(t.displayText == "明日の会議は")
        t.apply(Content(interimInputTranscription: .init(text: "15時から")))
        #expect(t.displayText == "明日の会議は15時から")
        t.apply(Content(inputTranscription: .init(text: "15時からです。"), turnComplete: true))
        #expect(t.finalText == "明日の会議は15時からです。")
        #expect(t.didCompleteTurn)
    }

    @Test func joinsLatinSegmentsWithASpaceOnly() {
        #expect(GeminiLiveTranscript.join("Hello.", "World") == "Hello. World")
        #expect(GeminiLiveTranscript.join("Hello ", "World") == "Hello World")
        #expect(GeminiLiveTranscript.join("AppSync", "を使う") == "AppSyncを使う")
        #expect(GeminiLiveTranscript.join("です。", "Next") == "です。Next")
        #expect(GeminiLiveTranscript.join("", "x") == "x")
    }

    @Test func badKeyCloseIsUnauthorized() {
        #expect(
            GeminiLiveSession.classify(
                closeCode: .policyViolation, reason: "API key not valid. Please pass a valid API key.")
                == .unauthorized)
        #expect(GeminiLiveSession.classify(closeCode: .internalServerError, reason: "") == .server("close code 1011"))
        #expect(GeminiLiveSession.classify(closeCode: .invalid, reason: "") == nil)
    }
}

@Suite struct GeminiCleanupTests {
    @Test func requestShape() throws {
        let body = GeminiCleanupProvider.makeRequest(system: "sys", user: "usr", model: "gemini-3.8-flash")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["model"] as? String == "gemini-3.8-flash")
        #expect(json["input"] as? String == "usr")
        #expect(json["system_instruction"] as? String == "sys")
        #expect(json["store"] as? Bool == false)
        #expect((json["generation_config"] as? [String: Any])?["thinking_level"] as? String == "low")
    }

    @Test func olderModelsOmitThinkingLevel() {
        #expect(
            GeminiCleanupProvider.makeRequest(system: "s", user: "u", model: "gemini-2.5-flash").generationConfig == nil
        )
    }

    @Test func parsesModelOutputAndSkipsThoughts() throws {
        let data = Data(
            #"{"status":"completed","steps":[{"type":"thought","signature":"x"},{"type":"model_output","content":[{"type":"text","text":"整形済み"}]}],"usage":{"total_input_tokens":120,"total_output_tokens":20,"total_thought_tokens":10,"total_tokens":150}}"#
                .utf8)
        let completion = try GeminiCleanupProvider.parse(data)
        #expect(completion.text == "整形済み")
        #expect(completion.usage == TokenUsage(input: 120, output: 30))
    }

    @Test func emptyOutputThrows() {
        let data = Data(#"{"status":"completed","steps":[]}"#.utf8)
        #expect(throws: CleanupError.invalidResponse) { try GeminiCleanupProvider.parse(data) }
    }

    @MainActor @Test func builderSharesTheTranscriptionKey() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "GeminiTests-\(UUID())")!)
        settings.cleanupProviderID = CleanupProviderKind.gemini.rawValue
        let builder = { (values: [String: String]) in
            DictationContextBuilder(
                settings: settings, secrets: MockSecrets(values: values), transcriptionProviders: [GeminiLiveProvider()]
            )
        }
        #expect(builder([:]).cleanup(for: nil).provider == nil)
        let cleanup = builder([GeminiLiveProvider().id: "key"]).cleanup(for: nil)
        #expect(cleanup.provider?.id == "gemini")
        #expect(cleanup.model == "gemini-3.8-flash")
    }

    @MainActor @Test func modelSavedForAnotherProviderFallsBackToDefault() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "GeminiTests-\(UUID())")!)
        settings.transcriptionProviderID = "gemini"
        settings.transcriptionModel = "stt-rt-v5"
        let context = try DictationContextBuilder(
            settings: settings, secrets: MockSecrets(values: ["gemini": "key"]),
            transcriptionProviders: [SonioxProvider(), GeminiLiveProvider()]
        ).make(target: nil)
        #expect(context.transcriptionProvider.id == "gemini")
        #expect(context.transcriptionConfig.model == "gemini-3.5-transcribe-live")
    }
}

@Suite struct GeminiPricingTests {
    @Test func flashUsesIntroPriceThroughTheEndOf2026() {
        #expect(
            UsagePricing.rate(provider: "gemini", model: "gemini-3.8-flash", day: "2026-12-31")
                == .init(input: 0.75, output: 3.75))
        #expect(
            UsagePricing.rate(provider: "gemini", model: "gemini-3.8-flash", day: "2027-01-01")
                == .init(input: 1.50, output: 7.50))
        #expect(
            UsagePricing.rate(provider: "gemini", model: "gemini-3.5-flash-lite", day: "2026-09-27")
                == .init(input: 0.30, output: 2.50))
        #expect(UsagePricing.rate(provider: "gemini", model: "gemini-unknown", day: "2026-09-27") == nil)
    }

    @Test func liveTranscriptionIsBilledPerMinute() throws {
        let usd = try #require(
            UsagePricing.transcriptionUSD(.init(provider: "gemini", model: "gemini-3.5-transcribe-live", seconds: 600)))
        #expect(abs(usd - 0.09) < 1e-9)
    }

    @Test func estimatePricesEachDayAtItsOwnRate() {
        func day(_ key: String) -> DailyUsage {
            var day = DailyUsage(day: key)
            day.cleanup = [
                .init(
                    provider: "gemini", model: "gemini-3.8-flash", requests: 1,
                    tokens: .init(input: 1_000_000, output: 0))
            ]
            return day
        }
        let estimate = UsagePricing.estimate([day("2026-12-31"), day("2027-01-01")])
        #expect(abs(estimate.cleanupUSD - 2.25) < 1e-9)
    }
}
