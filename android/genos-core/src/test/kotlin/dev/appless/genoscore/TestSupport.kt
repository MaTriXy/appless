package dev.appless.genoscore

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestScope
import kotlin.coroutines.coroutineContext

// Manual clock

/** Deterministic [GenOSClock]: time only moves when a test moves it. */
class ManualClock : GenOSClock {
    var nowMs: Double = 0.0
        private set

    private var nextToken = 0
    private val scheduled = mutableListOf<Entry>()

    private class Entry(val id: Int, val at: Double, val work: () -> Unit)

    override val now: Double
        get() = nowMs

    override fun schedule(afterMs: Double, work: () -> Unit): GenOSCancellable {
        val id = ++nextToken
        scheduled.add(Entry(id, nowMs + afterMs, work))
        return object : GenOSCancellable {
            override fun cancel() {
                scheduled.removeAll { it.id == id }
            }
        }
    }

    /** Advance time, firing due callbacks in schedule order. */
    fun advance(byMs: Double) {
        val target = nowMs + byMs
        while (true) {
            val next = scheduled.filter { it.at <= target }.minByOrNull { it.at } ?: break
            scheduled.removeAll { it.id == next.id }
            nowMs = maxOf(nowMs, next.at)
            next.work()
        }
        nowMs = target
    }

    /** Move the reading without firing anything (staleness tests). */
    fun jump(toMs: Double) {
        nowMs = toMs
    }

    val pendingCount: Int
        get() = scheduled.size
}

// In-memory secure store with gated reads/writes

/**
 * [SecureStore] test double. [gateReads] blocks reads until [releaseReads] so
 * tests can interleave user input with hydration; [gateWrites] blocks writes
 * until [releaseWrites] to simulate a hung keychain write. [failReads] makes the
 * read throw.
 */
class MemorySecureStore : SecureStore {
    val values = LinkedHashMap<String, String>()
    val writtenKeys = mutableListOf<String>()

    private var readGate: CompletableDeferred<Unit>? = null
    private var writeGate: CompletableDeferred<Unit>? = null
    var failReads: Boolean = false

    fun seed(key: String, value: String) {
        values[key] = value
    }

    fun gateReads() {
        readGate = CompletableDeferred()
    }

    fun releaseReads() {
        readGate?.complete(Unit)
        readGate = null
    }

    fun gateWrites() {
        writeGate = CompletableDeferred()
    }

    fun releaseWrites() {
        writeGate?.complete(Unit)
        writeGate = null
    }

    override suspend fun read(key: String): String? {
        readGate?.await()
        if (failReads) throw StreamException("keychain unavailable")
        return values[key]
    }

    override suspend fun write(key: String, value: String?) {
        writeGate?.await()
        writtenKeys.add(key)
        if (value == null) values.remove(key) else values[key] = value
    }
}

// Scripted HTTP

/**
 * One scripted streaming response: a status plus SSE body byte chunks delivered
 * exactly as scripted (chunk boundaries preserved).
 */
class ScriptedResponse(
    val status: Int = 200,
    val chunks: List<ByteArray> = emptyList(),
    /** Error thrown from the byte stream after the chunks (network failure). */
    val streamErrorMessage: String? = null,
    /** Non-stream body for error statuses (`res.text()`). */
    val errorBody: String = "",
) {
    companion object {
        fun sse(lines: List<String>, status: Int = 200): ScriptedResponse =
            ScriptedResponse(status = status, chunks = lines.map { it.toByteArray(Charsets.UTF_8) })

        fun bytes(chunks: List<ByteArray>, status: Int = 200): ScriptedResponse =
            ScriptedResponse(status = status, chunks = chunks)

        fun json(text: String, status: Int = 200): ScriptedResponse =
            ScriptedResponse(status = status, chunks = listOf(text.toByteArray(Charsets.UTF_8)))
    }
}

/**
 * Pull-based scripted transport. Chunks are handed out one per collector demand
 * and coroutine cancellation is honored between them, so tests can assert a
 * cancelled stream loop stops pulling. [gateAfterChunk] suspends the flow before
 * the Nth chunk until [releaseGate], giving deterministic mid-stream interleaving.
 */
class ScriptedHttp : HttpStreaming, HttpFetching {
    private val responses = ArrayDeque<ScriptedResponse>()
    val requests = mutableListOf<HttpRequest>()
    var chunksPulled: Int = 0
        private set

