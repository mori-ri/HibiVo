import Foundation
import Testing

@testable import HibiVoKit

@MainActor
@Suite struct DictationControllerTests {
    let state = AppState()
    let settings: SettingsStore
    let audio = MockAudio()
    let inserter = MockInserter()
    let ducker = MockDucker()
    let watcher = MockCorrectionWatcher()

    init() {
        let defaults = UserDefaults(suiteName: "DictationControllerTests-\(UUID())")!
        settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        settings.cleanupEnabled = false
    }

    private func makeController(
        provider: MockTranscriptionProvider = MockTranscriptionProvider(),
        secrets: MockSecrets = MockSecrets(),
        activeApp: MockActiveApp = MockActiveApp(),
        minimumDuration: Duration = .zero,
        holdThreshold: Duration = .zero
    ) -> DictationController {
        DictationController(
            state: state, audio: audio,
            contextBuilder: DictationContextBuilder(
                settings: settings, secrets: secrets, transcriptionProviders: [provider]),
            activeApp: activeApp, inserter: inserter, correctionWatcher: watcher, ducker: ducker,
            duckingEnabled: { settings.duckOutputWhileRecording }, minimumDuration: minimumDuration,
            holdThreshold: holdThreshold)
    }

    @Test func speakersAreDuckedOnlyWhileRecording() async {
        let sut = makeController()
        sut.handle(.pressed)
        #expect(ducker.isDucked)
        audio.speak()
        sut.handle(.released)
        #expect(!ducker.isDucked)
        await sut.waitUntilIdle()
    }

    @Test func cancelRestoresSpeakers() async {
        let sut = makeController()
        sut.handle(.pressed)
        sut.handle(.escape)
        #expect(!ducker.isDucked)
        await sut.waitUntilIdle()
    }

    @Test func duckingCanBeTurnedOff() async {
        settings.duckOutputWhileRecording = false
        let sut = makeController()
        sut.handle(.pressed)
        #expect(ducker.duckCount == 0)
        sut.handle(.escape)
        await sut.waitUntilIdle()
    }

    @Test func pressStartsRecordingAndReleaseTranscribes() async throws {
        let provider = MockTranscriptionProvider()
        let sut = makeController(provider: provider)

        sut.handle(.pressed)
        #expect(state.phase == .recording)
        audio.speak()
        audio.speak()
        sut.handle(.released)
        #expect(state.phase == .processing)
        await sut.waitUntilIdle()

        let session = try #require(provider.sessions.first)
        #expect(await session.receivedBytes == 640)
        #expect(await session.didFinish)
        #expect(state.phase == .idle)
        #expect(provider.lastConfig?.language == "ja")
        #expect(provider.lastConfig?.apiKey == "test-key")
        #expect(inserter.inserted.map(\.text) == ["今日の15時からAWSのAppSyncについて打ち合わせをします"])
        #expect(inserter.inserted.first?.target?.name == "Slack")
    }

    @Test func textGoesToTheAppInFrontWhenRecordingStops() async {
        let activeApp = MockActiveApp()
        let sut = makeController(activeApp: activeApp)
        sut.handle(.pressed)  // Reading something in Slack…
        audio.speak()
        let mail = TargetApplication(processID: 7, bundleID: "com.apple.mail", name: "Mail")
        activeApp.app = mail  // …then moving to the reply before stopping.
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(inserter.inserted.first?.target == mail)
        #expect(watcher.watched.first?.target == mail)
    }

    @Test func ownWindowInFrontAtStopKeepsTheStartingApp() async {
        let activeApp = MockActiveApp()
        let sut = makeController(activeApp: activeApp)
        sut.handle(.pressed)
        audio.speak()
        activeApp.app = TargetApplication(
            processID: ProcessInfo.processInfo.processIdentifier, bundleID: "io.github.mori-ri.hibivo", name: "HibiVo")
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(inserter.inserted.first?.target?.name == "Slack")
    }

    @Test func pastedTextIsWatchedForCorrectionsUntilTheNextDictation() async {
        let sut = makeController()
        sut.handle(.pressed)
        #expect(watcher.stopCount == 1)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(watcher.watched.map(\.inserted) == ["今日の15時からAWSのAppSyncについて打ち合わせをします"])
        #expect(watcher.watched.first?.target?.name == "Slack")
        sut.handle(.pressed)
        #expect(watcher.stopCount == 2)
        sut.handle(.escape)
        await sut.waitUntilIdle()
    }

    @Test func copiedTextIsNotWatched() async {
        inserter.outcome = .copiedOnly(reason: "test")
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(watcher.watched.isEmpty)
    }

    @Test func copiedOnlyOutcomeIsExplained() async {
        inserter.outcome = .copiedOnly(reason: "パスワード入力中のため貼り付けできません")
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(state.phase == .error("パスワード入力中のため貼り付けできません。クリップボードにコピーしました"))
    }

