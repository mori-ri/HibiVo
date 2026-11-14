package io.github.moriri.hibivo.core

import java.text.Normalizer

/** A user dictionary entry, e.g. preferred "AppSync", spoken forms ["アップシンク", "アップ シンク"]. */
data class VocabularyEntry(
    val preferred: String,
    /** How the term tends to come out of STT when misrecognised. */
    val spoken: List<String> = emptyList(),
    /** Disabled entries stay in the list but are not used for hints, replacement or cleanup. */
    val isEnabled: Boolean = true,
) {
    /** Non-empty spoken forms, i.e. everything that should become [preferred]. */
    val spokenForms: List<String>
        get() = spoken.map { it.trim { c -> c == ' ' || c == '\t' || c == '　' } }
            .filter { it.isNotEmpty() && it != preferred }

    /** Spoken forms safe to replace without context. */
    val replaceableForms: List<String> get() = spokenForms.filterNot(::needsContext)

    /**
     * Short kana forms such as "あい" for "AI": they are also everyday words and appear inside other words
     * ("あいさつ"), so only cleanup, which sees the context, may turn them into [preferred].
     */
    val contextualForms: List<String> get() = spokenForms.filter(::needsContext)

    /** Replaceable forms as STT hints. Katakana, because that is how STT writes a name it doesn't know. */
    val readings: List<String> get() = replaceableForms.map(KanaFolding::katakana)

    val promptTerm: CleanupPromptBuilder.Term
        get() = CleanupPromptBuilder.Term(preferred, replaceableForms, contextualForms)

    companion object {
        private const val CONTEXTUAL_LENGTH_LIMIT = 2

        /** Kana-only forms of at most two characters. Kanji and Latin forms that short are specific enough. */
        fun needsContext(form: String): Boolean {
            val keys = KanaFolding.keys(form)
            return keys.size <= CONTEXTUAL_LENGTH_LIMIT && keys.all(KanaFolding::isKatakana)
        }
    }
}

/**
 * Deterministic dictionary pass: replaces registered spoken forms with the preferred spelling.
 *
 * Runs before LLM cleanup so the Raw mode benefits too. Longer forms are replaced first so overlaps resolve to
 * the most specific entry. Matching ignores the difference between hiragana and katakana and between full- and
 * half-width forms, treats "ヂ"/"ジ" and "ヅ"/"ズ" as the same, and makes a space where Latin letters meet kana
 * optional (Soniox spaces out Latin words). "ー" and "・" are not ignored: they tell words apart. Text that isn't
 * replaced is left exactly as it was. Same rules as the macOS app's `VocabularyReplacer`.
 */
object VocabularyReplacer {
    fun apply(entries: List<VocabularyEntry>, text: String): String {
        val rules = entries.filter { it.isEnabled }
            .flatMap { entry -> entry.replaceableForms.map { KanaFolding.matchKeys(it) to entry.preferred } }
            .filter { it.first.isNotEmpty() }
            .sortedByDescending { it.first.size }
        if (rules.isEmpty()) return text

        val characters = Graphemes.split(text)
        val keys = characters.map(KanaFolding::key)
        // Single left-to-right scan so a replacement is never re-matched by a shorter rule.
        val result = StringBuilder()
        var index = 0
        scan@ while (index < characters.size) {
            for ((from, to) in rules) {
                val end = match(from, keys, index) ?: continue
                result.append(to)
                index = end
                continue@scan
            }
            result.append(characters[index])
            index += 1
        }
        return result.toString()
    }

    /** The index just past `rule` matched at `start`, skipping spaces where Latin letters meet kana. */
    private fun match(rule: List<String>, keys: List<String>, start: Int): Int? {
        var index = start
        var previous: String? = null
        for (key in rule) {
            if (previous != null && KanaFolding.isScriptBoundary(previous, key)) {
                while (index < keys.size && KanaFolding.isSpace(keys[index])) index += 1
            }
            if (index >= keys.size || keys[index] != key) return null
            index += 1
            previous = key
        }
        return index
    }
}

/** Folds Japanese script variants to one form for comparison. Pure so it can be unit tested. */
internal object KanaFolding {
    /**
     * Compatibility forms folded (full-width "Ａ" → "A", half-width "ｱ" → "ア"), then hiragana → katakana,
     * then "ヂ" → "ジ" and "ヅ" → "ズ", which sound the same and which STT rarely writes.
     */
    fun key(character: String): String = when (val key = katakana(Normalizer.normalize(character, Normalizer.Form.NFKC))) {
        "ヂ" -> "ジ"
        "ヅ" -> "ズ"
        else -> key
    }

    fun keys(string: String): List<String> = Graphemes.split(string).map(::key)

    /**
     * Keys a registered form is matched by: [keys] without the optional spaces where Latin letters meet kana,
     * so "AWS ラムダ" and "AWSラムダ" match the same text. Other spaces are kept.
     */
    fun matchKeys(string: String): List<String> {
        val keys = keys(string)
        return keys.indices.mapNotNull { index ->
            if (!isSpace(keys[index])) return@mapNotNull keys[index]
            val before = keys.subList(0, index).lastOrNull { !isSpace(it) }
            val after = keys.subList(index + 1, keys.size).firstOrNull { !isSpace(it) }
            if (before != null && after != null && isScriptBoundary(before, after)) null else keys[index]
        }
    }

    /** Spaces only; a line break is never skipped, so a match never joins two lines. */
    fun isSpace(key: String): Boolean = key == " " || key == "\t"

    /** Whether one side is a Latin letter or digit and the other isn't (and neither is a space). */
    fun isScriptBoundary(lhs: String, rhs: String): Boolean =
        !isSpace(lhs) && !isSpace(rhs) && isLatin(lhs) != isLatin(rhs)

    fun isLatin(key: String): Boolean = key.all { it in '0'..'9' || it in 'A'..'Z' || it in 'a'..'z' }

    /** Whether a folded key is katakana, including the prolonged sound mark and iteration marks. */
    fun isKatakana(key: String): Boolean =
        key.isNotEmpty() && key.all { it.code in 0x30A1..0x30FE && it.code != 0x30FB }

    /** Hiragana (ぁ–ゖ, ゝゞ) to katakana; everything else unchanged. */
    fun katakana(string: String): String = buildString(string.length) {
        for (c in string) append(if (c.code in 0x3041..0x3096 || c.code in 0x309D..0x309E) c + 0x60 else c)
    }
}
