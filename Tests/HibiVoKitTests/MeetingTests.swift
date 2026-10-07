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

    @Test func notesComeBeforeTheTranscript() throws {
        var t = MeetingTranscript()
        t.apply([token("始めます", "1", 0, 800)])
        let md = MeetingDocument.markdown(t, startedAt: Date(), endedAt: nil, notes: "\n- 予算は来週\n\n")
        let notes = try #require(md.range(of: "## メモ\n\n- 予算は来週\n\n---\n"))
        let speech = try #require(md.range(of: "**話者1** 始めます"))
        #expect(notes.upperBound <= speech.lowerBound)
        #expect(!MeetingDocument.markdown(t, startedAt: Date(), endedAt: nil, notes: " \n").contains("## メモ"))
    }

    @Test func minutesHaveTheTitleBodyAndSource() {
        let md = MeetingDocument.minutes(title: "予算", body: "## 概要\n予算の件。", transcriptFileName: "a.md")
        #expect(md == "# 予算\n\n## 概要\n予算の件。\n\n---\n\n*Claude が文字起こし「a.md」から作成しました。*\n")
        #expect(MeetingDocument.minutes(title: nil, body: "本文", transcriptFileName: "a.md").hasPrefix("# 議事録\n\n本文"))
    }

    @Test func markdownWhileRecordingSaysSo() {
        let md = MeetingDocument.markdown(MeetingTranscript(), startedAt: Date(), endedAt: nil)
        #expect(md.contains("- 記録中"))
        #expect(md.contains("- 音声: マイクのみ"))
    }

    @Test func speakersAreNumberedInOrderOfAppearance() {
        var t = MeetingTranscript()
        // Soniox labels need not start at 1 or be in order.
        t.apply([token("会議室から", "3", 0, 500), token("オンラインです", "1", 1_000, 1_500), token("了解", "3", 2_000, 2_500)])
        let md = MeetingDocument.markdown(t, startedAt: Date(), endedAt: nil, includesSystemAudio: true)
        let lines = md.split(separator: "\n").filter { $0.hasPrefix("[") }
        #expect(
            lines == [
                "[00:00:00] **話者1** 会議室から",
                "[00:00:01] **話者2** オンラインです",
                "[00:00:02] **話者1** 了解",
            ])
        #expect(md.contains("- 音声: マイクとシステム音声(相手の声)"))
    }

    @Test func speakersAfterReconnectGetNewNumbers() {
        var t = MeetingTranscript()
        t.apply([token("前", "1", 0, 500)])
        t.markReconnect(atMs: 10_000)
        t.apply([token("後", "1", 0, 500)])
        let md = MeetingDocument.markdown(t, startedAt: Date(), endedAt: nil)
        #expect(md.contains("**話者1** 前"))
        #expect(md.contains("文字起こしが途切れたため再接続しました"))
        #expect(md.contains("**話者2** 後"))
    }

    @Test func noticesExplainMissingSystemAudio() {
        let md = MeetingDocument.markdown(
            MeetingTranscript(), startedAt: Date(), endedAt: nil, notices: [.systemAudioUnavailable])
        #expect(md.contains("オンライン参加者の声は記録されていません"))
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
    let systemAudio = MockAudio()
    let provider = MockMeetingProvider()
    let directory: URL

    init() {
        settings = SettingsStore(defaults: UserDefaults(suiteName: "MeetingControllerTests-\(UUID())")!)
        // Most tests cover the microphone alone; the system-audio ones turn it back on.
        settings.meetingCapturesSystemAudio = false
        settings.meetingMinutesEnabled = false
        directory = FileManager.default.temporaryDirectory.appending(path: "HibiVoMeetingTests-\(UUID())")
    }

    private func makeController(
        secrets: MockSecrets = MockSecrets(), fileTranscriber: MockFileTranscriber? = nil,
        minutesWriter: MockMinutesWriter? = nil, onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> MeetingController {
        MeetingController(
            state: state, audio: audio, systemAudio: systemAudio, settings: settings, secrets: secrets,
            transcriber: { [provider] in MeetingTranscriber(provider: provider, fileTranscriber: fileTranscriber) },
            minutesWriter: { minutesWriter },
            vocabulary: { [VocabularyEntry(preferred: "AppSync", spoken: "あっぷしんく")] },
            directory: directory, saveInterval: .seconds(3600), reconnectDelays: [.zero], onSaved: onSaved)
    }

    private func savedFiles() -> [URL] {
        // Skips the hidden folder of saved recordings.
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
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
        #expect(config.vocabulary == ["AppSync"])
        // The hiragana spoken form is hinted in katakana, as in dictation.
        #expect(config.readings == ["アップシンク"])
        #expect(config.apiKey == "test-key")

        audio.speak()
        let session = try #require(provider.sessions.first)
        await session.emit(.tokens([MeetingToken(text: "始めます", isFinal: true, speaker: "1", startMs: 0, endMs: 800)]))
        await settle { state.partialTranscript == "始めます" }
        #expect(state.partialTranscript == "始めます")

        let t0 = ContinuousClock.now
        sut.handle(.pressed, at: t0)
        sut.handle(.released, at: t0 + .milliseconds(100))
        #expect(state.phase == .meeting)
        sut.handle(.pressed, at: t0 + .milliseconds(300))
        sut.handle(.released, at: t0 + .milliseconds(400))
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
        sut.handle(.pressed, at: .now)
        sut.handle(.interrupted, at: .now)
        sut.handle(.escape, at: .now)
        // A single tap, as Fn+volume looks to macOS, isn't enough either.
        sut.handle(.pressed, at: .now)
        sut.handle(.released, at: .now)
        #expect(state.phase == .meeting)
        sut.handle(.meeting, at: .now)
        await sut.waitUntilIdle()
        #expect(!sut.isActive)
    }

    @Test func missingKeyExplainsThatMeetingsNeedTheProvider() {
        let sut = makeController(secrets: MockSecrets(values: [:]))
        sut.start()
        #expect(state.phase == .error(UserFacingError.meetingRequiresAPIKey(provider: "Mock").message))
        #expect(audio.startCount == 0)
    }

    /// macOS's recognizer: no key, no speaker numbers, and it always streams.
    @Test func keylessProviderWithoutSpeakersStreamsAndSavesUnlabelledText() async throws {
        provider.requiresAPIKey = false
        provider.identifiesSpeakers = false
        settings.meetingTranscriptionTiming = .afterMeeting
        var saved: URL?
        let sut = makeController(secrets: MockSecrets(values: [:]), onSaved: { saved = $0 })
        sut.start()
        #expect(state.phase == .meeting)
        #expect(provider.configs.first?.apiKey == "")

        // No file transcriber, so after-meeting mode falls back to streaming.
        let session = try #require(provider.sessions.first)
        audio.speak()
        await session.emit(.tokens([MeetingToken(text: "始めます", isFinal: true, startMs: 0, endMs: 800)]))
        await settle { state.partialTranscript == "始めます" }
        sut.stop()
        await sut.waitUntilIdle()

        let text = try String(contentsOf: try #require(saved), encoding: .utf8)
        #expect(text.contains("[00:00:00] 始めます"))
        #expect(!text.contains("話者1"))
        #expect(text.contains("話者は区別していません"))
    }

    @Test func doesNotStartUntilTheModelIsReady() {
        provider.ready = false
        let sut = makeController()
        sut.start()
        #expect(state.phase == .error(UserFacingError.speechModelNotReady.message))
        #expect(audio.startCount == 0)
        #expect(!sut.isActive)
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

    @Test func systemAudioIsMixedIntoOneSession() async throws {
        settings.meetingCapturesSystemAudio = true
        let sut = makeController()
        sut.start()
        #expect(systemAudio.startCount == 1)
        #expect(provider.sessions.count == 1)
        let session = provider.sessions[0]

        // 10 ms from each source become 10 ms of mixed audio, not 20.
        audio.speak(bytes: 320)
        systemAudio.speak(bytes: 320)
        await session.emit(
            .tokens([
                MeetingToken(text: "聞こえますか", isFinal: true, speaker: "1", startMs: 0, endMs: 500),
                MeetingToken(text: "聞こえます", isFinal: true, speaker: "2", startMs: 1_000, endMs: 1_500),
            ]))
        await settle { state.partialTranscript == "聞こえます" }
        sut.stop()
        await sut.waitUntilIdle()

        #expect(await session.receivedBytes == 320)
        let url = try #require(savedFiles().first)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("**話者1** 聞こえますか"))
        #expect(text.contains("**話者2** 聞こえます"))
        #expect(text.contains("- 音声: マイクとシステム音声"))
        // Some level came through, so no permission warning.
        #expect(!text.contains("無音でした"))
    }

    @Test func microphoneFailureStopsAndSavesWithANotice() async throws {
        settings.meetingCapturesSystemAudio = true
        let sut = makeController()
        sut.start()
        let session = provider.sessions[0]
        audio.speak(bytes: 320)
        systemAudio.speak(bytes: 320)
        await session.emit(.tokens([MeetingToken(text: "保存する内容", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "保存する内容" }
        // An exhausted engine recovery ends the stream without a controller stop request.
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(!sut.isActive)
        #expect(state.phase == .error(UserFacingError.meetingMicrophoneLost.message))
        #expect(await session.didFinish)
        #expect(await session.receivedBytes == 320)
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("保存する内容"))
        #expect(text.contains("マイクの切り替え後に録音を再開できなかった"))
        #expect(text.contains("- 終了:"))
        #expect(!text.contains("- 記録中"))
    }

    @Test func microphoneFailureBeforeSpeechStillSavesANotice() async throws {
        let sut = makeController()
        sut.start()
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(state.phase == .error(UserFacingError.meetingMicrophoneLost.message))
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("マイクの切り替え後に録音を再開できなかった"))
    }

    @Test func afterMeetingMicrophoneFailureWithNoAudioSavesANotice() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([.success([])])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(await transcriber.calls.isEmpty)
        #expect(state.phase == .error(UserFacingError.meetingMicrophoneLost.message))
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("マイクの切り替え後に録音を再開できなかった"))
    }

    @Test func afterMeetingMicrophoneFailureNoticeSurvivesTranscriptionFailure() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([.failure(.unauthorized)])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak(bytes: 320)
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("マイクの切り替え後に録音を再開できなかった"))
    }

    @Test func afterMeetingMicrophoneFailureStillTranscribesCapturedAudio() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([
            .success([
                MeetingToken(text: "保存する内容", isFinal: true, speaker: "1", startMs: 0, endMs: 500)
            ])
        ])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak(bytes: 320)
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(state.phase == .error(UserFacingError.meetingMicrophoneLost.message))
        #expect(await transcriber.calls.first?.bytes == 320)
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("保存する内容"))
        #expect(text.contains("マイクの切り替え後に録音を再開できなかった"))
    }

    @Test func systemAudioFailureFallsBackToMicrophone() async throws {
        settings.meetingCapturesSystemAudio = true
        systemAudio.failStart = true
        let sut = makeController()
        sut.start()
        #expect(state.phase == .meeting)
        await provider.sessions[0].emit(
            .tokens([MeetingToken(text: "記録", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "記録" }
        sut.stop()
        await sut.waitUntilIdle()
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("オンライン参加者の声は記録されていません"))
        #expect(text.contains("- 音声: マイクのみ"))
    }

    @Test func silentSystemAudioSuggestsCheckingThePermission() async throws {
        settings.meetingCapturesSystemAudio = true
        let sut = makeController()
        sut.start()
        systemAudio.speak(level: 0)
        await provider.sessions[0].emit(
            .tokens([MeetingToken(text: "記録", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "記録" }
        sut.stop()
        await sut.waitUntilIdle()
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("システム音声が最後まで無音でした"))
    }

    @Test func turningSystemAudioOffRecordsOnlyTheMicrophone() async {
        let sut = makeController()
        sut.start()
        #expect(systemAudio.startCount == 0)
        #expect(provider.sessions.count == 1)
        sut.stop()
        await sut.waitUntilIdle()
    }

    @Test func afterMeetingRecordsWithoutStreamingThenTranscribesTheWholeMeeting() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([
            .success([
                MeetingToken(text: "始めます", isFinal: true, speaker: "1", startMs: 0, endMs: 800),
                MeetingToken(text: "はい", isFinal: true, speaker: "2", startMs: 1_000, endMs: 1_200),
                MeetingToken(text: "お願いします", isFinal: true, speaker: "3", startMs: 2_000, endMs: 2_500),
            ])
        ])
        var saved: URL?
        let sut = makeController(fileTranscriber: transcriber, onSaved: { saved = $0 })
        sut.start()
        #expect(state.phase == .meeting)
        #expect(provider.sessions.isEmpty)

        audio.speak(bytes: 320)
        audio.speak(bytes: 320)
        sut.stop()
        await sut.waitUntilIdle()

        #expect(state.phase == .idle)
        #expect(state.meetingTranscriptionsInProgress == 0)
        let call = try #require(await transcriber.calls.first)
        #expect(call.bytes == 640)
        #expect(call.sampleRate == 16_000)
        #expect(call.config.speakerDiarization)
        let text = try String(contentsOf: try #require(saved), encoding: .utf8)
        #expect(text.contains("**話者1** 始めます"))
        #expect(text.contains("**話者3** お願いします"))
        #expect(text.contains("- 終了: "))
    }

    @Test func afterMeetingRetriesTransientFailures() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([
            .failure(.network("offline")),
            .success([MeetingToken(text: "届きました", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]),
        ])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak()
        sut.stop()
        await sut.waitUntilIdle()
        // The audio is uploaded once; the retry fetches the same job again.
        #expect(await transcriber.calls.count == 1)
        #expect(await transcriber.fetched == [job1, job1])
        #expect(await transcriber.discarded == [job1])
        #expect(savedFiles().count == 1)
        #expect(savedRecordings().isEmpty)
    }

    @Test func afterMeetingRejectedKeyIsReportedWithoutRetrying() async {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([.failure(.unauthorized)])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak()
        sut.stop()
        await sut.waitUntilIdle()
        #expect(await transcriber.calls.count == 1)
        #expect(state.phase == .error(UserFacingError.invalidAPIKey(provider: "Mock").message))
        #expect(savedFiles().isEmpty)
    }

    private let job1 = MeetingFileJob(fileID: "file-1", transcriptionID: "job-1")

    private var recordingsDirectory: URL { directory.appending(path: ".recordings") }

    private func savedRecordings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: recordingsDirectory.path)) ?? []).sorted()
    }

    private func savedInfo(_ id: String) throws -> MeetingRecordingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            MeetingRecordingInfo.self, from: Data(contentsOf: recordingsDirectory.appending(path: "\(id).json")))
    }

    private func makeController(
        fileTranscriber: MockFileTranscriber, minutesWriter: MockMinutesWriter? = nil,
        onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> MeetingController {
        MeetingController(
            state: state, audio: audio, systemAudio: systemAudio, settings: settings, secrets: MockSecrets(),
            transcriber: { [provider] in MeetingTranscriber(provider: provider, fileTranscriber: fileTranscriber) },
            minutesWriter: { minutesWriter },
            vocabulary: { [VocabularyEntry(preferred: "AppSync", spoken: "あっぷしんく")] },
            directory: directory, saveInterval: .seconds(3600), reconnectDelays: [.zero], wakeDelay: .zero,
            onSaved: onSaved)
    }

    @Test func afterMeetingKeepsTheRecordingWhenTranscriptionKeepsFailing() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([.failure(.network("offline"))])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak(bytes: 320)
        audio.speak(bytes: 320)
        state.meetingNotes = "- 宿題を確認"
        sut.stop()
        await sut.waitUntilIdle()

        #expect(state.phase == .error(UserFacingError.meetingTranscriptionDeferred.message))
        #expect(await transcriber.calls.count == 1)
        #expect(await transcriber.discarded.isEmpty)
        let id = try #require(savedRecordings().first?.split(separator: ".").first.map(String.init))
        #expect(savedRecordings() == ["\(id).json", "\(id).pcm"])
        let audioFile = recordingsDirectory.appending(path: "\(id).pcm")
        #expect(try Data(contentsOf: audioFile).count == 640)
        let attributes = try FileManager.default.attributesOfItem(atPath: audioFile.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let info = try savedInfo(id)
        #expect(info.job == job1)
        #expect(info.endedAt != nil)
        #expect(info.notes == "- 宿題を確認")
        #expect(info.vocabulary.map(\.preferred) == ["AppSync"])
    }

    @Test func savedJobIsFetchedAgainAfterRelaunchWithoutUploading() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let first = MockFileTranscriber([.failure(.network("offline"))])
        let before = makeController(fileTranscriber: first)
        before.start()
        audio.speak(bytes: 320)
        state.meetingNotes = "- 宿題を確認"
        await before.prepareForTermination()
        await before.waitUntilIdle()

        // The next launch.
        let second = MockFileTranscriber([
            .success([MeetingToken(text: "続きです", isFinal: true, speaker: "1", startMs: 0, endMs: 500)])
        ])
        var saved: URL?
        let after = makeController(fileTranscriber: second, onSaved: { saved = $0 })
        after.resumeSavedRecordings()
        await after.waitUntilIdle()

        #expect(await second.calls.isEmpty)
        #expect(await second.fetched == [job1])
        #expect(await second.discarded == [job1])
        let text = try String(contentsOf: try #require(saved), encoding: .utf8)
        #expect(text.contains("**話者1** 続きです"))
        #expect(text.contains("- 宿題を確認"))
        #expect(text.contains("- 終了: "))
        #expect(savedRecordings().isEmpty)
        #expect(state.meetingTranscriptionsInProgress == 0)
    }

    @Test func recordingCutOffByAShutdownIsTranscribedFromDisk() async throws {
        // What a meeting leaves behind when the Mac shuts down mid-recording: audio, but no end time or job.
        let startedAt = Date(timeIntervalSinceNow: -600)
        let id = MeetingDocument.fileName(startedAt: startedAt).replacingOccurrences(of: ".md", with: "")
        let store = MeetingRecordingStore(directory: recordingsDirectory)
        let info = MeetingRecordingInfo(
            startedAt: startedAt, endedAt: nil, providerID: provider.id, model: "m1", language: "ja",
            vocabulary: [VocabularyEntry(preferred: "AppSync", spoken: "あっぷしんく")], includesSystemAudio: true,
            notices: [], notes: "", job: nil)
        #expect(await store.save(info, id: id))
        #expect(await store.append(Data(count: 960), id: id))
        await store.closeAudio(id: id)

        let transcriber = MockFileTranscriber([
            .success([MeetingToken(text: "残っていた", isFinal: true, speaker: "1", startMs: 0, endMs: 500)])
        ])
        let sut = makeController(fileTranscriber: transcriber)
        sut.resumeSavedRecordings()
        await sut.waitUntilIdle()

        let call = try #require(await transcriber.calls.first)
        #expect(call.bytes == 960)
        #expect(call.config.vocabulary == ["AppSync"])
        #expect(call.config.readings == ["アップシンク"])
        let text = try String(contentsOf: directory.appending(path: "\(id).md"), encoding: .utf8)
        #expect(text.contains("残っていた"))
        #expect(text.contains("- 終了: "))
        #expect(text.contains("マイクとシステム音声"))
        #expect(savedRecordings().isEmpty)
    }

    @Test func goneJobIsSubmittedAgain() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber(
            [.success([MeetingToken(text: "再送", isFinal: true, speaker: "1", startMs: 0, endMs: 500)])], gone: 1)
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak(bytes: 320)
        sut.stop()
        await sut.waitUntilIdle()
        #expect(await transcriber.calls.map(\.bytes) == [320, 320])
        #expect(await transcriber.discarded.map(\.transcriptionID) == ["job-1", "job-2"])
        #expect(savedFiles().count == 1)
        #expect(savedRecordings().isEmpty)
    }

    @Test func sleepEndsTheMeetingAndTranscribesAfterWaking() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([
            .success([MeetingToken(text: "起きてから", isFinal: true, speaker: "1", startMs: 0, endMs: 500)])
        ])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak(bytes: 320)
        sut.systemWillSleep()
        await settle { !sut.isActive }
        #expect(!sut.isActive)
        #expect(state.meetingTranscriptionsInProgress == 1)
        for _ in 0..<50 { await Task.yield() }
        // Nothing goes out while the Mac is asleep.
        #expect(await transcriber.calls.isEmpty)

        sut.systemDidWake()
        await sut.waitUntilIdle()
        #expect(await transcriber.calls.count == 1)
        #expect(savedFiles().count == 1)
        #expect(savedRecordings().isEmpty)
    }

    @Test func sleepEndsARealtimeMeetingAndSavesIt() async throws {
        let sut = makeController()
        sut.start()
        await provider.sessions[0].emit(
            .tokens([MeetingToken(text: "ここまで", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "ここまで" }
        sut.systemWillSleep()
        await sut.waitUntilIdle()
        #expect(!sut.isActive)
        let text = try String(contentsOf: try #require(savedFiles().first), encoding: .utf8)
        #expect(text.contains("ここまで"))
        #expect(text.contains("- 終了: "))
    }

    @Test func minutesWaitForWakingAndRetryAfterASleep() async throws {
        settings.meetingMinutesEnabled = true
        let writer = MockMinutesWriter(.success("# 定例\n\n本文"))
        var shown: [URL] = []
        let sut = makeController(fileTranscriber: MockFileTranscriber([.success([])]), minutesWriter: writer) {
            shown.append($0)
        }
        sut.start()
        await provider.sessions[0].emit(
            .tokens([MeetingToken(text: "議題", isFinal: true, speaker: "1", startMs: 0, endMs: 500)]))
        await settle { state.partialTranscript == "議題" }
        sut.systemWillSleep()
        for _ in 0..<50 { await Task.yield() }
        #expect(await writer.calls.isEmpty)
        sut.systemDidWake()
        await sut.waitUntilIdle()
        #expect(await writer.calls.count == 1)
        #expect(shown.first?.lastPathComponent.hasSuffix("_定例.md") == true)
    }

    @Test func expiredRecordingIsDropped() async throws {
        let startedAt = Date(timeIntervalSinceNow: -MeetingRecordingStore.lifetime - 60)
        let store = MeetingRecordingStore(directory: recordingsDirectory)
        let info = MeetingRecordingInfo(
            startedAt: startedAt, endedAt: startedAt, providerID: provider.id, model: "m1", language: "ja",
            vocabulary: [], includesSystemAudio: false, notices: [], notes: "", job: job1)
        #expect(await store.save(info, id: "old"))
        #expect(await store.append(Data(count: 320), id: "old"))
        await store.closeAudio(id: "old")
        let transcriber = MockFileTranscriber([.success([])])
        let sut = makeController(fileTranscriber: transcriber)
        sut.resumeSavedRecordings()
        await sut.waitUntilIdle()
        #expect(await transcriber.fetched.isEmpty)
        #expect(await transcriber.discarded == [job1])
        #expect(savedRecordings().isEmpty)
    }

    @Test func afterMeetingFreesTheHotkeyWhileTranscribing() async {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([.success([])])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        audio.speak()
        sut.stop()
        await settle { !sut.isActive }
        // Recording is over, so a new meeting (or dictation) can start before the transcript is back.
        #expect(!sut.isActive)
        await sut.waitUntilIdle()
        #expect(state.phase == .error(UserFacingError.nothingRecognized.message))
    }

    /// Records one line of speech and stops, leaving the transcript saved.
    private func recordShortMeeting(_ sut: MeetingController) async throws {
        sut.start()
        let session = try #require(provider.sessions.first)
        await session.emit(
            .tokens([MeetingToken(text: "来週リリースします", isFinal: true, speaker: "1", startMs: 0, endMs: 900)]))
        await settle { state.partialTranscript == "来週リリースします" }
        sut.stop()
        await sut.waitUntilIdle()
    }

    @Test func savedMeetingIsTurnedIntoMinutes() async throws {
        settings.meetingMinutesEnabled = true
        settings.meetingMinutesModel = .opus
        let writer = MockMinutesWriter(.success("# リリース日程の確認\n\n## 概要\nリリース日を決めた。"))
        var shown: [URL] = []
        let sut = MeetingController(
            state: state, audio: audio, systemAudio: systemAudio, settings: settings, secrets: MockSecrets(),
            transcriber: { [provider] in MeetingTranscriber(provider: provider) }, minutesWriter: { writer },
            vocabulary: { [VocabularyEntry(preferred: "AppSync", spoken: "アップシンク")] }, directory: directory,
            saveInterval: .seconds(3600), reconnectDelays: [.zero], onSaved: { shown.append($0) })
        try await recordShortMeeting(sut)

        let call = try #require(await writer.calls.first)
        #expect(call.model == "opus")
        #expect(call.vocabulary == [CleanupPromptBuilder.Term(preferred: "AppSync", spokenForms: ["アップシンク"])])
        #expect(call.transcript.contains("**話者1** 来週リリースします"))
        // Finder is pointed at the minutes only, not at the transcript first.
        let url = try #require(shown.first)
        #expect(shown.count == 1)
        #expect(url.lastPathComponent.hasSuffix("_リリース日程の確認.md"))
        let minutes = try String(contentsOf: url, encoding: .utf8)
        #expect(minutes.hasPrefix("# リリース日程の確認\n\n## 概要\nリリース日を決めた。"))
        #expect(savedFiles().count == 2)
        #expect(state.meetingMinutesInProgress == 0)
        #expect(state.phase == .idle)
    }

    @Test func notesReachTheMinutesThroughTheTranscriptOnly() async throws {
        settings.meetingMinutesEnabled = true
        let writer = MockMinutesWriter(.success("# リリース日程の確認\n\n## 概要\nリリース日を決めた。"))
        var shown: [URL] = []
        let sut = makeController(minutesWriter: writer, onSaved: { shown.append($0) })
        sut.start()
        state.meetingNotes = "### 宿題\n- [ ] 日程を連絡"
        let session = try #require(provider.sessions.first)
        await session.emit(
            .tokens([MeetingToken(text: "来週リリースします", isFinal: true, speaker: "1", startMs: 0, endMs: 900)]))
        await settle { state.partialTranscript == "来週リリースします" }
        sut.stop()
        // The window closes with the meeting; the next one starts with empty notes.
        #expect(state.meetingNotes.isEmpty)
        await sut.waitUntilIdle()

        let call = try #require(await writer.calls.first)
        #expect(call.transcript.contains("## メモ\n\n### 宿題\n- [ ] 日程を連絡\n"))
        let transcript = try #require(savedFiles().first { $0.lastPathComponent != shown.first?.lastPathComponent })
        #expect(try String(contentsOf: transcript, encoding: .utf8).contains("- [ ] 日程を連絡"))
        let minutes = try String(contentsOf: try #require(shown.first), encoding: .utf8)
        // Claude decides what of the notes belongs in the minutes; they aren't pasted in as written.
        #expect(minutes.hasPrefix("# リリース日程の確認\n\n## 概要\n"))
        #expect(!minutes.contains("日程を連絡"))
    }

    @Test func notesAreKeptWhenNothingWasSaid() async throws {
        settings.meetingMinutesEnabled = true
        let writer = MockMinutesWriter(.success("unused"))
        var shown: [URL] = []
        let sut = makeController(minutesWriter: writer, onSaved: { shown.append($0) })
        sut.start()
        state.meetingNotes = "あとで確認"
        sut.stop()
        await sut.waitUntilIdle()
        #expect(await writer.calls.isEmpty)
        let url = try #require(shown.first)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("## メモ\n\nあとで確認"))
        #expect(state.phase == .error(UserFacingError.nothingRecognized.message))
    }

    @Test func afterMeetingNotesSurviveATranscriptionFailure() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let transcriber = MockFileTranscriber([.failure(.unauthorized)])
        let sut = makeController(fileTranscriber: transcriber)
        sut.start()
        state.meetingNotes = "決定: A 案"
        audio.speak()
        sut.stop()
        await sut.waitUntilIdle()
        #expect(state.phase == .error(UserFacingError.invalidAPIKey(provider: "Mock").message))
        let url = try #require(savedFiles().first)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("決定: A 案"))
        #expect(text.contains("- 終了: "))
    }

    @Test func notesAreAutosavedDuringTheMeeting() async throws {
        let sut = MeetingController(
            state: state, audio: audio, systemAudio: systemAudio, settings: settings, secrets: MockSecrets(),
            transcriber: { [provider] in MeetingTranscriber(provider: provider) }, directory: directory,
            saveInterval: .milliseconds(10), reconnectDelays: [.zero])
        sut.start()
        state.meetingNotes = "途中のメモ"
        for _ in 0..<200 where savedFiles().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let url = try #require(savedFiles().first)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("途中のメモ"))
        #expect(text.contains("- 記録中"))
        sut.stop()
        await sut.waitUntilIdle()
    }

    @Test func afterMeetingDeletedNotesLeaveNoFile() async throws {
        settings.meetingTranscriptionTiming = .afterMeeting
        let sut = MeetingController(
            state: state, audio: audio, systemAudio: systemAudio, settings: settings, secrets: MockSecrets(),
            transcriber: { [provider] in
                MeetingTranscriber(provider: provider, fileTranscriber: MockFileTranscriber([.success([])]))
            }, directory: directory, saveInterval: .milliseconds(10), reconnectDelays: [.zero])
        sut.start()
        state.meetingNotes = "消すメモ"
        for _ in 0..<200 where savedFiles().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!savedFiles().isEmpty)
        state.meetingNotes = ""
        audio.speak()
        sut.stop()
        await sut.waitUntilIdle()
        #expect(savedFiles().isEmpty)
    }

    @Test func failedMinutesStillShowTheTranscript() async throws {
        settings.meetingMinutesEnabled = true
        let writer = MockMinutesWriter(.failure(.failed("usage limit")))
        var shown: [URL] = []
        let sut = makeController(minutesWriter: writer, onSaved: { shown.append($0) })
        try await recordShortMeeting(sut)

        #expect(shown.count == 1)
        // The transcript is the only file, and it is what Finder shows.
        #expect(shown.first?.lastPathComponent == savedFiles().first?.lastPathComponent)
        #expect(savedFiles().count == 1)
        #expect(state.phase == .error(UserFacingError.meetingMinutesFailed.message))
    }

    @Test func minutesWithoutClaudeCodeExplainWhy() async throws {
        settings.meetingMinutesEnabled = true
        var shown: [URL] = []
        let sut = makeController(minutesWriter: nil, onSaved: { shown.append($0) })
        try await recordShortMeeting(sut)
        #expect(shown.count == 1)
        #expect(state.phase == .error(UserFacingError.claudeCodeNotFound.message))
    }

    @Test func minutesOffShowsTheTranscriptOnly() async throws {
        let writer = MockMinutesWriter(.success("unused"))
        var shown: [URL] = []
        let sut = makeController(minutesWriter: writer, onSaved: { shown.append($0) })
        try await recordShortMeeting(sut)
        #expect(await writer.calls.isEmpty)
        #expect(shown.count == 1)
        #expect(state.phase == .idle)
    }

    @Test func microphoneNoticeAloneIsNotTurnedIntoMinutes() async throws {
        settings.meetingMinutesEnabled = true
        let writer = MockMinutesWriter(.success("unused"))
        var shown: [URL] = []
        let sut = makeController(minutesWriter: writer, onSaved: { shown.append($0) })
        sut.start()
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(await writer.calls.isEmpty)
        #expect(shown.count == 1)
        #expect(savedFiles().count == 1)
    }

    @Test func afterMeetingMicrophoneNoticeAloneIsNotTurnedIntoMinutes() async throws {
        settings.meetingMinutesEnabled = true
        settings.meetingTranscriptionTiming = .afterMeeting
        let writer = MockMinutesWriter(.success("unused"))
        var shown: [URL] = []
        let sut = makeController(
            fileTranscriber: MockFileTranscriber([.success([])]), minutesWriter: writer,
            onSaved: { shown.append($0) })
        sut.start()
        audio.speak(bytes: 320)
        audio.stop()
        await settle { state.phase != .meeting }
        await sut.waitUntilIdle()
        #expect(await writer.calls.isEmpty)
        #expect(shown.count == 1)
        #expect(savedFiles().count == 1)
    }
}

@MainActor @Suite struct HUDModelTests {
    @Test func stoppingFromTheHUDTakesTwoClicks() {
        let model = HUDModel()
        #expect(!model.confirmStop())
        #expect(model.stopArmed)
        #expect(model.confirmStop())
        #expect(!model.stopArmed)
    }

    @Test func resetDisarms() {
        let model = HUDModel()
        _ = model.confirmStop()
        model.reset()
        #expect(!model.confirmStop())
    }
}

@Suite struct PCMMixerTests {
    private func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func samples(_ data: Data?) -> [Int16] {
        guard let data else { return [] }
        var out = [Int16](repeating: 0, count: data.count / 2)
        out.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        return out
    }

    @Test func mixesOnceBothSourcesHaveSamples() {
        var mixer = PCMMixer(maximumLag: 100)
        #expect(mixer.push(pcm([100, 200, 300]), from: .microphone) == nil)
        #expect(samples(mixer.push(pcm([10, 20]), from: .system)) == [110, 220])
        #expect(samples(mixer.push(pcm([30, 40]), from: .system)) == [330])
        #expect(samples(mixer.flush()) == [40])
    }

    @Test func aStalledSourceDoesNotHoldTheOtherBack() {
        var mixer = PCMMixer(maximumLag: 2)
        #expect(samples(mixer.push(pcm([1, 2, 3, 4, 5]), from: .microphone)) == [1, 2, 3])
        #expect(samples(mixer.push(pcm([6]), from: .microphone)) == [4])
    }

    @Test func resumedMicrophoneDoesNotAccumulateTheOutageAsLag() {
        var mixer = PCMMixer(maximumLag: 2)
        _ = mixer.push(pcm([100, 100]), from: .microphone)
        #expect(samples(mixer.push(pcm([1, 2]), from: .system)) == [101, 102])
        // During a long microphone restart only the last maximumLag samples remain queued.
        #expect(samples(mixer.push(pcm([3, 4, 5, 6, 7, 8]), from: .system)) == [3, 4, 5, 6])
        #expect(samples(mixer.push(pcm([100, 200]), from: .microphone)) == [107, 208])
        #expect(mixer.flush() == nil)
        _ = mixer.push(pcm([300, 400]), from: .microphone)
        #expect(samples(mixer.push(pcm([9, 10]), from: .system)) == [309, 410])
    }

    @Test func sumsAreClamped() {
        var mixer = PCMMixer(maximumLag: 10)
        _ = mixer.push(pcm([30_000, -30_000]), from: .microphone)
        #expect(samples(mixer.push(pcm([10_000, -10_000]), from: .system)) == [Int16.max, Int16.min])
    }
}

@Suite struct SonioxFileTranscriberTests {
    @Test func wavHeaderDescribesMonoPCM16() {
        let header = [UInt8](SonioxFileTranscriber.wavHeader(dataSize: 32_000, sampleRate: 16_000))
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(header[at + $1]) << (8 * $1) } }
        func u16(_ at: Int) -> UInt16 { UInt16(header[at]) | UInt16(header[at + 1]) << 8 }
        #expect(header.count == 44)
        #expect(String(decoding: header[0..<4], as: UTF8.self) == "RIFF")
        #expect(u32(4) == 36 + 32_000)
        #expect(u16(22) == 1)
        #expect(u32(24) == 16_000)
        #expect(u32(28) == 32_000)
        #expect(u16(34) == 16)
        #expect(u32(40) == 32_000)
    }

    @Test func multipartBodyWrapsTheWav() {
        let pcm = Data([1, 2, 3, 4])
        let body = SonioxFileTranscriber.multipartBody(wav: pcm, sampleRate: 16_000, boundary: "B")
        let head =
            "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
        let tail = "\r\n--B--\r\n"
        #expect(body.count == head.utf8.count + 44 + pcm.count + tail.utf8.count)
        #expect(body.prefix(head.utf8.count) == Data(head.utf8))
        #expect(body.dropFirst(head.utf8.count).prefix(4) == Data("RIFF".utf8))
        #expect(body.suffix(tail.utf8.count + pcm.count) == pcm + Data(tail.utf8))
    }

    @Test func createRequestAsksForDiarizationWithHintsAndTerms() throws {
        let request = try SonioxFileTranscriber.createRequest(
            fileID: "f1", model: "stt-async-v5",
            config: TranscriptionConfig(
                apiKey: "k", model: "m", language: "ja", vocabulary: ["AppSync"], readings: ["アップシンク"]))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["file_id"] as? String == "f1")
        #expect(object["model"] as? String == "stt-async-v5")
        #expect(object["enable_speaker_diarization"] as? Bool == true)
        #expect(object["language_hints"] as? [String] == ["ja", "en"])
        #expect((object["context"] as? [String: Any])?["terms"] as? [String] == ["AppSync", "アップシンク"])
    }

    @Test func transcriptTokensAreAllFinal() throws {
        let json = #"{"id":"t","text":"はい","tokens":[{"text":"はい","speaker":"2","start_ms":10,"end_ms":200}]}"#
        let response = try JSONDecoder().decode(SonioxProtocol.Response.self, from: Data(json.utf8))
        #expect(
            SonioxFileTranscriber.tokens(response) == [
                MeetingToken(text: "はい", isFinal: true, speaker: "2", startMs: 10, endMs: 200)
            ])
    }

    /// A job interrupted by a sleep must stay on Soniox's side so it can be fetched again; one that no
    /// longer exists or failed has to be submitted again.
    @Test(arguments: [
        (404, #"{"error":"not found"}"#), (200, #"{"id":"job-1","status":"error","error_message":"bad"}"#),
    ])
    func missingOrFailedJobIsGoneWithoutDeletingAnything(status: Int, body: String) async throws {
        let session = SonioxStubProtocol.session { request in
            (request.httpMethod == "DELETE" ? 204 : status, Data(body.utf8))
        }
        let transcriber = SonioxFileTranscriber(urlSession: session, pollInterval: .zero)
        let job = MeetingFileJob(fileID: "file-1", transcriptionID: "job-1")
        await #expect(throws: MeetingFileJobError.gone) {
            try await transcriber.result(of: job, apiKey: "k")
        }
        let requests = SonioxStubProtocol.requests(of: session)
        #expect(requests.map(\.httpMethod) == ["GET"])
        #expect(requests.first?.url?.path == "/v1/transcriptions/job-1")
    }

    @Test func asyncAudioIsPricedLowerThanRealtime() throws {
        let async = try #require(
            UsagePricing.transcriptionUSD(TranscriptionUsage(provider: "soniox", model: "stt-async-v5", seconds: 3600)))
        let live = try #require(
            UsagePricing.transcriptionUSD(TranscriptionUsage(provider: "soniox", model: "stt-rt-v5", seconds: 3600)))
        #expect(abs(async - 0.10) < 1e-9)
        #expect(abs(live - 0.12) < 1e-9)
    }
}

