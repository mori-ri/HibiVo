package io.github.moriri.hibivo.core

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.addJsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

sealed class CleanupError : Exception() {
    data object MissingApiKey : CleanupError()
    data object MissingModel : CleanupError()
    data object Unauthorized : CleanupError()
    data class Http(val status: Int) : CleanupError()
    data object Refused : CleanupError()
    data object InvalidResponse : CleanupError()
    data object RejectedByGuard : CleanupError()
    data object TimedOut : CleanupError()
    data object Network : CleanupError()
}

/**
 * An LLM that rewrites text. It only knows how to send one system + user message and return text.
 * Each provider is created with its own credentials.
 */
interface TextCleanupProvider {
    suspend fun complete(system: String, user: String, model: String): String
}

/** The cleanup providers users can pick in Settings. */
enum class CleanupProviderKind(val id: String, val displayName: String, val defaultModel: String) {
    ANTHROPIC("anthropic", "Anthropic (Claude)", "claude-haiku-4-5"),
    OPENAI_COMPATIBLE("openai-compatible", "OpenAI compatible", ""),
    GEMINI("gemini", "Google Gemini", "gemini-3.5-flash-lite");

    companion object {
        const val DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"

        fun fromId(id: String?): CleanupProviderKind? = entries.firstOrNull { it.id == id }
    }
}

internal object HttpJson {
    private val mediaType = "application/json".toMediaType()
    val json = Json { ignoreUnknownKeys = true }

    /** POSTs `body` and returns the parsed response, mapping failures to [CleanupError]. */
    suspend fun post(client: OkHttpClient, url: String, headers: Map<String, String>, body: JsonObject): JsonObject {
        val request = try {
            Request.Builder().url(url.toHttpUrl()).post(body.toString().toRequestBody(mediaType))
                .apply { headers.forEach { (name, value) -> header(name, value) } }
                .build()
        } catch (e: IllegalArgumentException) {
            // A malformed base URL or a key with characters a header can't carry.
            throw CleanupError.InvalidResponse
        }
        val (status, text) = client.newCall(request).await()
        when {
            status in 200..299 -> Unit
            status == 401 || status == 403 -> throw CleanupError.Unauthorized
            // Gemini reports a bad key as 400 API_KEY_INVALID rather than 401.
            status == 400 && "API_KEY_INVALID" in text -> throw CleanupError.Unauthorized
            else -> throw CleanupError.Http(status)
        }
        return try {
            json.parseToJsonElement(text) as? JsonObject ?: throw CleanupError.InvalidResponse
        } catch (e: kotlinx.serialization.SerializationException) {
            throw CleanupError.InvalidResponse
        }
    }

    private suspend fun Call.await(): Pair<Int, String> = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(CleanupError.Network)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use { it.code to (it.body?.string() ?: "") }
                } catch (e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(CleanupError.Network)
                    return
                }
                if (continuation.isActive) continuation.resume(result)
            }
        })
    }

    fun JsonElement?.obj(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
    fun JsonElement?.array(key: String): JsonArray? = (this as? JsonObject)?.get(key) as? JsonArray
    fun JsonElement?.string(key: String): String? =
        ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
}

