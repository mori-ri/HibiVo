import Foundation
import Testing

@testable import HibiVoKit

@Suite struct MeetingTranscriptTests {
    private func token(_ text: String, _ speaker: String?, _ start: Int, _ end: Int, final: Bool = true) -> MeetingToken
    {
        MeetingToken(text: text, isFinal: final, speaker: speaker, startMs: start, endMs: end)
    }

    @Test func tokensGroupBySpeaker() {
        var t = MeetingTranscript()
        t.apply([token("おはよう", "1", 0, 500), token("ございます", "1", 500, 1000), token("はい", "2", 1200, 1500)])
        #expect(t.segments.map(\.text) == ["おはようございます", "はい"])
        #expect(t.segments.map(\.kind) == [.speech(speaker: "1"), .speech(speaker: "2")])
        #expect(t.segments.first?.endMs == 1000)
    }

    @Test func longPauseStartsNewParagraph() {
        var t = MeetingTranscript()
        t.apply([token("前半", "1", 0, 500), token("後半", "1", 5000, 5500)])
        #expect(t.segments.map(\.text) == ["前半", "後半"])
    }

    @Test func tentativeTokensAreReplacedAndNotKept() {
        var t = MeetingTranscript()
        t.apply([token("確定", "1", 0, 500), token("仮", "1", 500, 600, final: false)])
        #expect(t.tentativeText == "仮")
        #expect(t.liveTail == "確定仮")
        t.apply([token("仮の続き", "1", 500, 900, final: false)])
        #expect(t.tentativeText == "仮の続き")
        #expect(t.segments.map(\.text) == ["確定"])
    }

    @Test func leadingSpaceIsDroppedAtParagraphStart() {
        var t = MeetingTranscript()
        t.apply([token(" Hello", "1", 0, 300), token(" world", "1", 300, 600)])
        #expect(t.segments.map(\.text) == ["Hello world"])
    }

    @Test func reconnectShiftsTimesAndSeparatesSpeakers() {
        var t = MeetingTranscript()
        t.apply([token("最初", "1", 0, 500)])
        t.markReconnect(atMs: 60_000)
        t.apply([token("続き", "1", 100, 400)])
        #expect(t.segments.map(\.kind) == [.speech(speaker: "1"), .reconnected, .speech(speaker: "1")])
        #expect(t.segments.last?.startMs == 60_100)
    }

    @Test func emptyUntilSomethingFinalIsSaid() {
        var t = MeetingTranscript()
        #expect(t.isEmpty)
        t.apply([token("仮", "1", 0, 100, final: false)])
        #expect(t.isEmpty)
        t.markReconnect(atMs: 1000)
        #expect(t.isEmpty)
        t.apply([token("確定", "1", 0, 100)])
        #expect(!t.isEmpty)
    }

    @Test func markdownHasTimestampsSpeakersAndVocabulary() {
        var t = MeetingTranscript()
        t.apply([token("アップシンクの件です", "1", 5_000, 6_000), token("了解", "2", 3_725_000, 3_726_000)])
        let start = Date(timeIntervalSince1970: 0)
        let md = MeetingDocument.markdown(
            t, startedAt: start, endedAt: start.addingTimeInterval(3_780),
            vocabulary: [VocabularyEntry(preferred: "AppSync", spoken: "アップシンク")],
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(md.hasPrefix("# ミーティング 1970-01-01 00:00\n"))
        #expect(md.contains("- 終了: 1970-01-01 01:03:00(63 分)"))
        #expect(md.contains("[00:00:05] **話者1** AppSyncの件です"))
        #expect(md.contains("[01:02:05] **話者2** 了解"))
    }

    @Test func markdownWhileRecordingSaysSo() {
        let md = MeetingDocument.markdown(MeetingTranscript(), startedAt: Date(), endedAt: nil)
        #expect(md.contains("- 記録中"))
    }

    @Test func fileNameIsSortableAndFilesystemSafe() {
        let name = MeetingDocument.fileName(
            startedAt: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "1970-01-01_00-00-00.md")
    }
}

@Suite struct SonioxDiarizationTests {
    @Test func diarizationIsRequestedOnlyWhenAsked() throws {
        let on = try SonioxProtocol.config(
            for: TranscriptionConfig(apiKey: "k", model: "m", language: "ja", speakerDiarization: true),
            sampleRate: 16_000)
        let object = try #require(JSONSerialization.jsonObject(with: Data(on.utf8)) as? [String: Any])
        #expect(object["enable_speaker_diarization"] as? Bool == true)

        let off = try SonioxProtocol.config(
            for: TranscriptionConfig(apiKey: "k", model: "m", language: "ja"), sampleRate: 16_000)
        #expect(!off.contains("enable_speaker_diarization"))
    }

