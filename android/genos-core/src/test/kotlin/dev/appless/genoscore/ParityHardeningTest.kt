package dev.appless.genoscore

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

// Findings closed in this file come from a differential review whose ORACLE is
// the real RN source (src/genos/{stream,store,tools}.ts) executed under node
// with only `expo/fetch` and `src/config` stubbed. Every expectation below was
// produced by running that oracle or a bare `node -e`, never by reading either
// port. The generating command is named on each test.

private val userTurn = listOf(ChatMessage(ChatRole.USER, "hi"))

private fun toolCallChunk(index: String, id: String, args: String): String {
    val escaped = args.replace("\"", "\\\"")
    return "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":$index," +
        "\"id\":\"$id\",\"function\":{\"name\":\"web_search\",\"arguments\":\"$escaped\"}}]}}]}\n"
}

/** Findings 2/5: hostile tool_call index and non-string chunk fields. */
class StreamHostileChunkTest {
    /**
     * FINDING 2. RN keys its accumulator `Map` by the RAW Number, so `3.2` and
     * `3.7` are TWO distinct calls. This port narrowed with `toInt()`
     * (TRUNCATION), collapsing them onto key 3 and CONCATENATING both
     * `arguments` blobs into `{"query":"x"}{"query":"y"}` — which fails
     * `JSON.parse` and degrades to `args={}`, so one tool round went out
     * instead of two and the round-2 body differed from RN's bytes.
     *
     * The hazard is the CLASS "any Double→Int narrowing", so these pairs
     * collapse under DIFFERENT narrowings — a test using only 3.2/3.7 passes
     * against rounding (3 and 4) and would have certified the Swift sibling
     * while this port merged them.
     *
     * RN oracle (`probe2b.ts`) — every pair is TWO calls:
     *
     *     3.2    /3.4     calls=2 ids=["call_a","call_b"]
     *     3.7    /4.2     calls=2 ids=["call_a","call_b"]
     *     3.2    /3.7     calls=2 ids=["call_a","call_b"]
     *     0.4    /0.5     calls=2 ids=["call_a","call_b"]
     *     -0.4   /-0.6    calls=2 ids=["call_b","call_a"]
     *     1e+300 /1e+301  calls=2 ids=["call_a","call_b"]
     */
    @Test
    fun `fractional indices stay two distinct calls`() = runTest {
        val pairs = listOf(
            Triple("3.2", "3.4", listOf("call_a", "call_b")),
            Triple("3.7", "4.2", listOf("call_a", "call_b")),
            Triple("3.2", "3.7", listOf("call_a", "call_b")),
            Triple("0.4", "0.5", listOf("call_a", "call_b")),
            Triple("-0.4", "-0.6", listOf("call_b", "call_a")),
            Triple("1e300", "1e301", listOf("call_a", "call_b")),
        )
        for ((a, b, expectedIds) in pairs) {
            val expectedQueries = expectedIds.map { if (it == "call_a") "x" else "y" }
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf(
                        toolCallChunk(a, "call_a", "{\"query\":\"x\"}"),
                        toolCallChunk(b, "call_b", "{\"query\":\"y\"}"),
                        sseFinish("tool_calls"),
                        SSE_DONE,
                    ),
                ),
            )
            http.enqueue(ScriptedResponse.sse(listOf(sseContent("second"), sseFinish("stop"), SSE_DONE)))
            val rec = StreamRecorder()
            makeStreamClient(http, appScope(), tools = FakeTool())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())

            assertEquals(1, rec.toolRounds.size, "index $a/$b")
            assertEquals(2, rec.toolRounds[0].size, "index $a/$b must not merge")
            assertEquals(
                expectedQueries,
                rec.toolRounds[0].map { jsStringCoerce(it.args["query"]) },
                "index $a/$b",
            )
            val messages = http.requestBodies()[1]["messages"]?.arr!!
            val assistant = messages.first { it["role"]?.str == "assistant" }
            assertEquals(
                expectedIds,
                assistant["tool_calls"]?.arr!!.map { it["id"]?.str },
                "index $a/$b",
            )
            assertEquals(
                expectedIds,
                messages.filter { it["role"]?.str == "tool" }.map { it["tool_call_id"]?.str },
                "index $a/$b",
            )
        }
    }

    /**
     * PROBE on the path the fix does NOT take: keys RN's `Map` DOES unify must
     * still unify. A JS Map key uses SameValueZero, under which -0 and +0 are
     * the SAME key — while boxed `java.lang.Double.equals` separates them, so
     * a raw-Double `LinkedHashMap` needs the explicit normalization.
     *
     * RN oracle (`probe2.ts`, scenarios C/E/F) — all three merge into ONE call
     * whose concatenated arguments then fail JSON.parse:
     *
     *     E. index -0 / 0
     *       toolRound calls: [{"name":"web_search","args":{}}]
     *       assistant.tool_calls: [{"id":"call_b", ... "arguments":
     *                               "{\"query\":\"x\"}{\"query\":\"y\"}"}]
     */
    @Test
    fun `keys RN unifies are still unified`() = runTest {
        for ((a, b) in listOf("3.7" to "3.7", "-0" to "0", "null" to "0")) {
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf(
                        toolCallChunk(a, "call_a", "{\"query\":\"x\"}"),
                        toolCallChunk(b, "call_b", "{\"query\":\"y\"}"),
                        sseFinish("tool_calls"),
                        SSE_DONE,
                    ),
                ),
            )
            http.enqueue(ScriptedResponse.sse(listOf(sseContent("second"), sseFinish("stop"), SSE_DONE)))
            val rec = StreamRecorder()
            makeStreamClient(http, appScope(), tools = FakeTool())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())

            assertEquals(1, rec.toolRounds[0].size, "index $a/$b must merge like RN")
            assertTrue(rec.toolRounds[0][0].args.isEmpty(), "index $a/$b: concatenation is unparseable")
            val assistant = http.requestBodies()[1]["messages"]?.arr!!
                .first { it["role"]?.str == "assistant" }
            assertEquals(
                "{\"query\":\"x\"}{\"query\":\"y\"}",
                assistant["tool_calls"]?.get(0)?.get("function")?.get("arguments")?.str,
                "index $a/$b",
            )
        }
    }

    /** A hostile index must never abort or saturate the accumulator. */
    @Test
    fun `hostile indices do not break the stream`() = runTest {
        for (index in listOf("1e300", "1e999", "-1e999", "-1e300", "3.7", "-0", "0.5")) {
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf(toolCallChunk(index, "c", "{\"query\":\"x\"}"), sseFinish("tool_calls"), SSE_DONE),
                ),
            )
            http.enqueue(ScriptedResponse.sse(listOf(sseContent("second round"), sseFinish("stop"), SSE_DONE)))
            val rec = StreamRecorder()
            makeStreamClient(http, appScope(), tools = FakeTool())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
            assertTrue(rec.errors.isEmpty(), "index $index surfaced ${rec.errors}")
            assertEquals(listOf("second round"), rec.deltas, "index $index")
        }
    }

    /**
     * FINDING 5a. RN: `msg = typeof error === "string" ? error : error.message`
     * then `new Error(msg || "stream error")`, and `new Error` runs ToString on
     * a non-string argument.
     *
     * RN oracle (`probe56.ts`), left column is the `error` value:
     *
     *     {"message":42}          => "42"
     *     {"message":true}        => "true"
     *     {"message":[1,2]}       => "1,2"
     *     {"message":{"nested":1}}=> "[object Object]"
     *     {"message":0}           => "stream error"   (falsy)
     *     42 / true / [] / {}     => "stream error"   (no usable .message)
     *     "boom"                  => "boom"
     */
    @Test
    fun `non-string error messages are ToString-coerced like RN`() = runTest {
        val cases = listOf(
            "{\"message\":42}" to "42",
            "{\"message\":true}" to "true",
            "{\"message\":[1,2]}" to "1,2",
            "{\"message\":{\"nested\":1}}" to "[object Object]",
            "{\"message\":1e999}" to "Infinity",
            "{\"message\":0}" to "stream error",
            "{\"message\":false}" to "stream error",
            "{\"message\":null}" to "stream error",
            "{\"message\":\"\"}" to "stream error",
            "42" to "stream error",
            "true" to "stream error",
            "[]" to "stream error",
            "{}" to "stream error",
            "\"boom\"" to "boom",
        )
        for ((payload, expected) in cases) {
            val http = ScriptedHttp()
            http.enqueue(ScriptedResponse.sse(listOf("data: {\"error\":$payload}\n", SSE_DONE)))
            val rec = StreamRecorder()
            makeStreamClient(http, appScope())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
            assertEquals(listOf(expected), rec.errors, "error payload $payload")
        }
    }

    /**
     * PROBE on the path the fix does NOT take: a FALSY `chunk.error` is not an
     * error at all in RN (`if (chunk.error)`), so the stream completes.
     *
     * RN oracle (`probe56.ts`): `error=0` and `error=""` both give
     * `done: {"truncated":false,"dropped":false}` and no onError.
     */
    @Test
    fun `falsy error values are not errors`() = runTest {
        for (payload in listOf("0", "\"\"", "false", "null")) {
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf("data: {\"error\":$payload}\n", sseContent("ok"), sseFinish("stop"), SSE_DONE),
                ),
            )
            val rec = StreamRecorder()
            makeStreamClient(http, appScope())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
            assertTrue(rec.errors.isEmpty(), "error payload $payload must not throw")
            assertEquals(1, rec.doneInfos.size, "error payload $payload")
        }
    }

    /**
     * FINDING 5b. RN: `if (delta.content) { content += delta.content;
     * onDelta(delta.content) }` — a truthy guard, then string concatenation,
     * which coerces. Requiring a string dropped the delta entirely AND
     * shortened the assistant replay message in the next round's body.
     *
     * RN oracle (`probe56.ts`): content=5 → deltas [5]; content=0/false/null/""
     * → deltas []; and the round-2 assistant message carries `"content":"5"`.
     */
    @Test
    fun `non-string delta content is forwarded coerced`() = runTest {
        val cases = listOf(
            "5" to listOf("5"),
            "true" to listOf("true"),
            "{\"a\":1}" to listOf("[object Object]"),
            "[1,2]" to listOf("1,2"),
            "1e999" to listOf("Infinity"),
            "\"ok\"" to listOf("ok"),
            "0" to emptyList(),
            "false" to emptyList(),
            "null" to emptyList(),
            "\"\"" to emptyList<String>(),
        )
        for ((payload, expected) in cases) {
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf(
                        "data: {\"choices\":[{\"delta\":{\"content\":$payload}}]}\n",
                        sseFinish("stop"),
                        SSE_DONE,
                    ),
                ),
            )
            val rec = StreamRecorder()
            makeStreamClient(http, appScope())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
            assertEquals(expected, rec.deltas, "delta.content $payload")
            assertTrue(rec.errors.isEmpty(), "delta.content $payload")
        }
    }

    /**
     * The coerced content must also reach the WIRE as the assistant replay
     * message, which is where a dropped delta was observable to the model.
     *
     * RN oracle (`probe56.ts`, finding 5c):
     *     assistant.content in round 2 body: "5"
     */
    @Test
    fun `coerced content reaches the next round's body`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"choices\":[{\"delta\":{\"content\":5}}]}\n",
                    toolCallChunk("0", "c1", "{\"query\":\"q\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(userTurn, StreamRecorder().handlers(), StreamCancelToken())

        val assistant = http.requestBodies()[1]["messages"]?.arr!!
            .first { it["role"]?.str == "assistant" }
        assertEquals("5", assistant["content"]?.str)
    }

    /**
     * RN concatenates `arguments` fragments onto a STRING, so a non-string
     * fragment coerces rather than being dropped.
     *
     * RN oracle (`probe7.ts`): `{"arguments":9}` produces
     * `"function":{"name":7,"arguments":"9"}` on the wire.
     */
    @Test
    fun `non-string argument fragments coerce like string concat`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\"," +
                        "\"function\":{\"name\":\"web_search\",\"arguments\":9}}]}}]}\n",
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(userTurn, StreamRecorder().handlers(), StreamCancelToken())

        val assistant = http.requestBodies()[1]["messages"]?.arr!!
            .first { it["role"]?.str == "assistant" }
        assertEquals(
            "9",
            assistant["tool_calls"]?.get(0)?.get("function")?.get("arguments")?.str,
        )
    }

    /**
     * RN's `dropped` consults the RAW `finish_reason` for truthiness, not a
     * string. A truthy non-string one therefore means NOT dropped — and with no
     * content that is the difference between a clean `onDone` and a thrown
     * "stream dropped before any content arrived".
     *
     * RN oracle (`probe7.ts`):
     *     fr=42, no content, no [DONE] => done {"truncated":false,"dropped":false}
     *     fr="", no content, no [DONE] => error "stream dropped before any content arrived"
     */
    @Test
    fun `truthy non-string finish_reason means not dropped`() = runTest {
        for (fr in listOf("42", "true", "{\"a\":1}")) {
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf("data: {\"choices\":[{\"delta\":{},\"finish_reason\":$fr}]}\n"),
                ),
            )
            val rec = StreamRecorder()
            makeStreamClient(http, appScope())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
            assertTrue(rec.errors.isEmpty(), "finish_reason $fr surfaced ${rec.errors}")
            assertEquals(
                listOf(StreamEndInfo(truncated = false, dropped = false)),
                rec.doneInfos,
                "finish_reason $fr",
            )
        }
        // PROBE the other path: a FALSY finish_reason with no content and no
        // [DONE] is still a dropped stream.
        for (fr in listOf("\"\"", "0", "null", "false")) {
            val http = ScriptedHttp()
            http.enqueue(
                ScriptedResponse.sse(
                    listOf("data: {\"choices\":[{\"delta\":{},\"finish_reason\":$fr}]}\n"),
                ),
            )
            val rec = StreamRecorder()
            makeStreamClient(http, appScope())
                .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
            assertEquals(
                listOf("stream dropped before any content arrived"),
                rec.errors,
                "finish_reason $fr",
            )
        }
        // And a truthy STRING finish_reason still drives truncated.
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("a"), sseFinish("length"))))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope())
            .streamScreen(userTurn, rec.handlers(), StreamCancelToken())
        assertEquals(listOf(StreamEndInfo(truncated = true, dropped = false)), rec.doneInfos)
    }
}

