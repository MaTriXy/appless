import Foundation
import Testing
@testable import GenOSCore

// src/genos/tools/search.ts - Exa web_search + ERROR-string degradation.
@Suite struct WebResultFormattingTests {
    @Test func numberedResultsWithDomainDateAndSnippet() {
        let results = [
            SearchResult(
                title: "Goa monsoon update",
                url: "https://www.example.com/goa",
                snippet: "Heavy rain expected.",
                published: "2026-07-20T09:30:00.000Z"
            ),
            SearchResult(title: "Beaches", url: "https://travel.org/beaches", snippet: "Top beaches."),
        ]
        #expect(
            formatWebResults(query: "goa weather", results: results) == """
            Web results for "goa weather":
            1. Goa monsoon update - example.com (2026-07-20)
               Heavy rain expected.
            2. Beaches - travel.org
               Top beaches.
            """
        )
    }

    @Test func emptyResultsInstructHonesty() {
        #expect(
            formatWebResults(query: "nothing", results: [])
                == "Web results for \"nothing\": none found. Say so honestly on the screen; do not fabricate specifics."
        )
    }

    @Test func domainStripsSchemeAndWww() {
        #expect(resultDomain("https://www.example.com/a/b") == "example.com")
        #expect(resultDomain("http://sub.site.io/x") == "sub.site.io")
        // Non-http input falls back to the input itself.
        #expect(resultDomain("not a url") == "not a url")
    }
}

@Suite struct ExaToolTests {
    func makeTool(key: String? = "exa-key", http: ScriptedHTTP = ScriptedHTTP()) -> ExaSearchTool {
        ExaSearchTool(apiKey: key, http: http)
    }

    @Test func availabilityRequiresKey() {
        #expect(makeTool(key: "exa-key").available)
        #expect(!makeTool(key: nil).available)
        #expect(!makeTool(key: "").available)
    }

    @Test func toolDefsDeclareWebSearchWithRequiredQuery() {
        let defs = makeTool().toolDefs
        let fn = defs[0]?["function"]
        #expect(defs[0]?["type"]?.stringValue == "function")
        #expect(fn?["name"]?.stringValue == "web_search")
        #expect(fn?["parameters"]?["required"] == .array([.string("query")]))
    }

    @Test func promptSectionMentionsTheRealTool() {
        #expect(makeTool().promptSection.contains("You have a REAL web_search tool."))
        #expect(makeTool().promptSection.hasPrefix("\n\n## Live Data (web_search tool)"))
    }

    @Test func unknownToolDegradesToErrorString() async {
        let out = await makeTool().execute(name: "calculator", args: [:])
        #expect(out == "ERROR: unknown tool \"calculator\"")
    }

    @Test func emptyQueryDegradesToErrorString() async {
        let tool = makeTool()
        let missing = await tool.execute(name: "web_search", args: [:])
        #expect(missing == "ERROR: web_search requires a non-empty query")
        let blank = await tool.execute(name: "web_search", args: ["query": .string("   ")])
        #expect(blank == "ERROR: web_search requires a non-empty query")
    }

    @Test func httpFailureDegradesToErrorStringTruncatedTo200() async {
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 429, errorBody: String(repeating: "x", count: 500)))
        let out = await makeTool(http: http).execute(name: "web_search", args: ["query": .string("q")])
        #expect(out == "ERROR: web search failed (\(String(repeating: "x", count: 200)))")
    }

    @Test func searchRequestShapeAndResultMapping() async throws {
        let http = ScriptedHTTP()
        let payload = """
        {"results":[
          {"title":"Hotel Aurora","url":"https://www.aurora.com/rooms","text":"  Grand \\n  old   hotel  ","publishedDate":"2026-01-02"},
          {"url":"https://plain.net/page","text":"no title"},
          {"title":"No url entry","text":"dropped"}
        ]}
        """
        await http.enqueue(ScriptedResponse(chunks: [Data(payload.utf8)]))
        let tool = makeTool(http: http)
        let results = try await tool.webSearch(query: "famous hotels")

        #expect(results == [
            SearchResult(title: "Hotel Aurora", url: "https://www.aurora.com/rooms", snippet: "Grand old hotel", published: "2026-01-02"),
            SearchResult(title: "plain.net", url: "https://plain.net/page", snippet: "no title", published: nil),
        ])

        let requests = await http.requests()
        try #require(requests.count == 1)
        #expect(requests[0].url == "https://api.exa.ai/search")
        #expect(requests[0].headers["x-api-key"] == "exa-key")
        let body = (await http.requestBodies()).first
        #expect(body?["query"]?.stringValue == "famous hotels")
        #expect(body?["numResults"]?.numberValue == 5)
        #expect(body?["contents"]?["text"]?["maxCharacters"]?.numberValue == 400)
    }

    @Test func snippetCollapseUsesEcmaScriptWhitespaceSet() async throws {
        // RN: .replace(/\s+/g, " ") - JS \s includes \v and U+FEFF, which
        // ICU's \s misses; both must collapse to single spaces.
        let http = ScriptedHTTP()
        let payload = "{\"results\":[{\"title\":\"T\",\"url\":\"https://a.com/x\",\"text\":\"a\\u000b\\ufeffb  c\"}]}"
        await http.enqueue(ScriptedResponse(chunks: [Data(payload.utf8)]))
        let results = try await makeTool(http: http).webSearch(query: "q")
        #expect(results.first?.snippet == "a b c")
    }

    @Test func executeFormatsSuccessfulSearch() async {
        let http = ScriptedHTTP()
        let payload = #"{"results":[{"title":"T","url":"https://a.com/x","text":"snippet"}]}"#
        await http.enqueue(ScriptedResponse(chunks: [Data(payload.utf8)]))
        let out = await makeTool(http: http).execute(name: "web_search", args: ["query": .string("q")])
        #expect(out == "Web results for \"q\":\n1. T - a.com\n   snippet")
    }
}
