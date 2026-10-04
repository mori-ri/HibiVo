import Foundation
import Testing

@testable import HibiVoKit

@Suite struct AppModeRulesTests {
    @Test func appsWithoutUserSettingUseDefault() {
        #expect(AppModeRules.mode(for: "com.tinyspeck.slackmacgap", overrides: [], default: .business) == .business)
        #expect(AppModeRules.mode(for: "com.apple.Terminal", overrides: [], default: .natural) == .natural)
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

    @MainActor @Test func initialModesAreSeededOnceAndCanBeRemoved() {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.appModeOverrides == AppModeRules.initialOverrides)
        #expect(settings.cleanupMode(for: "com.apple.Terminal") == .prompt)
        #expect(settings.cleanupMode(for: "com.apple.mail") == .business)

        settings.setMode(nil, bundleID: "com.apple.Terminal", name: "Terminal")
        #expect(settings.cleanupMode(for: "com.apple.Terminal") == .natural)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.appModeOverrides.map(\.bundleID) == ["com.apple.mail"])
    }

    @MainActor @Test func seedingKeepsExistingUserSettings() throws {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let saved = [AppModeOverride(bundleID: "com.apple.mail", name: "Mail", mode: .raw)]
        defaults.set(try JSONEncoder().encode(saved), forKey: "appModeOverrides")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.cleanupMode(for: "com.apple.mail") == .raw)
        #expect(settings.cleanupMode(for: "com.apple.Terminal") == .prompt)
        #expect(settings.appModeOverrides.count == 2)
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

    @MainActor @Test func retargetPicksTheModeFromTheTableFrozenAtKeyDown() throws {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        let builder = DictationContextBuilder(
            settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()])
        let terminal = TargetApplication(processID: 1, bundleID: "com.apple.Terminal", name: "Terminal")
        let mail = TargetApplication(processID: 2, bundleID: "com.apple.mail", name: "Mail")

        var context = try builder.make(target: terminal)
        settings.appModeOverrides = []  // Edited mid-utterance; not applied to this one.
        context.retarget(to: mail)
        #expect(context.target == mail)
        #expect(context.cleanup.mode == .business)

        settings.cleanupEnabled = false
        var raw = try builder.make(target: mail)
        raw.retarget(to: terminal)
        #expect(raw.cleanup.mode == .raw)
    }

    @MainActor @Test func customInstructionsAreCappedPersistedAndFrozenInTheContext() throws {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        settings.setCustomCleanupInstructions(String(repeating: "あ", count: CleanupMode.customInstructionsLimit + 10))
        #expect(settings.customCleanupInstructions.count == CleanupMode.customInstructionsLimit)
        settings.setCustomCleanupInstructions("箇条書きにする")
        #expect(SettingsStore(defaults: defaults).customCleanupInstructions == "箇条書きにする")

        let builder = DictationContextBuilder(
            settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()])
        let context = try builder.make(target: nil)
        settings.setCustomCleanupInstructions("変更後")
        #expect(context.cleanup.customInstructions == "箇条書きにする")
    }

    @MainActor @Test func minutesInstructionsFollowTheDefaultUntilEdited() {
        let defaults = UserDefaults(suiteName: "AppModeRulesTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.meetingMinutesInstructions == nil)
        settings.setMeetingMinutesInstructions("## 要点\n箇条書き。")
        #expect(SettingsStore(defaults: defaults).meetingMinutesInstructions == "## 要点\n箇条書き。")
        settings.setMeetingMinutesInstructions(
            String(repeating: "あ", count: MeetingMinutesPrompt.instructionsLimit + 1))
        #expect(settings.meetingMinutesInstructions?.count == MeetingMinutesPrompt.instructionsLimit)
        for reset in [nil, " \n", MeetingMinutesPrompt.defaultInstructions] {
            settings.setMeetingMinutesInstructions("## 要点")
            settings.setMeetingMinutesInstructions(reset)
            #expect(settings.meetingMinutesInstructions == nil)
        }
        #expect(SettingsStore(defaults: defaults).meetingMinutesInstructions == nil)
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

    @Test func disabledEntriesAreKeptButNotUsed() async throws {
        let file = tempFile([VocabularyEntry].self)
        let store = VocabularyStore(file: file)
        var entry = VocabularyEntry(preferred: "AppSync", spoken: "アップシンク")
        store.add(entry)
        entry.isEnabled = false
        store.update(entry)
        #expect(store.activeEntries.isEmpty)
        // Still owns its spoken form, so learning doesn't bring the word back.
        #expect(!store.canLearn(VocabularyCorrection(original: "アップシンク", corrected: "AppSync2")))
        // Nor does a new misrecognition of the disabled spelling extend it.
        #expect(store.learn(VocabularyCorrection(original: "アプシンク", corrected: "AppSync")) == nil)
        #expect(store.entries.first?.aliases == [])
        try await Task.sleep(for: .milliseconds(200))
        #expect(VocabularyStore(file: file).entries.first?.isEnabled == false)
    }

    @Test func entriesSavedBeforeOriginAndEnabledDecodeAsManualAndEnabled() throws {
        let json = #"[{"id":"7E1B5C2A-0000-4000-8000-000000000001","preferred":"AppSync","spoken":"","aliases":[]}]"#
        let entries = try JSONDecoder().decode([VocabularyEntry].self, from: Data(json.utf8))
        #expect(entries.first?.isEnabled == true)
        #expect(entries.first?.origin == .manual)
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
            activeApp: MockActiveApp(), inserter: MockInserter(), history: history, minimumDuration: .zero,
            holdThreshold: .zero)
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(history.records.first?.status == .failed)
        #expect(history.records.first?.errorMessage == "ネットワークに接続できません")
        #expect(history.records.first?.appName == "Slack")
    }

    @Test func togglingCleanupWhileRecordingAppliesToThatUtterance() async {
        let defaults = UserDefaults(suiteName: "StoreTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProviderID = "mock"
        settings.cleanupEnabled = false
        let history = HistoryStore(file: tempFile([HistoryRecord].self))
        let audio = MockAudio()
        let sut = DictationController(
            state: AppState(), audio: audio,
            contextBuilder: DictationContextBuilder(
                settings: settings, secrets: MockSecrets(), transcriptionProviders: [MockTranscriptionProvider()]),
            activeApp: MockActiveApp(), inserter: MockInserter(), history: history, minimumDuration: .zero,
            holdThreshold: .zero)
        sut.toggleCleanup()  // Ignored while idle.
        #expect(settings.cleanupEnabled == false)

        sut.handle(.pressed)
        sut.toggleCleanup()
        audio.speak()
        sut.handle(.released)
        sut.toggleCleanup()  // Ignored once processing.
        await sut.waitUntilIdle()
        #expect(settings.cleanupEnabled == true)
        #expect(history.records.first?.cleanupMode == .natural)
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
            historyEnabled: { settings.historyEnabled }, minimumDuration: .zero, holdThreshold: .zero)
        sut.handle(.pressed)
        audio.speak()
        sut.handle(.released)
        await sut.waitUntilIdle()
        #expect(history.records.isEmpty)
    }
}
