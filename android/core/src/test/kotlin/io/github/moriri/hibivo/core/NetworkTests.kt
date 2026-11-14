package io.github.moriri.hibivo.core

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class SonioxProtocolTests {
    @Test fun configCarriesHintsAndTerms() {
        val text = SonioxProtocol.config(
            TranscriptionConfig("key", language = "ja", vocabulary = listOf("HibiVo", "AI"), readings = listOf("ヒビボ", "AI")),
        )
        val json = HttpJson.json.parseToJsonElement(text).jsonObject
        assertEquals("key", json["api_key"]!!.jsonPrimitive.content)
        assertEquals("stt-rt-v6", json["model"]!!.jsonPrimitive.content)
        assertEquals("pcm_s16le", json["audio_format"]!!.jsonPrimitive.content)
        assertEquals("16000", json["sample_rate"]!!.jsonPrimitive.content)
        assertEquals(listOf("ja", "en"), json["language_hints"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(
            listOf("HibiVo", "AI", "ヒビボ"),
            json["context"]!!.jsonObject["terms"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
    }

    @Test fun configOmitsContextWithoutTerms() {
        val json = HttpJson.json.parseToJsonElement(SonioxProtocol.config(TranscriptionConfig("k", language = "en"))).jsonObject
        assertFalse("context" in json)
        assertEquals(listOf("en"), json["language_hints"]!!.jsonArray.map { it.jsonPrimitive.content })
    }

    @Test fun transcriptKeepsFinalTokensAndReplacesTentativeOnes() {
        val transcript = SonioxTranscript()
        transcript.apply(SonioxProtocol.parse("""{"tokens":[{"text":"こん","is_final":true},{"text":"にち"}]}""")!!)
        assertEquals("こんにち", transcript.displayText)
        transcript.apply(SonioxProtocol.parse("""{"tokens":[{"text":"にちは","is_final":false}]}""")!!)
        assertEquals("こんにちは", transcript.displayText)
        transcript.apply(SonioxProtocol.parse("""{"tokens":[{"text":"にちは","is_final":true},{"text":"<end>","is_final":true},{"text":"<fin>","is_final":true}]}""")!!)
        assertEquals("こんにちは", transcript.finalText)
        assertEquals("", transcript.tentativeText)
        assertTrue(transcript.didFinalize)
    }

    @Test fun parsesErrorsAndSkipsGarbage() {
        val error = SonioxProtocol.parse("""{"error_code":401,"error_message":"Invalid API key"}""")!!
        assertEquals(401, error.errorCode)
        assertEquals("Invalid API key", error.errorMessage)
        assertNull(SonioxProtocol.parse("not json"))
    }

    @Test fun rmsOfSilenceAndFullScale() {
        assertEquals(0f, PcmLevel.rms(ByteArray(320)))
        // -32768 in little-endian PCM16.
        val loud = ByteArray(320) { if (it % 2 == 0) 0x00 else 0x80.toByte() }
        assertEquals(1f, PcmLevel.rms(loud))
    }
}

class SonioxSessionTests {
    private val server = MockWebServer()
    private val client = OkHttpClient()
    private val received = CopyOnWriteArrayList<String>()

    @AfterTest fun tearDown() {
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
        runCatching { server.shutdown() }
    }

    /** A fake Soniox: records what it gets and answers each text message with `reply`. */
    private fun serve(reply: (message: String, socket: WebSocket) -> Unit) {
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                received += text
                reply(text, webSocket)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                received += "audio:${bytes.size}"
            }
        }))
        server.start()
    }

    private fun session(timeout: kotlin.time.Duration = 4.seconds) = SonioxSession(
        TranscriptionConfig("key", language = "ja"), client, server.url("/").toString().replaceFirst("http", "ws"), timeout,
    )

    @Test fun sendsConfigThenAudioThenFinalizeAndReturnsFinalText() = runBlocking {
        serve { message, socket ->
            if (message == SonioxProtocol.FINALIZE_MESSAGE) {
                socket.send("""{"tokens":[{"text":" 今日は晴れ ","is_final":true},{"text":"<fin>","is_final":true}]}""")
            }
        }
        val session = session()
        session.start()
        // Sent before the connection is up; must still arrive, in order, after the config.
        session.send(ByteArray(3200))
        session.send(ByteArray(1600))
        assertEquals("今日は晴れ", session.finish())
        assertTrue(received[0].contains("\"api_key\":\"key\""))
        assertEquals(listOf("audio:3200", "audio:1600", "audio:6400", SonioxProtocol.FINALIZE_MESSAGE), received.drop(1))
    }

    @Test fun publishesPartials() = runBlocking {
        serve { message, socket ->
            if (message.contains("api_key")) socket.send("""{"tokens":[{"text":"途中","is_final":false}]}""")
        }
        val session = session(timeout = 300.milliseconds)
        session.start()
        while (session.partials.value.isEmpty()) delay(10)
        assertEquals("途中", session.partials.value)
        // No <fin> ever arrives: the tentative text is kept rather than lost.
        assertEquals("途中", session.finish())
    }

    @Test fun invalidKeyIsReportedAsUnauthorized() = runBlocking {
        serve { message, socket ->
            if (message.contains("api_key")) socket.send("""{"error_code":401,"error_message":"Invalid API key"}""")
        }
        val session = session()
        session.start()
        assertFailsWith<TranscriptionError.Unauthorized> { session.finish() }
        Unit
    }

    @Test fun timeoutWithNothingHeardThrows() = runBlocking {
        serve { _, _ -> }
        val session = session(timeout = 200.milliseconds)
        session.start()
        assertFailsWith<TranscriptionError.TimedOut> { session.finish() }
        Unit
    }

    @Test fun unreachableServerIsANetworkError() = runBlocking {
        server.start()
        val url = server.url("/").toString().replaceFirst("http", "ws")
        server.shutdown()
        val session = SonioxSession(TranscriptionConfig("key", language = "ja"), client, url)
        session.start()
        assertFailsWith<TranscriptionError.Network> { session.finish() }
        Unit
    }
}