/** Claude via the Messages API (POST /v1/messages). */
class AnthropicCleanupProvider(
    private val apiKey: String,
    private val client: OkHttpClient,
    private val endpoint: String = "https://api.anthropic.com/v1/messages",
) : TextCleanupProvider {
    override suspend fun complete(system: String, user: String, model: String): String {
        val body = makeRequest(system, user, model)
        val headers = buildMap {
            put("x-api-key", apiKey)
            put("anthropic-version", "2023-06-01")
            if ("fallbacks" in body) put("anthropic-beta", "server-side-fallback-2026-07-01")
        }
        return parse(HttpJson.post(client, endpoint, headers, body))
    }

    companion object {
        internal fun makeRequest(system: String, user: String, model: String): JsonObject = buildJsonObject {
            put("model", model)
            put("max_tokens", 4_000)
            put("system", system)
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    put("content", user)
                }
            }
            // Cleanup is a light rewrite; low effort keeps latency down on models that think adaptively.
            // Haiku 4.5 rejects effort; Haiku 5.5 takes it (and defaults to medium, so low is worth sending).
            if (!model.startsWith("claude-haiku-4")) putJsonObject("output_config") { put("effort", "low") }
            // Server-side fallback when a safety classifier declines (Opus 5 and later, Fable 5, Sonnet 5.5).
            if (listOf("claude-opus-5", "claude-fable-5", "claude-sonnet-5-5").any(model::startsWith)) {
                put("fallbacks", "default")
            }
        }

        internal fun parse(response: JsonObject): String {
            with(HttpJson) {
                if (response.string("stop_reason") == "refusal") throw CleanupError.Refused
                // Cut off at the output cap: entering it would silently drop the end of the utterance.
                if (response.string("stop_reason") == "max_tokens") throw CleanupError.InvalidResponse
                val text = response.array("content").orEmpty()
                    .filter { it.string("type") == "text" }
                    .mapNotNull { it.string("text") }
                    .joinToString("")
                if (text.isEmpty()) throw CleanupError.InvalidResponse
                return text
            }
        }
    }
}

/** Any `/chat/completions` endpoint: OpenAI, Groq, OpenRouter, an in-house gateway, etc. */
class OpenAICompatibleCleanupProvider(
    private val baseUrl: String,
    private val apiKey: String,
    private val client: OkHttpClient,
) : TextCleanupProvider {
    override suspend fun complete(system: String, user: String, model: String): String {
        // No output cap is sent, because endpoints disagree on its name and reject the one they don't know.
        val body = buildJsonObject {
            put("model", model)
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "system")
                    put("content", system)
                }
                addJsonObject {
                    put("role", "user")
                    put("content", user)
                }
            }
            put("temperature", 0)
        }
        val url = baseUrl.trim().trimEnd('/') + "/chat/completions"
        return parse(HttpJson.post(client, url, mapOf("Authorization" to "Bearer $apiKey"), body))
    }

    companion object {
        internal fun parse(response: JsonObject): String {
            with(HttpJson) {
                val choice = response.array("choices")?.firstOrNull()
                // Cut off at the output cap: entering it would silently drop the end of the utterance.
                if (choice.string("finish_reason") == "length") throw CleanupError.InvalidResponse
                val text = choice.obj("message").string("content")
                if (text.isNullOrEmpty()) throw CleanupError.InvalidResponse
                return text
            }
        }
    }
}

/** Gemini via the Interactions API (POST /v1beta/interactions). */
class GeminiCleanupProvider(
    private val apiKey: String,
    private val client: OkHttpClient,
    private val endpoint: String = "https://generativelanguage.googleapis.com/v1beta/interactions",
) : TextCleanupProvider {
    override suspend fun complete(system: String, user: String, model: String): String =
        parse(HttpJson.post(client, endpoint, mapOf("x-goog-api-key" to apiKey), makeRequest(system, user, model)))

    companion object {
        internal fun makeRequest(system: String, user: String, model: String): JsonObject = buildJsonObject {
            put("model", model)
            put("input", user)
            put("system_instruction", system)
            // Dictated text must not be kept server-side for later retrieval.
            put("store", false)
            // Cleanup is a light rewrite, so keep thinking low. Pre-3 models don't take `thinking_level`.
            if (model.startsWith("gemini-3")) putJsonObject("generation_config") { put("thinking_level", "low") }
        }

        internal fun parse(response: JsonObject): String {
            with(HttpJson) {
                val text = response.array("steps").orEmpty()
                    .filter { it.string("type") == "model_output" }
                    .flatMap { it.array("content").orEmpty() }
                    .filter { it.string("type") == "text" }
                    .mapNotNull { it.string("text") }
                    .joinToString("")
                if (text.isEmpty()) throw CleanupError.InvalidResponse
                return text
            }
        }
    }
}
