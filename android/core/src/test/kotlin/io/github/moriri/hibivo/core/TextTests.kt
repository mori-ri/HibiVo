package io.github.moriri.hibivo.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Cases are the macOS app's (Tests/HibiVoKitTests/CleanupTests.swift), so both apps behave the same.

class CleanupOutputGuardTests {
    private val raw = "えーっと、明日の、いや明後日の会議なんだけど、田中さんに3時からで大丈夫ですかって送って"

    @Test fun acceptsNormalCleanup() {
        val out = "田中さん、明後日の15時からの会議で問題ないでしょうか？"
        assertEquals(out, CleanupOutputGuard.validate(out, raw, CleanupMode.BUSINESS))
    }

    @Test fun stripsThinkingTagsAndPreamble() {
        val out = "<think>考え中</think>以下が整形後の文章です：\n明後日の会議の件です。"
        assertEquals("明後日の会議の件です。", CleanupOutputGuard.validate(out, raw, CleanupMode.NATURAL))
    }

    @Test fun stripsTranscriptTagsAndCodeFence() {
        assertEquals("こんにちは", CleanupOutputGuard.validate("<transcript>\nこんにちは\n</transcript>", "こんにちは", CleanupMode.NATURAL))
        assertEquals("こんにちは", CleanupOutputGuard.validate("```\nこんにちは\n```", "こんにちは", CleanupMode.NATURAL))
    }

    @Test fun rejectsEmptyOutput() = assertNull(CleanupOutputGuard.validate("  \n", raw, CleanupMode.NATURAL))

    @Test fun rejectsAnswerThatIsFarLongerThanInput() {
        val answer = "AppSync は AWS のマネージド GraphQL サービスで、".repeat(10)
        assertNull(CleanupOutputGuard.validate(answer, "AppSyncって何？", CleanupMode.NATURAL))
    }

    @Test fun rejectsOutputThatDropsMostOfALongInput() =
        assertNull(CleanupOutputGuard.validate("了解。", raw, CleanupMode.NATURAL))

    @Test fun customModeMayShortenALot() {
        val long = "明日の会議では予算とスケジュールについて話します。".repeat(4)
        assertNull(CleanupOutputGuard.validate("- 予算", long, CleanupMode.NATURAL))
        assertEquals("- 予算", CleanupOutputGuard.validate("- 予算", long, CleanupMode.CUSTOM))
    }

    @Test fun allowsShortInputToShrink() =
        assertEquals("はい。", CleanupOutputGuard.validate("はい。", "えーと、はい", CleanupMode.NATURAL))
}

class VocabularyReplacerTests {
    private val entries = listOf(
        VocabularyEntry("AppSync", listOf("アップシンク", "アップ シンク")),
        VocabularyEntry("AWS Lambda", listOf("AWSラムダ")),
        VocabularyEntry("Claude Code", listOf("クロードコード")),
        VocabularyEntry("Bedrock"),
    )

    private fun replace(text: String, with: List<VocabularyEntry> = entries) = VocabularyReplacer.apply(with, text)

    @Test fun replacesSpokenFormsAndAliases() {
        assertEquals("今日の15時からAWSのAppSyncについて打ち合わせ", replace("今日の15時からAWSのアップシンクについて打ち合わせ"))
        assertEquals("AppSyncとClaude Code", replace("アップ シンクとクロードコード"))
    }

    @Test fun longerFormWins() = assertEquals("AWS Lambdaを使う", replace("AWSラムダを使う"))

    @Test fun textWithoutMatchesIsUnchanged() {
        assertEquals("特に何もなし😀", replace("特に何もなし😀"))
        assertEquals("abc", replace("abc", emptyList()))
    }

    @Test fun kanaScriptsMatchEachOther() {
        val hibivo = listOf(VocabularyEntry("HibiVo", listOf("ひびぼ")))
        assertEquals("HibiVoの進捗です", replace("ヒビボの進捗です", hibivo))
        assertEquals("HibiVoの進捗です", replace("ひびぼの進捗です", hibivo))
        assertEquals("HibiVo", replace("ヒビぼ", hibivo))
        assertEquals("Claude Codeで書く", replace("くろーどこーどで書く"))
    }

    @Test fun fullAndHalfWidthFormsMatch() {
        assertEquals("AWS Lambda", replace("ＡＷＳラムダ"))
        assertEquals("AppSyncに聞く", replace("ｱｯﾌﾟｼﾝｸに聞く"))
        // A half-width voiced mark joins the kana before it into one character, so "ﾄﾞ" folds to "ド".
        assertEquals("Claude Code", replace("ｸﾛｰﾄﾞｺｰﾄﾞ"))
    }

    @Test fun unreplacedTextKeepsItsScript() =
        assertEquals("ひらがなとＡＢＣはそのまま、AppSync", replace("ひらがなとＡＢＣはそのまま、アップシンク"))

    @Test fun sameSoundingKanaMatch() {
        val kanazuchi = listOf(VocabularyEntry("Kanazuchi", listOf("カナヅチ")))
        assertEquals("Kanazuchiを使う", replace("カナズチを使う", kanazuchi))
        assertEquals("Kanazuchi", replace("かなづち", kanazuchi))
    }

    @Test fun spaceBetweenLatinAndKanaIsOptional() {
        assertEquals("AWS Lambdaも使う", replace("AWS ラムダも使う"))
        assertEquals("AWS Lambda", replace("ＡＷＳ　ラムダ"))
        val spaced = listOf(VocabularyEntry("Zip AI", listOf("ジップ AI")))
        assertEquals("Zip AIとZip AI", replace("ジップAIとジップ AI", spaced))
    }