class CleanupProviderTests {
    private val server = MockWebServer()
    private val client = OkHttpClient()

    @AfterTest fun tearDown() {
        runCatching { server.shutdown() }
    }

    private fun body(): JsonObject = HttpJson.json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject

    @Test fun anthropicSendsKeyAndReadsTextBlocks() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"整形後"}],"stop_reason":"end_turn"}"""))
        val provider = AnthropicCleanupProvider("sk-test", client, server.url("/v1/messages").toString())
        assertEquals("整形後", provider.complete("sys", "user", "claude-haiku-4-5"))
        val request = server.takeRequest()
        assertEquals("sk-test", request.getHeader("x-api-key"))
        assertEquals("2023-06-01", request.getHeader("anthropic-version"))
        assertNull(request.getHeader("anthropic-beta"))
        val json = HttpJson.json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("sys", json["system"]!!.jsonPrimitive.content)
        assertEquals("user", json["messages"]!!.jsonArray[0].jsonObject["content"]!!.jsonPrimitive.content)
        // Haiku 4.5 rejects effort.
        assertFalse("output_config" in json)
    }

    @Test fun anthropicEffortAndFallbacksDependOnModel() {
        val haiku5 = AnthropicCleanupProvider.makeRequest("s", "u", "claude-haiku-5-5")
        assertEquals("low", haiku5["output_config"]!!.jsonObject["effort"]!!.jsonPrimitive.content)
        assertFalse("fallbacks" in haiku5)
        assertTrue("fallbacks" in AnthropicCleanupProvider.makeRequest("s", "u", "claude-sonnet-5-5"))
    }

    @Test fun anthropicRefusalAndStatusCodes() = runBlocking {
        val provider = AnthropicCleanupProvider("k", client, server.url("/").toString())
        server.enqueue(MockResponse().setBody("""{"content":[],"stop_reason":"refusal"}"""))
        assertFailsWith<CleanupError.Refused> { provider.complete("s", "u", "m") }
        server.enqueue(MockResponse().setResponseCode(401).setBody("{}"))
        assertFailsWith<CleanupError.Unauthorized> { provider.complete("s", "u", "m") }
        server.enqueue(MockResponse().setResponseCode(529).setBody("{}"))
        assertEquals(CleanupError.Http(529), assertFailsWith<CleanupError.Http> { provider.complete("s", "u", "m") })
        server.enqueue(MockResponse().setBody("<html>"))
        assertFailsWith<CleanupError.InvalidResponse> { provider.complete("s", "u", "m") }
        Unit
    }

    @Test fun openAICompatibleUsesBaseUrlAndBearer() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"choices":[{"message":{"content":"done"},"finish_reason":"stop"}]}"""))
        val provider = OpenAICompatibleCleanupProvider(server.url("/v1/").toString(), "key", client)
        assertEquals("done", provider.complete("sys", "user", "gpt"))
        val request = server.takeRequest()
        assertEquals("/v1/chat/completions", request.path)
        assertEquals("Bearer key", request.getHeader("Authorization"))
    }

    @Test fun malformedBaseUrlFailsWithoutCrashing() = runBlocking {
        val provider = OpenAICompatibleCleanupProvider("not a url", "key", client)
        assertFailsWith<CleanupError.InvalidResponse> { provider.complete("s", "u", "m") }
        Unit
    }

    @Test fun geminiRequestAndResponse() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"steps":[{"type":"thought"},{"type":"model_output","content":[{"type":"text","text":"整"},{"type":"text","text":"形"}]}]}"""))
        val provider = GeminiCleanupProvider("gkey", client, server.url("/").toString())
        assertEquals("整形", provider.complete("sys", "user", "gemini-3.5-flash-lite"))
        val request = server.takeRequest()
        assertEquals("gkey", request.getHeader("x-goog-api-key"))
        val json = HttpJson.json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("false", json["store"]!!.jsonPrimitive.content)
        assertEquals("low", json["generation_config"]!!.jsonObject["thinking_level"]!!.jsonPrimitive.content)

        server.enqueue(MockResponse().setResponseCode(400).setBody("""{"error":{"message":"API_KEY_INVALID"}}"""))
        assertFailsWith<CleanupError.Unauthorized> { provider.complete("s", "u", "gemini-2.5-flash") }
        Unit
    }
}

class CleanupCoordinatorTests {
    private class Fake(val reply: suspend (system: String, user: String) -> String) : TextCleanupProvider {
        var calls = 0
        override suspend fun complete(system: String, user: String, model: String): String {
            calls += 1
            return reply(system, user)
        }
    }

    private val coordinator = CleanupCoordinator()
    private fun request(raw: String, mode: CleanupMode = CleanupMode.NATURAL) = CleanupCoordinator.Request(raw, mode)

    @Test fun rawModeNeverCallsTheModel() = runTest {
        val fake = Fake { _, _ -> "x" }
        assertEquals(CleanupOutcome("えーと", false), coordinator.run(request("えーと", CleanupMode.RAW), fake, "m"))
        assertEquals(0, fake.calls)
    }

    @Test fun missingCredentialsOrModelFallBackToRaw() = runTest {
        assertEquals(CleanupError.MissingApiKey, coordinator.run(request("こんにちは"), null, "m").failure)
        val outcome = coordinator.run(request("こんにちは"), Fake { _, _ -> "x" }, " ")
        assertEquals(CleanupOutcome("こんにちは", false, CleanupError.MissingModel), outcome)
    }

    @Test fun returnsCleanedText() = runTest {
        val fake = Fake { _, user ->
            assertEquals("<transcript>\nえーと、こんにちは\n</transcript>", user)
            "こんにちは"
        }
        assertEquals(CleanupOutcome("こんにちは", true), coordinator.run(request("えーと、こんにちは"), fake, "m"))
    }

    @Test fun errorsTimeoutsAndRejectedOutputKeepTheUtterance() = runTest {
        val raw = "明日の会議は15時からです"
        assertEquals(CleanupError.Unauthorized, coordinator.run(request(raw), Fake { _, _ -> throw CleanupError.Unauthorized }, "m").failure)
        assertEquals(CleanupError.InvalidResponse, coordinator.run(request(raw), Fake { _, _ -> error("boom") }, "m").failure)
        assertEquals(CleanupError.RejectedByGuard, coordinator.run(request(raw), Fake { _, _ -> "" }, "m").failure)
        // Virtual time: the stalled request is cut off at the deadline.
        val stalled = coordinator.run(request(raw), Fake { _, _ -> delay(60.seconds); "late" }, "m")
        assertEquals(CleanupOutcome(raw, false, CleanupError.TimedOut), stalled)
    }

    @Test fun timeoutGrowsWithLengthUpToTheCap() {
        assertEquals(5.seconds, coordinator.timeout(""))
        assertEquals(6.seconds, coordinator.timeout("あ".repeat(50)))
        assertEquals(30.seconds, coordinator.timeout("あ".repeat(5000)))
    }

    @Test fun dictationPathAppliesDictionaryThenDropsLonePeriod() = runTest {
        val vocabulary = listOf(VocabularyEntry("AppSync", listOf("アップシンク")), VocabularyEntry("Off", listOf("オフ語"), isEnabled = false))
        val fake = Fake { system, user ->
            assertTrue("- AppSync（聞き取り例: アップシンク）" in system)
            assertFalse("Off" in system)
            assertEquals("<transcript>\nAppSync\n</transcript>", user)
            "AppSync。"
        }
        val (raw, outcome) = coordinator.run(
            "アップシンク", vocabulary, CleanupMode.NATURAL, null, "", PromptLanguage.JAPANESE, fake, "m",
        )
        assertEquals("AppSync", raw)
        assertEquals(CleanupOutcome("AppSync", true), outcome)
    }
}