    var gateAfterChunk: Int? = null
    private var gate = CompletableDeferred<Unit>()

    fun releaseGate() {
        gate.complete(Unit)
    }

    fun enqueue(r: ScriptedResponse) {
        responses.addLast(r)
    }

    /** Parsed JSON bodies of every request seen, oldest first. */
    fun requestBodies(): List<JsonValue> = requests.mapNotNull { JsonValue.parse(it.bodyText) }

    override suspend fun stream(request: HttpRequest): Pair<HttpResponseHead, Flow<ByteArray>> {
        requests.add(request)
        val scripted = responses.removeFirstOrNull() ?: throw StreamException("no scripted response")
        val head = HttpResponseHead(scripted.status)
        // For error statuses the RN reference reads the body via res.text();
        // surface errorBody through the byte stream so the client's
        // drain-and-decode path sees it.
        val chunks = if (!head.ok && scripted.chunks.isEmpty() && scripted.errorBody.isNotEmpty()) {
            listOf(scripted.errorBody.toByteArray(Charsets.UTF_8))
        } else {
            scripted.chunks
        }
        val body = flow {
            chunks.forEachIndexed { i, chunk ->
                coroutineContext.ensureActive()
                gateAfterChunk?.let { if (i >= it) gate.await() }
                chunksPulled++
                emit(chunk)
            }
            scripted.streamErrorMessage?.let { throw StreamException(it) }
        }
        return head to body
    }

    override suspend fun fetch(request: HttpRequest): Pair<HttpResponseHead, ByteArray> {
        requests.add(request)
        val scripted = responses.removeFirstOrNull() ?: throw StreamException("no scripted response")
        var body = ByteArray(0)
        for (c in scripted.chunks) body += c
        if (body.isEmpty()) body = scripted.errorBody.toByteArray(Charsets.UTF_8)
        return HttpResponseHead(scripted.status) to body
    }
}

/** An [HttpFetching] whose fetch never returns (hung network). */
class HangingHttp : HttpFetching {
    val requests = mutableListOf<HttpRequest>()
    private val never = CompletableDeferred<Unit>()

    override suspend fun fetch(request: HttpRequest): Pair<HttpResponseHead, ByteArray> {
        requests.add(request)
        never.await()
        error("unreachable")
    }
}

// Fake screen streamer (controller tests)

/** Records every stream start; the test drives the handlers manually. */
class FakeStreamer : ScreenStreaming {
    class Started(
        val messages: List<ChatMessage>,
        val handlers: StreamHandlers,
        val token: StreamCancelToken,
    )

    val started = mutableListOf<Started>()

    override fun stream(
        messages: List<ChatMessage>,
        handlers: StreamHandlers,
        token: StreamCancelToken,
    ) {
        started.add(Started(messages, handlers, token))
    }

    val last: Started?
        get() = started.lastOrNull()

    val count: Int
        get() = started.size
}

/**
 * A [ScreenStreaming] impl that fires its handlers SYNCHRONOUSLY inside
 * `stream()` — the regression double for the RN inflight-before-stream ordering
 * (a synchronous delta must not be dropped as stale).
 */
class SyncFiringStreamer : ScreenStreaming {
    var deltas: List<String> = listOf("sync delta")
    var finish: Boolean = true

    override fun stream(
        messages: List<ChatMessage>,
        handlers: StreamHandlers,
        token: StreamCancelToken,
    ) {
        for (d in deltas) handlers.onDelta(d)
        if (finish) handlers.onDone(StreamEndInfo(truncated = false, dropped = false))
    }
}

// SSE payload builders

private fun jsonEscape(text: String): String = text
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
    .replace("\n", "\\n")

fun sseContent(text: String): String =
    "data: {\"choices\":[{\"delta\":{\"content\":\"${jsonEscape(text)}\"}}]}\n"

fun sseFinish(reason: String): String =
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"$reason\"}]}\n"

const val SSE_DONE: String = "data: [DONE]\n"

/** Whole-call style tool-call chunk (Cerebras): id + name + full arguments at once. */
fun sseWholeToolCall(index: Int, id: String, name: String, arguments: String): String =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":$index,\"id\":\"$id\"," +
        "\"function\":{\"name\":\"$name\",\"arguments\":\"${jsonEscape(arguments)}\"}}]}}]}\n"

/** Split-arguments style fragment (OpenAI): only an `arguments` fragment. */
fun sseArgsFragment(index: Int, fragment: String): String =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":$index," +
        "\"function\":{\"arguments\":\"${jsonEscape(fragment)}\"}}]}}]}\n"