@Suite struct ClaudeCodeMinutesWriterTests {
    @Test func runsHeadlessWithoutToolsOrSettings() {
        let args = ClaudeCodeMinutesWriter.arguments(model: "sonnet")
        #expect(args.starts(with: ["-p", "--output-format", "json", "--model", "sonnet"]))
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args[args.firstIndex(of: "--setting-sources")! + 1] == "")
        // --bare would force API-key auth and bypass the subscription.
        #expect(!args.contains("--bare"))
        #expect(args.last == MeetingMinutesPrompt.system)
    }

    @Test func apiKeysAreRemovedSoTheSubscriptionIsUsed() {
        let environment = ClaudeCodeMinutesWriter.environment([
            "ANTHROPIC_API_KEY": "sk", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDECODE": "1", "HOME": "/Users/me",
        ])
        #expect(environment == ["HOME": "/Users/me"])
    }

    @Test func parsesTheResult() throws {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"概要\n本文"}"#
        #expect(try ClaudeCodeMinutesWriter.parse(Data(ok.utf8)) == "概要\n本文")
    }

    @Test func reportsFailures() {
        let error = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#
        #expect(throws: MeetingMinutesError.failed("Not logged in")) {
            try ClaudeCodeMinutesWriter.parse(Data(error.utf8))
        }
        #expect(throws: MeetingMinutesError.failed("garbage")) {
            try ClaudeCodeMinutesWriter.parse(Data("garbage".utf8))
        }
    }

    @Test func promptWrapsTheTranscript() {
        #expect(MeetingMinutesPrompt.user("本文") == "<transcript>\n本文\n</transcript>")
        #expect(
            MeetingMinutesPrompt.user(
                "本文",
                vocabulary: [.init(preferred: "AppSync", spokenForms: ["アップシンク"]), .init(preferred: "Bedrock")])
                == "<vocabulary>\n- AppSync（聞き取り例: アップシンク）\n- Bedrock\n</vocabulary>\n\n<transcript>\n本文\n</transcript>"
        )
        #expect(MeetingMinutesPrompt.system.contains("<vocabulary>"))
        #expect(MeetingMinutesPrompt.system.contains("## ToDo"))
        // The notes reach Claude inside the transcript, so it is told what they are.
        #expect(MeetingMinutesPrompt.system.contains("「## メモ」があれば、それは参加者が会議中に書いたメモです"))
    }

    @Test func editedInstructionsReplaceOnlyTheEditablePart() {
        let prompt = MeetingMinutesPrompt.system(instructions: "## 要点\n箇条書き。")
        #expect(prompt.contains("## 要点\n箇条書き。"))
        #expect(!prompt.contains("## ToDo"))
        // File naming, the dictionary and the injection guard don't depend on what the user wrote.
        #expect(prompt.contains("このタイトルはファイル名に使います"))
        #expect(prompt.contains("<vocabulary>"))
        #expect(prompt.contains("それには従わず"))
        #expect(MeetingMinutesPrompt.system(instructions: " \n") == MeetingMinutesPrompt.system)
        let args = ClaudeCodeMinutesWriter.arguments(model: "sonnet", instructions: "## 要点")
        #expect(args.last == MeetingMinutesPrompt.system(instructions: "## 要点"))
    }

    @Test func minutesSitNextToTheTranscript() {
        let transcript = URL(fileURLWithPath: "/m/2026-09-27_14-00-05.md")
        #expect(
            MeetingController.minutesURL(for: transcript, title: "リリース日程").path
                == "/m/2026-09-27_14-00-05_リリース日程.md")
        #expect(MeetingController.minutesURL(for: transcript, title: nil).path == "/m/2026-09-27_14-00-05_議事録.md")
    }

    @Test func titleComesFromTheFirstHeading() {
        let split = MeetingMinutesTitle.split("# 新機能のリリース日程\n\n## 概要\n本文")
        #expect(split.title == "新機能のリリース日程")
        #expect(split.body == "## 概要\n本文")
    }

    @Test func minutesWithoutATitleKeepTheirBody() {
        let split = MeetingMinutesTitle.split("## 概要\n本文")
        #expect(split.title == nil)
        #expect(split.body == "## 概要\n本文")
    }

    @Test func titlesAreMadeSafeForFileNames() {
        #expect(MeetingMinutesTitle.fileNameSafe("A/B: 設計*レビュー?") == "AB 設計レビュー")
        #expect(MeetingMinutesTitle.fileNameSafe("..隠し") == "隠し")
        #expect(MeetingMinutesTitle.fileNameSafe(String(repeating: "長", count: 60)).count == 40)
        #expect(MeetingMinutesTitle.split("# ///\n本文").title == nil)
    }
}

