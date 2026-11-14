package io.github.moriri.hibivo

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import io.github.moriri.hibivo.core.CleanupCoordinator
import io.github.moriri.hibivo.core.CleanupError
import io.github.moriri.hibivo.core.CleanupMode
import io.github.moriri.hibivo.core.CleanupProviderKind
import io.github.moriri.hibivo.core.AnthropicCleanupProvider
import io.github.moriri.hibivo.core.GeminiCleanupProvider
import io.github.moriri.hibivo.core.OpenAICompatibleCleanupProvider
import io.github.moriri.hibivo.core.PromptLanguage
import io.github.moriri.hibivo.core.TextCleanupProvider
import io.github.moriri.hibivo.core.TranscriptionConfig
import io.github.moriri.hibivo.core.TranscriptionError
import io.github.moriri.hibivo.core.VocabularyEntry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/**
 * The dictation state machine: idle → recording → processing → idle.
 *
 * Starting fixes what the utterance needs (provider, language, dictionary, the app being typed into), so a
 * settings change mid-utterance can't mix in. Cleanup settings are read when recording stops: the keyboard
 * shows the mode and lets the user change it while speaking. Main thread only.
 */
class DictationController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val settings: Settings,
    private val secrets: SecretStore,
    private val vocabularyStore: VocabularyStore,
    private val client: OkHttpClient,
    private val listener: Listener,
) {
    enum class State { IDLE, RECORDING, TRANSCRIBING, CLEANING_UP }

    interface Listener {
        fun onStateChanged(state: State)
        fun onPartial(text: String)
        fun onLevel(level: Float)

        /** Something the user should know, already worded for them. */
        fun onNotice(message: String)

        /** The microphone permission is missing; only an activity can ask for it. */
        fun onMicrophonePermissionNeeded()

        /** @return false when the text couldn't be entered into the app. */
        fun onResult(text: String, language: String): Boolean
    }

    private class Utterance(
        val recognizer: Recognizer,
        val startedAt: Long,
        val language: String,
        val vocabulary: List<VocabularyEntry>,
        val appName: String?,
    )

    var state = State.IDLE
        private set(value) {
            if (field == value) return
            field = value
            listener.onStateChanged(value)
        }

    private var utterance: Utterance? = null
    private var work: Job? = null
    private var limit: Job? = null
    private val coordinator = CleanupCoordinator()

    /** @param appName The app being typed into, for the cleanup prompt. */
    fun start(appName: String?) {
        if (state != State.IDLE) return
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            listener.onMicrophonePermissionNeeded()
            return
        }
        val language = settings.language
        val vocabulary = vocabularyStore.load().filter { it.isEnabled }
        val recognizer = makeRecognizer(language, vocabulary) ?: return
        val started = recognizer.start(object : Recognizer.Listener {
            override fun onPartial(text: String) = listener.onPartial(text)
            override fun onLevel(level: Float) = listener.onLevel(level)
            override fun onFailure(failure: RecognizerFailure) {
                utterance = null
                limit?.cancel()
                state = State.IDLE
                listener.onNotice(context.getString(failure.notice))
            }

            override fun onEndedEarly() = stop(endedEarly = true)
        })
        if (!started) return
        utterance = Utterance(recognizer, SystemClock.elapsedRealtime(), language, vocabulary, appName)
        state = State.RECORDING
        // A session left running by mistake would keep the microphone (and a paid stream) open.
        limit = scope.launch {
            delay(MAX_DURATION_MS)
            stop()
        }
    }

    /** Ends recording and enters the result. */
    fun stop() = stop(endedEarly = false)

    /** @param endedEarly The recognizer stopped by itself, so its error must be reported, not dropped. */
    private fun stop(endedEarly: Boolean) {
        val utterance = utterance ?: return
        if (state != State.RECORDING) return
        limit?.cancel()
        // An accidental double tap.
        if (!endedEarly && SystemClock.elapsedRealtime() - utterance.startedAt < MINIMUM_DURATION_MS) {
            cancel()
            return
        }
        state = State.TRANSCRIBING
        work = scope.launch {
            val transcript = try {
                utterance.recognizer.finish()
            } catch (e: TranscriptionError) {
                finish(context.getString(e.notice))
                return@launch
            }
            if (transcript.isBlank()) {
                finish(context.getString(R.string.notice_nothing_heard))
                return@launch
            }
            val mode = settings.mode
            if (mode != CleanupMode.RAW) state = State.CLEANING_UP
            val kind = settings.cleanupProvider
            val (_, outcome) = coordinator.run(
                transcript, utterance.vocabulary, mode, utterance.appName, settings.customInstructions,
                PromptLanguage.of(utterance.language), makeCleanupProvider(kind), settings.cleanupModel(kind),
            )
            val entered = listener.onResult(outcome.text, utterance.language)
            finish(
                when {
                    !entered -> context.getString(R.string.notice_copied_instead)
                    outcome.failure != null -> context.getString(outcome.failure!!.notice)
                    else -> null
                },
            )
        }
    }

    /** Drops the utterance, whether it is still being recorded or already being processed. */
    fun cancel() {
        if (state == State.IDLE) return
        limit?.cancel()
        work?.cancel()
        work = null
        utterance?.recognizer?.cancel()
        utterance = null
        state = State.IDLE
    }

    private fun finish(notice: String?) {
        utterance = null
        work = null
        state = State.IDLE
        notice?.let(listener::onNotice)
    }

    private fun makeRecognizer(language: String, vocabulary: List<VocabularyEntry>): Recognizer? {
        if (settings.sttProvider != Settings.STT_SONIOX) {
            return SystemRecognizer(context, language, vocabulary.map { it.preferred })
        }
        val key = secrets.get(Settings.SECRET_SONIOX)
        if (key.isNullOrEmpty()) {
            listener.onNotice(context.getString(R.string.notice_soniox_key_missing))
            return null
        }
        val config = TranscriptionConfig(
            apiKey = key, language = language,
            vocabulary = vocabulary.map { it.preferred }, readings = vocabulary.flatMap { it.readings },
        )
        return SonioxRecognizer(config, client, scope)
    }

    /** Null when the selected provider has no API key saved. */
    private fun makeCleanupProvider(kind: CleanupProviderKind): TextCleanupProvider? {
        val key = secrets.get(kind.id)?.takeIf { it.isNotEmpty() } ?: return null
        return when (kind) {
            CleanupProviderKind.ANTHROPIC -> AnthropicCleanupProvider(key, client)
            CleanupProviderKind.OPENAI_COMPATIBLE -> OpenAICompatibleCleanupProvider(settings.openAIBaseUrl, key, client)
            CleanupProviderKind.GEMINI -> GeminiCleanupProvider(key, client)
        }
    }

    private val RecognizerFailure.notice: Int
        get() = when (this) {
            RecognizerFailure.MICROPHONE_UNAVAILABLE -> R.string.notice_microphone_unavailable
            RecognizerFailure.RECOGNITION_UNAVAILABLE -> R.string.notice_recognition_unavailable
            RecognizerFailure.PERMISSION_DENIED -> R.string.notice_recognition_permission
            RecognizerFailure.RECOGNITION_FAILED -> R.string.notice_recognition_failed
        }

    private val TranscriptionError.notice: Int
        get() = when (this) {
            TranscriptionError.Unauthorized -> R.string.notice_soniox_key_invalid
            is TranscriptionError.Network -> R.string.notice_network
            TranscriptionError.TimedOut -> R.string.notice_transcription_timed_out
            is TranscriptionError.Server, TranscriptionError.Cancelled -> R.string.notice_recognition_failed
        }

    /** Every cleanup failure still enters the raw transcript, so each message says so. */
    private val CleanupError.notice: Int
        get() = when (this) {
            CleanupError.MissingApiKey -> R.string.notice_cleanup_key_missing
            CleanupError.MissingModel -> R.string.notice_cleanup_model_missing
            CleanupError.Unauthorized -> R.string.notice_cleanup_key_invalid
            CleanupError.TimedOut -> R.string.notice_cleanup_timed_out
            CleanupError.Network -> R.string.notice_cleanup_network
            else -> R.string.notice_cleanup_failed
        }

    private companion object {
        const val MINIMUM_DURATION_MS = 250L
        const val MAX_DURATION_MS = 10 * 60 * 1_000L
    }
}