// Stream test harness

/** Collected callback activity from one `streamScreen` run. */
class StreamRecorder {
    val deltas = mutableListOf<String>()
    val doneInfos = mutableListOf<StreamEndInfo>()
    val errors = mutableListOf<String>()
    val toolRounds = mutableListOf<List<ToolRoundCall>>()
    var toolDecision: ToolRoundDecision = ToolRoundDecision.PROCEED
    var onDeltaHook: ((String) -> Unit)? = null

    fun handlers(): StreamHandlers = StreamHandlers(
        onDelta = {
            deltas.add(it)
            onDeltaHook?.invoke(it)
        },
        onDone = { doneInfos.add(it) },
        onError = { errors.add((it as? StreamException)?.message ?: it.toString()) },
        onToolRound = {
            toolRounds.add(it)
            toolDecision
        },
    )

    val content: String
        get() = deltas.joinToString("")
}

/** An always-available fake tool executor with scripted outputs. */
class FakeTool(
    var availableFlag: Boolean = true,
    var output: (String, Map<String, JsonValue>) -> String = { name, args ->
        "TOOL($name):${args["query"]?.str ?: ""}"
    },
) : ToolExecuting {
    val executed = mutableListOf<Pair<String, Map<String, JsonValue>>>()

    override val available: Boolean
        get() = availableFlag

    override val promptSection: String
        get() = "\n\n## Tools available"

    override val toolDefs: JsonValue
        get() = JsonValue.Arr(
            listOf(
                JsonValue.obj(
                    "type" to JsonValue.Str("function"),
                    "function" to JsonValue.obj(
                        "name" to JsonValue.Str("web_search"),
                        "description" to JsonValue.Str("Search the live web."),
                        "parameters" to JsonValue.obj(
                            "type" to JsonValue.Str("object"),
                            "properties" to JsonValue.obj(
                                "query" to JsonValue.obj("type" to JsonValue.Str("string")),
                            ),
                            "required" to JsonValue.Arr(listOf(JsonValue.Str("query"))),
                        ),
                    ),
                ),
            ),
        )

    override suspend fun execute(name: String, args: Map<String, JsonValue>): String {
        executed.add(name to args)
        return output(name, args)
    }
}

fun makeKeyStore(
    envKey: String? = "test-key",
    store: MemorySecureStore = MemorySecureStore(),
    scope: CoroutineScope,
): KeyStore = KeyStore(envKey, store, scope)

fun makeStreamClient(
    http: ScriptedHttp,
    scope: CoroutineScope,
    keyStore: KeyStore? = null,
    tools: ToolExecuting? = null,
    systemPrompt: String = "SYSTEM",
    today: String = "Friday, July 25, 2026",
): StreamClient = StreamClient(
    http = http,
    keyStore = keyStore ?: makeKeyStore(scope = scope),
    config = StreamConfig(systemPrompt = systemPrompt, todayString = { today }),
    tools = tools,
    scope = scope,
)

// Controller harness

class ControllerHarness(apps: List<AppDef> = emptyList()) {
    val clock = ManualClock()
    val streamer = FakeStreamer()
    val store = ScreenStore(clock)
    val controller = GenOSController(store, streamer, clock, apps)

    /** Finish the most recent stream with plain content. */
    fun finishLast(content: String, truncated: Boolean = false) {
        val s = streamer.last ?: return
        s.handlers.onDelta(content)
        s.handlers.onDone(StreamEndInfo(truncated = truncated, dropped = false))
    }
}

val sampleApp: AppDef = AppDef(
    id = "weather",
    name = "Weather",
    emoji = "⛅",
    tileStart = "#5ac8fa",
    tileEnd = "#007aff",
    request = "Open the \"Weather\" app home screen.",
)

/**
 * A coroutine scope on the test dispatcher that `runTest` does NOT wait for.
 *
 * `runTest`'s own `backgroundScope` is deliberately excluded from
 * `advanceUntilIdle` (foreground work only), so a fire-and-forget persist or a
 * detached stream launched into it would never run inside an assertion window.
 * Reusing the test's context with a FRESH `Job` keeps the tasks foreground —
 * `advanceUntilIdle()` drains them — while detaching them from the test's job so
 * a deliberately hung coroutine cannot stall the test.
 */
fun TestScope.appScope(): CoroutineScope = CoroutineScope(coroutineContext + Job())
