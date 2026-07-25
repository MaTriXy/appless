import Foundation

/// One tool call surfaced to onToolRound, arguments already JSON-parsed
/// (malformed arguments → empty object).
public struct ToolRoundCall: Sendable, Equatable {
    public var name: String
    public var args: [String: JSONValue]

    public init(name: String, args: [String: JSONValue]) {
        self.name = name
        self.args = args
    }
}

public enum ToolRoundDecision: Sendable, Equatable {
    /// Execute the calls and stream the next round.
    case proceed
    /// Refuse execution (speculative prefetch) → stream errors NEEDS_LIVE_DATA.
    case abort
}

/// Callbacks for one screen generation (src/genos/stream.ts StreamHandlers).
@MainActor
public struct StreamHandlers {
    public var onDelta: @MainActor (String) -> Void
    public var onDone: @MainActor (StreamEndInfo) -> Void
    public var onError: @MainActor (Error) -> Void
    public var onToolRound: (@MainActor ([ToolRoundCall]) -> ToolRoundDecision)?

    public init(
        onDelta: @escaping @MainActor (String) -> Void,
        onDone: @escaping @MainActor (StreamEndInfo) -> Void,
        onError: @escaping @MainActor (Error) -> Void,
        onToolRound: (@MainActor ([ToolRoundCall]) -> ToolRoundDecision)? = nil
    ) {
        self.onDelta = onDelta
        self.onDone = onDone
        self.onError = onError
        self.onToolRound = onToolRound
    }
}

/// AbortController analog. Cancelling suppresses all further callbacks AND
/// tears down the in-flight work: the stream loop runs inside a Task retained
/// by the token, and cancel() cancels that Task so the SSE drain and any
/// running tool execution stop (mirrors RN's AbortController aborting the
/// fetch and the Exa call).
@MainActor
public final class StreamCancelToken {
    public private(set) var isCancelled = false
    private var task: Task<Void, Never>?

    public init() {}

    /// Bind the running stream Task. If the token was already cancelled the
    /// task is cancelled immediately.
    public func attach(_ task: Task<Void, Never>) {
        self.task = task
        if isCancelled { task.cancel() }
    }

    public func cancel() {
        isCancelled = true
        task?.cancel()
    }

    /// Await the underlying stream Task settling (teardown/test aid).
    public func join() async {
        await task?.value
    }
}

/// Stream seam the controller uses; StreamClient is the production impl,
/// tests inject a scripted fake.
///
/// The caller creates the token and registers it (e.g. in its inflight map)
/// BEFORE calling stream(), mirroring RN's `inflight.set(id, controller)`
/// then `streamScreen(...)` ordering - so even an implementation that fires
/// handlers synchronously is never dropped as stale.
@MainActor
public protocol ScreenStreaming: AnyObject {
    /// Start a full tool-loop generation bound to `token`. Implementations
    /// must stop consuming and stop calling handlers once the token is
    /// cancelled.
    func stream(messages: [ChatMessage], handlers: StreamHandlers, token: StreamCancelToken)
}

extension ScreenStreaming {
    /// Convenience: create the token, start the stream, return the handle.
    @discardableResult
    public func stream(messages: [ChatMessage], handlers: StreamHandlers) -> StreamCancelToken {
        let token = StreamCancelToken()
        stream(messages: messages, handlers: handlers, token: token)
        return token
    }
}

public struct StreamConfig: Sendable {
    public var baseURL: String
    public var model: String
    /// Build-time system prompt embed (SYSTEM_PROMPT analog).
    public var systemPrompt: String
    /// "Weekday, Month D, YYYY" (en-US long) for the "Today is ..." line.
    public var todayString: @Sendable () -> String

    /// Fail-safe default for `todayString`: the RN systemPrompt date
    /// (src/genos/stream.ts) - `new Date().toLocaleDateString("en-US",
    /// { weekday: "long", year: "numeric", month: "long", day: "numeric" })`
    /// - e.g. "Friday, July 25, 2026". en_US_POSIX pins the English
    /// weekday/month names regardless of device locale; the device's current
    /// time zone is kept, matching toLocaleDateString's local-time behavior.
    public static let defaultTodayString: @Sendable () -> String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: Date())
    }

    public init(
        baseURL: String = GenOSConstants.defaultBaseURL,
        model: String = GenOSConstants.defaultModel,
        systemPrompt: String = "",
        todayString: @escaping @Sendable () -> String = StreamConfig.defaultTodayString
    ) {
        self.baseURL = baseURL
        self.model = model
        self.systemPrompt = systemPrompt
        self.todayString = todayString
    }
}

