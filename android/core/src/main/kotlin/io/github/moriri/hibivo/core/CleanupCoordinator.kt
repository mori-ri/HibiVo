package io.github.moriri.hibivo.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

data class CleanupOutcome(
    /** What should be entered: the cleaned text, or the raw transcript as a fallback. */
    val text: String,
    val didCleanup: Boolean,
    /** Set when cleanup was attempted and failed; the raw transcript is used instead. */
    val failure: CleanupError? = null,
)

/**
 * Runs one cleanup with a hard timeout and falls back to the raw transcript on any problem.
 * The timeout grows with the transcript, since the model has to write roughly as much as it reads.
 * Cleanup must never cost the user their utterance.
 */
class CleanupCoordinator(
    private val baseTimeout: Duration = 5.seconds,
    private val maxTimeout: Duration = 30.seconds,
) {
    data class Request(
        val raw: String,
        val mode: CleanupMode,
        val vocabulary: List<CleanupPromptBuilder.Term> = emptyList(),
        val appName: String? = null,
        /** Used only by [CleanupMode.CUSTOM]. */
        val customInstructions: String = "",
        val language: PromptLanguage = PromptLanguage.JAPANESE,
    )

    /** 1 s per 50 characters: well under typical output speeds, so only a stalled request hits the limit. */
    internal fun timeout(raw: String): Duration =
        minOf(maxOf(baseTimeout, maxTimeout), baseTimeout + 20.milliseconds * raw.length)

    /** @param provider null when the selected provider has no credentials configured. */
    suspend fun run(request: Request, provider: TextCleanupProvider?, model: String): CleanupOutcome {
        val raw = request.raw
        if (request.mode == CleanupMode.RAW) return CleanupOutcome(raw, didCleanup = false)
        if (provider == null) return CleanupOutcome(raw, false, CleanupError.MissingApiKey)
        if (model.isBlank()) return CleanupOutcome(raw, false, CleanupError.MissingModel)

        val system = CleanupPromptBuilder.systemPrompt(
            request.mode, request.customInstructions, request.vocabulary, request.appName, request.language,
        )
        val user = CleanupPromptBuilder.userMessage(raw)
        return try {
            val output = withTimeout(timeout(raw)) { provider.complete(system, user, model.trim()) }
            CleanupOutputGuard.validate(output, raw, request.mode)?.let { CleanupOutcome(it, didCleanup = true) }
                ?: CleanupOutcome(raw, false, CleanupError.RejectedByGuard)
        } catch (e: TimeoutCancellationException) {
            CleanupOutcome(raw, false, CleanupError.TimedOut)
        } catch (e: CancellationException) {
            throw e
        } catch (e: CleanupError) {
            CleanupOutcome(raw, false, e)
        } catch (e: Exception) {
            CleanupOutcome(raw, false, CleanupError.InvalidResponse)
        }
    }

    /**
     * What dictation does with a finished transcript: apply the dictionary, clean up, then drop the period
     * after a lone word.
     * @return The transcript after dictionary replacement, and the cleanup outcome.
     */
    suspend fun run(
        transcript: String,
        vocabulary: List<VocabularyEntry>,
        mode: CleanupMode,
        appName: String?,
        customInstructions: String,
        language: PromptLanguage,
        provider: TextCleanupProvider?,
        model: String,
    ): Pair<String, CleanupOutcome> {
        val enabled = vocabulary.filter { it.isEnabled }
        val raw = VocabularyReplacer.apply(enabled, transcript)
        val outcome = run(
            Request(raw, mode, enabled.map { it.promptTerm }, appName, customInstructions, language), provider, model,
        )
        return raw to outcome.copy(text = TrailingPeriod.trimmed(outcome.text))
    }
}