/** Finding 3: ES2019 well-formed JSON.stringify, and finding 6's pinned divergence. */
class WellFormedStringifyTest {
    /**
     * FINDING 3. ES2019 well-formed `JSON.stringify` ESCAPES an unpaired
     * surrogate rather than encoding it. A JVM `String` holds the lone unit
     * (this port keeps RN's parse behavior verbatim), so emitting it raw made
     * `toByteArray(UTF_8)` substitute `?` (0x3F) and a round-2 body diverged
     * from RN's bytes.
     *
     * node:
     *
     *     $ node -e 'for (const s of ["pre\ud83dpost","pre\udca9post","\udca9\ud83d","pre\ud83d","\ud83dx\udca9","pre\u{1F4A9}post"])
     *                console.log(JSON.stringify(s), Buffer.from(JSON.stringify(s)).toString("hex"))'
     *     "pre\ud83dpost"   227072655c7564383364706f737422
     *     "pre\udca9post"   227072655c7564636139706f737422
     *     "\udca9\ud83d"    225c75646361395c756438336422
     *     "pre\ud83d"       227072655c756438336422
     *     "\ud83dx\udca9"   225c7564383364785c756463613922
     *     "pre💩post"       22707265f09f92a9706f737422
     */
    @Test
    fun `unpaired surrogates are escaped, pairs pass through`() {
        val cases = listOf(
            "pre\uD83Dpost" to "227072655c7564383364706f737422",
            "pre\uDCA9post" to "227072655c7564636139706f737422",
            "\uDCA9\uD83D" to "225c75646361395c756438336422",
            "pre\uD83D" to "227072655c756438336422",
            "\uD83Dx\uDCA9" to "225c7564383364785c756463613922",
            // A WELL-FORMED pair is emitted as the astral character itself.
            "pre💩post" to "22707265f09f92a9706f737422",
        )
        for ((input, expectedHex) in cases) {
            val bytes = JsonValue.Str(input).stringified().toByteArray(Charsets.UTF_8)
            assertEquals(
                expectedHex,
                bytes.joinToString("") { "%02x".format(it) },
                "stringify(${input.map { it.code.toString(16) }})",
            )
        }
    }

