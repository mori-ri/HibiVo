import Foundation
import Testing

@testable import HibiVoKit

@Suite struct ElevenLabsProtocolTests {
    typealias Response = ElevenLabsProtocol.Response

    private func json(_ string: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func query(_ request: URLRequest) throws -> [URLQueryItem] {
        let url = try #require(request.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    private func decode(_ string: String) throws -> Response {
        try JSONDecoder().decode(Response.self, from: Data(string.utf8))
    }

    @Test func requestCarriesSettingsInQueryAndKeyInHeader() throws {
        let request = ElevenLabsProtocol.request(
            for: .init(
                apiKey: "secret", model: "scribe_v3_live", language: "ja", vocabulary: ["AppSync"],
                readings: ["アップシンク"]),
            sampleRate: 16_000)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?"))
        #expect(!url.contains("secret"))
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "secret")

        let items = try query(request)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("model_id") == "scribe_v3_live")
        #expect(value("audio_format") == "pcm_16000")
        #expect(value("language_code") == "ja")
        #expect(value("commit_strategy") == "manual")
        #expect(items.filter { $0.name == "keyterms" }.map(\.value) == ["AppSync", "アップシンク"])
    }

    @Test func keytermsKeepPlusSignsIntact() throws {
        let request = ElevenLabsProtocol.request(
            for: .init(apiKey: "k", model: "m", language: "en", vocabulary: ["C++ & Go"]), sampleRate: 16_000)
        let raw = try #require(request.url?.query)
        #expect(raw.contains("keyterms=C%2B%2B%20%26%20Go"))
        let terms = try query(request).filter { $0.name == "keyterms" }.map(\.value)
        #expect(terms == ["C++ & Go"])
    }

    @Test func keytermsAreDedupedFilteredAndCapped() {
        let config = TranscriptionConfig(
            apiKey: "k", model: "m", language: "ja",
            vocabulary: ["Claude Code", " ", "a{b}", String(repeating: "x", count: 21), "Claude Code"],
            readings: ["クロードコード"])
        #expect(ElevenLabsProtocol.keyterms(for: config) == ["Claude Code", "クロードコード"])

        let many = TranscriptionConfig(
            apiKey: "k", model: "m", language: "ja", vocabulary: (0..<80).map { "term\($0)" })
        let terms = ElevenLabsProtocol.keyterms(for: many)
        #expect(terms.count == ElevenLabsProtocol.keytermLimit)
        #expect(terms.first == "term0")
    }

    @Test func requestOmitsKeytermsWithoutVocabulary() throws {
        let request = ElevenLabsProtocol.request(
            for: .init(apiKey: "k", model: "m", language: "en"), sampleRate: 16_000)
        let names = try query(request).map(\.name)
        #expect(!names.contains("keyterms"))
    }

    @Test func audioAndCommitMessages() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let audio = try json(ElevenLabsProtocol.audioMessage(pcm, sampleRate: 16_000))
        #expect(audio["message_type"] as? String == "input_audio_chunk")
        #expect(audio["audio_base_64"] as? String == pcm.base64EncodedString())
        #expect(audio["commit"] as? Bool == false)
        #expect(audio["sample_rate"] as? Int == 16_000)

        let commit = try json(ElevenLabsProtocol.commitMessage(sampleRate: 16_000))
        #expect(commit["message_type"] as? String == "input_audio_chunk")
        #expect(commit["audio_base_64"] as? String == "")
        #expect(commit["commit"] as? Bool == true)
    }

    @Test func decodesServerMessages() throws {
        let started = try decode(
            #"{"message_type":"session_started","session_id":"s","config":{"model_id":"scribe_v3_live"}}"#)
        #expect(started.messageType == "session_started")
        let partial = try decode(#"{"message_type":"partial_transcript","text":"こんに"}"#)
        #expect(partial.text == "こんに")
        let error = try decode(#"{"message_type":"auth_error","error":"Invalid API key"}"#)
        #expect(error.error == "Invalid API key")
    }

    @Test func partialsAreReplacedAndCommitsAppend() throws {
        var transcript = ElevenLabsTranscript()
        let partial = try decode(#"{"message_type":"partial_transcript","text":"こんに"}"#)
        let committedPartial = transcript.apply(partial)
        #expect(!committedPartial)
        #expect(transcript.displayText == "こんに")
        transcript.apply(try decode(#"{"message_type":"final_transcript","text":"こんにちは。"}"#))
        #expect(transcript.displayText == "こんにちは。")
        let commit = try decode(#"{"message_type":"committed_transcript","text":"こんにちは。"}"#)
        let committed = transcript.apply(commit)
        #expect(committed)
        #expect(transcript.committedText == "こんにちは。")
        #expect(transcript.interimText == "")
        transcript.apply(try decode(#"{"message_type":"partial_transcript","text":"AppSync"}"#))
        #expect(transcript.displayText == "こんにちは。AppSync")

        var english = ElevenLabsTranscript()
        english.apply(try decode(#"{"message_type":"committed_transcript","text":" Hello."}"#))
        english.apply(try decode(#"{"message_type":"committed_transcript","text":"World"}"#))
        #expect(english.displayText == "Hello. World")
    }

    @Test func ignoresUnrelatedMessages() throws {
        var transcript = ElevenLabsTranscript()
        transcript.apply(try decode(#"{"message_type":"partial_transcript","text":"abc"}"#))
        let warning = try decode(#"{"message_type":"warning","warning":"slow"}"#)
        let committed = transcript.apply(warning)
        #expect(!committed)
        #expect(transcript.displayText == "abc")
    }

    @Test func classifiesErrors() {
        #expect(ElevenLabsSession.classify(messageType: "auth_error", error: "bad key") == .unauthorized)
        #expect(
            ElevenLabsSession.classify(messageType: "quota_exceeded", error: "Out of credits")
                == .server("Out of credits"))
        #expect(ElevenLabsSession.classify(messageType: "rate_limited", error: "") == .server("rate_limited"))
    }
}
