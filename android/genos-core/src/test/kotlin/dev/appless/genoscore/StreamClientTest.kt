package dev.appless.genoscore

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val userTurn = listOf(ChatMessage(ChatRole.USER, "hi"))

/** src/genos/stream.ts streamRound: SSE protocol, framing, errors, cancellation. */
class StreamClientTest {
    @Test
    fun `content deltas are forwarded and the stream ends cleanly`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(sseContent("Hello "), sseContent("world"), sseFinish("stop"), SSE_DONE),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())

        assertEquals(listOf("Hello ", "world"), rec.deltas)
        assertEquals(listOf(StreamEndInfo(truncated = false, dropped = false)), rec.doneInfos)
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `the request body carries the parity constants`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, StreamRecorder().handlers(), StreamCancelToken())

        val request = http.requests.single()
        assertEquals("https://api.cerebras.ai/v1/chat/completions", request.url)
        assertEquals("POST", request.method)
        assertEquals("application/json", request.headers["Content-Type"])
        assertEquals("Bearer test-key", request.headers["Authorization"])

        val body = JsonValue.parse(request.bodyText)!!
        assertEquals("gemma-4-31b", body["model"]?.str)
        assertEquals(true, body["stream"]?.bool)
        assertEquals(0.8, body["temperature"]?.num)
        assertEquals(3072.0, body["max_completion_tokens"]?.num)
        assertNull(body["tools"], "no tools offered when none are available")
        val messages = body["messages"]?.arr!!
        assertEquals(2, messages.size)
        assertEquals("system", messages[0]["role"]?.str)
        assertEquals("SYSTEM\n\nToday is Friday, July 25, 2026.", messages[0]["content"]?.str)
        assertEquals("user", messages[1]["role"]?.str)
        assertEquals("hi", messages[1]["content"]?.str)
    }

    @Test
    fun `the request body bytes are exactly the RN object-literal order`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), systemPrompt = "S")
            .streamScreen(userTurn, StreamRecorder().handlers(), StreamCancelToken())
        assertEquals(
            "{\"model\":\"gemma-4-31b\",\"messages\":[" +
                "{\"role\":\"system\",\"content\":\"S\\n\\nToday is Friday, July 25, 2026.\"}," +
                "{\"role\":\"user\",\"content\":\"hi\"}]," +
                "\"stream\":true,\"temperature\":0.8,\"max_completion_tokens\":3072}",
            http.requests.single().bodyText,
        )
    }

    @Test
    fun `a null message content serializes as JSON null`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), systemPrompt = "S").streamScreen(
            listOf(ChatMessage(ChatRole.ASSISTANT, null)),
            StreamRecorder().handlers(),
            StreamCancelToken(),
        )
        assertTrue(http.requests.single().bodyText.contains("{\"role\":\"assistant\",\"content\":null}"))
    }

    @Test
    fun `data lines split across chunk boundaries`() = runTest {
        val http = ScriptedHttp()
        val whole = sseContent("split me") + sseFinish("stop") + SSE_DONE
        // Deliberately cut mid-JSON and mid-line.
        http.enqueue(
            ScriptedResponse.sse(
                listOf(whole.substring(0, 17), whole.substring(17, 40), whole.substring(40)),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("split me", rec.content)
        assertEquals(1, rec.doneInfos.size)
    }

    @Test
    fun `a multi-byte UTF-8 sequence split across chunks decodes once`() = runTest {
        val http = ScriptedHttp()
        val payload = sseContent("héllo → 😀") + sseFinish("stop") + SSE_DONE
        val bytes = payload.toByteArray(Charsets.UTF_8)
        // Split at every byte so every multi-byte sequence straddles a boundary.
        http.enqueue(ScriptedResponse.bytes(bytes.map { byteArrayOf(it) }))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("héllo → 😀", rec.content)
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `non-data lines and malformed payloads are ignored`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    ": keep-alive comment\n",
                    "event: message\n",
                    "\n",
                    "data:\n",
                    "data: {not json}\n",
                    "data: {\"choices\":[]}\n",
                    sseContent("survived"),
                    sseFinish("stop"),
                    SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("survived", rec.content)
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `JSON-parse-strict chunks are skipped and the stream continues`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    // Leading zero and a raw control char: JSON.parse throws on
                    // both, so RN's try/catch skips these chunks.
                    "data: {\"choices\":[{\"delta\":{\"content\":\"a\"},\"index\":01}]}\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\"b\u0001c\"}}]}\n",
                    sseContent("ok"),
                    sseFinish("stop"),
                    SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("ok", rec.content)
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `finish_reason length sets truncated`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("cut"), sseFinish("length"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(StreamEndInfo(truncated = true, dropped = false), rec.doneInfos.single())
    }

    @Test
    fun `ending without DONE or a finish reason is a dropped stream`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("half a screen"))))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(StreamEndInfo(truncated = false, dropped = true), rec.doneInfos.single())
        assertEquals("half a screen", rec.content)
    }

    @Test
    fun `a finish reason without the DONE sentinel is not dropped`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), sseFinish("stop"))))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(StreamEndInfo(truncated = false, dropped = false), rec.doneInfos.single())
    }

    @Test
    fun `DONE without a finish reason is not dropped either`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(StreamEndInfo(truncated = false, dropped = false), rec.doneInfos.single())
    }

    @Test
    fun `a drop with nothing at all arrived is an error, not a done`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(emptyList()))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("stream dropped before any content arrived"), rec.errors)
        assertTrue(rec.doneInfos.isEmpty())
    }

    @Test
    fun `a mid-stream transport failure surfaces as an error`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse(
                chunks = listOf(sseContent("partial").toByteArray(Charsets.UTF_8)),
                streamErrorMessage = "connection reset",
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("connection reset"), rec.errors)
        assertTrue(rec.doneInfos.isEmpty())
    }

    @Test
    fun `an in-stream error object surfaces as an error`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf("data: {\"error\":{\"message\":\"rate limited\"}}\n", SSE_DONE),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("rate limited"), rec.errors)
    }

    @Test
    fun `an in-stream error string surfaces as an error`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf("data: {\"error\":\"plain string\"}\n")))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("plain string"), rec.errors)
    }

    @Test
    fun `falsy error chunks are skipped like the RN truthy guard`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"error\":null,\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n",
                    "data: {\"error\":\"\",\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n",
                    "data: {\"error\":0,\"choices\":[{\"delta\":{\"content\":\"c\"}}]}\n",
                    "data: {\"error\":false,\"choices\":[{\"delta\":{\"content\":\"d\"}}]}\n",
                    sseFinish("stop"),
                    SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("abcd", rec.content)
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `a truthy error without a message falls back to the generic text`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf("data: {\"error\":{\"code\":42}}\n")))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("stream error"), rec.errors)
    }

    @Test
    fun `401 marks the key rejected`() = runTest {
        val secure = MemorySecureStore()
        secure.seed(KeyStore.STORAGE_KEY, "bad")
        val keys = KeyStore("bad", secure, appScope())
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 401))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), keyStore = keys)
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("Cerebras rejected the API key - enter a valid key"), rec.errors)
        assertEquals(KeyStatus.REJECTED, keys.status)
        assertNull(keys.get())
        testScheduler.advanceUntilIdle()
        assertNull(secure.values[KeyStore.STORAGE_KEY])
    }

    @Test
    fun `403 also marks the key rejected`() = runTest {
        val keys = KeyStore("bad", MemorySecureStore(), appScope())
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 403))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), keyStore = keys)
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(KeyStatus.REJECTED, keys.status)
        assertEquals(1, rec.errors.size)
    }

    @Test
    fun `a 401 for a key the user already replaced does not wipe the new one`() = runTest {
        val keys = KeyStore("old", MemorySecureStore(), appScope())
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 401))
        val client = makeStreamClient(http, appScope(), keyStore = keys)
        // The stream captured "old"; the user types a new key mid-flight.
        val token = StreamCancelToken()
        keys.set("new")
        val rec = StreamRecorder()
        client.streamScreen(userTurn, rec.handlers(), token)
        // The request went out with "new", so markRejected("new") DOES fire —
        // the guard is exercised directly instead.
        keys.set("newer")
        keys.markRejected("new")
        assertEquals("newer", keys.get())
    }

    @Test
    fun `an HTTP error surfaces the body detail`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 500, errorBody = "upstream exploded"))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("upstream exploded"), rec.errors)
    }

    @Test
    fun `an HTTP error with an empty body falls back to the status`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 503))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("HTTP 503"), rec.errors)
    }

    @Test
    fun `the HTTP error detail is truncated at 500 UTF-16 units`() = runTest {
        val http = ScriptedHttp()
        // 499 ASCII + an astral char: JS slice(0, 500) keeps the lone HIGH
        // surrogate; Kotlin's substring does the same.
        val body = "a".repeat(499) + "😀tail"
        http.enqueue(ScriptedResponse(status = 500, errorBody = body))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        val detail = rec.errors.single()
        assertEquals(500, detail.length)
        assertTrue(Character.isHighSurrogate(detail[499]))
    }

    @Test
    fun `a missing API key errors without issuing a request`() = runTest {
        val keys = KeyStore(null, MemorySecureStore(), appScope())
        keys.hydrate()
        testScheduler.advanceUntilIdle()
        val http = ScriptedHttp()
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), keyStore = keys)
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("No Cerebras API key set"), rec.errors)
        assertTrue(http.requests.isEmpty())
    }

    @Test
    fun `a whitespace-only key errors locally without issuing a request`() = runTest {
        val keys = KeyStore(null, MemorySecureStore(), appScope())
        keys.set("   ")
        assertEquals("", keys.get(), "RN stores the trimmed empty string")
        val http = ScriptedHttp()
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), keyStore = keys)
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("No Cerebras API key set"), rec.errors)
        assertTrue(http.requests.isEmpty(), "no blank Authorization header ever goes out")
    }
}