    @Test func tokensDecodeSpeakerAndTimes() throws {
        let json = #"""
            {"tokens":[{"text":"はい","is_final":true,"speaker":"2","start_ms":120,"end_ms":360},
                       {"text":"ええ","is_final":false,"speaker":3}]}
            """#
        let response = try JSONDecoder().decode(SonioxProtocol.Response.self, from: Data(json.utf8))
        let tokens = try #require(response.tokens)
        #expect(tokens[0].speaker == "2")
        #expect(tokens[0].startMs == 120)
        #expect(tokens[0].endMs == 360)
        #expect(tokens[1].speaker == "3")
        #expect(tokens[1].startMs == nil)
    }
}

@MainActor
@Suite struct MeetingControllerTests {
    let state = AppState()
    let settings: SettingsStore
    let audio = MockAudio()
    let provider = MockMeetingProvider()
    let directory: URL

    init() {
        settings = SettingsStore(defaults: UserDefaults(suiteName: "MeetingControllerTests-\(UUID())")!)
        directory = FileManager.default.temporaryDirectory.appending(path: "HibiVoMeetingTests-\(UUID())")
    }

    private func makeController(
        secrets: MockSecrets = MockSecrets(), onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> MeetingController {
        MeetingController(
            state: state, audio: audio, settings: settings, secrets: secrets, provider: provider,
            directory: directory, saveInterval: .seconds(3600), reconnectDelays: [.zero], onSaved: onSaved)
    }

    private func savedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Lets the controller's event loop take in what a mock session emitted.
    private func settle(until condition: () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) {
            await Task.yield()
        }
    }

    @Test func startRecordsWithDiarizationAndStopSavesMarkdown() async throws {
        var saved: URL?
        let sut = makeController(onSaved: { saved = $0 })
        sut.start()
        #expect(state.phase == .meeting)
        #expect(state.meetingStartedAt != nil)
        let config = try #require(provider.configs.first)
        #expect(config.speakerDiarization)
        #expect(config.apiKey == "test-key")

        audio.speak()
        let session = try #require(provider.sessions.first)
        await session.emit(.tokens([MeetingToken(text: "始めます", isFinal: true, speaker: "1", startMs: 0, endMs: 800)]))
        await settle { state.partialTranscript == "始めます" }
        #expect(state.partialTranscript == "始めます")

        sut.handle(.released)
        #expect(state.phase == .processing)
        await sut.waitUntilIdle()

        #expect(state.phase == .idle)
        #expect(!sut.isActive)
        #expect(await session.didFinish)
        #expect(await session.receivedBytes == 320)
        let url = try #require(saved)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("**話者1** 始めます"))
        #expect(text.contains("- 終了: "))
    }

    @Test func otherHotkeyActionsDoNotStopTheMeeting() async {
        let sut = makeController()
        sut.start()
        sut.handle(.pressed)
        sut.handle(.interrupted)
        sut.handle(.escape)
        #expect(state.phase == .meeting)
        sut.handle(.meeting)
        await sut.waitUntilIdle()
        #expect(!sut.isActive)
    }

    @Test func missingKeyExplainsThatMeetingsNeedTheProvider() {
        let sut = makeController(secrets: MockSecrets(values: [:]))
        sut.start()
        #expect(state.phase == .error(UserFacingError.meetingRequiresAPIKey(provider: "Mock").message))
        #expect(audio.startCount == 0)
    }

    @Test func nothingSaidLeavesNoFile() async {
        let sut = makeController()
        sut.start()
        sut.stop()
        await sut.waitUntilIdle()
        #expect(savedFiles().isEmpty)
        #expect(state.phase == .error(UserFacingError.nothingRecognized.message))
    }

    @Test func droppedConnectionReconnectsAndKeepsEarlierText() async throws {
        let sut = makeController()
        sut.start()
        let first = try #require(provider.sessions.first)
        await first.emit(.tokens([MeetingToken(text: "前半", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await first.emit(.ended(.network("lost")))
        await settle { provider.sessions.count == 2 }
        let second = try #require(provider.sessions.last)
        #expect(provider.sessions.count == 2)
        await settle { await first.didCancel }
        #expect(await first.didCancel)

        audio.speak()
        await second.emit(.tokens([MeetingToken(text: "後半", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "後半" }
        sut.stop()
        await sut.waitUntilIdle()

        #expect(await second.receivedBytes == 320)
        let url = try #require(savedFiles().first)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("前半"))
        #expect(text.contains("再接続しました"))
        #expect(text.contains("後半"))
    }

    @Test func repeatedFailuresAddOnlyOneReconnectNote() async throws {
        let sut = makeController()
        sut.start()
        let first = try #require(provider.sessions.first)
        await first.emit(.tokens([MeetingToken(text: "前半", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await first.emit(.ended(.network("lost")))
        await settle { provider.sessions.count == 2 }
        await provider.sessions[1].emit(.ended(.network("still down")))
        await settle { provider.sessions.count == 3 }
        await provider.sessions[2].emit(
            .tokens([MeetingToken(text: "後半", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "後半" }
        sut.stop()
        await sut.waitUntilIdle()

        let url = try #require(savedFiles().first)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "再接続しました").count == 2)
    }

    @Test func rejectedKeyStopsButKeepsWhatWasTranscribed() async throws {
        let sut = makeController()
        sut.start()
        let session = try #require(provider.sessions.first)
        await session.emit(.tokens([MeetingToken(text: "記録", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await session.emit(.ended(.unauthorized))
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(state.phase == .error(UserFacingError.invalidAPIKey(provider: "Mock").message))
        #expect(savedFiles().count == 1)
        #expect(provider.sessions.count == 1)
    }
}
