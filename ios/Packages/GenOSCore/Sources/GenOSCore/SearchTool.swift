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
///
/// Cancellation contract: execute(name:args:) runs inside the stream's Task,
/// which StreamCancelToken.cancel() cancels (RN passes the AbortSignal into
/// executeTool). Implementations should honor cooperative Task cancellation -
/// URLSession-backed fetches do natively; long-running custom impls should
/// check `Task.isCancelled` and return early. The stream loop discards all
/// outputs and never issues the next round's request once cancelled.
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
        !(apiKey ?? "").isEmpty
    }

    public var promptSection: String { SearchToolText.promptSection }

    public var toolDefs: JSONValue {
        .array([
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("web_search"),
                    "description": .string(
                        "Search the live web. Use for current or real-world facts: news, prices, scores, weather, events, and real places such as famous hotels, restaurants or attractions."
                    ),
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string"),
                                "description": .string("Concise web search query"),
                            ]),
                        ]),
                        "required": .array([.string("query")]),
                    ]),
                ]),
            ]),
        ])
    }

    public func execute(name: String, args: [String: JSONValue]) async -> String {
        guard name == "web_search" else { return "ERROR: unknown tool \"\(name)\"" }
        // RN: String(args.query ?? "").trim().
        let query = jsTrim(jsStringCoerce(args["query"]))
        guard !query.isEmpty else { return "ERROR: web_search requires a non-empty query" }
        do {
            return formatWebResults(query: query, results: try await webSearch(query: query))
        } catch {
            let message = (error as? StreamError)?.message ?? String(describing: error)
            return "ERROR: web search failed (\(message))"
        }
    }

    /// Raw Exa search; throws on HTTP/network failure (detail truncated to
    /// 200 chars). Results mapped: title fallback = domain, snippet
    /// whitespace-collapsed + trimmed, url-less entries dropped.
    public func webSearch(query: String) async throws -> [SearchResult] {
        let body: JSONValue = .object([
            "query": .string(query),
            "numResults": .number(Double(GenOSConstants.exaNumResults)),
            "contents": .object([
                "text": .object(["maxCharacters": .number(Double(GenOSConstants.exaMaxCharacters))]),
            ]),
        ])
        let request = HTTPRequest(
            url: "https://api.exa.ai/search",
            method: "POST",
            headers: ["Content-Type": "application/json", "x-api-key": apiKey ?? ""],
            body: Data(body.stringified(keyOrder: ["query", "numResults", "contents", "text", "maxCharacters"]).utf8)
        )
        let (head, data) = try await http.fetch(request)
        guard head.ok else {
            let detail = String((String(data: data, encoding: .utf8) ?? "").prefix(200))
            throw StreamError(detail.isEmpty ? "Exa HTTP \(head.status)" : detail)
        }
        let json = JSONValue.parse(data)
        let rawResults = json?["results"]?.arrayValue ?? []
        return rawResults.compactMap { r -> SearchResult? in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            let title = r["title"]?.stringValue
            let text = r["text"]?.stringValue ?? ""
            // RN: (r.text ?? "").replace(/\s+/g, " ").trim() - JS \s spelled
            // out (ICU's \s misses \v and U+FEFF, see JSRegex.swift).
            let snippet = jsTrim(JSRegex.replacingAll("\(JSRegex.jsWS)+", in: text, with: " "))
            return SearchResult(
                title: title ?? resultDomain(url),
                url: url,
                snippet: snippet,
                published: r["publishedDate"]?.stringValue
            )
        }
    }
}

/// "Web results for ..." tool-message formatting (pure).
public func formatWebResults(query: String, results: [SearchResult]) -> String {
    if results.isEmpty {
        return "Web results for \"\(query)\": none found. Say so honestly on the screen; do not fabricate specifics."
    }
    let lines = results.enumerated().map { i, r -> String in
        let date = (r.published?.isEmpty == false) ? " (\(String(r.published!.prefix(10))))" : ""
        return "\(i + 1). \(r.title) - \(resultDomain(r.url))\(date)\n   \(r.snippet)"
    }
    return "Web results for \"\(query)\":\n" + lines.joined(separator: "\n")
}

/// Hostname without leading www., or the input when not http(s).
/// RN: /^https?:\/\/(?:www\.)?([^\/]+)/ - literals + a negated ASCII class
/// (which matches line terminators in both engines) and `^` with no `m`
/// flag (start-of-input in both). Identical in ICU and JS (audited).
public func resultDomain(_ url: String) -> String {
    guard
        let m = JSRegex.first(#"^https?://(?:www\.)?([^/]+)"#, url),
        let host = m.count > 1 ? m[1] : nil
    else { return url }
    return host
}