    /**
     * End-to-end: a lone surrogate arriving in a content delta must reach the
     * next round's REQUEST BYTES as RN's escape, not as `?`.
     *
     *     $ node -e 'console.log(JSON.stringify({role:"assistant",content:"pre\ud83dpost"}))'
     *     {"role":"assistant","content":"pre\ud83dpost"}
     */
    @Test
    fun `a lone surrogate delta reaches the wire as RN's escape`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"pre\\ud83dpost\"}}]}\n",
                    toolCallChunk("0", "c1", "{\"query\":\"q\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(userTurn, StreamRecorder().handlers(), StreamCancelToken())

        val raw = http.requests[1].body!!.toString(Charsets.UTF_8)
        assertTrue(
            raw.contains("\"content\":\"pre\\ud83dpost\""),
            "round-2 body must carry RN's escape, got: ${raw.take(400)}",
        )
        // The `?` substitution must be gone: no 0x3F anywhere near the content.
        assertTrue(
            !raw.contains("\"content\":\"pre?post\""),
            "the JVM UTF-8 `?` substitution is still on the wire",
        )
    }

    /**
     * FINDING 6. RN's SUCCESS path calls `onDone` unconditionally; only the
     * catch path checks `signal.aborted`. Both ports additionally suppress
     * `onDelta`/`onDone` once the token is cancelled.
     *
     * RN oracle (`probe56.ts`), aborting during the first delta with a
     * transport that ignores the signal:
     *
     *     delta:a | ABORTED | delta:b | done:{"truncated":false,"dropped":false}
     *
     * The ports stop after `delta:a`. This is DOCUMENTED, not fixed, in both
     * READMEs; the test pins it so the divergence cannot drift silently.
     */
    @Test
    fun `cancel suppresses later handlers unlike RN's success path`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(listOf(sseContent("a"), sseContent("b"), sseFinish("stop"), SSE_DONE)),
        )
        val token = StreamCancelToken()
        val seen = mutableListOf<String>()
        val handlers = StreamHandlers(
            onDelta = {
                seen.add("delta:$it")
                if (it == "a") token.cancel()
            },
            onDone = { seen.add("done") },
            onError = { seen.add("error:${it.message}") },
        )
        makeStreamClient(http, appScope()).streamScreen(userTurn, handlers, token)
        // RN would be [delta:a, delta:b, done].
        assertEquals(listOf("delta:a"), seen, "cancel must suppress every later handler")

        // PROBE the path the guard does NOT take: without a cancel the same
        // script delivers everything, so the guard is not simply swallowing.
        val http2 = ScriptedHttp()
        http2.enqueue(
            ScriptedResponse.sse(listOf(sseContent("a"), sseContent("b"), sseFinish("stop"), SSE_DONE)),
        )
        val seen2 = mutableListOf<String>()
        val handlers2 = StreamHandlers(
            onDelta = { seen2.add("delta:$it") },
            onDone = { seen2.add("done") },
            onError = { seen2.add("error:${it.message}") },
        )
        makeStreamClient(http2, appScope())
            .streamScreen(userTurn, handlers2, StreamCancelToken())
        assertEquals(listOf("delta:a", "delta:b", "done"), seen2)
    }
}
