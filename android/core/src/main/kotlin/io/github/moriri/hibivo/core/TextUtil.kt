package io.github.moriri.hibivo.core

import java.text.Normalizer

/**
 * Splits text into user-perceived characters, so counting and matching agree with the macOS app (Swift's
 * `Character`). A base code point takes the combining marks after it, including the half-width voiced marks,
 * so "ｶﾞ" is one character that folds to "ガ".
 */
internal object Graphemes {
    fun split(text: String): List<String> {
        val result = ArrayList<String>(text.length)
        var start = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (index > start && !extends(codePoint)) {
                result += text.substring(start, index)
                start = index
            }
            index += Character.charCount(codePoint)
        }
        if (start < text.length) result += text.substring(start)
        return result
    }

    fun count(text: String): Int = split(text).size

    private fun extends(codePoint: Int): Boolean = when (Character.getType(codePoint).toByte()) {
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK -> true
        else -> codePoint == 0xFF9E || codePoint == 0xFF9F
    }
}

/** Which writing system a character belongs to. */
internal enum class Script {
    LATIN, HIRAGANA, KATAKANA, KANJI, OTHER;

    /** Scripts a word is written in. Hiragana is left out: it is mostly particles and okurigana. */
    val isWord: Boolean get() = this == LATIN || this == KATAKANA || this == KANJI

    companion object {
        fun of(character: String): Script {
            val folded = Normalizer.normalize(character, Normalizer.Form.NFKC)
            if (folded.isEmpty() || folded.codePointCount(0, folded.length) != 1) return OTHER
            return when (folded.codePointAt(0)) {
                in 0x30..0x39, in 0x41..0x5A, in 0x61..0x7A -> LATIN
                in 0x3041..0x309F -> HIRAGANA
                0x30FB -> OTHER // "・" separates words.
                in 0x30A0..0x30FF -> KATAKANA
                0x3005, in 0x3400..0x4DBF, in 0x4E00..0x9FFF, in 0xF900..0xFAFF -> KANJI
                else -> OTHER
            }
        }
    }
}