/** SSE line framing hazards: CRLF, BOM, combining marks, chunk boundaries. */
class SseFramingTest {
    @Test
    fun `a CRLF-terminated stream delivers every delta`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseContent("one").replace("\n", "\r\n"),
                    sseContent("two").replace("\n", "\r\n"),
                    sseFinish("stop").replace("\n", "\r\n"),
                    SSE_DONE.replace("\n", "\r\n"),
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("one", "two"), rec.deltas)
        assertEquals(StreamEndInfo(), rec.doneInfos.single())
    }

    @Test
    fun `a CRLF split across a chunk boundary still parses`() = runTest {
        val http = ScriptedHttp()
        val line = sseContent("crlf").replace("\n", "\r\n")
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    line.dropLast(1), // ends with "\r"
                    "\n" + sseFinish("stop") + SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("crlf", rec.content)
    }

    @Test
    fun `mixed LF and CRLF lines all split`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseContent("lf") + sseContent("crlf").replace("\n", "\r\n") + sseContent("lf2"),
                    sseFinish("stop"),
                    SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("lf", "crlf", "lf2"), rec.deltas)
    }

    @Test
    fun `a BOM before the data prefix is trimmed like JS`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(listOf("\uFEFF" + sseContent("bom"), sseFinish("stop"), SSE_DONE)),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("bom", rec.content)
    }

    @Test
    fun `a combining mark at line start does not glue to the previous newline`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseContent("first") + "\u0301 stray line\n" + sseContent("second"),
                    sseFinish("stop"),
                    SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("first", "second"), rec.deltas)
    }

    @Test
    fun `the tail buffer survives a stream ending without a final newline`() = runTest {
        val http = ScriptedHttp()
        // Last line has no "\n": RN keeps it in the buffer and never parses it,
        // so the finish_reason it carries is lost and the stream reads dropped.
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("body"), sseFinish("stop").dropLast(1))))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("body", rec.content)
        assertEquals(StreamEndInfo(truncated = false, dropped = true), rec.doneInfos.single())
    }

    @Test
    fun `whitespace around the data payload is trimmed like JS`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "   data:   {\"choices\":[{\"delta\":{\"content\":\"padded\"}}]}   \n",
                    "data:\u00A0[DONE]\n",
                    sseFinish("stop"),
                ),
            ),
        )
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals("padded", rec.content)
        assertEquals(StreamEndInfo(), rec.doneInfos.single())
    }
}