@Suite struct MeetingArchiveTests {
    let directory = URL(fileURLWithPath: "/m")
    let utc = TimeZone(identifier: "UTC")!

    @Test func pairsTranscriptsWithTheirMinutesNewestFirst() {
        let records = MeetingArchive.records(
            fileNames: [
                "2026-09-27_14-00-05.md", "2026-09-27_14-00-05_リリース日程.md",
                "2026-09-28_09-30-00.md", ".DS_Store", "メモ.md", "2026-09-27_14-00-05.txt",
            ],
            in: directory, timeZone: utc)
        #expect(records.map(\.id) == ["2026-09-28_09-30-00", "2026-09-27_14-00-05"])
        #expect(records[0].minutesURL == nil)
        #expect(records[0].primaryURL?.lastPathComponent == "2026-09-28_09-30-00.md")
        #expect(records[1].title == "リリース日程")
        #expect(records[1].transcriptURL?.path == "/m/2026-09-27_14-00-05.md")
        #expect(records[1].primaryURL?.path == "/m/2026-09-27_14-00-05_リリース日程.md")
        #expect(records[1].startedAt == Date(timeIntervalSince1970: 1_790_517_605))
    }

    @Test func fallbackMinutesHaveNoTitleAndMinutesSurviveADeletedTranscript() {
        let records = MeetingArchive.records(fileNames: ["2026-09-27_14-00-05_議事録.md"], in: directory, timeZone: utc)
        #expect(records.count == 1)
        #expect(records[0].title == nil)
        #expect(records[0].transcriptURL == nil)
        #expect(records[0].primaryURL?.lastPathComponent == "2026-09-27_14-00-05_議事録.md")
    }
}

