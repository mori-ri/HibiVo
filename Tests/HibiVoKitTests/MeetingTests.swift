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
        directory = FileManager.default.temporaryDirectory.appending(path: "HibiVoMeetingTests-\(UUID())")
    }

    private func makeController(
        secrets: MockSecrets = MockSecrets(), fileTranscriber: MockFileTranscriber? = nil,
        onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> MeetingController {
        MeetingController(
            state: state, audio: audio, systemAudio: systemAudio, settings: settings, secrets: secrets,
            provider: provider, fileTranscriber: fileTranscriber,
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
        #expect(await transcriber.calls.count == 2)
        #expect(savedFiles().count == 1)
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
            config: TranscriptionConfig(apiKey: "k", model: "m", language: "ja", vocabulary: ["AppSync"]))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["file_id"] as? String == "f1")
        #expect(object["model"] as? String == "stt-async-v5")
        #expect(object["enable_speaker_diarization"] as? Bool == true)
        #expect(object["language_hints"] as? [String] == ["ja", "en"])
        #expect((object["context"] as? [String: Any])?["terms"] as? [String] == ["AppSync"])
    }

    @Test func transcriptTokensAreAllFinal() throws {
        let json = #"{"id":"t","text":"はい","tokens":[{"text":"はい","speaker":"2","start_ms":10,"end_ms":200}]}"#
        let response = try JSONDecoder().decode(SonioxProtocol.Response.self, from: Data(json.utf8))
        #expect(
            SonioxFileTranscriber.tokens(response) == [
                MeetingToken(text: "はい", isFinal: true, speaker: "2", startMs: 10, endMs: 200)
            ])
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
