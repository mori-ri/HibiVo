package io.github.moriri.hibivo.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.add
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Everything needed to open one streaming session. */
data class TranscriptionConfig(
    val apiKey: String,
    val model: String = SonioxProtocol.DEFAULT_MODEL,
    /** BCP-47 primary language, e.g. "ja". */
    val language: String,
    /** Preferred spellings to bias recognition toward (e.g. "AppSync", "Claude Code"). */
    val vocabulary: List<String> = emptyList(),
    /** How dictionary terms sound, in katakana, so STT writes an unfamiliar name consistently. */
    val readings: List<String> = emptyList(),
)

sealed class TranscriptionError : Exception() {
    data object Unauthorized : TranscriptionError()
    data class Network(val detail: String) : TranscriptionError()
    data class Server(val detail: String) : TranscriptionError()
    data object TimedOut : TranscriptionError()
    data object Cancelled : TranscriptionError()
}

/** Wire format for Soniox real-time transcription. */
object SonioxProtocol {
    const val ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket"
    const val DEFAULT_MODEL = "stt-rt-v6"
    const val SAMPLE_RATE = 16_000
    const val FINALIZE_MESSAGE = """{"type":"finalize"}"""
    const val FINALIZE_MARKER = "<fin>"
    const val END_MARKER = "<end>"

    data class Token(val text: String, val isFinal: Boolean)

    data class Response(
        val tokens: List<Token>?,
        val finished: Boolean,
        val errorCode: Int?,
        val errorMessage: String?,
    )

    /** Preferred spellings first, then readings, without duplicates, within Soniox's 200-term budget. */
    fun terms(config: TranscriptionConfig): List<String> = (config.vocabulary + config.readings).distinct().take(200)

    /** Hint English as well so technical terms stay in Latin script ("AppSync", not "アップシンク"). */
    fun languageHints(language: String): List<String> = if (language == "en") listOf("en") else listOf(language, "en")

    fun config(config: TranscriptionConfig, sampleRate: Int = SAMPLE_RATE): String = buildJsonObject {
        put("api_key", config.apiKey)
        put("model", config.model)
        put("audio_format", "pcm_s16le")
        put("sample_rate", sampleRate)
        put("num_channels", 1)
        putJsonArray("language_hints") { languageHints(config.language).forEach { add(it) } }
        val terms = terms(config)
        if (terms.isNotEmpty()) putJsonObject("context") { putJsonArray("terms") { terms.forEach { add(it) } } }
    }.toString()

    /** Null when the message isn't one we understand; such messages are skipped. */
    fun parse(text: String): Response? {
        val json = try {
            HttpJson.json.parseToJsonElement(text) as? JsonObject ?: return null
        } catch (e: kotlinx.serialization.SerializationException) {
            return null
        }
        val tokens = (json["tokens"] as? JsonArray)?.mapNotNull { element ->
            val token = element as? JsonObject ?: return@mapNotNull null
            val tokenText = (token["text"] as? JsonPrimitive)?.content ?: return@mapNotNull null
            Token(tokenText, (token["is_final"] as? JsonPrimitive)?.booleanOrNull ?: false)
        }
        return Response(
            tokens = tokens,
            finished = (json["finished"] as? JsonPrimitive)?.booleanOrNull == true,
            errorCode = (json["error_code"] as? JsonPrimitive)?.intOrNull,
            errorMessage = (json["error_message"] as? JsonPrimitive)?.content,
        )
    }
}

/**
 * Folds Soniox token messages into a transcript.
 *
 * Final tokens arrive once and never change; non-final tokens are replaced by every message.
 */
class SonioxTranscript {
    var finalText = ""
        private set
    var tentativeText = ""
        private set
    var didFinalize = false
        private set
    var didFinish = false
        private set

    val displayText: String get() = finalText + tentativeText

    fun apply(response: SonioxProtocol.Response) {
        if (response.finished) didFinish = true
        val tokens = response.tokens ?: return
        val tentative = StringBuilder()
        for (token in tokens) {
            when (token.text) {
                SonioxProtocol.FINALIZE_MARKER -> didFinalize = true
                SonioxProtocol.END_MARKER -> Unit
                else -> if (token.isFinal) finalText += token.text else tentative.append(token.text)
            }
        }
        tentativeText = tentative.toString()
    }
}

/**
 * One Soniox WebSocket connection for one utterance, so back-to-back dictations can never mix audio.
 *
 * Audio may be sent right after [start]: OkHttp queues it until the connection is ready, so speech from the
 * moment the button goes down is never lost. On [finish] we send a short tail of silence plus `finalize`,
 * then wait for the `<fin>` token, which marks every earlier token as final. On a timeout or a dropped
 * connection, [finish] returns the text so far instead of throwing.
 */
