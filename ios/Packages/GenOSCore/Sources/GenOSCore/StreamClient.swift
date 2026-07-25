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

/// AbortController analog. Cancelling suppresses all further callbacks.
@MainActor
public final class StreamCancelToken {
    public private(set) var isCancelled = false
    public init() {}
    public func cancel() { isCancelled = true }
}

/// Stream seam the controller uses; StreamClient is the production impl,
/// tests inject a scripted fake.
@MainActor
public protocol ScreenStreaming: AnyObject {
    /// Start a full tool-loop generation. Returns the cancellation handle.
    @discardableResult
    func stream(messages: [ChatMessage], handlers: StreamHandlers) -> StreamCancelToken
}

public struct StreamConfig: Sendable {
    public var baseURL: String
    public var model: String
    /// Build-time system prompt embed (SYSTEM_PROMPT analog).
    public var systemPrompt: String
    /// "Weekday, Month D, YYYY" (en-US long) for the "Today is ..." line.
    public var todayString: @Sendable () -> String

    public init(
        baseURL: String = GenOSConstants.defaultBaseURL,
        model: String = GenOSConstants.defaultModel,
        systemPrompt: String = "",
        todayString: @escaping @Sendable () -> String = { "" }
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

/// Incremental UTF-8 decoding (TextDecoder-stream semantics): incomplete
/// trailing multi-byte sequences are held back between chunks.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: data)
        pending = []
        var end = bytes.count
        var i = max(0, bytes.count - 3)
        while i < bytes.count {
            let b = bytes[i]
            let need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : (b >= 0xC0 ? 2 : 0))
            if need > 0 && i + need > bytes.count {
                end = i
                break
            }
            i += 1
        }
        pending = Array(bytes[end...])
        return String(decoding: bytes[..<end], as: UTF8.self)
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
        guard let apiKey = keyStore.get() else {
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
            let detail = String((String(data: detailData, encoding: .utf8) ?? "").prefix(500))
            throw StreamError(detail.isEmpty ? "HTTP \(head.status)" : detail)
        }

        var decoder = UTF8StreamDecoder()
        var buffer = ""
        var sawDone = false
        var finishReason: String?
        var content = ""
        var toolCalls: [Int: ToolCall] = [:]

        for try await chunkData in byteStream {
            buffer += decoder.decode(chunkData)
            var lines = buffer.components(separatedBy: "\n")
            buffer = lines.popLast() ?? ""

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.isEmpty { continue }
                if payload == "[DONE]" {
                    sawDone = true
                    continue
                }

                guard let chunk = JSONValue.parse(payload) else { continue }
                if let errorValue = chunk["error"], errorValue != .null {
                    let msg = errorValue.stringValue ?? errorValue["message"]?.stringValue
                    throw StreamError((msg?.isEmpty == false) ? msg! : "stream error")
                }
                let choice = chunk["choices"]?[0]
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
            if token.isCancelled { return }
            handlers.onError(error)
        }
    }

    @discardableResult
    public func stream(messages: [ChatMessage], handlers: StreamHandlers) -> StreamCancelToken {
        let token = StreamCancelToken()
        Task { await streamScreen(messages: messages, handlers: handlers, token: token) }
        return token
    }
}
