package io.github.moriri.hibivo

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.github.moriri.hibivo.core.PcmLevel
import io.github.moriri.hibivo.core.SonioxProtocol
import io.github.moriri.hibivo.core.SonioxSession
import io.github.moriri.hibivo.core.TranscriptionConfig
import io.github.moriri.hibivo.core.TranscriptionError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import kotlin.concurrent.thread

/** Why recognition couldn't start or had to stop. */
enum class RecognizerFailure { MICROPHONE_UNAVAILABLE, RECOGNITION_UNAVAILABLE, PERMISSION_DENIED, RECOGNITION_FAILED }

/**
 * Listens to one utterance and turns it into text. One instance per utterance, so back-to-back dictations
 * can never mix. All methods and callbacks run on the main thread.
 */
interface Recognizer {
    interface Listener {
        /** Running transcript for live display. */
        fun onPartial(text: String)

        /** Microphone level, 0…1. */
        fun onLevel(level: Float)

        /** Recognition stopped by itself; nothing more will arrive. */
        fun onFailure(failure: RecognizerFailure)

        /**
         * Listening can't go on (the connection dropped, the service keeps failing), but [finish] may still
         * have text to return or a precise error to report. The owner should finish now.
         */
        fun onEndedEarly()
    }

    /** False when listening couldn't start; [Listener.onFailure] has then already said why. */
    fun start(listener: Listener): Boolean

    /** Stops listening and returns the transcript; empty when nothing was said. */
    @Throws(TranscriptionError::class)
    suspend fun finish(): String

    fun cancel()
}

/**
 * Records mono PCM16 at 16 kHz on its own thread and hands out 100 ms chunks. Audio only ever lives in memory.
 * `onChunk` and `onError` are called on the recording thread.
 */
class AudioRecorder(private val onChunk: (ByteArray) -> Unit, private val onError: () -> Unit) {
    @Volatile private var running = false
    private var worker: Thread? = null

    // The caller checks RECORD_AUDIO before starting; a revoked permission surfaces as a failed start.
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) return false
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, SAMPLE_RATE),
            )
        } catch (e: IllegalArgumentException) {
            return false
        } catch (e: SecurityException) {
            return false
        }
        val started = record.state == AudioRecord.STATE_INITIALIZED && try {
            record.startRecording()
            record.recordingState == AudioRecord.RECORDSTATE_RECORDING
        } catch (e: IllegalStateException) {
            false
        }
        if (!started) {
            record.release()
            return false
        }
        running = true
        worker = thread(name = "hibivo-audio") {
            val buffer = ByteArray(CHUNK_BYTES)
            try {
                while (running) {
                    val read = record.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        onChunk(buffer.copyOf(read))
                    } else if (read < 0) {
                        if (running) onError()
                        break
                    }
                }
            } finally {
                runCatching { record.stop() }
                record.release()
            }
        }
        return true
    }

    /** Stops recording; every chunk has been delivered when this returns. */
    fun stop() {
        running = false
        worker?.join(1_000)
        worker = null
    }

    private companion object {
        const val SAMPLE_RATE = SonioxProtocol.SAMPLE_RATE
        const val CHUNK_BYTES = SAMPLE_RATE * 2 / 10
    }
}

/** Streams the microphone to Soniox while the user speaks, so the text is ready soon after they stop. */
class SonioxRecognizer(
    config: TranscriptionConfig,
    client: OkHttpClient,
    private val scope: CoroutineScope,
) : Recognizer {
    private val main = Handler(Looper.getMainLooper())

    // A rejected key or a dropped connection ends the recording at once, rather than letting the user
    // keep talking to nobody; `finish` then reports why, or returns what was heard until then.
    private val session = SonioxSession(
        config, client,
        onFailure = {
            main.post {
                failed = true
                listener?.onEndedEarly()
            }
        },
    )
    private var failed = false
    private var listener: Recognizer.Listener? = null
    private var partials: Job? = null
    @Volatile private var peak = 0f

    private val recorder = AudioRecorder(
        onChunk = { chunk ->
            session.send(chunk)
            val level = PcmLevel.rms(chunk)
            if (level > peak) peak = level
            main.post { listener?.onLevel((level * LEVEL_GAIN).coerceAtMost(1f)) }
        },
        onError = { main.post { fail(RecognizerFailure.MICROPHONE_UNAVAILABLE) } },
    )

    override fun start(listener: Recognizer.Listener): Boolean {
        this.listener = listener
        // Connect first: audio is queued until the socket is up, so the first words aren't lost.
        session.start()
        if (!recorder.start()) {
            fail(RecognizerFailure.MICROPHONE_UNAVAILABLE)
            return false
        }
        partials = scope.launch { session.partials.collect { text -> this@SonioxRecognizer.listener?.onPartial(text) } }
        return true
    }

    override suspend fun finish(): String {
        stopListening()
        // Nobody spoke: don't wait for (or pay for) a transcript of silence.
        // After a failure the session has the reason to report, so ask it even if nobody spoke.
        if (peak < SILENCE_THRESHOLD && !failed) {
            session.cancel()
            return ""
        }
        return session.finish()
    }

    override fun cancel() {
        stopListening()
        session.cancel()
    }

    private fun stopListening() {
        listener = null
        recorder.stop()
        partials?.cancel()
    }

    private fun fail(failure: RecognizerFailure) {
        val listener = listener ?: return
        cancel()
        listener.onFailure(failure)
    }

    private companion object {
        /** Peak RMS below this means nobody spoke. Same threshold as the macOS app. */
        const val SILENCE_THRESHOLD = 0.005f

        /** Speech sits around 0.05–0.2 RMS; this spreads it over the meter. */
        const val LEVEL_GAIN = 6f
    }
}