/** Cancellation must tear the stream down, not just mute the callbacks. */
class StreamCancellationTest {
    @Test
    fun `an already-cancelled token suppresses every callback`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), sseFinish("stop"), SSE_DONE)))
        val rec = StreamRecorder()
        val token = StreamCancelToken()
        token.cancel()
        makeStreamClient(http, appScope()).streamScreen(userTurn, rec.handlers(), token)
        assertTrue(rec.deltas.isEmpty())
        assertTrue(rec.doneInfos.isEmpty())
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `cancelling mid-stream stops pulling chunks`() = runTest {
        val http = ScriptedHttp()
        http.gateAfterChunk = 2
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseContent("a"), sseContent("b"), sseContent("c"),
                    sseFinish("stop"), SSE_DONE,
                ),
            ),
        )
        val rec = StreamRecorder()
        val token = StreamCancelToken()
        makeStreamClient(http, appScope()).stream(userTurn, rec.handlers(), token)
        testScheduler.advanceUntilIdle()
        assertEquals(2, http.chunksPulled)
        assertEquals(listOf("a", "b"), rec.deltas)

        token.cancel()
        http.releaseGate()
        testScheduler.advanceUntilIdle()
        assertEquals(2, http.chunksPulled, "no further chunks were pulled")
        assertTrue(rec.doneInfos.isEmpty())
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `cancelling before attach cancels the coroutine immediately`() = runTest {
        val http = ScriptedHttp()
        http.gateAfterChunk = 0
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("never"), SSE_DONE)))
        val rec = StreamRecorder()
        val token = StreamCancelToken()
        token.cancel()
        makeStreamClient(http, appScope()).stream(userTurn, rec.handlers(), token)
        testScheduler.advanceUntilIdle()
        assertEquals(0, http.chunksPulled)
        assertTrue(rec.deltas.isEmpty())
        token.join()
    }

    @Test
    fun `cancelling during tool execution prevents the next round's request`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseWholeToolCall(0, "call_1", "web_search", "{\"query\":\"goa\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("second round"), SSE_DONE)))

        val gate = CompletableDeferred<Unit>()
        val tool = object : ToolExecuting {
            override val available = true
            override val promptSection = ""
            override val toolDefs = JsonValue.Arr(emptyList())
            override suspend fun execute(name: String, args: Map<String, JsonValue>): String {
                gate.await()
                return "never used"
            }
        }
        val rec = StreamRecorder()
        val token = StreamCancelToken()
        makeStreamClient(http, appScope(), tools = tool).stream(userTurn, rec.handlers(), token)
        testScheduler.advanceUntilIdle()
        assertEquals(1, http.requests.size)
        assertEquals(1, rec.toolRounds.size)

        token.cancel()
        gate.complete(Unit)
        testScheduler.advanceUntilIdle()
        assertEquals(1, http.requests.size, "the second round never went out")
        assertTrue(rec.doneInfos.isEmpty())
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun `deltas arriving after cancellation are suppressed`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(sseContent("a"), sseContent("b"), sseContent("c"), sseFinish("stop"), SSE_DONE),
            ),
        )
        val rec = StreamRecorder()
        val token = StreamCancelToken()
        rec.onDeltaHook = { if (it == "a") token.cancel() }
        makeStreamClient(http, appScope()).streamScreen(userTurn, rec.handlers(), token)
        assertEquals(listOf("a"), rec.deltas)
        assertTrue(rec.doneInfos.isEmpty())
        assertTrue(rec.errors.isEmpty())
    }
}

