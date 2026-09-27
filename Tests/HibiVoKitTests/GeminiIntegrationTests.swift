import Foundation
import Testing

@testable import HibiVoKit

/// Talks to the real Gemini endpoints. Opt-in:
///   HIBIVO_INTEGRATION=1 swift test --filter GeminiIntegration
/// With GEMINI_API_KEY set, a second of silence must round-trip and cleanup must answer; without it
/// an invalid key must be rejected.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HIBIVO_INTEGRATION"] == "1"))
struct GeminiIntegrationTests {
    let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]

    @Test func liveTranscriptionRoundTrip() async throws {
        let provider = GeminiLiveProvider()
        let session = provider.makeSession(
            TranscriptionConfig(apiKey: key ?? "invalid-key", model: provider.defaultModel, language: "ja"))
        await session.start()
        for _ in 0..<10 { await session.send(Data(count: 3_200)) }  // 1 s of silence

        if key == nil {
            await #expect(throws: TranscriptionError.unauthorized) { try await session.finish() }
        } else {
            let text = try await session.finish()
            #expect(text.isEmpty)
        }
    }

    @Test func cleanupRoundTrip() async throws {
        let provider = GeminiCleanupProvider(apiKey: key ?? "invalid-key")
        if key == nil {
            await #expect(throws: CleanupError.unauthorized) {
                try await provider.complete(system: "Repeat the input.", user: "hello", model: provider.defaultModel)
            }
        } else {
            let completion = try await provider.complete(
                system: "Repeat the input.", user: "hello", model: provider.defaultModel)
            #expect(!completion.text.isEmpty)
            #expect(completion.usage != nil)
        }
    }
}
