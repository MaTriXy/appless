package dev.appless.genoscore

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** src/genos/tools/search.ts parity: formatting, degradation, request shape. */
class SearchToolFormattingTest {
    private val results = listOf(
        SearchResult(
            title = "Taj Exotica",
            url = "https://www.tajhotels.com/goa",
            snippet = "Beachfront resort in Benaulim.",
            published = "2026-07-01T09:00:00.000Z",
        ),
        SearchResult(
            title = "Goa Tourism",
            url = "http://goatourism.gov.in/stay",
            snippet = "Official listings.",
        ),
    )

    @Test
    fun `numbered results carry domain, date and snippet`() {
        assertEquals(
            "Web results for \"goa hotels\":\n" +
                "1. Taj Exotica - tajhotels.com (2026-07-01)\n   Beachfront resort in Benaulim.\n" +
                "2. Goa Tourism - goatourism.gov.in\n   Official listings.",
            formatWebResults("goa hotels", results),
        )
    }

    @Test
    fun `empty results instruct honesty`() {
        assertEquals(
            "Web results for \"nothing\": none found. Say so honestly on the screen; " +
                "do not fabricate specifics.",
            formatWebResults("nothing", emptyList()),
        )
    }

    @Test
    fun `the empty-results text is verbatim from the RN source`() {
        val source = File("../../src/genos/tools/search.ts").readText()
        assertTrue(
            source.contains(": none found. Say so honestly on the screen; do not fabricate specifics."),
        )
    }

    @Test
    fun `an empty published string emits no date parenthetical`() {
        val out = formatWebResults("q", listOf(SearchResult("T", "https://x.dev/a", "s", "")))
        assertEquals("Web results for \"q\":\n1. T - x.dev\n   s", out)
    }

    @Test
    fun `the domain strips the scheme and a leading www`() {
        assertEquals("example.com", resultDomain("https://example.com/path?q=1"))
        assertEquals("example.com", resultDomain("https://www.example.com"))
        assertEquals("example.com", resultDomain("http://example.com"))
        assertEquals("sub.www.example.com", resultDomain("https://sub.www.example.com/x"))
        // Not http(s): the input passes through.
        assertEquals("ftp://example.com/x", resultDomain("ftp://example.com/x"))
        assertEquals("", resultDomain(""))
    }

    @Test
    fun `the prompt section is verbatim from the RN source`() {
        val source = File("../../src/genos/tools/search.ts").readText()
        val start = source.indexOf("export const TOOLS_PROMPT_SECTION = `")
        assertTrue(start >= 0)
        val bodyStart = source.indexOf('`', start) + 1
        val bodyEnd = source.indexOf('`', bodyStart)
        assertEquals(source.substring(bodyStart, bodyEnd), SearchToolText.promptSection)
    }

    @Test
    fun `the prompt section mentions the real tool`() {
        assertTrue(SearchToolText.promptSection.startsWith("\n\n## Live Data (web_search tool)"))
        assertTrue(SearchToolText.promptSection.contains("You have a REAL web_search tool."))
        assertTrue(SearchToolText.promptSection.contains("NEVER call tools for invented/personal content"))
    }
}

class ExaSearchToolTest {
    @Test
    fun `availability requires a key`() {
        val http = ScriptedHttp()
        assertTrue(!ExaSearchTool(null, http).available)
        assertTrue(!ExaSearchTool("", http).available)
        assertTrue(ExaSearchTool("k", http).available)
    }

    @Test
    fun `toolDefs declare web_search with a required query`() {
        val defs = ExaSearchTool("k", ScriptedHttp()).toolDefs
        val fn = defs[0]?.get("function")!!
        assertEquals("function", defs[0]?.get("type")?.str)
        assertEquals("web_search", fn["name"]?.str)
        assertEquals("object", fn["parameters"]?.get("type")?.str)
        assertEquals("string", fn["parameters"]?.get("properties")?.get("query")?.get("type")?.str)
        assertEquals(
            listOf(JsonValue.Str("query")),
            fn["parameters"]?.get("required")?.arr,
        )
        assertEquals("Concise web search query", fn["parameters"]?.get("properties")?.get("query")?.get("description")?.str)
    }

    @Test
    fun `an unknown tool degrades to an ERROR string`() = runTest {
        val out = ExaSearchTool("k", ScriptedHttp()).execute("image_gen", emptyMap())
        assertEquals("ERROR: unknown tool \"image_gen\"", out)
    }

    @Test
    fun `an empty or missing query degrades to an ERROR string`() = runTest {
        val tool = ExaSearchTool("k", ScriptedHttp())
        assertEquals("ERROR: web_search requires a non-empty query", tool.execute("web_search", emptyMap()))
        assertEquals(
            "ERROR: web_search requires a non-empty query",
            tool.execute("web_search", mapOf("query" to JsonValue.Str("   "))),
        )
        assertEquals(
            "ERROR: web_search requires a non-empty query",
            tool.execute("web_search", mapOf("query" to JsonValue.Null)),
        )
    }

