import Foundation
import Testing

@testable import HibiVoKit

/// Talks to a real Azure Speech resource. Opt-in:
///   HIBIVO_INTEGRATION=1 MAI_TRANSCRIBE_ENDPOINT=eastus swift test --filter MAITranscribeIntegration
/// With AZURE_SPEECH_KEY set, a second of silence must round-trip; without it an invalid key must be rejected.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["HIBIVO_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["MAI_TRANSCRIBE_ENDPOINT"] != nil))
struct MAITranscribeIntegrationTests {
    let key = ProcessInfo.processInfo.environment["AZURE_SPEECH_KEY"]
    let endpoint = ProcessInfo.processInfo.environment["MAI_TRANSCRIBE_ENDPOINT"] ?? ""

    @Test func transcriptionRoundTrip() async throws {
        let provider = MAITranscribeProvider()
        let session = provider.makeSession(
            TranscriptionConfig(
                apiKey: key ?? "invalid-key", model: provider.defaultModel, language: "ja", endpoint: endpoint))
        await session.start()
        for _ in 0..<10 { await session.send(Data(count: 3_200)) }  // 1 s of silence

        if key == nil {
            await #expect(throws: TranscriptionError.unauthorized) { try await session.finish() }
        } else {
            _ = try await session.finish()
        }
    }
}
