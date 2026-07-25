import Foundation

// MARK: - Chat protocol models (src/genos/stream.ts)

public struct ToolCall: Sendable, Equatable {
    public var id: String
    /// Always "function" in the OpenAI-compatible schema.
    public var type: String
    public var name: String
    public var arguments: String

    public init(id: String = "", type: String = "function", name: String = "", arguments: String = "") {
        self.id = id
        self.type = type
        self.name = name
        self.arguments = arguments
    }
}

public enum ChatRole: String, Sendable, Equatable {
    case user, assistant, system, tool
}

public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    public init(
        role: ChatRole,
        content: String?,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct StreamEndInfo: Sendable, Equatable {
    /// Provider reported finish_reason "length" - the screen was cut short.
    public var truncated: Bool
    /// Stream ended without [DONE] or a finish_reason - likely dropped mid-flight.
    public var dropped: Bool

    public init(truncated: Bool = false, dropped: Bool = false) {
        self.truncated = truncated
        self.dropped = dropped
    }
}

// MARK: - Screen model (src/genos/store.ts)

public enum ScreenStatus: String, Sendable, Equatable {
    case pending, streaming, done, error
}

public enum OSCommandKind: String, Sendable, Equatable {
    case back, home, switcher, open
}

public struct OSCommand: Sendable, Equatable {
    public var cmd: OSCommandKind
    public var arg: String?

    public init(cmd: OSCommandKind, arg: String? = nil) {
        self.cmd = cmd
        self.arg = arg
    }
}

public struct Screen: Sendable, Equatable {
    public var id: String
    public var appId: String
    public var appName: String
    /// The user-intent message that produced this screen.
    public var request: String
    public var parentId: String?
    /// Accumulating openui-lang source.
    public var content: String
    public var status: ScreenStatus
    public var error: String?
    /// True while the screen exists only as a speculative prefetch.
    public var speculative: Bool
    /// Clock milliseconds when generation started - staleness + latency tracking.
    public var startedAt: Double
    /// Wall-clock generation time once done.
    public var genMs: Int?
    /// The screen was already fully generated when the user tapped into it.
    public var prefetched: Bool?
    /// Provider cut the generation short (finish_reason "length").
    public var truncated: Bool?
    /// The model answered with an @OS(...) command instead of a screen.
    public var osCommand: OSCommand?
    /// The model is running tools (web_search) before composing the screen.
    public var searching: Bool?

    public init(
        id: String,
        appId: String,
        appName: String,
        request: String,
        parentId: String? = nil,
        content: String = "",
        status: ScreenStatus = .pending,
        error: String? = nil,
        speculative: Bool = false,
        startedAt: Double = 0,
        genMs: Int? = nil,
        prefetched: Bool? = nil,
        truncated: Bool? = nil,
        osCommand: OSCommand? = nil,
        searching: Bool? = nil
    ) {
        self.id = id
        self.appId = appId
        self.appName = appName
        self.request = request
        self.parentId = parentId
        self.content = content
        self.status = status
        self.error = error
        self.speculative = speculative
        self.startedAt = startedAt
        self.genMs = genMs
        self.prefetched = prefetched
        self.truncated = truncated
        self.osCommand = osCommand
        self.searching = searching
    }
}
