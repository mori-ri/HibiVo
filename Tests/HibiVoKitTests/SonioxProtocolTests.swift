import Foundation
import Testing

@testable import HibiVoKit

@Suite struct SonioxProtocolTests {
    typealias Token = SonioxProtocol.Response.Token

    private func response(_ tokens: [(String, Bool)], finished: Bool? = nil) -> SonioxProtocol.Response {
        SonioxProtocol.Response(
            tokens: tokens.map { Token(text: $0.0, isFinal: $0.1) }, finished: finished)
    }

    @Test func configIncludesJapaneseAndEnglishHintsAndTerms() throws {
        let json = try SonioxProtocol.config(
            for: TranscriptionConfig(
                apiKey: "k", model: "stt-rt-v5", language: "ja", vocabulary: ["AppSync", "Bedrock"]),
            sampleRate: 16_000)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["api_key"] as? String == "k")
        #expect(object["model"] as? String == "stt-rt-v5")
        #expect(object["audio_format"] as? String == "pcm_s16le")
        #expect(object["sample_rate"] as? Int == 16_000)
        #expect(object["num_channels"] as? Int == 1)
        #expect(object["language_hints"] as? [String] == ["ja", "en"])
        let context = try #require(object["context"] as? [String: Any])
        #expect(context["terms"] as? [String] == ["AppSync", "Bedrock"])
    }

    @Test func readingsAreHintedAfterSpellingsWithoutDuplicates() throws {
        let config = TranscriptionConfig(
            apiKey: "k", model: "m", language: "ja", vocabulary: ["HibiVo", "AppSync"],
            readings: ["ヒビボ", "AppSync"])
        #expect(SonioxProtocol.terms(for: config) == ["HibiVo", "AppSync", "ヒビボ"])
        let many = TranscriptionConfig(
            apiKey: "k", model: "m", language: "ja", vocabulary: (0..<150).map { "v\($0)" },
            readings: (0..<150).map { "r\($0)" })
        let terms = SonioxProtocol.terms(for: many)
        #expect(terms.count == 200)
        #expect(terms.first == "v0")
        #expect(terms.last == "r49")
    }

    @Test func configOmitsContextWithoutVocabulary() throws {
        let json = try SonioxProtocol.config(
            for: TranscriptionConfig(apiKey: "k", model: "m", language: "ja"), sampleRate: 16_000)
        #expect(!json.contains("context"))
    }

    @Test func finalTokensAccumulateAndTentativeTokensAreReplaced() {
        var t = SonioxTranscript()
        t.apply(response([("今日の", true), ("15", false)]))
        #expect(t.displayText == "今日の15")
        t.apply(response([("15時から", false)]))
        #expect(t.finalText == "今日の")
        #expect(t.displayText == "今日の15時から")
        t.apply(response([("15時から", true), ("AWSの", true), ("AppSync", false)]))
        #expect(t.displayText == "今日の15時からAWSのAppSync")
        #expect(!t.didFinalize)
    }

    @Test func finalizeMarkerIsDetectedAndNotIncludedInText() {
        var t = SonioxTranscript()
        t.apply(response([("打ち合わせをします", true), ("<fin>", true)]))
        #expect(t.didFinalize)
        #expect(t.finalText == "打ち合わせをします")
    }

    @Test func decodesErrorResponse() throws {
        let data = Data(#"{"error_code":401,"error_message":"Invalid API key"}"#.utf8)
        let r = try JSONDecoder().decode(SonioxProtocol.Response.self, from: data)
        #expect(r.errorCode == 401)
        #expect(r.tokens == nil)
    }

    @Test func decodesTokenResponseIgnoringExtraFields() throws {
        let data = Data(
            #"{"tokens":[{"text":"今日","start_ms":600,"end_ms":760,"confidence":0.97,"is_final":true}],"final_audio_proc_ms":760,"total_audio_proc_ms":880}"#
                .utf8)
        var t = SonioxTranscript()
        t.apply(try JSONDecoder().decode(SonioxProtocol.Response.self, from: data))
        #expect(t.finalText == "今日")
    }
}