public struct StreamError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Incremental UTF-8 decoding: a byte-for-byte port of the WHATWG Encoding
/// Standard's utf-8 decoder state machine (https://encoding.spec.whatwg.org/#utf-8-decoder),
/// which is exactly the algorithm `new TextDecoder()` runs with `{stream: true}`
/// and `fatal: false` - the RN reference's decoder (stream.ts createUtf8Decoder).
///
/// Porting the state machine rather than approximating it with a tail scan makes
/// emission timing AND totals match TextDecoder for EVERY input by construction:
/// valid sequences, invalid lead bytes, out-of-range continuation bytes
/// (overlong C0/C1, surrogate ED A0, out-of-range F4 90), stray continuations,
/// and any chunk boundary. Earlier tail-scan versions matched only the cases
/// they were patched for; see UTF8StreamDecoderTests for the pinned
/// counterexamples plus the seeded fuzz differential against TextDecoder.
struct UTF8StreamDecoder {
    private static let replacement = Unicode.Scalar(0xFFFD)!

    // Spec state: carried across chunks so a sequence may span any boundary.
    private var codePoint: UInt32 = 0
    private var bytesSeen: Int = 0
    private var bytesNeeded: Int = 0
    private var lowerBoundary: UInt8 = 0x80
    private var upperBoundary: UInt8 = 0xBF

    mutating func decode(_ data: Data) -> String {
        let queue = Array(data)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < queue.count {
            let byte = queue[i]
            i += 1

            if bytesNeeded == 0 {
                switch byte {
                case 0x00...0x7F:
                    out.append(Unicode.Scalar(byte))
                case 0xC2...0xDF:
                    bytesNeeded = 1
                    codePoint = UInt32(byte & 0x1F)
                case 0xE0...0xEF:
                    if byte == 0xE0 { lowerBoundary = 0xA0 }
                    if byte == 0xED { upperBoundary = 0x9F }
                    bytesNeeded = 2
                    codePoint = UInt32(byte & 0x0F)
                case 0xF0...0xF4:
                    if byte == 0xF0 { lowerBoundary = 0x90 }
                    if byte == 0xF4 { upperBoundary = 0x8F }
                    bytesNeeded = 3
                    codePoint = UInt32(byte & 0x07)
                default:
                    // Invalid lead (C0, C1, F5-FF, stray continuation): error
                    // now, no holdback.
                    out.append(Self.replacement)
                }
                continue
            }

            if byte < lowerBoundary || byte > upperBoundary {
                // Spec: reset state, emit an error, and PREPEND the offending
                // byte back onto the stream so it is re-processed as a lead.
                codePoint = 0
                bytesNeeded = 0
                bytesSeen = 0
                lowerBoundary = 0x80
                upperBoundary = 0xBF
                out.append(Self.replacement)
                i -= 1
                continue
            }

            lowerBoundary = 0x80
            upperBoundary = 0xBF
            codePoint = (codePoint << 6) | UInt32(byte & 0x3F)
            bytesSeen += 1
            if bytesSeen != bytesNeeded { continue }

            let scalarValue = codePoint
            codePoint = 0
            bytesNeeded = 0
            bytesSeen = 0
            out.append(Unicode.Scalar(scalarValue) ?? Self.replacement)
        }
        return String(out)
    }
}

/// Direct Cerebras streaming (OpenAI-compatible chat completions) with the
/// real tool-calling loop (src/genos/stream.ts streamScreen/streamRound):
/// SSE "data:" line protocol, [DONE] sentinel, tool-call delta accumulation
/// by index (whole-call and split-arguments styles), MAX_TOOL_ROUNDS budget,
/// 401/403 → keyStore.markRejected, dropped-stream detection.
@MainActor
public final class StreamClient: ScreenStreaming {
    let http: HTTPStreaming
    let keyStore: KeyStore
    let config: StreamConfig
    let tools: ToolExecuting?

    public init(http: HTTPStreaming, keyStore: KeyStore, config: StreamConfig, tools: ToolExecuting?) {
        self.http = http
        self.keyStore = keyStore
        self.config = config
        self.tools = tools
    }

    private var toolsAvailable: Bool {
        tools?.available ?? false
    }

    /// System prompt + optional tools section + today's date line.
    public func systemPrompt() -> String {
        let toolsSection = toolsAvailable ? (tools?.promptSection ?? "") : ""
        return config.systemPrompt + toolsSection + "\n\nToday is \(config.todayString())."
    }

    private enum RoundFinish {
        case content
        case toolCalls
    }

    private struct RoundResult {
        var finish: RoundFinish
        var content: String
        var toolCalls: [ToolCall]
        var info: StreamEndInfo
    }

