import Foundation
import Testing

@testable import HibiVoKit

@Suite struct CorrectionExtractorTests {
    private func extract(_ original: String, _ edited: String) -> [VocabularyCorrection] {
        CorrectionExtractor.corrections(from: original, to: edited)
    }

    private func pair(_ original: String, _ corrected: String) -> VocabularyCorrection {
        VocabularyCorrection(original: original, corrected: corrected)
    }

    @Test func replacedWordIsFound() {
        #expect(extract("アップシンクの設定を確認します", "AppSyncの設定を確認します") == [pair("アップシンク", "AppSync")])
    }

    @Test func partialFixGrowsToTheWholeWord() {
        #expect(extract("クバネテスを使う", "クバネティスを使う") == [pair("クバネテス", "クバネティス")])
        #expect(extract("App sinkで同期", "AppSyncで同期") == [pair("App sink", "AppSync")])
        #expect(extract("会義に出ます", "会議に出ます") == [pair("会義", "会議")])
    }

    @Test func hiraganaAroundTheWordIsNotPulledIn() {
        #expect(extract("明日ひびぼを使います", "明日HibiVoを使います") == [pair("ひびぼ", "HibiVo")])
    }

    @Test func surroundingPunctuationIsTrimmed() {
        #expect(extract("それはラムダ。", "それはLambda!") == [pair("ラムダ", "Lambda")])
    }

    @Test func severalFixesInOneText() {
        let result = extract(
            "ギットハブとスラックの連携について、来週の定例で詳しく話します",
            "GitHubとSlackの連携について、来週の定例で詳しく話します")
        #expect(result == [pair("ギットハブ", "GitHub"), pair("スラック", "Slack")])
    }

    @Test func acronymsNeedNotSoundAlike() {
        #expect(extract("エーダブリューエスで動かす", "AWSで動かす") == [pair("エーダブリューエス", "AWS")])
    }

    @Test func contentEditsAreIgnored() {
        // Different words, not a misrecognition.
        #expect(extract("明日の会議に出ます", "今日の会議に出ます").isEmpty)
        // Numbers, okurigana, particles, punctuation.
        #expect(extract("3時に集合", "15時に集合").isEmpty)
        #expect(extract("打ち合わせをします", "打合せをします").isEmpty)
        #expect(extract("私は行きます", "私が行きます").isEmpty)
        #expect(extract("了解です。", "了解です!").isEmpty)
        // Pure additions and deletions.
        #expect(extract("資料を送ります", "資料を明日送ります").isEmpty)
        #expect(extract("資料を明日送ります", "資料を送ります").isEmpty)
    }

    @Test func onlyNounsAreLearned() {
        // Verb and adjective stems: the kanji alone isn't a dictionary word.
        #expect(extract("資料を早く送ります", "資料を速く送ります").isEmpty)
        #expect(extract("会場を移した", "会場を写した").isEmpty)
        #expect(extract("温かい料理", "暖かい料理").isEmpty)
        // Nouns, including one used with する.
        #expect(extract("文章を構成して送ります", "文章を校正して送ります") == [pair("構成", "校正")])
        #expect(extract("早朝に感数を直す", "早朝に関数を直す") == [pair("感数", "関数")])
    }

    @Test func scriptOnlyChangesAreIgnored() {
        #expect(extract("すごいですね", "スゴイですね").isEmpty)
    }

    @Test func shortKanaIsIgnored() {
        #expect(extract("あいの時代", "AIの時代").isEmpty)
    }

    @Test func rewritesAreIgnored() {
        #expect(extract("明日は休みます", "来週の打ち合わせは延期でお願いします").isEmpty)
        #expect(extract("アプリ、テスト、ビルド、リリース", "App、Test、Build、Release").isEmpty)
    }

    @Test func wholeUtteranceCanBeOneWord() {
        #expect(extract("アップシンク", "AppSync") == [pair("アップシンク", "AppSync")])
    }

    @Test func textTypedAfterTheFixIsLeftOut() {
        #expect(extract("アップシンク", "AppSyncを使う") == [pair("アップシンク", "AppSync")])
        #expect(extract("設定はアップシンク", "設定はAppSync、以上") == [pair("アップシンク", "AppSync")])
        #expect(extract("この構成", "この校正をお願い") == [pair("構成", "校正")])
    }

    @Test func unchangedTextHasNoCorrections() {
        #expect(extract("そのまま", "そのまま").isEmpty)
    }

    @Test func skeletonFoldsRomajiAndEnglishSpelling() {
        #expect(CorrectionExtractor.skeleton("アップシンク") == CorrectionExtractor.skeleton("AppSync"))
        #expect(CorrectionExtractor.similarity("ラムダ", "Lambda") >= CorrectionExtractor.minimumSimilarity)
        #expect(CorrectionExtractor.similarity("明日", "今日") < CorrectionExtractor.minimumSimilarity)
    }
}