    @Test func shortTapIsCancelled() async throws {
        let provider = MockTranscriptionProvider()
        let sut = makeController(provider: provider, minimumDuration: .seconds(10))
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        #expect(state.phase == .idle)
        let session = try #require(provider.sessions.first)
        await sut.waitUntilIdle()
        #expect(await session.didCancel)
        #expect(await !session.didFinish)
    }

    @Test func shortTapStaysLatchedWhenReleaseIsHandledLate() async {
        // The release event queues up while the audio engine starts; its own time is what counts.
        audio.startDelay = 0.3
        let sut = makeController(holdThreshold: .milliseconds(200))
        let pressedAt = ContinuousClock.now
        sut.handle(.pressed, at: pressedAt)
        sut.handle(.released, at: pressedAt + .milliseconds(50))
        #expect(state.phase == .recording)
        sut.handle(.escape)
        await sut.waitUntilIdle()
    }

    @Test func escapeCancelsRecording() async throws {
        let provider = MockTranscriptionProvider()
        let sut = makeController(provider: provider)
        sut.handle(.pressed)
        sut.handle(.escape)
        #expect(state.phase == .idle)
        sut.handle(.released)  // Late release must be a no-op.
        #expect(state.phase == .idle)
    }

    @Test func shortTapKeepsRecordingUntilNextPress() async throws {
        let provider = MockTranscriptionProvider()
        let sut = makeController(provider: provider, holdThreshold: .seconds(10))
        sut.handle(.pressed)
        sut.handle(.released)
        #expect(state.phase == .recording)
        audio.speak()
        sut.handle(.pressed)
        #expect(state.phase == .processing)
        sut.handle(.released)  // The release after the stopping press is a no-op.
        await sut.waitUntilIdle()
        let session = try #require(provider.sessions.first)
        #expect(await session.didFinish)
        #expect(audio.startCount == 1)
        #expect(inserter.inserted.count == 1)
    }

    @Test func longHoldStopsOnRelease() async {
        let sut = makeController(holdThreshold: .milliseconds(20))
        sut.handle(.pressed)
        audio.speak()
        try? await Task.sleep(for: .milliseconds(40))
        sut.handle(.released)
        #expect(state.phase == .processing)
        await sut.waitUntilIdle()
        #expect(inserter.inserted.count == 1)
    }

    @Test func interruptedHoldIsCancelled() {
        let sut = makeController(holdThreshold: .seconds(10))
        sut.handle(.pressed)
        sut.handle(.interrupted)
        #expect(state.phase == .idle)
    }

    @Test func pressWhileProcessingIsIgnored() async {
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        sut.handle(.pressed)
        #expect(audio.startCount == 1)
        await sut.waitUntilIdle()
    }

    @Test func consecutiveDictationsUseSeparateSessions() async {
        let provider = MockTranscriptionProvider()
        let sut = makeController(provider: provider)
        for _ in 0..<3 {
            sut.handle(.pressed)
            audio.speak()
            sut.handle(.released)
            await sut.waitUntilIdle()
        }
        #expect(provider.sessions.count == 3)
        #expect(state.phase == .idle)
    }

    @Test func silenceSkipsTranscription() async throws {
        let provider = MockTranscriptionProvider()
        let sut = makeController(provider: provider)
        sut.handle(.pressed)
        audio.speak(level: 0.0001)
        sut.handle(.released)
        await sut.waitUntilIdle()
        let session = try #require(provider.sessions.first)
        #expect(await !session.didFinish)
        #expect(state.phase == .idle)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func missingAPIKeyShowsErrorWithoutRecording() {
        let sut = makeController(secrets: MockSecrets(values: [:]))
        sut.handle(.pressed)
        #expect(audio.startCount == 0)
        #expect(state.phase == .error("Mock の API Key が未設定です"))
    }

    @Test func microphoneFailureShowsError() {
        audio.failStart = true
        let sut = makeController()
        sut.handle(.pressed)
        #expect(state.phase == .error("マイクを使用できません"))
    }

    @Test(arguments: [
        (TranscriptionError.network("offline"), "ネットワークに接続できません"),
        (.timedOut, "文字起こしがタイムアウトしました"),
        (.unauthorized, "Mock の API Key が正しくありません"),
        (.server("500"), "文字起こしに失敗しました"),
    ])
    func transcriptionErrorsAreReadable(error: TranscriptionError, message: String) async {
        let sut = makeController(provider: MockTranscriptionProvider(result: .failure(error)))
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(state.phase == .error(message))
    }

    @Test func emptyTranscriptShowsNothingRecognized() async {
        let sut = makeController(provider: MockTranscriptionProvider(result: .success("")))
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(state.phase == .error("音声を認識できませんでした"))
    }

    @Test func cleanupFailureStillPastesRawTranscript() async {
        settings.cleanupEnabled = true  // No cleanup API key in MockSecrets → falls back.
        let sut = makeController()
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(inserter.inserted.map(\.text) == ["今日の15時からAWSのAppSyncについて打ち合わせをします"])
        #expect(state.phase == .error("整形できなかったため、文字起こしをそのまま入力しました"))
    }
}
