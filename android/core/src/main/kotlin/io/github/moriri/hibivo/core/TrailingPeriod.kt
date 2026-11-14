package io.github.moriri.hibivo.core

/**
 * Drops the period that STT and cleanup put after a lone word ("AppSync。", "Lambda."), which gets in the way
 * when dictating into a search box, a form field or the middle of a sentence. Pure so it can be unit tested.
 */
object TrailingPeriod {
    /** Longer text is left alone even without other punctuation: it is likely a sentence. */
    private const val MAX_WORD_LENGTH = 20

    fun trimmed(text: String): String {
        val word = Graphemes.split(text.trim())
        val period = word.lastOrNull() ?: return text
        if (period != "。" && period != ".") return text
        val body = word.dropLast(1)
        val last = body.lastOrNull() ?: return text
        val isWord = body.size <= MAX_WORD_LENGTH &&
            body.none { it == "\n" || it == "\r" || it == "\r\n" || it in PUNCTUATION } &&
            !hasParticle(body) &&
            // Japanese sentences end in hiragana (です, ました, ね); words end in kanji, katakana or letters.
            Script.of(last).isWord &&
            // An English sentence ends in a letter too, so only a single English word loses its ".".
            (period == "。" || body.none { it.isBlank() })
        return if (isWord) body.joinToString("") else text
    }

    /**
     * "次回は来週" ends in kanji but is a sentence: a lone は, が, を… between words marks a clause.
     * の and と are left out because they join nouns ("会議の資料", "AWSとGCP").
     */
    private fun hasParticle(characters: List<String>): Boolean = (1 until characters.size - 1).any { i ->
        characters[i] in PARTICLES && Script.of(characters[i - 1]).isWord && Script.of(characters[i + 1]).isWord
    }

    private val PARTICLES = "はがをにでもへ".map { it.toString() }.toSet()
    private val PUNCTUATION = "、。，．,.！？!?…".map { it.toString() }.toSet()
}
