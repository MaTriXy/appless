package dev.appless.genoscore

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * One tool call surfaced to `onToolRound`, arguments already JSON-parsed
 * (malformed arguments → empty object).
 */
public data class ToolRoundCall(val name: String, val args: Map<String, JsonValue>)

public enum class ToolRoundDecision {
    /** Execute the calls and stream the next round. */
    PROCEED,

    /** Refuse execution (speculative prefetch) → the stream errors NEEDS_LIVE_DATA. */
    ABORT,
}

/** Callbacks for one screen generation (src/genos/stream.ts `StreamHandlers`). */
public class StreamHandlers(
    public val onDelta: (String) -> Unit,
    public val onDone: (StreamEndInfo) -> Unit,
    public val onError: (Throwable) -> Unit,
    public val onToolRound: ((List<ToolRoundCall>) -> ToolRoundDecision)? = null,
)

/** Errors this package raises; `message` is what the shell shows. */
public class StreamException(message: String) : Exception(message)

/**
 * `AbortController` analog. Cancelling suppresses all further callbacks AND
 * tears down the in-flight work: the stream loop runs inside a coroutine
 * retained by the token, and [cancel] cancels that coroutine so the SSE drain
 * and any running tool execution stop (mirroring RN's AbortController aborting
 * the fetch and the Exa call).
 */
public class StreamCancelToken {
    public var isCancelled: Boolean = false
        private set

    private var job: Job? = null

    /**
     * Bind the running stream coroutine. If the token was already cancelled the
     * job is cancelled immediately.
     */
    public fun attach(job: Job) {
        this.job = job
        if (isCancelled) job.cancel()
    }

    public fun cancel() {
        isCancelled = true
        job?.cancel()
    }

    /** Await the underlying stream coroutine settling (teardown/test aid). */
    public suspend fun join() {
        job?.join()
    }
}

/**
 * Stream seam the controller uses; [StreamClient] is the production impl, tests
 * inject a scripted fake.
 *
 * The caller creates the token and registers it (e.g. in its inflight map)
 * BEFORE calling [stream], mirroring RN's `inflight.set(id, controller)` then
 * `streamScreen(...)` ordering — so even an implementation that fires handlers
 * synchronously is never dropped as stale.
 */
public interface ScreenStreaming {
    /**
     * Start a full tool-loop generation bound to [token]. Implementations must
     * stop consuming and stop calling handlers once the token is cancelled.
     */
    public fun stream(messages: List<ChatMessage>, handlers: StreamHandlers, token: StreamCancelToken)
}

/** Convenience: create the token, start the stream, return the handle. */
public fun ScreenStreaming.stream(
    messages: List<ChatMessage>,
    handlers: StreamHandlers,
): StreamCancelToken {
    val token = StreamCancelToken()
    stream(messages, handlers, token)
    return token
}

public class StreamConfig(
    public val baseURL: String = GenOSConstants.DEFAULT_BASE_URL,
    public val model: String = GenOSConstants.DEFAULT_MODEL,
    /** Build-time system prompt embed (`SYSTEM_PROMPT` analog). */
    public val systemPrompt: String = "",
    /** "Weekday, Month D, YYYY" (en-US long) for the "Today is ..." line. */
    public val todayString: () -> String = defaultTodayString,
) {
    public companion object {
        /**
         * Fail-safe default: the RN `systemPrompt` date (src/genos/stream.ts) —
         * `new Date().toLocaleDateString("en-US", { weekday: "long", year:
         * "numeric", month: "long", day: "numeric" })` — e.g.
         * "Friday, July 25, 2026". `Locale.US` pins the English weekday/month
         * names regardless of device locale; the device's current time zone is
         * kept, matching `toLocaleDateString`'s local-time behavior.
         */
        public val defaultTodayString: () -> String = {
            LocalDate.now().format(DateTimeFormatter.ofPattern("EEEE, MMMM d, yyyy", Locale.US))
        }
    }
}

/**
 * Incremental UTF-8 decoding: a byte-for-byte port of the WHATWG Encoding
 * Standard's utf-8 decoder state machine (https://encoding.spec.whatwg.org/#utf-8-decoder),
 * which is exactly the algorithm `new TextDecoder()` runs with `{stream: true}`
 * and `fatal: false` — the RN reference's decoder (stream.ts `createUtf8Decoder`).
 *
 * Porting the state machine rather than approximating it with a tail scan makes
 * emission timing AND totals match `TextDecoder` for EVERY input by
 * construction: valid sequences, invalid lead bytes, out-of-range continuation
 * bytes (overlong C0/C1, surrogate ED A0, out-of-range F4 90), stray
 * continuations, and any chunk boundary.
 *
 * `String(bytes, UTF_8)` cannot be used: it is not incremental, and its
 * malformed-input substitution differs from the spec's in how many U+FFFD it
 * emits for a truncated sequence.
 */