/// Answers every request of one session with a canned response, and records the requests.
final class SonioxStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SonioxStubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub": id]
        return URLSession(configuration: configuration)
    }

    static func requests(of session: URLSession) -> [URLRequest] {
        let id = session.configuration.httpAdditionalHeaders?["X-Stub"] as? String ?? ""
        return lock.withLock { recorded[id] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        let handler = Self.lock.withLock {
            Self.recorded[id, default: []].append(request)
            return Self.handlers[id]
        }
        let (status, data) = handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct MeetingStopGestureTests {
    let t0 = ContinuousClock.now

    private func ms(_ value: Int) -> ContinuousClock.Instant { t0 + .milliseconds(value) }

    @Test func doubleTapStops() {
        var sut = MeetingStopGesture()
        #expect(sut.handle(.pressed, at: ms(0)) == false)
        #expect(sut.handle(.released, at: ms(100)) == false)
        #expect(sut.handle(.pressed, at: ms(400)) == false)
        #expect(sut.handle(.released, at: ms(500)) == true)
    }

    @Test func singleTapDoesNotStop() {
        var sut = MeetingStopGesture()
        _ = sut.handle(.pressed, at: ms(0))
        #expect(sut.handle(.released, at: ms(100)) == false)
    }

    @Test func slowSecondTapStartsOver() {
        var sut = MeetingStopGesture()
        _ = sut.handle(.pressed, at: ms(0))
        _ = sut.handle(.released, at: ms(100))
        _ = sut.handle(.pressed, at: ms(700))
        #expect(sut.handle(.released, at: ms(800)) == false)
        // That late tap counts as the first of a new pair.
        _ = sut.handle(.pressed, at: ms(1000))
        #expect(sut.handle(.released, at: ms(1100)) == true)
    }

    @Test func holdsAreNotTaps() {
        var sut = MeetingStopGesture()
        _ = sut.handle(.pressed, at: ms(0))
        _ = sut.handle(.released, at: ms(100))
        _ = sut.handle(.pressed, at: ms(200))
        #expect(sut.handle(.released, at: ms(900)) == false)
        _ = sut.handle(.pressed, at: ms(1000))
        #expect(sut.handle(.released, at: ms(1100)) == false)
    }

    @Test func otherKeysInBetweenStartOver() {
        for interruption in [HotkeyAction.interrupted, .escape] {
            var sut = MeetingStopGesture()
            _ = sut.handle(.pressed, at: ms(0))
            _ = sut.handle(.released, at: ms(100))
            _ = sut.handle(.pressed, at: ms(200))
            // Fn+← (or a media key): the interpreter sends no release after an interruption.
            _ = sut.handle(interruption, at: ms(250))
            _ = sut.handle(.pressed, at: ms(400))
            #expect(sut.handle(.released, at: ms(500)) == false)
        }
    }

    @Test func triggerPlusMStops() {
        var sut = MeetingStopGesture()
        #expect(sut.handle(.meeting, at: ms(0)) == true)
    }
}
