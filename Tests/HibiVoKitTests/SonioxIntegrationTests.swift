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

    /// A diarized meeting session reports a rejected key through `events`, and closes cleanly with a valid one.
    @Test func meetingSessionRoundTrip() async throws {
        let key = ProcessInfo.processInfo.environment["SONIOX_API_KEY"]
        let provider = SonioxProvider()
        let session = provider.makeMeetingSession(
            TranscriptionConfig(
                apiKey: key ?? "invalid-key", model: provider.defaultModel, language: "ja", speakerDiarization: true))
        await session.start()
        for _ in 0..<10 { await session.send(Data(count: 3_200)) }

        if key == nil {
            var events: [MeetingSessionEvent] = []
            for await event in session.events { events.append(event) }
            #expect(events.last == .ended(.unauthorized))
        } else {
            _ = try await session.finish()
            for await event in session.events { #expect(event != .ended(.unauthorized)) }
        }
    }
}
