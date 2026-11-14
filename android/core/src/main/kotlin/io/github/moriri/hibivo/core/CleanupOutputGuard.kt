package io.github.moriri.hibivo.core

/** Sanity-checks LLM output before it is entered. Returns null when the raw transcript should be used. */
object CleanupOutputGuard {
    fun validate(output: String, raw: String, mode: CleanupMode): String? {
        var text = output
        for (tag in listOf("think", "thinking", "reasoning")) {
            text = Regex("<$tag>[\\s\\S]*?</$tag>", RegexOption.IGNORE_CASE).replace(text, "")
        }
        text = Regex("</?transcript>").replace(text, "")
        text = strippingCodeFence(text.trim())
        text = strippingPreamble(text).trim()
        if (text.isEmpty()) return null

        // Guard against the model answering the transcript or inventing content.
        val rawCount = Graphemes.count(raw)
        val count = Graphemes.count(text)
        // Custom instructions may legitimately lengthen the text, e.g. translating Japanese into English.
        val maxRatio = if (mode == CleanupMode.PROMPT || mode == CleanupMode.CUSTOM) 3.0 else 2.0
        if (count > rawCount * maxRatio + 40) return null
        // …or silently dropping most of it. Short inputs are legitimately shortened a lot by filler removal.
        // Custom instructions may ask for a summary.
        if (mode != CleanupMode.CUSTOM && rawCount >= 30 && count < rawCount * 0.25) return null
        return text
    }

    private fun strippingCodeFence(text: String): String {
        if (!text.startsWith("```") || !text.endsWith("```") || text.length <= 6) return text
        val lines = text.split("\n")
        if (lines.size < 3) return text
        return lines.subList(1, lines.size - 1).joinToString("\n")
    }

    /** Drops a leading line like 「以下が整形後の文章です：」 or "Here is the cleaned text:". */
    private fun strippingPreamble(text: String): String {
        val newline = text.indexOf('\n')
        if (newline < 0) return text
        val first = text.substring(0, newline).trim()
        val looksLikePreamble = (first.endsWith("：") || first.endsWith(":")) &&
            listOf("整形", "修正", "以下", "清書", "Here", "here").any { it in first }
        return if (looksLikePreamble) text.substring(newline + 1) else text
    }
}
