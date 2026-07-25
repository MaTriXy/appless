import Foundation

/// src/genos/tools/search.ts parity: Exa-backed web_search tool.
public struct SearchResult: Sendable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String
    public var published: String?

    public init(title: String, url: String, snippet: String, published: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.published = published
    }
}

/// Tool execution seam offered to the stream loop.
public protocol ToolExecuting: Sendable {
    /// Whether any tools should be offered (Exa key present).
    var available: Bool { get }
    /// Prompt section appended to the system prompt when available.
    var promptSection: String { get }
    /// OpenAI-format tool definitions for the request body.
    var toolDefs: JSONValue { get }
    /// Execute one call; failures return an "ERROR: ..." string, never throw.
    func execute(name: String, args: [String: JSONValue]) async -> String
}

public enum SearchToolText {
    /// TOOLS_PROMPT_SECTION verbatim.
    public static let promptSection = """


## Live Data (web_search tool)
You have a REAL web_search tool. When a truthful screen needs real-world or current facts - latest news, live prices or scores, current weather, real venues (famous hotels, restaurants, attractions) in real places, current events - call web_search FIRST (1-3 focused queries), then compose the screen strictly from the returned facts: real names, real numbers, real dates. Finish such screens with a small TextContent("Sources: …", "small") footnote naming the source domains. If results are empty or the tool errors, build the screen from what you know and mark it clearly as possibly outdated. NEVER call tools for invented/personal content (messages, notes, playlists, settings, workouts) - invent that as usual.
"""
}

/// Exa web_search: POST https://api.exa.ai/search with x-api-key, numResults 5,
/// contents.text.maxCharacters 400. All failures degrade to ERROR strings.
public struct ExaSearchTool: ToolExecuting {
    public let apiKey: String?
    let http: HTTPFetching

    public init(apiKey: String?, http: HTTPFetching) {
        self.apiKey = apiKey
        self.http = http
    }

    public var available: Bool {
        false // STUB
    }

    public var promptSection: String { SearchToolText.promptSection }

    public var toolDefs: JSONValue {
        .null // STUB
    }

    public func execute(name: String, args: [String: JSONValue]) async -> String {
        "" // STUB
    }

    /// Raw Exa search; throws on HTTP/network failure (detail truncated to
    /// 200 chars). Results mapped: title fallback = domain, snippet
    /// whitespace-collapsed + trimmed, url-less entries dropped.
    public func webSearch(query: String) async throws -> [SearchResult] {
        [] // STUB
    }
}

/// "Web results for ..." tool-message formatting (pure).
public func formatWebResults(query: String, results: [SearchResult]) -> String {
    "" // STUB
}

/// Hostname without leading www., or the input when not http(s).
public func resultDomain(_ url: String) -> String {
    "" // STUB
}
