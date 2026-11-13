import Foundation
import Testing

@testable import HibiVoKit

/// Talks to the real ElevenLabs realtime endpoint. Opt-in:
///   HIBIVO_INTEGRATION=1 swift test --filter ElevenLabsIntegration
/// With ELEVENLABS_API_KEY set, a second of silence must round-trip; without it an invalid key must be rejected.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HIBIVO_INTEGRATION"] == "1"))
struct ElevenLabsIntegrationTests {
    let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]

    @Test func realtimeTranscriptionRoundTrip() async throws {
        let provider = ElevenLabsProvider()
        let session = provider.makeSession(
            TranscriptionConfig(
                apiKey: key ?? "invalid-key", model: provider.defaultModel, language: "ja", vocabulary: ["HibiVo"]))
        await session.start()
        for _ in 0..<10 { await session.send(Data(count: 3_200)) }  // 1 s of silence

        if key == nil {
            await #expect(throws: TranscriptionError.unauthorized) { try await session.finish() }
        } else {
            let text = try await session.finish()
            #expect(text.isEmpty)
        }
    }
}
