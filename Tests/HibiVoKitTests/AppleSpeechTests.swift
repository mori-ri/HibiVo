import Foundation
import Testing

@testable import HibiVoKit

@Suite struct AppleSpeechTextTests {
    @Test func englishResultsAreSpacedAndJapaneseAreNot() {
        #expect(AppleSpeechText.join("Hello world.", "How are you") == "Hello world. How are you")
        #expect(AppleSpeechText.join("こんにちは。", "今日は") == "こんにちは。今日は")
        #expect(AppleSpeechText.join("AppSync", "の設定") == "AppSyncの設定")
        #expect(AppleSpeechText.join("確認します", "AWS") == "確認しますAWS")
        #expect(AppleSpeechText.join("", "Hello") == "Hello")
        #expect(AppleSpeechText.join("Hello ", "world") == "Hello world")
    }

    @Test func spaceBeforeFullWidthPunctuationIsDropped() {
        #expect(AppleSpeechText.normalized("いかがですか ？") == "いかがですか？")
        #expect(AppleSpeechText.normalized("はい 。そうです") == "はい。そうです")
        #expect(AppleSpeechText.normalized("Is it OK?") == "Is it OK?")
    }

    @Test func costsNothing() {
        let usage = TranscriptionUsage(provider: AppleSpeechProvider().id, model: "speech-transcriber", seconds: 3600)
        #expect(UsagePricing.transcriptionUSD(usage) == 0)
    }
}

@MainActor
@Suite struct TranscriptionDefaultsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TranscriptionDefaultsTests-\(UUID())")!
    }

    @Test func macOSRecognizerIsTheDefaultWhereAvailable() {
        let settings = SettingsStore(defaults: makeDefaults())
        let expected = AppleSpeechProvider.isSupported ? "apple" : "soniox"
        #expect(settings.transcriptionProviderID == expected)
        #expect(settings.meetingTranscriptionProviderID == expected)
    }

    @Test func existingSonioxUsersKeepSoniox() {
        let defaults = makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.keepSonioxForExistingUsers { true }
        #expect(settings.transcriptionProviderID == "soniox")
        #expect(settings.meetingTranscriptionProviderID == "soniox")
        #expect(SettingsStore(defaults: defaults).transcriptionProviderID == "soniox")
    }

    @Test func migrationRunsOnceAndLeavesChoicesAlone() {
        let defaults = makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "gemini"
        settings.keepSonioxForExistingUsers { true }
        #expect(settings.transcriptionProviderID == "gemini")
        #expect(settings.meetingTranscriptionProviderID == "soniox")

        // A key added after the first launch with this version doesn't switch anything.
        let fresh = SettingsStore(defaults: makeDefaults())
        fresh.keepSonioxForExistingUsers { false }
        fresh.keepSonioxForExistingUsers { true }
        #expect(fresh.transcriptionProviderID == SettingsStore.defaultTranscriptionProviderID)
    }

    @Test func keylessProviderNeedsNoAPIKey() throws {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.transcriptionProviderID = "mock"
        let provider = MockTranscriptionProvider()
        provider.requiresAPIKey = false
        let builder = DictationContextBuilder(
            settings: settings, secrets: MockSecrets(values: [:]), transcriptionProviders: [provider])
        let context = try builder.make(target: nil)
        #expect(context.transcriptionConfig.apiKey == "")

        provider.requiresAPIKey = true
        #expect(throws: UserFacingError.missingAPIKey(provider: "Mock")) { try builder.make(target: nil) }
    }
}

/// Runs macOS's recognizer on speech made with `say`. Opt-in, needs macOS 26 and may download the model:
///   HIBIVO_INTEGRATION=1 scripts/test.sh --filter AppleSpeechIntegration
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["HIBIVO_INTEGRATION"] == "1" && AppleSpeechProvider.isSupported))
struct AppleSpeechIntegrationTests {
    /// 16 kHz mono PCM16 of `text` read by the Japanese system voice.
    private func speech(_ text: String) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appending(path: "HibiVoAppleSpeech-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appending(path: "speech.aiff")
        let raw = directory.appending(path: "speech.wav")
        try run("/usr/bin/say", "-v", "Kyoko", "-o", aiff.path, text)
        try run("/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, raw.path)
        // Skip the 44-byte header of the canonical WAV afconvert writes.
        let wav = try Data(contentsOf: raw)
        guard let data = wav.range(of: Data("data".utf8)) else { return wav }
        return wav.subdata(in: (data.upperBound + 4)..<wav.count)
    }

    private func run(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func send(_ pcm: Data, to session: any TranscriptionSession) async {
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3_200, pcm.count)
            await session.send(pcm.subdata(in: offset..<end))
            offset = end
        }
    }

    @Test func dictationRoundTrip() async throws {
        #expect(await AppleSpeechProvider.prepareModel(language: "ja") == .ready)
        let pcm = try speech("今日は新しい機能のリリース日程について相談しましょう。")
        let provider = AppleSpeechProvider()
        let session = provider.makeSession(
            TranscriptionConfig(apiKey: "", model: provider.defaultModel, language: "ja"))
        // Audio sent before the analyzer is ready is buffered.
        Task { await session.start() }
        await send(pcm, to: session)
        let text = try await session.finish()
        #expect(text.contains("リリース"))
    }

    @Test func meetingSessionReportsTimedTokensWithoutSpeakers() async throws {
        let pcm = try speech("来週の水曜日はいかがですか。")
        let provider = AppleSpeechProvider()
        let session = provider.makeMeetingSession(
            TranscriptionConfig(apiKey: "", model: provider.defaultModel, language: "ja", speakerDiarization: true))
        let collected = Task {
            var tokens: [MeetingToken] = []
            for await event in session.events {
                if case .tokens(let batch) = event { tokens += batch.filter(\.isFinal) }
            }
            return tokens
        }
        await session.start()
        await send(pcm, to: session)
        _ = try await session.finish()
        let tokens = await collected.value
        #expect(tokens.map(\.text).joined().contains("水曜日"))
        #expect(tokens.allSatisfy { $0.speaker == nil && $0.startMs != nil })
    }
}
