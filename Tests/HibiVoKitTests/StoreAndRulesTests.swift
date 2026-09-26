import Foundation
import Testing

@testable import HibiVoKit

@Suite struct AppModeRulesTests {
    @Test(arguments: [
        ("com.apple.Terminal", CleanupMode.prompt),
        ("com.todesktop.230313mzl4w4u92", .prompt),
        ("com.microsoft.VSCode", .prompt),
        ("com.openai.chat", .prompt),
        ("com.tinyspeck.slackmacgap", .natural),
        ("com.microsoft.teams2", .natural),
        ("com.microsoft.Outlook", .business),
        ("com.apple.mail", .business),
        ("com.apple.Safari", .natural),
    ])
    func builtInDefaults(bundleID: String, expected: CleanupMode) {
        #expect(AppModeRules.mode(for: bundleID, overrides: [], default: .natural) == expected)
    }

    @Test func userOverrideWinsAndMatchingIsCaseInsensitive() {
        let overrides = [AppModeOverride(bundleID: "com.apple.terminal", name: "Terminal", mode: .raw)]
        #expect(AppModeRules.mode(for: "com.apple.Terminal", overrides: overrides, default: .natural) == .raw)
    }

    @Test func unknownOrMissingAppUsesDefault() {
        #expect(AppModeRules.mode(for: "com.example.unknown", overrides: [], default: .business) == .business)
        #expect(AppModeRules.mode(for: nil, overrides: [], default: .raw) == .raw)
    }

    @MainActor @Test func settingsResolveAndPersistOverrides() {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.setMode(.business, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        #expect(settings.cleanupMode(for: "com.tinyspeck.slackmacgap") == .business)
        #expect(SettingsStore(defaults: defaults).cleanupMode(for: "com.tinyspeck.slackmacgap") == .business)
        settings.setMode(nil, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        #expect(settings.cleanupMode(for: "com.tinyspeck.slackmacgap") == .natural)
    }

    @MainActor @Test func contextUsesModeOfTargetApp() throws {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        let builder = DictationContextBuilder(
            settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()],
            vocabulary: { [VocabularyEntry(preferred: "AppSync", spoken: "アップシンク")] })
        let terminal = TargetApplication(processID: 1, bundleID: "com.apple.Terminal", name: "Terminal")
        let context = try builder.make(target: terminal)
        #expect(context.cleanup.mode == .prompt)
        #expect(context.transcriptionConfig.vocabulary == ["AppSync"])
        settings.cleanupEnabled = false
        #expect(try builder.make(target: terminal).cleanup.mode == .raw)
    }
}

@MainActor
@Suite struct StoreTests {
    func tempFile<T: Codable & Sendable>(_: T.Type) -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appending(path: "hibivo-\(UUID()).json"))
    }

    func record(_ text: String) -> HistoryRecord {
        HistoryRecord(
            timestamp: Date(), rawTranscript: text, cleanedTranscript: nil, appName: "Slack", bundleID: nil,
            provider: "Soniox", cleanupMode: .natural, latencyMs: 420, status: .pasted)
    }

    @Test func historyIsNewestFirstAndCapped() {
        let store = HistoryStore(file: tempFile([HistoryRecord].self))
        for i in 0..<(HistoryStore.limit + 5) { store.append(record("#\(i)")) }
        #expect(store.records.count == HistoryStore.limit)
        #expect(store.records.first?.rawTranscript == "#\(HistoryStore.limit + 4)")
    }

    @Test func historyPersistsAcrossLaunches() async throws {
        let file = tempFile([HistoryRecord].self)
        let store = HistoryStore(file: file)
        store.append(record("今日の15時からAWSのAppSyncについて打ち合わせをします"))
        try await Task.sleep(for: .milliseconds(200))  // Saves happen off the main actor.
        let reloaded = HistoryStore(file: file)
        #expect(reloaded.records.first?.rawTranscript == "今日の15時からAWSのAppSyncについて打ち合わせをします")
        #expect(reloaded.records.first?.latencyMs == 420)
    }

    @Test func historyUpdateReplacesRecord() {
        let store = HistoryStore(file: tempFile([HistoryRecord].self))
        var r = record("raw")
        store.append(r)
        r.cleanedTranscript = "cleaned"
        store.update(r)
        #expect(store.records.first?.finalText == "cleaned")
    }

    @Test func vocabularyCrud() async throws {
        let file = tempFile([VocabularyEntry].self)
        let store = VocabularyStore(file: file)
        var entry = VocabularyEntry(preferred: "AppSync", spoken: "アップシンク")
        store.add(entry)
        store.add(VocabularyEntry(preferred: "  "))
        #expect(store.activeEntries.map(\.preferred) == ["AppSync"])
        entry.aliases = ["アップ シンク"]
        store.update(entry)
        try await Task.sleep(for: .milliseconds(200))
        #expect(VocabularyStore(file: file).entries.first?.aliases == ["アップ シンク"])
        store.remove(ids: [entry.id])
        #expect(store.entries.count == 1)
    }

    @Test func historyRecordsFailuresAndCleanup() async {
        let defaults = UserDefaults(suiteName: "StoreTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        settings.cleanupEnabled = false
        let history = HistoryStore(file: tempFile([HistoryRecord].self))
        let audio = MockAudio()
        let sut = DictationController(
            state: AppState(), audio: audio,
            contextBuilder: DictationContextBuilder(
                settings: settings, secrets: MockSecrets(),
                transcriptionProviders: [MockTranscriptionProvider(result: .failure(.network("x")))]),
            activeApp: MockActiveApp(), inserter: MockInserter(), history: history, minimumHold: .zero)
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(history.records.first?.status == .failed)
        #expect(history.records.first?.errorMessage == "ネットワークに接続できません")
        #expect(history.records.first?.appName == "Slack")
    }

    @Test func liveTranscriptIsHiddenByDefaultAndPersists() {
        let defaults = UserDefaults(suiteName: "StoreTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.showLiveTranscript == false)
        settings.showLiveTranscript = true
        #expect(SettingsStore(defaults: defaults).showLiveTranscript == true)
    }

    @Test func disabledHistoryRecordsNothing() async {
        let defaults = UserDefaults(suiteName: "StoreTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        settings.cleanupEnabled = false
        settings.historyEnabled = false
        let history = HistoryStore(file: tempFile([HistoryRecord].self))
        let audio = MockAudio()
        let sut = DictationController(
            state: AppState(), audio: audio,
            contextBuilder: DictationContextBuilder(
                settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()]),
            activeApp: MockActiveApp(), inserter: MockInserter(), history: history,
            historyEnabled: { settings.historyEnabled }, minimumHold: .zero)
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(history.records.isEmpty)
    }
}