/**
 * The device's own speech recognition (`SpeechRecognizer`). Needs no API key. The service ends an utterance
 * at every pause, so this restarts it and joins the pieces until the user stops.
 */
class SystemRecognizer(
    private val context: Context,
    private val language: String,
    private val vocabulary: List<String>,
) : Recognizer {
    private var recognizer: SpeechRecognizer? = null
    private var listener: Recognizer.Listener? = null
    private val segments = mutableListOf<String>()
    private var current = ""
    private var stopping = false
    private var consecutiveErrors = 0
    private val finished = CompletableDeferred<Unit>()
    private val main = Handler(Looper.getMainLooper())
    private val restart = Runnable { if (!stopping) recognizer?.startListening(intent()) }

    override fun start(listener: Recognizer.Listener): Boolean {
        this.listener = listener
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            fail(RecognizerFailure.RECOGNITION_UNAVAILABLE)
            return false
        }
        recognizer = SpeechRecognizer.createSpeechRecognizer(context).also {
            it.setRecognitionListener(Callbacks())
            it.startListening(intent())
        }
        return true
    }

    override suspend fun finish(): String {
        stopping = true
        listener = null
        recognizer?.stopListening()
        // The last result normally follows at once; don't hang if the service never answers.
        withTimeoutOrNull(FINISH_TIMEOUT_MS) { finished.await() }
        release()
        return text()
    }

    override fun cancel() {
        listener = null
        stopping = true
        recognizer?.cancel()
        release()
    }

    private fun release() {
        main.removeCallbacks(restart)
        recognizer?.destroy()
        recognizer = null
    }

    private fun fail(failure: RecognizerFailure) {
        val listener = listener ?: return
        cancel()
        listener.onFailure(failure)
    }

    private fun text(): String =
        (segments + current).filter { it.isNotBlank() }.joinToString(if (language == "en") " " else "") { it.trim() }

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, if (language == "en") "en-US" else "ja-JP")
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && vocabulary.isNotEmpty()) {
            putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(vocabulary.take(MAX_BIASING_STRINGS)))
        }
    }

    private fun best(results: Bundle?): String =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

    private inner class Callbacks : RecognitionListener {
        override fun onPartialResults(partialResults: Bundle?) {
            consecutiveErrors = 0
            current = best(partialResults)
            listener?.onPartial(text())
        }

        override fun onResults(results: Bundle?) {
            consecutiveErrors = 0
            // Some services send an empty final result after good partials; keep the partial then.
            segments += best(results).ifBlank { current }
            current = ""
            listener?.onPartial(text())
            continueOrFinish()
        }

        override fun onError(error: Int) {
            when (error) {
                // A pause with nothing said. Keep listening until the user stops.
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> continueOrFinish(RESTART_DELAY_MS)
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    finished.complete(Unit)
                    fail(RecognizerFailure.PERMISSION_DENIED)
                }
                else -> {
                    consecutiveErrors += 1
                    when {
                        stopping || consecutiveErrors <= MAX_CONSECUTIVE_ERRORS -> continueOrFinish(RESTART_DELAY_MS)
                        // What was heard so far is still worth entering.
                        text().isNotBlank() -> {
                            stopping = true
                            finished.complete(Unit)
                            listener?.onEndedEarly()
                        }
                        else -> {
                            finished.complete(Unit)
                            fail(RecognizerFailure.RECOGNITION_FAILED)
                        }
                    }
                }
            }
        }

        override fun onRmsChanged(rmsdB: Float) {
            // Reported roughly between -2 and 10 dB.
            listener?.onLevel(((rmsdB + 2f) / 12f).coerceIn(0f, 1f))
        }

        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        /** @param delayMs Services answer "busy" when restarted from inside an error callback. */
        private fun continueOrFinish(delayMs: Long = 0) {
            when {
                stopping -> finished.complete(Unit)
                delayMs > 0 -> main.postDelayed(restart, delayMs)
                else -> recognizer?.startListening(intent())
            }
        }
    }

    private companion object {
        const val FINISH_TIMEOUT_MS = 3_000L
        const val MAX_CONSECUTIVE_ERRORS = 3
        const val RESTART_DELAY_MS = 150L
        const val MAX_BIASING_STRINGS = 100
    }
}