internal class Utf8StreamDecoder {
    private var codePoint = 0
    private var bytesSeen = 0
    private var bytesNeeded = 0
    private var lowerBoundary = 0x80
    private var upperBoundary = 0xBF

    fun decode(data: ByteArray): String {
        val out = StringBuilder(data.size)
        var i = 0
        while (i < data.size) {
            val byte = data[i].toInt() and 0xFF
            i++

            if (bytesNeeded == 0) {
                when {
                    byte <= 0x7F -> out.append(Char(byte))
                    byte in 0xC2..0xDF -> {
                        bytesNeeded = 1
                        codePoint = byte and 0x1F
                    }
                    byte in 0xE0..0xEF -> {
                        if (byte == 0xE0) lowerBoundary = 0xA0
                        if (byte == 0xED) upperBoundary = 0x9F
                        bytesNeeded = 2
                        codePoint = byte and 0x0F
                    }
                    byte in 0xF0..0xF4 -> {
                        if (byte == 0xF0) lowerBoundary = 0x90
                        if (byte == 0xF4) upperBoundary = 0x8F
                        bytesNeeded = 3
                        codePoint = byte and 0x07
                    }
                    // Invalid lead (C0, C1, F5-FF, stray continuation): error
                    // now, no holdback.
                    else -> out.append(REPLACEMENT)
                }
                continue
            }

            if (byte < lowerBoundary || byte > upperBoundary) {
                // Spec: reset state, emit an error, and PREPEND the offending
                // byte back onto the stream so it is re-processed as a lead.
                codePoint = 0
                bytesNeeded = 0
                bytesSeen = 0
                lowerBoundary = 0x80
                upperBoundary = 0xBF
                out.append(REPLACEMENT)
                i--
                continue
            }

            lowerBoundary = 0x80
            upperBoundary = 0xBF
            codePoint = (codePoint shl 6) or (byte and 0x3F)
            bytesSeen++
            if (bytesSeen != bytesNeeded) continue

            val scalar = codePoint
            codePoint = 0
            bytesNeeded = 0
            bytesSeen = 0
            if (scalar <= 0xFFFF) {
                out.append(Char(scalar))
            } else {
                val u = scalar - 0x10000
                out.append(Char(0xD800 + (u shr 10)))
                out.append(Char(0xDC00 + (u and 0x3FF)))
            }
        }
        return out.toString()
    }

    private companion object {
        const val REPLACEMENT = '\uFFFD'
    }
}

/**
 * Direct Cerebras streaming (OpenAI-compatible chat completions) with the real
 * tool-calling loop (src/genos/stream.ts `streamScreen`/`streamRound`): SSE
 * "data:" line protocol, `[DONE]` sentinel, tool-call delta accumulation by
 * index (whole-call and split-arguments styles), MAX_TOOL_ROUNDS budget,
 * 401/403 → `keyStore.markRejected`, dropped-stream detection.
 */
