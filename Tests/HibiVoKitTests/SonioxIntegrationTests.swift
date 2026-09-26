import Foundation
import Testing

@testable import HibiVoKit

/// Talks to the real Soniox endpoint. Opt-in:
///   HIBIVO_INTEGRATION=1 swift test --filter SonioxIntegration
/// With SONIOX_API_KEY set, a second of silence must round-trip; without it an invalid key must be rejected.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HIBIVO_INTEGRATION"] == "1"))
struct SonioxIntegrationTests {
    @Test func realEndpointRoundTrip() async throws {
        let key = ProcessInfo.processInfo.environment["SONIOX_API_KEY"]
        let provider = SonioxProvider()
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
}