    /// One streamed completion. Content deltas are forwarded live; tool-call
    /// deltas are accumulated by index (whole-call and split-arguments styles).
    private func streamRound(
        convo: [ChatMessage],
        includeTools: Bool,
        token: StreamCancelToken,
        onDelta: @MainActor (String) -> Void
    ) async throws -> RoundResult {
        // RN: `if (!apiKey) throw` - JS falsy, so an EMPTY key (whitespace-only
        // set()) errors locally too; no request with a blank bearer goes out.
        guard let apiKey = keyStore.get(), !apiKey.isEmpty else {
            throw StreamError("No Cerebras API key set")
        }

        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array(
                [messageJSON(ChatMessage(role: .system, content: systemPrompt()))]
                    + convo.map(messageJSON)
            ),
            "stream": .bool(true),
            "temperature": .number(GenOSConstants.temperature),
            "max_completion_tokens": .number(Double(GenOSConstants.maxCompletionTokens)),
        ]
        if includeTools, let tools {
            body["tools"] = tools.toolDefs
        }

        let keyOrder = [
            "model", "messages", "tools", "stream", "temperature", "max_completion_tokens",
            "role", "content", "tool_calls", "tool_call_id",
            "id", "type", "function", "name", "arguments",
        ]
        let request = HTTPRequest(
            url: "\(config.baseURL)/chat/completions",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)",
            ],
            body: Data(JSONValue.object(body).stringified(keyOrder: keyOrder).utf8)
        )

        let (head, byteStream) = try await http.stream(request)
        if head.status == 401 || head.status == 403 {
            keyStore.markRejected(apiKey)
            throw StreamError("Cerebras rejected the API key - enter a valid key")
        }
        if !head.ok {
            var detailData = Data()
            do {
                for try await chunk in byteStream { detailData.append(chunk) }
            } catch {
                detailData = Data()
            }
            // RN: detail.slice(0, 500) - UTF-16 units, not Characters.
            let detail = jsSlice(String(data: detailData, encoding: .utf8) ?? "", upTo: 500)
            throw StreamError(detail.isEmpty ? "HTTP \(head.status)" : detail)
        }

        var decoder = UTF8StreamDecoder()
        var buffer = ""
        var sawDone = false
        var finishReason: String?
        var content = ""
        var toolCalls: [Int: ToolCall] = [:]

        for try await chunkData in byteStream {
            // Stop pulling chunks the moment the token is cancelled, even if
            // the byte-stream impl ignores Task cancellation.
            if token.isCancelled { throw CancellationError() }
            buffer += decoder.decode(chunkData)
            // RN: buffer.split("\n") - UTF-16-level. jsSplit splits at scalar
            // level, so a CRLF-terminated SSE stream (legal per the SSE spec)
            // yields ["…\r", …] exactly like JS; Character-level splitting
            // treats "\r\n" as ONE grapheme, never splits, and buffers the
            // whole stream forever. Tail-buffer semantics are identical:
            // the final (possibly empty) piece goes back into `buffer`.
            var lines = jsSplit(buffer, on: "\n")
            buffer = lines.popLast() ?? ""

            for line in lines {
                // RN: line.trim() / payload.trim() - exact JS whitespace set
                // (strips a BOM before "data:", strips the trailing \r a CRLF
                // stream leaves on each line, keeps U+0085).
                let trimmed = jsTrim(line)
                // RN: trimmed.startsWith("data:") / trimmed.slice(5) - both
                // UTF-16-level; scalar prefix + UTF-16 slice keep a combining
                // mark straight after "data:" from defeating the match.
                guard jsHasPrefix(trimmed, "data:") else { continue }
                let payload = jsTrim(jsSlice(trimmed, from: 5))
                if payload.isEmpty { continue }
                // == on an all-ASCII literal is safe despite Swift's
                // canonical-equivalence ==: no distinct scalar sequence
                // normalizes to a pure-ASCII string.
                if payload == "[DONE]" {
                    sawDone = true
                    continue
                }

                guard let chunk = JSONValue.parse(payload) else { continue }
                // RN: `if (chunk.error)` - a TRUTHY guard. Falsy error values
                // ("", 0, false, null) are skipped, not thrown.
                if let errorValue = chunk["error"], errorValue.isJSTruthy {
                    let msg = errorValue.stringValue ?? errorValue["message"]?.stringValue
                    throw StreamError((msg?.isEmpty == false) ? msg! : "stream error")
                }
                let choice = chunk["choices"]?[0]
                // RN: `if (choice?.finish_reason)` - truthy, so a NON-STRING
                // truthy finish_reason (number/object) would land there but is
                // dropped by stringValue here; unreachable with real providers.
                if let fr = choice?["finish_reason"]?.stringValue, !fr.isEmpty {
                    finishReason = fr
                }
                let delta = choice?["delta"]
                if let text = delta?["content"]?.stringValue, !text.isEmpty {
                    content += text
                    if !token.isCancelled { onDelta(text) }
                }
                for tc in delta?["tool_calls"]?.arrayValue ?? [] {
                    let idx = tc["index"]?.numberValue.map { Int($0) } ?? 0
                    var cur = toolCalls[idx] ?? ToolCall()
                    if let id = tc["id"]?.stringValue, !id.isEmpty { cur.id = id }
                    if let name = tc["function"]?["name"]?.stringValue, !name.isEmpty { cur.name = name }
                    if let args = tc["function"]?["arguments"]?.stringValue, !args.isEmpty {
                        cur.arguments += args
                    }
                    toolCalls[idx] = cur
                }
            }
        }

        let dropped = !sawDone && finishReason == nil
        if dropped && content.isEmpty && toolCalls.isEmpty {
            throw StreamError("stream dropped before any content arrived")
        }
        let sorted = toolCalls.sorted { $0.key < $1.key }.map(\.value)
        return RoundResult(
            finish: (finishReason == "tool_calls" && !toolCalls.isEmpty) ? .toolCalls : .content,
            content: content,
            toolCalls: sorted,
            info: StreamEndInfo(truncated: finishReason == "length", dropped: dropped)
        )
    }

    private func messageJSON(_ message: ChatMessage) -> JSONValue {
        var obj: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": message.content.map { .string($0) } ?? .null,
        ]
        if let toolCalls = message.toolCalls {
            obj["tool_calls"] = .array(toolCalls.map { tc in
                .object([
                    "id": .string(tc.id),
                    "type": .string(tc.type),
                    "function": .object([
                        "name": .string(tc.name),
                        "arguments": .string(tc.arguments),
                    ]),
                ])
            })
        }
        if let toolCallID = message.toolCallID {
            obj["tool_call_id"] = .string(toolCallID)
        }
        return .object(obj)
    }

    /// Run the whole tool loop to completion (or error/cancel).
    public func streamScreen(messages: [ChatMessage], handlers: StreamHandlers, token: StreamCancelToken) async {
        var convo = messages

        do {
            var round = 0
            while true {
                // Past the round budget, stop offering tools - forces a screen.
                let includeTools = toolsAvailable && round < GenOSConstants.maxToolRounds
                let result = try await streamRound(
                    convo: convo,
                    includeTools: includeTools,
                    token: token,
                    onDelta: handlers.onDelta
                )

                if result.finish != .toolCalls {
                    if token.isCancelled { return }
                    handlers.onDone(result.info)
                    return
                }

                let calls = result.toolCalls.map { tc -> ToolRoundCall in
                    let raw = tc.arguments.isEmpty ? "{}" : tc.arguments
                    // Malformed arguments → empty object; executeTool reports
                    // the empty query.
                    let args = JSONValue.parse(raw)?.objectValue ?? [:]
                    return ToolRoundCall(name: tc.name, args: args)
                }

                if (handlers.onToolRound?(calls) ?? .proceed) == .abort {
                    throw StreamError(GenOSConstants.needsLiveData)
                }

                convo.append(ChatMessage(
                    role: .assistant,
                    content: result.content.isEmpty ? nil : result.content,
                    toolCalls: result.toolCalls
                ))
                // Tool execution runs inside the stream's Task: token.cancel()
                // cancels it, so a cooperative ToolExecuting impl (URLSession
                // honors Task cancellation) tears down mid-call, and the loop
                // below never issues the next round's request.
                //
                // Sequential execution vs RN's Promise.all: outputs are
                // collected in call order either way and tool messages are
                // appended by index, so ordering and content are identical -
                // only wall-clock overlap differs (deliberate; see review).
                var outputs: [String] = []
                for call in calls {
                    if let tools {
                        outputs.append(await tools.execute(name: call.name, args: call.args))
                    } else {
                        outputs.append("ERROR: unknown tool \"\(call.name)\"")
                    }
                }
                if token.isCancelled { return }
                for (i, tc) in result.toolCalls.enumerated() {
                    convo.append(ChatMessage(role: .tool, content: outputs[i], toolCallID: tc.id))
                }
                round += 1
            }
        } catch {
            // RN: `if (signal?.aborted) return` - cancellation ends silently.
            if token.isCancelled || error is CancellationError { return }
            handlers.onError(error)
        }
    }

    /// Runs the tool loop in a Task retained by `token`, so token.cancel()
    /// tears down the SSE drain and tool execution (AbortController analog).
    public func stream(messages: [ChatMessage], handlers: StreamHandlers, token: StreamCancelToken) {
        let task = Task { await self.streamScreen(messages: messages, handlers: handlers, token: token) }
        token.attach(task)
    }
}
