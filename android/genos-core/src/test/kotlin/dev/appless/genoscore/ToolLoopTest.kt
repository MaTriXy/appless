package dev.appless.genoscore

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val ask = listOf(ChatMessage(ChatRole.USER, "hotels in goa"))

/** src/genos/stream.ts streamScreen: the real tool-calling loop. */
class ToolLoopTest {
    @Test
    fun `whole-call style round-trips through the tool loop`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseWholeToolCall(0, "call_1", "web_search", "{\"query\":\"goa hotels\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("root = Card()"), sseFinish("stop"), SSE_DONE)))

        val tool = FakeTool()
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = tool)
            .streamScreen(ask, rec.handlers(), StreamCancelToken())

        assertEquals("root = Card()", rec.content)
        assertEquals(1, rec.doneInfos.size)
        val expectedArgs: Map<String, JsonValue> = mapOf("query" to JsonValue.Str("goa hotels"))
        assertEquals(listOf(ToolRoundCall("web_search", expectedArgs)), rec.toolRounds.single())
        assertEquals(listOf<Pair<String, Map<String, JsonValue>>>("web_search" to expectedArgs), tool.executed.toList())

        // The second request replays assistant(tool_calls) + tool(result).
        val second = JsonValue.parse(http.requests[1].bodyText)!!["messages"]!!.arr!!
        assertEquals(4, second.size)
        assertEquals("assistant", second[2]["role"]?.str)
        assertEquals(JsonValue.Null, second[2]["content"])
        val calls = second[2]["tool_calls"]!!.arr!!
        assertEquals("call_1", calls[0]["id"]?.str)
        assertEquals("function", calls[0]["type"]?.str)
        assertEquals("web_search", calls[0]["function"]?.get("name")?.str)
        assertEquals("{\"query\":\"goa hotels\"}", calls[0]["function"]?.get("arguments")?.str)
        assertEquals("tool", second[3]["role"]?.str)
        assertEquals("call_1", second[3]["tool_call_id"]?.str)
        assertEquals("TOOL(web_search):goa hotels", second[3]["content"]?.str)
    }

    @Test
    fun `the tool message key order matches the RN object literal`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseWholeToolCall(0, "c1", "web_search", "{}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("ok"), SSE_DONE)))
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, StreamRecorder().handlers(), StreamCancelToken())
        // RN builds {role, tool_call_id, content} in that order.
        assertTrue(
            http.requests[1].bodyText.contains(
                "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"TOOL(web_search):\"}",
            ),
        )
    }

    @Test
    fun `split arguments fragments accumulate by index`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\"," +
                        "\"function\":{\"name\":\"web_search\",\"arguments\":\"\"}}]}}]}\n",
                    sseArgsFragment(0, "{\"que"),
                    sseArgsFragment(0, "ry\":\"live "),
                    sseArgsFragment(0, "scores\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("done"), SSE_DONE)))
        val tool = FakeTool()
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = tool)
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        val expectedArgs: Map<String, JsonValue> = mapOf("query" to JsonValue.Str("live scores"))
        assertEquals(listOf(ToolRoundCall("web_search", expectedArgs)), rec.toolRounds.single())
    }

    @Test
    fun `multiple calls are sorted by index and each gets a tool message`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    // Arriving out of order: index 1 first.
                    sseWholeToolCall(1, "c2", "web_search", "{\"query\":\"second\"}"),
                    sseWholeToolCall(0, "c1", "web_search", "{\"query\":\"first\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("ok"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())

        assertEquals(
            listOf("first", "second"),
            rec.toolRounds.single().map { it.args["query"]?.str },
        )
        val messages = JsonValue.parse(http.requests[1].bodyText)!!["messages"]!!.arr!!
        assertEquals(5, messages.size)
        assertEquals(listOf("c1", "c2"), messages[2]["tool_calls"]!!.arr!!.map { it["id"]?.str })
        assertEquals("c1", messages[3]["tool_call_id"]?.str)
        assertEquals("TOOL(web_search):first", messages[3]["content"]?.str)
        assertEquals("c2", messages[4]["tool_call_id"]?.str)
        assertEquals("TOOL(web_search):second", messages[4]["content"]?.str)
    }

    @Test
    fun `a tool-call delta with no index defaults to zero`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"c1\"," +
                        "\"function\":{\"name\":\"web_search\"}}]}}]}\n",
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":" +
                        "{\"arguments\":\"{\\\"query\\\":\\\"noidx\\\"}\"}}]}}]}\n",
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("ok"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        assertEquals("noidx", rec.toolRounds.single().single().args["query"]?.str)
    }

    @Test
    fun `malformed arguments become an empty object`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseWholeToolCall(0, "c1", "web_search", "{not json"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("ok"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        assertEquals(emptyMap<String, JsonValue>(), rec.toolRounds.single().single().args)
    }

    @Test
    fun `absent arguments parse as an empty object`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\"," +
                        "\"function\":{\"name\":\"web_search\"}}]}}]}\n",
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("ok"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        assertEquals(emptyMap<String, JsonValue>(), rec.toolRounds.single().single().args)
    }

    @Test
    fun `an abort decision throws NEEDS_LIVE_DATA`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseWholeToolCall(0, "c1", "web_search", "{\"query\":\"q\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        val tool = FakeTool()
        val rec = StreamRecorder()
        rec.toolDecision = ToolRoundDecision.ABORT
        makeStreamClient(http, appScope(), tools = tool)
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("needs live data"), rec.errors)
        assertTrue(rec.doneInfos.isEmpty())
        assertTrue(tool.executed.isEmpty(), "no quota burned")
        assertEquals(1, http.requests.size)
    }

    @Test
    fun `MAX_TOOL_ROUNDS withholds tools to force a screen`() = runTest {
        val http = ScriptedHttp()
        // Four consecutive tool_calls rounds; the 4th request must carry no tools.
        repeat(4) { i ->
            http.enqueue(
                ScriptedResponse.sse(
                    listOf(
                        sseWholeToolCall(0, "c$i", "web_search", "{\"query\":\"q$i\"}"),
                        sseFinish("tool_calls"),
                        SSE_DONE,
                    ),
                ),
            )
        }
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("finally"), sseFinish("stop"), SSE_DONE)))

        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())

        val bodies = http.requestBodies()
        assertTrue(bodies.size >= 4)
        assertTrue(bodies[0]["tools"] != null, "round 0 offers tools")
        assertTrue(bodies[1]["tools"] != null, "round 1 offers tools")
        assertTrue(bodies[2]["tools"] != null, "round 2 offers tools")
        assertNull(bodies[3]["tools"], "round 3 is past MAX_TOOL_ROUNDS")
    }

    @Test
    fun `an unavailable tool executor never offers tools`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("x"), sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), tools = FakeTool(availableFlag = false))
            .streamScreen(ask, StreamRecorder().handlers(), StreamCancelToken())
        assertNull(http.requestBodies().single()["tools"])
    }

    @Test
    fun `content before tool calls is forwarded and replayed as assistant content`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseContent("thinking..."),
                    sseWholeToolCall(0, "c1", "web_search", "{\"query\":\"q\"}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("screen"), sseFinish("stop"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        assertEquals(listOf("thinking...", "screen"), rec.deltas)
        val messages = JsonValue.parse(http.requests[1].bodyText)!!["messages"]!!.arr!!
        assertEquals("thinking...", messages[2]["content"]?.str)
    }

    @Test
    fun `a tool_calls finish reason with zero calls is a content finish`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("body"), sseFinish("tool_calls"), SSE_DONE)))
        val rec = StreamRecorder()
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        assertEquals(1, rec.doneInfos.size)
        assertTrue(rec.toolRounds.isEmpty())
        assertEquals(1, http.requests.size)
    }

    @Test
    fun `with no tool executor a tool round degrades to an unknown-tool message`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.sse(
                listOf(
                    sseWholeToolCall(0, "c1", "mystery", "{}"),
                    sseFinish("tool_calls"),
                    SSE_DONE,
                ),
            ),
        )
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("ok"), SSE_DONE)))
        val rec = StreamRecorder()
        // tools == null: toolsAvailable is false, but a provider can still send
        // tool calls; the loop must not crash.
        makeStreamClient(http, appScope(), tools = null)
            .streamScreen(ask, rec.handlers(), StreamCancelToken())
        val messages = JsonValue.parse(http.requests[1].bodyText)!!["messages"]!!.arr!!
        assertEquals("ERROR: unknown tool \"mystery\"", messages.last()["content"]?.str)
    }

    @Test
    fun `the system prompt includes the tools section only when available`() = runTest {
        val http = ScriptedHttp()
        val withTools = makeStreamClient(http, appScope(), tools = FakeTool())
        assertEquals(
            "SYSTEM\n\n## Tools available\n\nToday is Friday, July 25, 2026.",
            withTools.systemPrompt(),
        )
        val withoutTools = makeStreamClient(http, appScope(), tools = FakeTool(availableFlag = false))
        assertEquals("SYSTEM\n\nToday is Friday, July 25, 2026.", withoutTools.systemPrompt())
        val noneAtAll = makeStreamClient(http, appScope(), tools = null)
        assertEquals("SYSTEM\n\nToday is Friday, July 25, 2026.", noneAtAll.systemPrompt())
    }

    @Test
    fun `every round replays the accumulated conversation`() = runTest {
        val http = ScriptedHttp()
        repeat(2) { i ->
            http.enqueue(
                ScriptedResponse.sse(
                    listOf(
                        sseWholeToolCall(0, "c$i", "web_search", "{\"query\":\"q$i\"}"),
                        sseFinish("tool_calls"),
                        SSE_DONE,
                    ),
                ),
            )
        }
        http.enqueue(ScriptedResponse.sse(listOf(sseContent("done"), sseFinish("stop"), SSE_DONE)))
        makeStreamClient(http, appScope(), tools = FakeTool())
            .streamScreen(ask, StreamRecorder().handlers(), StreamCancelToken())
        val sizes = http.requestBodies().map { it["messages"]!!.arr!!.size }
        // system+user, then +assistant+tool each round.
        assertEquals(listOf(2, 4, 6), sizes)
    }
}