/** The incremental UTF-8 decoder must match `TextDecoder(stream: true)` exactly. */
class Utf8StreamDecoderTest {
    private fun decodeAll(vararg chunks: ByteArray): String {
        val d = Utf8StreamDecoder()
        return chunks.joinToString("") { d.decode(it) }
    }

    @Test
    fun `valid sequences decode across every boundary`() {
        val text = "aé€😀z"
        val bytes = text.toByteArray(Charsets.UTF_8)
        for (cut in 0..bytes.size) {
            assertEquals(
                text,
                decodeAll(bytes.copyOfRange(0, cut), bytes.copyOfRange(cut, bytes.size)),
                "cut at $cut",
            )
        }
    }

    @Test
    fun `invalid leads emit a replacement immediately, with no holdback`() {
        assertEquals("\uFFFD", decodeAll(byteArrayOf(0xC0.toByte())))
        assertEquals("\uFFFD", decodeAll(byteArrayOf(0xC1.toByte())))
        assertEquals("\uFFFD", decodeAll(byteArrayOf(0xF5.toByte())))
        assertEquals("\uFFFD", decodeAll(byteArrayOf(0xFF.toByte())))
        assertEquals("\uFFFD", decodeAll(byteArrayOf(0x80.toByte())), "a stray continuation")
    }

