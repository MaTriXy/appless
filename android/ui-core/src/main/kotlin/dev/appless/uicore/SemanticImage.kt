package dev.appless.uicore

/**
 * `useSemanticImage` (`src/genos/tools/images.ts`) without React: turn a
 * model-emitted `src` into a loadable URL.
 *
 * The prompt makes the model reference every image as
 * `/api/img?q=KEYWORDS&seed=N&w=W&h=H` — a declarative query, never a real URL.
 * These resolve to LoremFlickr with no key (zero-config), or to an Unsplash
 * search result when a key is configured.
 *
 * NO Compose in this file.
 */

/** `ImgQuery` — `tools/images.ts` L11-16. */
public data class ImgQuery(val q: String, val seed: Int, val w: Int, val h: Int)

public object Images {

    /** `clamp` — `tools/images.ts` L18-19; a non-finite/unparsable n falls to `min`. */
    private fun clamp(n: Int?, min: Int, max: Int): Int =
        if (n == null) min else maxOf(min, minOf(max, n))

    /**
     * Parse an `/api/img?...` reference; `null` for any other src —
     * `tools/images.ts` L21-43.
     *
     * Query decoding mirrors the JS exactly: split on `&`, split each pair at
     * the FIRST `=`, pairs with no `=` are skipped, and a `decodeURIComponent`
     * failure keeps the raw (still-encoded) value.
     */
    public fun parseImgUrl(src: String): ImgQuery? {
        if (!src.startsWith("/api/img")) return null
        val params = LinkedHashMap<String, String>()
        val queryString = src.split("?").getOrNull(1) ?: ""
        for (pair in queryString.split("&")) {
            val eq = pair.indexOf('=')
            if (eq == -1) continue
            val key = pair.substring(0, eq)
            val raw = pair.substring(eq + 1)
            params[key] = decodeUriComponentOrRaw(raw)
        }
        // `params.q || "abstract gradient"` — an EMPTY string is falsy in JS.
        val q = (params["q"].takeUnless { it.isNullOrEmpty() } ?: "abstract gradient")
            .replace("+", " ")
            .replace(Regex("[^a-zA-Z0-9, -]"), "")
            .trim()
        return ImgQuery(
            q = q,
            seed = clamp(parseIntJs(params["seed"].takeUnless { it.isNullOrEmpty() } ?: "1"), 1, 10_000),
            w = clamp(parseIntJs(params["w"].takeUnless { it.isNullOrEmpty() } ?: "800"), 40, 1600),
            h = clamp(parseIntJs(params["h"].takeUnless { it.isNullOrEmpty() } ?: "500"), 40, 1600),
        )
    }

    /**
     * `parseInt(s, 10)` — leading whitespace and sign, then digits until the
     * first non-digit; `NaN` (here `null`) when no digits lead.
     */
    private fun parseIntJs(s: String): Int? {
        var i = 0
        while (i < s.length && s[i].isWhitespace()) i++
        var sign = 1
        if (i < s.length && (s[i] == '+' || s[i] == '-')) {
            if (s[i] == '-') sign = -1
            i++
        }
        val start = i
        while (i < s.length && s[i] in '0'..'9') i++
        if (i == start) return null
        val digits = s.substring(start, i)
        val value = digits.toLongOrNull() ?: return Int.MAX_VALUE * sign
        return (value * sign).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
    }

    private fun decodeUriComponentOrRaw(raw: String): String = try {
        java.net.URLDecoder.decode(raw.replace("+", "%2B"), Charsets.UTF_8)
    } catch (_: Exception) {
        raw
    }

    /** `loremflickrUrl` — `tools/images.ts` L45-48. */
    public fun loremflickrUrl(query: ImgQuery): String {
        val keywords = MapGeometry.encodeUriComponent(query.q.replace(Regex("[ ,]+"), ","))
        return "https://loremflickr.com/${query.w}/${query.h}/$keywords?lock=${query.seed}"
    }

    /** `candidates[parsed.seed % candidates.length]` + sizing — `tools/images.ts` L115-116. */
    public fun resolveUnsplash(query: ImgQuery, candidates: List<String>): String {
        val raw = candidates[query.seed % candidates.size]
        return "$raw&w=${query.w}&h=${query.h}&fit=crop&q=80"
    }
}

/**
 * The resolution POLICY the renderers apply, so the Compose layer never
 * re-derives it — `tools/images.ts` L86-117.
 */
public object SemanticImage {

    /** How a `src` resolved. */
    public sealed interface Resolution {
        /** Load this URL. */
        public data class Url(val url: String) : Resolution

        /**
         * An Unsplash search is in flight — show the themed placeholder and
         * nothing else, so the image never double-loads (`return undefined`,
         * `images.ts` L113).
         */
        public data object Pending : Resolution

        /** No `src` at all — show the placeholder (`images.ts` L109). */
        public data object None : Resolution
    }

    /**
     * Resolve without an Unsplash key: `/api/img?...` references become
     * LoremFlickr URLs, everything else passes through untouched
     * (`images.ts` L109-111 with the key unset).
     */
    public fun resolve(src: String?): Resolution {
        if (src.isNullOrEmpty()) return Resolution.None
        val query = Images.parseImgUrl(src) ?: return Resolution.Url(src)
        return Resolution.Url(Images.loremflickrUrl(query))
    }

    /**
     * Resolve with an Unsplash key. `candidates` is the cache entry for the
     * parsed query: `null` means "still searching" (placeholder), empty means
     * "search failed" (LoremFlickr) — `images.ts` L112-116.
     */
    public fun resolve(src: String?, unsplashCandidates: List<String>?): Resolution {
        if (src.isNullOrEmpty()) return Resolution.None
        val query = Images.parseImgUrl(src) ?: return Resolution.Url(src)
        if (unsplashCandidates == null) return Resolution.Pending
        if (unsplashCandidates.isEmpty()) return Resolution.Url(Images.loremflickrUrl(query))
        return Resolution.Url(Images.resolveUnsplash(query, unsplashCandidates))
    }

    /**
     * The parsed query behind a semantic `src`, for callers that need to warm
     * the Unsplash cache before rendering.
     */
    public fun query(src: String?): ImgQuery? {
        if (src.isNullOrEmpty()) return null
        return Images.parseImgUrl(src)
    }
}
