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

    /// System prompt + optional tools section + today's date line.
    public func systemPrompt() -> String {
        "" // STUB
    }

    /// Run the whole tool loop to completion (or error/cancel).
    public func streamScreen(messages: [ChatMessage], handlers: StreamHandlers, token: StreamCancelToken) async {
        // STUB
    }

    @discardableResult
    public func stream(messages: [ChatMessage], handlers: StreamHandlers) -> StreamCancelToken {
        let token = StreamCancelToken()
        // STUB: production impl starts a Task running streamScreen.
        return token
    }
}
