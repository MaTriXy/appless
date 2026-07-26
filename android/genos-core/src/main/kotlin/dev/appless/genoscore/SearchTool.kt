package dev.appless.genoscore

/** src/genos/tools/search.ts parity: Exa-backed `web_search` tool. */
public data class SearchResult(
    val title: String,
    val url: String,
    val snippet: String,
    val published: String? = null,
)

/**
 * Tool execution seam offered to the stream loop.
 *
 * Cancellation contract: [execute] runs inside the stream's coroutine, which
 * `StreamCancelToken.cancel()` cancels (RN passes the `AbortSignal` into
 * `executeTool`). Suspending implementations are cooperatively cancellable for
 * free; the stream loop discards all outputs and never issues the next round's
 * request once cancelled.
 */
public interface ToolExecuting {
    /** Whether any tools should be offered (Exa key present). */
    public val available: Boolean

    /** Prompt section appended to the system prompt when available. */
    public val promptSection: String

    /** OpenAI-format tool definitions for the request body. */
    public val toolDefs: JsonValue

    /** Execute one call; failures return an "ERROR: ..." string, never throw. */
    public suspend fun execute(name: String, args: Map<String, JsonValue>): String
}

public object SearchToolText {
    /** `TOOLS_PROMPT_SECTION` verbatim. */
    public val promptSection: String = "\n\n## Live Data (web_search tool)\n" +
        "You have a REAL web_search tool. When a truthful screen needs real-world or current " +
        "facts - latest news, live prices or scores, current weather, real venues (famous " +
        "hotels, restaurants, attractions) in real places, current events - call web_search " +
        "FIRST (1-3 focused queries), then compose the screen strictly from the returned " +
        "facts: real names, real numbers, real dates. Finish such screens with a small " +
        "TextContent(\"Sources: …\", \"small\") footnote naming the source domains. If results " +
        "are empty or the tool errors, build the screen from what you know and mark it clearly " +
        "as possibly outdated. NEVER call tools for invented/personal content (messages, notes, " +
        "playlists, settings, workouts) - invent that as usual."
}

/**
 * Exa `web_search`: `POST https://api.exa.ai/search` with `x-api-key`,
 * `numResults` 5, `contents.text.maxCharacters` 400. All failures degrade to
 * ERROR strings.
 */
public class ExaSearchTool(
    public val apiKey: String?,
    private val http: HttpFetching,
) : ToolExecuting {

    override val available: Boolean
        get() = !apiKey.isNullOrEmpty()

    override val promptSection: String
        get() = SearchToolText.promptSection

    override val toolDefs: JsonValue
        get() = JsonValue.Arr(
            listOf(
                JsonValue.obj(
                    "type" to JsonValue.Str("function"),
                    "function" to JsonValue.obj(
                        "name" to JsonValue.Str("web_search"),
                        "description" to JsonValue.Str(
                            "Search the live web. Use for current or real-world facts: news, " +
                                "prices, scores, weather, events, and real places such as famous " +
                                "hotels, restaurants or attractions.",
                        ),
                        "parameters" to JsonValue.obj(
                            "type" to JsonValue.Str("object"),
                            "properties" to JsonValue.obj(
                                "query" to JsonValue.obj(
                                    "type" to JsonValue.Str("string"),
                                    "description" to JsonValue.Str("Concise web search query"),
                                ),
                            ),
                            "required" to JsonValue.Arr(listOf(JsonValue.Str("query"))),
                        ),
                    ),
                ),
            ),
        )

    override suspend fun execute(name: String, args: Map<String, JsonValue>): String {
        if (name != "web_search") return "ERROR: unknown tool \"$name\""
        // RN: String(args.query ?? "").trim().
        val query = jsTrim(jsStringCoerce(args["query"]))
        if (query.isEmpty()) return "ERROR: web_search requires a non-empty query"
        return try {
            formatWebResults(query, webSearch(query))
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            // RN emits the bare err.message here too — and this string goes
            // to the MODEL, so a JVM class prefix would be noise the Swift
            // port does not send.
            "ERROR: web search failed (${jsErrorMessage(e)})"
        }
    }

    /**
     * Raw Exa search; throws on HTTP/network failure (detail truncated to 200
     * chars). Results mapped: title fallback = domain, snippet
     * whitespace-collapsed + trimmed, url-less entries dropped.
     */
    public suspend fun webSearch(query: String): List<SearchResult> {
        val body = JsonValue.obj(
            "query" to JsonValue.Str(query),
            "numResults" to JsonValue.Num(GenOSConstants.EXA_NUM_RESULTS.toDouble()),
            "contents" to JsonValue.obj(
                "text" to JsonValue.obj(
                    "maxCharacters" to JsonValue.Num(GenOSConstants.EXA_MAX_CHARACTERS.toDouble()),
                ),
            ),
        )
        val request = HttpRequest(
            url = "https://api.exa.ai/search",
            method = "POST",
            headers = mapOf("Content-Type" to "application/json", "x-api-key" to (apiKey ?: "")),
            body = body.stringified().toByteArray(Charsets.UTF_8),
        )
        val (head, data) = http.fetch(request)
        if (!head.ok) {
            // RN: detail.slice(0, 200) — UTF-16 units.
            val detail = jsSliceTo(data.toString(Charsets.UTF_8), 200)
            throw StreamException(detail.ifEmpty { "Exa HTTP ${head.status}" })
        }
        // RN: `await res.json()` REJECTS on a malformed body, so executeTool's
        // catch degrades to `ERROR: web search failed (...)` — never the
        // "none found... do not fabricate" tool message. Throw to match.
        val json = JsonValue.parse(data) ?: throw StreamException("Exa returned invalid JSON")
        val rawResults = json["results"]?.arr ?: emptyList()
        return rawResults.mapNotNull { r ->
            val url = r["url"]?.str?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val text = r["text"]?.str ?: ""
            // RN: (r.text ?? "").replace(/\s+/g, " ").trim() — JS \s spelled out.
            val snippet = jsTrim(JsRegex.replaceAll("${JsRegex.WS}+", text, " "))
            SearchResult(
                title = r["title"]?.str ?: resultDomain(url),
                url = url,
                snippet = snippet,
                published = r["publishedDate"]?.str,
            )
        }
    }
}

/** "Web results for ..." tool-message formatting (pure). */
public fun formatWebResults(query: String, results: List<SearchResult>): String {
    if (results.isEmpty()) {
        return "Web results for \"$query\": none found. Say so honestly on the screen; " +
            "do not fabricate specifics."
    }
    val lines = results.mapIndexed { i, r ->
        // RN: r.published.slice(0, 10) — UTF-16 units.
        val date = if (!r.published.isNullOrEmpty()) " (${jsSliceTo(r.published, 10)})" else ""
        "${i + 1}. ${r.title} - ${resultDomain(r.url)}$date\n   ${r.snippet}"
    }
    return "Web results for \"$query\":\n" + lines.joinToString("\n")
}

/**
 * Hostname without a leading `www.`, or the input when not http(s).
 *
 * RN: `/^https?:\/\/(?:www\.)?([^\/]+)/` — literals plus a negated ASCII class
 * (which matches line terminators in both engines) and `^` with no `m` flag
 * (start-of-input in both). Identical in Java and JS.
 */
public fun resultDomain(url: String): String {
    val m = JsRegex.first("\\Ahttps?://(?:www\\.)?([^/]+)", url) ?: return url
    return m.getOrNull(1) ?: url
}