class SonioxSession(
    private val config: TranscriptionConfig,
    private val client: OkHttpClient,
    private val endpoint: String = SonioxProtocol.ENDPOINT,
    private val finalizeTimeout: Duration = 4.seconds,
    /** Called once, on an OkHttp thread, when the session fails by itself (not when cancelled). */
    private val onFailure: (TranscriptionError) -> Unit = {},
) {
    private val lock = Any()
    private val transcript = SonioxTranscript()
    private val finalized = CompletableDeferred<Unit>()
    private var socket: WebSocket? = null
    private var isClosed = false
    private var failure: TranscriptionError? = null

    private val _partials = MutableStateFlow("")

    /** Running transcript (final + tentative text) for live display. */
    val partials: StateFlow<String> = _partials

    fun start() {
        synchronized(lock) {
            if (socket != null || isClosed) return
            // An http(s) URL is what OkHttp takes; it upgrades to a WebSocket itself.
            val url = endpoint.replaceFirst("wss://", "https://").replaceFirst("ws://", "http://")
            socket = client.newWebSocket(Request.Builder().url(url).build(), Listener()).also {
                it.send(SonioxProtocol.config(config))
            }
        }
    }

    fun send(pcm16: ByteArray) {
        synchronized(lock) {
            if (isClosed || failure != null) return
            socket?.send(pcm16.toByteString())
        }
    }

    /** Flushes the remaining audio and returns the final transcript. */
    suspend fun finish(): String {
        val needsFinalize = synchronized(lock) {
            val needed = failure == null && !transcript.didFinalize && !transcript.didFinish
            if (needed) {
                // Soniox recommends a little trailing silence before a manual finalize.
                socket?.send(TRAILING_SILENCE)
                socket?.send(SonioxProtocol.FINALIZE_MESSAGE)
            }
            needed
        }
        var waitError: TranscriptionError? = null
        if (needsFinalize && withTimeoutOrNull(finalizeTimeout) { finalized.await() } == null) {
            waitError = TranscriptionError.TimedOut
        }
        close()
        return synchronized(lock) {
            // After a successful finalize every token is final. Otherwise keep whatever we have (including
            // tentative text) rather than losing the utterance.
            val text = transcript.displayText.trim()
            val error = failure ?: waitError
            if (text.isEmpty() && error != null) throw error
            text
        }
    }

    fun cancel() {
        fail(TranscriptionError.Cancelled)
        close()
    }

    private fun fail(error: TranscriptionError) {
        val first = synchronized(lock) { (failure == null).also { if (it) failure = error } }
        finalized.complete(Unit)
        if (first && error != TranscriptionError.Cancelled) onFailure(error)
    }

    private fun close() {
        val socket = synchronized(lock) {
            if (isClosed) return
            isClosed = true
            socket
        }
        // `cancel` rather than `close`: nothing more is wanted from the server, and it frees the socket at once.
        socket?.cancel()
    }

    private inner class Listener : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handle(bytes.utf8())

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            // A close after the transcript is complete is the normal end of a session.
            val unexpected = synchronized(lock) { !isClosed && !transcript.didFinalize && !transcript.didFinish }
            if (unexpected) fail(TranscriptionError.Network(reason))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (synchronized(lock) { isClosed }) return
            fail(if (response?.code == 401) TranscriptionError.Unauthorized else TranscriptionError.Network(t.message ?: ""))
        }

        private fun handle(message: String) {
            val response = SonioxProtocol.parse(message) ?: return
            response.errorCode?.let { code ->
                fail(
                    if (code == 401) TranscriptionError.Unauthorized
                    else TranscriptionError.Server(response.errorMessage ?: code.toString()),
                )
                return
            }
            val done = synchronized(lock) {
                if (isClosed) return
                transcript.apply(response)
                _partials.value = transcript.displayText
                transcript.didFinalize || transcript.didFinish
            }
            if (done) finalized.complete(Unit)
        }
    }

    private companion object {
        /** 200 ms of PCM16 at 16 kHz. */
        val TRAILING_SILENCE: ByteString = ByteArray(SonioxProtocol.SAMPLE_RATE * 2 / 5).toByteString()
    }
}

/** Root-mean-square level of little-endian PCM16, 0…1. Used for the level meter and to skip silence. */
object PcmLevel {
    fun rms(pcm16: ByteArray, length: Int = pcm16.size): Float {
        val samples = length / 2
        if (samples == 0) return 0f
        var sum = 0.0
        for (i in 0 until samples) {
            val sample = (pcm16[2 * i].toInt() and 0xFF) or (pcm16[2 * i + 1].toInt() shl 8)
            val value = sample / 32768.0
            sum += value * value
        }
        return kotlin.math.sqrt(sum / samples).toFloat()
    }
}
