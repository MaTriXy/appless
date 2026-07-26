package dev.appless.genoscore

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async

/** Semantic image tool (src/genos/tools/images.ts, spec §11.5). */
public data class ImgQuery(val q: String, val seed: Int, val w: Int, val h: Int)

public object Images {
    /**
     * Clamp with JS `Number` semantics: NaN AND ±Infinity fall to the min bound
     * (RN: `Number.isFinite(n) ? n : min` before `Math.min/max`), so a digit run
     * long enough to overflow to Infinity clamps to min, while a merely huge
     * finite value (a 23-digit seed ≈ 1.23e22) clamps to max — both matching JS
     * `parseInt` feeding the clamp.
     */
    private fun clamp(n: Double, min: Int, max: Int): Int {
        if (!n.isFinite()) return min
        return maxOf(min.toDouble(), minOf(max.toDouble(), n)).toInt()
    }

    /**
     * Parse an `/api/img?...` reference; null for any other src.
     *
     * Key-only pairs (no "=") are SKIPPED entirely — unlike [Lang.parseGenosUrl].
     * `q` defaults to "abstract gradient", `+`→space, stripped to
     * `[a-zA-Z0-9, -]`, trimmed. `seed` default 1 clamp [1, 10000]; `w` default
     * 800 clamp [40, 1600]; `h` default 500 clamp [40, 1600]; NaN/±Infinity → the
     * min bound.
     */
    public fun parseImgUrl(src: String): ImgQuery? {
        if (!src.startsWith("/api/img")) return null
        val params = LinkedHashMap<String, String>()
        val queryParts = src.split('?')
        val query = if (queryParts.size > 1) queryParts[1] else ""
        for (pair in query.split('&')) {
            val eq = pair.indexOf('=')
            if (eq == -1) continue
            val key = pair.substring(0, eq)
            val value = pair.substring(eq + 1)
            params[key] = jsDecodeURIComponent(value) ?: value
        }
        // RN: `params.q || "abstract gradient"` — a JS falsy check, so an empty
        // value also takes the default.
        var q = params["q"].orEmpty()
        if (q.isEmpty()) q = "abstract gradient"
        q = q.replace('+', ' ')
        // RN: /[^a-zA-Z0-9, -]/g — explicit ASCII class, no `i` flag: identical
        // in Java and JS.
        q = JsRegex.replaceAll("[^a-zA-Z0-9, -]", q, "")
        q = jsTrim(q)
        val seedText = params["seed"].takeUnless { it.isNullOrEmpty() } ?: "1"
        val wText = params["w"].takeUnless { it.isNullOrEmpty() } ?: "800"
        val hText = params["h"].takeUnless { it.isNullOrEmpty() } ?: "500"
        return ImgQuery(
            q = q,
            seed = clamp(jsParseInt(seedText), 1, 10_000),
            w = clamp(jsParseInt(wText), 40, 1600),
            h = clamp(jsParseInt(hText), 40, 1600),
        )
    }

    /**
     * `https://loremflickr.com/{w}/{h}/{keywords}?lock={seed}` where keywords is
     * `q` with runs of spaces/commas collapsed to "," then percent-encoded.
     */
    public fun loremflickrUrl(query: ImgQuery): String {
        val keywords = jsEncodeURIComponent(JsRegex.replaceAll("[ ,]+", query.q, ","))
        return "https://loremflickr.com/${query.w}/${query.h}/$keywords?lock=${query.seed}"
    }

    /**
     * Unsplash raw URL + crop suffix: pick `candidates[seed % count]` and append
     * `&w={w}&h={h}&fit=crop&q=80`. Empty candidates → LoremFlickr.
     */
    public fun resolveUnsplash(query: ImgQuery, candidates: List<String>): String {
        if (candidates.isEmpty()) return loremflickrUrl(query)
        val raw = candidates[query.seed % candidates.size]
        return "$raw&w=${query.w}&h=${query.h}&fit=crop&q=80"
    }
}

/**
 * query → Unsplash raw URLs, with in-flight dedupe (images.ts `unsplashCache` +
 * `unsplashPending`). An empty list means the search failed — use LoremFlickr.
 *
 * Single-threaded by contract, like every other stateful type here: [scope] must
 * be confined to the same dispatcher the caller uses.
 */
public class UnsplashCache(
    private val http: HttpFetching,
    private val accessKey: String?,
    private val scope: CoroutineScope,
) {
    private val cache = HashMap<String, List<String>>()

    /** images.ts `unsplashPending`: one shared fetch per in-flight query. */
    private val pending = HashMap<String, Deferred<Unit>>()

    public fun cached(q: String): List<String>? = cache[q]

    public fun store(q: String, urls: List<String>) {
        cache[q] = urls
    }

    /**
     * `ensureUnsplash` parity: concurrent ensures for the same query await one
     * shared fetch (a pending entry is joined, never duplicated); the entry is
     * removed on completion (RN `finally`), so a LATER ensure fetches again —
     * callers consult [cached] first, exactly like `useSemanticImage`. Any
     * failure (HTTP error, thrown fetch, malformed JSON) caches an empty list.
     */
    public suspend fun ensure(q: String) {
        pending[q]?.let {
            it.await()
            return
        }
        val task = scope.async {
            val urls = fetchCandidates(q)
            cache[q] = urls
            pending.remove(q)
            Unit
        }
        pending[q] = task
        task.await()
    }

    /**
     * `GET https://api.unsplash.com/search/photos?query=...&per_page=10` with
     * Client-ID auth; maps `results[].urls.raw`, dropping absent/empty entries
     * (RN `.filter((u): u is string => !!u)`). Non-OK → `{}` → []; throw → [].
     */
    private suspend fun fetchCandidates(q: String): List<String> {
        val request = HttpRequest(
            url = "https://api.unsplash.com/search/photos?query=${jsEncodeURIComponent(q)}&per_page=10",
            method = "GET",
            headers = mapOf("Authorization" to "Client-ID ${accessKey ?: ""}"),
        )
        // RN wraps the whole fetch+json in one try/catch that degrades to [];
        // CancellationException is re-thrown so a cancelled caller still unwinds.
        val response = try {
            http.fetch(request)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            null
        }
        val (head, data) = response ?: return emptyList()
        if (!head.ok) return emptyList()
        val json = JsonValue.parse(data) ?: return emptyList()
        val results = json["results"]?.arr ?: return emptyList()
        return results.mapNotNull { r -> r["urls"]?.get("raw")?.str?.takeIf { it.isNotEmpty() } }
    }
}