    @Test fun otherSpacesAndLineBreaksAreNotSkipped() {
        for (text in listOf("A WSラムダ", "AWS\nラムダ", "クロード コード")) assertEquals(text, replace(text))
    }

    @Test fun longVowelsMarksAndVoicingStillTellWordsApart() {
        val cases = listOf(
            "バッター" to "バッタが跳ぶ", "ヒビボー" to "ヒビボ", "ハートマーク" to "ハトマーク", "サーバー" to "サバ",
            "ソニックス" to "ゾニックス", "アマゾン" to "アマ・ゾン",
        )
        for ((spoken, text) in cases) assertEquals(text, replace(text, listOf(VocabularyEntry("X", listOf(spoken)))))
    }

    @Test fun readingsAreKatakanaSpokenForms() {
        assertEquals(listOf("ヒビボ", "日比保"), VocabularyEntry("HibiVo", listOf("ひびぼ", "日比保")).readings)
    }

    @Test fun shortKanaFormsAreLeftToCleanup() {
        val ai = VocabularyEntry("AI", listOf("エーアイ", "あい"))
        assertEquals("AIとあい", replace("エーアイとあい", listOf(ai)))
        assertEquals(listOf("エーアイ"), ai.replaceableForms)
        assertEquals(listOf("あい"), ai.contextualForms)
        assertEquals(CleanupPromptBuilder.Term("AI", listOf("エーアイ"), listOf("あい")), ai.promptTerm)
        for (form in listOf("あい", "シリ", "ｼﾘ", "ジー", "ア")) assertTrue(VocabularyEntry.needsContext(form), form)
        for (form in listOf("ひびぼ", "ジェイ", "会期", "ai", "AI", "Aい")) assertFalse(VocabularyEntry.needsContext(form), form)
    }

    @Test fun disabledEntriesAreIgnored() {
        val disabled = listOf(VocabularyEntry("AppSync", listOf("アップシンク"), isEnabled = false))
        assertEquals("アップシンク", replace("アップシンク", disabled))
    }
}

class TrailingPeriodTests {
    @Test fun dropsPeriodAfterLoneWord() {
        val cases = listOf(
            "AppSync。" to "AppSync", "会議資料。" to "会議資料", "AWS Lambda。" to "AWS Lambda", "Lambda." to "Lambda",
            "テスト。\n" to "テスト", "会議の資料。" to "会議の資料", "お客様。" to "お客様",
        )
        for ((input, expected) in cases) assertEquals(expected, TrailingPeriod.trimmed(input))
    }

    @Test fun keepsSentences() {
        val cases = listOf(
            "了解しました。", "ありがとう。", "明日、会議資料。", "資料を確認。次は会議。", "This is Lambda.", "3.14.",
            "本日の議題は来期の予算計画と人員配置の見直しについて。", "改行\nあり。", "AppSync", "次回は来週。", "今日は雨。",
            "東京で開催。",
        )
        for (input in cases) assertEquals(input, TrailingPeriod.trimmed(input))
    }
}

class CleanupPromptBuilderTests {
    @Test fun japanesePromptHasModeDictionaryAndDestination() {
        val prompt = CleanupPromptBuilder.systemPrompt(
            CleanupMode.BUSINESS, vocabulary = listOf(CleanupPromptBuilder.Term("AppSync", listOf("アップシンク"))),
            appName = "Gmail",
        )
        assertTrue(prompt.startsWith("あなたは日本語の音声入力の整形担当です。"))
        assertTrue("# モード: Business\n- 「えー」" in prompt)
        assertTrue("# ユーザー辞書（この表記を優先する）\n- AppSync（聞き取り例: アップシンク）" in prompt)
        assertTrue("# 入力先\nGmail に入力されます。" in prompt)
        assertTrue(prompt.endsWith("整形後の文章だけを出力する。前置き・説明・引用符・タグは付けない。"))
        // Multi-line literals must not keep source indentation.
        assertFalse(prompt.lines().any { it.startsWith(" ") })
    }

    @Test fun customInstructionsOnlyInCustomMode() {
        val custom = CleanupPromptBuilder.systemPrompt(CleanupMode.CUSTOM, " 英語にする ", emptyList(), null)
        assertTrue("# ユーザーの指示\n<instructions>\n英語にする\n</instructions>" in custom)
        val natural = CleanupPromptBuilder.systemPrompt(CleanupMode.NATURAL, "英語にする", emptyList(), null)
        assertFalse("英語にする" in natural)
        assertEquals(500, CleanupPromptBuilder.normalizedCustomInstructions("あ".repeat(600))!!.length)
    }

    @Test fun englishPromptForEnglishTranscription() {
        val prompt = CleanupPromptBuilder.systemPrompt(
            CleanupMode.NATURAL, vocabulary = listOf(CleanupPromptBuilder.Term("AI", contextualForms = listOf("あい"))),
            appName = null, language = PromptLanguage.of("en"),
        )
        assertTrue(prompt.startsWith("You clean up voice dictation."))
        assertTrue("\"$200\"" in prompt)
        assertTrue("- AI (reading: あい. Everyday words" in prompt)
        assertFalse(prompt.lines().any { it.startsWith(" ") })
    }

    @Test fun transcriptIsWrapped() =
        assertEquals("<transcript>\nこんにちは\n</transcript>", CleanupPromptBuilder.userMessage("こんにちは"))
}