@MainActor
@Suite struct VocabularyLearningTests {
    let store = VocabularyStore(
        file: JSONFileStore(url: FileManager.default.temporaryDirectory.appending(path: "hibivo-\(UUID()).json")))

    @Test func newWordBecomesAnEntry() throws {
        let learning = try #require(store.learn(VocabularyCorrection(original: "アップシンク", corrected: "AppSync")))
        #expect(store.entries.map(\.preferred) == ["AppSync"])
        #expect(store.entries.first?.spoken == "アップシンク")
        #expect(store.entries.first?.origin == .learned)
        store.undo(learning)
        #expect(store.entries.isEmpty)
    }

    @Test func knownSpellingGainsAnAlias() throws {
        store.add(VocabularyEntry(preferred: "AppSync", spoken: "アップシンク"))
        let learning = try #require(store.learn(VocabularyCorrection(original: "アプシンク", corrected: "AppSync")))
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.aliases == ["アプシンク"])
        #expect(store.entries.first?.origin == .manual)
        store.undo(learning)
        #expect(store.entries.first?.aliases == [])
    }

    @Test func kanjiMisrecognitionBecomesAnAliasNotAReading() throws {
        try #require(store.learn(VocabularyCorrection(original: "構成", corrected: "校正")))
        #expect(store.entries.first?.spoken == "")
        #expect(store.entries.first?.aliases == ["構成"])

        store.add(VocabularyEntry(preferred: "関数"))
        try #require(store.learn(VocabularyCorrection(original: "感数", corrected: "関数")))
        #expect(store.entries.last?.spoken == "")
        #expect(store.entries.last?.aliases == ["感数"])
    }

    @Test func coveredFormsAreNotLearnedAgain() {
        store.add(VocabularyEntry(preferred: "AppSync", spoken: "あっぷしんく"))
        #expect(store.learn(VocabularyCorrection(original: "アップシンク", corrected: "AppSync")) == nil)
        // Another entry already owns the spoken form.
        #expect(store.learn(VocabularyCorrection(original: "アップシンク", corrected: "Appsync")) == nil)
        // The original is itself a registered spelling.
        #expect(store.learn(VocabularyCorrection(original: "AppSync", corrected: "AppSync2")) == nil)
        #expect(store.entries.count == 1)
    }
}

@Suite struct InsertedTextTrackerTests {
    @Test func findsTheInsertionAfterEdits() throws {
        // "資料を" typed earlier, "アップシンク" pasted, caret after it, "。" already there.
        let tracker = try #require(InsertedTextTracker(value: "資料をアップシンク。", caret: 9, inserted: "アップシンク"))
        #expect(tracker.region(in: "資料をAppSync。") == "AppSync")
        #expect(tracker.region(in: "資料を。") == "")
        #expect(tracker.region(in: "別の文章") == nil)
    }

    @Test func textTypedAfterTheInsertionIsIncluded() throws {
        let tracker = try #require(InsertedTextTracker(value: "アップシンク", caret: 6, inserted: "アップシンク"))
        #expect(tracker.region(in: "AppSync を使う") == "AppSync を使う")
        #expect(
            extractFromTracker("アップシンク", "AppSync を使う") == [
                VocabularyCorrection(original: "アップシンク", corrected: "AppSync")
            ])
    }

    @Test func caretMustFollowTheInsertedText() {
        #expect(InsertedTextTracker(value: "アップシンク", caret: 3, inserted: "アップシンク") == nil)
        #expect(InsertedTextTracker(value: "別の文章", caret: 4, inserted: "アップシンク") == nil)
    }

    @Test func caretCountsUTF16() throws {
        let tracker = try #require(InsertedTextTracker(value: "😀アップシンク", caret: 8, inserted: "アップシンク"))
        #expect(tracker.region(in: "😀AppSync") == "AppSync")
    }

    private func extractFromTracker(_ inserted: String, _ region: String) -> [VocabularyCorrection] {
        CorrectionExtractor.corrections(from: inserted, to: region)
    }
}

@MainActor
@Suite struct CorrectionLearnerTests {
    let state = AppState()
    let store = VocabularyStore(
        file: JSONFileStore(url: FileManager.default.temporaryDirectory.appending(path: "hibivo-\(UUID()).json")))

    @Test func learnedWordsAreShownAndCanBeUndone() {
        let learner = CorrectionLearner(vocabulary: store, state: state)
        learner.learn(inserted: "アップシンクの設定", edited: "AppSyncの設定")
        #expect(store.entries.map(\.preferred) == ["AppSync"])
        #expect(state.learnedVocabulary.map(\.correction.corrected) == ["AppSync"])
        learner.undoShown()
        #expect(store.entries.isEmpty)
        #expect(state.learnedVocabulary.isEmpty)
    }

    @Test func nothingIsShownWhenNothingIsLearned() {
        let learner = CorrectionLearner(vocabulary: store, state: state)
        learner.learn(inserted: "明日の会議", edited: "今日の会議")
        #expect(store.entries.isEmpty)
        #expect(state.learnedVocabulary.isEmpty)
    }
}