    @Test
    fun `an HTTP failure degrades to an ERROR string truncated at 200 units`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 500, errorBody = "x".repeat(400)))
        val out = ExaSearchTool("k", http).execute("web_search", mapOf("query" to JsonValue.Str("q")))
        assertTrue(out.startsWith("ERROR: web search failed ("))
        assertEquals("ERROR: web search failed (".length + 200 + 1, out.length)
    }

    @Test
    fun `an HTTP failure with an empty body reports the status`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 429))
        val out = ExaSearchTool("k", http).execute("web_search", mapOf("query" to JsonValue.Str("q")))
        assertEquals("ERROR: web search failed (Exa HTTP 429)", out)
    }

    @Test
    fun `a thrown transport failure degrades to an ERROR string`() = runTest {
        // Nothing enqueued → the scripted transport throws.
        val out = ExaSearchTool("k", ScriptedHttp())
            .execute("web_search", mapOf("query" to JsonValue.Str("q")))
        assertTrue(out.startsWith("ERROR: web search failed ("))
        assertTrue(out.contains("no scripted response"))
    }

    @Test
    fun `the search request shape matches the RN body`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.json("{\"results\":[]}"))
        ExaSearchTool("exa-key", http).webSearch("goa hotels")
        val request = http.requests.single()
        assertEquals("https://api.exa.ai/search", request.url)
        assertEquals("POST", request.method)
        assertEquals("exa-key", request.headers["x-api-key"])
        assertEquals("application/json", request.headers["Content-Type"])
        assertEquals(
            "{\"query\":\"goa hotels\",\"numResults\":5," +
                "\"contents\":{\"text\":{\"maxCharacters\":400}}}",
            request.bodyText,
        )
    }

    @Test
    fun `result mapping fills the title fallback and drops url-less entries`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.json(
                """
                {"results":[
                  {"title":"A","url":"https://www.a.com/x","text":"  a  ","publishedDate":"2026-01-02T00:00:00Z"},
                  {"url":"https://b.io/y","text":"b"},
                  {"title":"no url","text":"c"},
                  {"url":"","text":"d"}
                ]}
                """.trimIndent(),
            ),
        )
        val results = ExaSearchTool("k", http).webSearch("q")
        assertEquals(2, results.size)
        assertEquals("A", results[0].title)
        assertEquals("a", results[0].snippet)
        assertEquals("2026-01-02T00:00:00Z", results[0].published)
        assertEquals("b.io", results[1].title, "the domain is the title fallback")
        assertEquals(null, results[1].published)
    }

    @Test
    fun `snippet collapse uses the ECMAScript whitespace set`() = runTest {
        val http = ScriptedHttp()
        // \v and U+FEFF are JS whitespace; java.util.regex's \s misses both.
        http.enqueue(
            ScriptedResponse.json(
                "{\"results\":[{\"url\":\"https://x.dev\"," +
                    "\"text\":\"a\\u000b\\u000b b\\ufeffc \\u00a0 d\"}]}",
            ),
        )
        val results = ExaSearchTool("k", http).webSearch("q")
        assertEquals("a b c d", results.single().snippet)
    }

    @Test
    fun `malformed JSON on a 200 degrades to ERROR, not none-found`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.json("not json at all"))
        val out = ExaSearchTool("k", http).execute("web_search", mapOf("query" to JsonValue.Str("q")))
        assertEquals("ERROR: web search failed (Exa returned invalid JSON)", out)
    }

    @Test
    fun `webSearch throws rather than returning empty on failure`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 500, errorBody = "boom"))
        val thrown = assertFailsWith<StreamException> { ExaSearchTool("k", http).webSearch("q") }
        assertEquals("boom", thrown.message)
    }

    @Test
    fun `execute formats a successful search`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.json(
                "{\"results\":[{\"title\":\"T\",\"url\":\"https://www.e.com/a\"," +
                    "\"text\":\"snip\",\"publishedDate\":\"2026-03-04\"}]}",
            ),
        )
        val out = ExaSearchTool("k", http).execute("web_search", mapOf("query" to JsonValue.Str(" q ")))
        assertEquals("Web results for \"q\":\n1. T - e.com (2026-03-04)\n   snip", out)
    }

    @Test
    fun `a missing results array yields the none-found message`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.json("{}"))
        val out = ExaSearchTool("k", http).execute("web_search", mapOf("query" to JsonValue.Str("q")))
        assertTrue(out.startsWith("Web results for \"q\": none found."))
    }
}