public class StreamClient(
    private val http: HttpStreaming,
    private val keyStore: KeyStore,
    private val config: StreamConfig,
    private val tools: ToolExecuting?,
    private val scope: CoroutineScope,
) : ScreenStreaming {

    private val toolsAvailable: Boolean
        get() = tools?.available ?: false

    /** System prompt + optional tools section + today's date line. */
    public fun systemPrompt(): String {
        val toolsSection = if (toolsAvailable) tools?.promptSection.orEmpty() else ""
        return config.systemPrompt + toolsSection + "\n\nToday is ${config.todayString()}."
    }

    private enum class RoundFinish { CONTENT, TOOL_CALLS }

    private class RoundResult(
        val finish: RoundFinish,
        val content: String,
        val toolCalls: List<ToolCall>,
        val info: StreamEndInfo,
    )

    /**
     * One streamed completion. Content deltas are forwarded live; tool-call
     * deltas are accumulated by index (whole-call and split-arguments styles).
     */
    private suspend fun streamRound(
        convo: List<ChatMessage>,
        includeTools: Boolean,
        token: StreamCancelToken,
        onDelta: (String) -> Unit,
    ): RoundResult {
        // RN: `if (!apiKey) throw` — a JS falsy check, so an EMPTY key
        // (whitespace-only set()) errors locally too; no request with a blank
        // bearer goes out.
        val apiKey = keyStore.get()
        if (apiKey.isNullOrEmpty()) throw StreamException("No Cerebras API key set")

        val body = LinkedHashMap<String, JsonValue>()
        body["model"] = JsonValue.Str(config.model)
        body["messages"] = JsonValue.Arr(
            listOf(messageJson(ChatMessage(ChatRole.SYSTEM, systemPrompt()))) +
                convo.map { messageJson(it) },
        )
        if (includeTools && tools != null) body["tools"] = tools.toolDefs
        body["stream"] = JsonValue.Bool(true)
        body["temperature"] = JsonValue.Num(GenOSConstants.TEMPERATURE)
        body["max_completion_tokens"] = JsonValue.Num(GenOSConstants.MAX_COMPLETION_TOKENS.toDouble())

        val request = HttpRequest(
            url = "${config.baseURL}/chat/completions",
            method = "POST",
            headers = mapOf(
                "Content-Type" to "application/json",
                "Authorization" to "Bearer $apiKey",
            ),
            body = JsonValue.Obj(body).stringified().toByteArray(Charsets.UTF_8),
        )

        val (head, byteStream) = http.stream(request)
        if (head.status == 401 || head.status == 403) {
            keyStore.markRejected(apiKey)
            throw StreamException("Cerebras rejected the API key - enter a valid key")
        }
        if (!head.ok) {
            val bytes = try {
                byteStream.toList().fold(ByteArray(0)) { acc, c -> acc + c }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                ByteArray(0)
            }
            // RN: detail.slice(0, 500) — UTF-16 units.
            val detail = jsSliceTo(bytes.toString(Charsets.UTF_8), 500)
            throw StreamException(detail.ifEmpty { "HTTP ${head.status}" })
        }

        val decoder = Utf8StreamDecoder()
        var buffer = ""
        var sawDone = false
        var finishReason: String? = null
        var content = ""
        val toolCalls = LinkedHashMap<Int, ToolCall>()

        byteStream.collect { chunk ->
            // Stop pulling chunks the moment the token is cancelled, even if the
            // byte-stream impl ignores coroutine cancellation.
            if (token.isCancelled) throw CancellationException("stream token cancelled")
            buffer += decoder.decode(chunk)
            // RN: buffer.split("\n"). Kotlin's split keeps every empty segment
            // (java.lang.String.split would drop the trailing one and silently
            // eat the tail buffer), and operates on UTF-16 units, so a
            // CRLF-terminated SSE stream yields ["…\r", …] exactly like JS.
            val lines = buffer.split('\n')
            buffer = lines.last()

            for (line in lines.subList(0, lines.size - 1)) {
                // RN: line.trim() / payload.trim() — the exact JS whitespace set
                // (strips a BOM before "data:", strips the trailing \r a CRLF
                // stream leaves on each line, keeps U+0085).
                val trimmed = jsTrim(line)
                if (!trimmed.startsWith("data:")) continue
                val payload = jsTrim(jsSliceFrom(trimmed, 5))
                if (payload.isEmpty()) continue
                if (payload == "[DONE]") {
                    sawDone = true
                    continue
                }

                val parsed = JsonValue.parse(payload) ?: continue
                // RN: `if (chunk.error)` — a TRUTHY guard. Falsy error values
                // ("", 0, false, null) are skipped, not thrown.
                val errorValue = parsed["error"]
                if (errorValue != null && errorValue.isJsTruthy) {
                    val msg = errorValue.str ?: errorValue["message"]?.str
                    throw StreamException(if (!msg.isNullOrEmpty()) msg else "stream error")
                }
                val choice = parsed["choices"]?.get(0)
                // RN: `if (choice?.finish_reason)` — truthy, so a NON-STRING
                // truthy finish_reason would land there but is dropped by the
                // string accessor here; unreachable with real providers.
                choice?.get("finish_reason")?.str?.takeIf { it.isNotEmpty() }?.let {
                    finishReason = it
                }
                val delta = choice?.get("delta")
                val text = delta?.get("content")?.str
                if (!text.isNullOrEmpty()) {
                    content += text
                    if (!token.isCancelled) onDelta(text)
                }
                for (tc in delta?.get("tool_calls")?.arr ?: emptyList()) {
                    val idx = tc["index"]?.num?.toInt() ?: 0
                    var cur = toolCalls[idx] ?: ToolCall()
                    tc["id"]?.str?.takeIf { it.isNotEmpty() }?.let { cur = cur.copy(id = it) }
                    tc["function"]?.get("name")?.str?.takeIf { it.isNotEmpty() }?.let {
                        cur = cur.copy(name = it)
                    }
                    tc["function"]?.get("arguments")?.str?.takeIf { it.isNotEmpty() }?.let {
                        cur = cur.copy(arguments = cur.arguments + it)
                    }
                    toolCalls[idx] = cur
                }
            }
        }

        val dropped = !sawDone && finishReason == null
        if (dropped && content.isEmpty() && toolCalls.isEmpty()) {
            throw StreamException("stream dropped before any content arrived")
        }
        val sorted = toolCalls.entries.sortedBy { it.key }.map { it.value }
        return RoundResult(
            finish = if (finishReason == "tool_calls" && toolCalls.isNotEmpty()) {
                RoundFinish.TOOL_CALLS
            } else {
                RoundFinish.CONTENT
            },
            content = content,
            toolCalls = sorted,
            info = StreamEndInfo(truncated = finishReason == "length", dropped = dropped),
        )
    }

    /**
     * RN's object literals, key for key: `{role, content}` for user/assistant
     * (plus `tool_calls`), `{role, tool_call_id, content}` for tool messages.
     * `LinkedHashMap` reproduces `JSON.stringify`'s insertion order exactly.
     */
    private fun messageJson(message: ChatMessage): JsonValue {
        val obj = LinkedHashMap<String, JsonValue>()
        obj["role"] = JsonValue.Str(message.role.wire)
        message.toolCallId?.let { obj["tool_call_id"] = JsonValue.Str(it) }
        obj["content"] = message.content?.let { JsonValue.Str(it) } ?: JsonValue.Null
        message.toolCalls?.let { calls ->
            obj["tool_calls"] = JsonValue.Arr(
                calls.map { tc ->
                    JsonValue.obj(
                        "id" to JsonValue.Str(tc.id),
                        "type" to JsonValue.Str(tc.type),
                        "function" to JsonValue.obj(
                            "name" to JsonValue.Str(tc.name),
                            "arguments" to JsonValue.Str(tc.arguments),
                        ),
                    )
                },
            )
        }
        return JsonValue.Obj(obj)
    }

    /** Run the whole tool loop to completion (or error/cancel). */
    public suspend fun streamScreen(
        messages: List<ChatMessage>,
        handlers: StreamHandlers,
        token: StreamCancelToken,
    ) {
        val convo = ArrayList(messages)

        try {
            var round = 0
            while (true) {
                // Past the round budget, stop offering tools — forces a screen.
                val includeTools = toolsAvailable && round < GenOSConstants.MAX_TOOL_ROUNDS
                val result = streamRound(convo, includeTools, token, handlers.onDelta)

                if (result.finish != RoundFinish.TOOL_CALLS) {
                    if (token.isCancelled) return
                    handlers.onDone(result.info)
                    return
                }

                val calls = result.toolCalls.map { tc ->
                    val raw = tc.arguments.ifEmpty { "{}" }
                    // Malformed arguments → empty object; executeTool reports
                    // the empty query.
                    val args = JsonValue.parse(raw)?.obj ?: emptyMap()
                    ToolRoundCall(tc.name, args)
                }

                if ((handlers.onToolRound?.invoke(calls) ?: ToolRoundDecision.PROCEED)
                    == ToolRoundDecision.ABORT
                ) {
                    throw StreamException(GenOSConstants.NEEDS_LIVE_DATA)
                }

                convo.add(
                    ChatMessage(
                        role = ChatRole.ASSISTANT,
                        content = result.content.ifEmpty { null },
                        toolCalls = result.toolCalls,
                    ),
                )
                // Tool execution runs inside the stream's coroutine:
                // token.cancel() cancels it, so a cooperative ToolExecuting impl
                // tears down mid-call and the loop below never issues the next
                // round's request.
                //
                // Sequential execution vs RN's Promise.all: outputs are collected
                // in call order either way and tool messages are appended by
                // index, so ordering and content are identical — only wall-clock
                // overlap differs (deliberate; see the Swift port's review).
                val outputs = ArrayList<String>(calls.size)
                for (call in calls) {
                    outputs.add(
                        tools?.execute(call.name, call.args)
                            ?: "ERROR: unknown tool \"${call.name}\"",
                    )
                }
                if (token.isCancelled) return
                result.toolCalls.forEachIndexed { i, tc ->
                    convo.add(ChatMessage(ChatRole.TOOL, outputs[i], toolCallId = tc.id))
                }
                round++
            }
        } catch (e: Throwable) {
            // RN: `if (signal?.aborted) return` — cancellation ends silently.
            if (token.isCancelled) return
            if (e is CancellationException) throw e
            handlers.onError(e)
        }
    }

    /**
     * Runs the tool loop in a coroutine retained by [token], so `token.cancel()`
     * tears down the SSE drain and tool execution (AbortController analog).
     */
    override fun stream(
        messages: List<ChatMessage>,
        handlers: StreamHandlers,
        token: StreamCancelToken,
    ) {
        val job = scope.launch { streamScreen(messages, handlers, token) }
        token.attach(job)
    }
}
