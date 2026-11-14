package io.github.moriri.hibivo.core

/** How the transcript is rewritten before it is entered. Same modes and prompts as the macOS app. */
enum class CleanupMode(val id: String) {
    RAW("raw"),
    NATURAL("natural"),
    BUSINESS("business"),
    PROMPT("prompt"),

    /** Follows instructions the user wrote in settings. */
    CUSTOM("custom");

    companion object {
        /** Most characters the custom instructions may have, to keep the per-utterance system prompt small. */
        const val CUSTOM_INSTRUCTIONS_LIMIT = 500

        fun fromId(id: String?): CleanupMode? = entries.firstOrNull { it.id == id }
    }
}

/** Which prompt cleanup uses. Japanese keeps a prompt written in Japanese: an English one was less faithful. */
enum class PromptLanguage {
    JAPANESE,
    ENGLISH;

    companion object {
        /** @param transcriptionLanguage BCP-47 primary language, e.g. "ja" or "en". */
        fun of(transcriptionLanguage: String): PromptLanguage =
            if (transcriptionLanguage == "en") ENGLISH else JAPANESE
    }
}