    @Test
    fun `valid incomplete tails are still held back`() {
        val d = Utf8StreamDecoder()
        assertEquals("", d.decode(byteArrayOf(0xE2.toByte(), 0x82.toByte())))
        assertEquals("€", d.decode(byteArrayOf(0xAC.toByte())))
    }

    @Test
    fun `out-of-range continuations emit in the arriving chunk, offending byte reprocessed`() {
        // ED A0 80 (a surrogate): the A0 is out of range for ED, so the spec
        // emits an error and REPROCESSES A0 as a lead — three replacements.
        assertEquals(
            "\uFFFD\uFFFD\uFFFD",
            decodeAll(byteArrayOf(0xED.toByte(), 0xA0.toByte(), 0x80.toByte())),
        )
        // F4 90 80 80 (> U+10FFFF): four replacements.
        assertEquals(
            "\uFFFD\uFFFD\uFFFD\uFFFD",
            decodeAll(byteArrayOf(0xF4.toByte(), 0x90.toByte(), 0x80.toByte(), 0x80.toByte())),
        )
        // E0 80 (overlong): two replacements.
        assertEquals("\uFFFD\uFFFD", decodeAll(byteArrayOf(0xE0.toByte(), 0x80.toByte())))
    }

    @Test
    fun `an ASCII byte after a truncated sequence is reprocessed, not swallowed`() {
        // E2 'a' → replacement for the truncated sequence, then 'a'.
        assertEquals("\uFFFDa", decodeAll(byteArrayOf(0xE2.toByte(), 0x61)))
    }

    @Test
    fun `boundary code points decode`() {
        assertEquals("\u0000", decodeAll(byteArrayOf(0x00)))
        assertEquals("\u007F", decodeAll(byteArrayOf(0x7F)))
        assertEquals("\u0080", decodeAll(byteArrayOf(0xC2.toByte(), 0x80.toByte())))
        assertEquals("\uFFFF", decodeAll(byteArrayOf(0xEF.toByte(), 0xBF.toByte(), 0xBF.toByte())))
        assertEquals(
            "\uDBFF\uDFFF", // U+10FFFF
            decodeAll(byteArrayOf(0xF4.toByte(), 0x8F.toByte(), 0xBF.toByte(), 0xBF.toByte())),
        )
    }

    @Test
    fun `a byte-at-a-time feed matches a whole-buffer decode for a mixed corpus`() {
        val corpus = "ASCII, é, €, 😀, \u0000, ߿, \uFFFF, 中文, ﷽"
        val bytes = corpus.toByteArray(Charsets.UTF_8)
        val perByte = Utf8StreamDecoder().let { d ->
            bytes.joinToString("") { d.decode(byteArrayOf(it)) }
        }
        assertEquals(corpus, perByte)
        assertEquals(corpus, Utf8StreamDecoder().decode(bytes))
    }
}

/** The production date formatter must produce the RN en-US long-date shape. */
class TodayStringTest {
    @Test
    fun `the default today string matches the RN en-US long date shape`() {
        val today = StreamConfig.defaultTodayString()
        assertTrue(
            Regex(
                "\\A(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), " +
                    "(January|February|March|April|May|June|July|August|September|October|" +
                    "November|December) [0-9]{1,2}, [0-9]{4}\\z",
            ).matches(today),
            "unexpected shape: $today",
        )
        assertTrue(!today.contains(",,"))
    }

    @Test
    fun `the default today string is locale-independent`() {
        val previous = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.forLanguageTag("de-DE"))
            assertTrue(StreamConfig.defaultTodayString().first().isUpperCase())
            assertTrue(
                StreamConfig.defaultTodayString().substringBefore(",") in
                    listOf(
                        "Monday", "Tuesday", "Wednesday", "Thursday",
                        "Friday", "Saturday", "Sunday",
                    ),
            )
        } finally {
            java.util.Locale.setDefault(previous)
        }
    }
}
