package dev.appless.genoscore

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** spec/openui-lang.md §11.5 — parseImgUrl clamps and image resolution. */
class ParseImgUrlTest {
    @Test
    fun `a non-semantic src passes through as null`() {
        assertNull(Images.parseImgUrl("https://example.com/a.png"))
        assertNull(Images.parseImgUrl(""))
        assertNull(Images.parseImgUrl("/api/imgx".take(4)))
    }

    @Test
    fun `a bare reference gets all the defaults`() {
        assertEquals(ImgQuery("abstract gradient", 1, 800, 500), Images.parseImgUrl("/api/img"))
        assertEquals(ImgQuery("abstract gradient", 1, 800, 500), Images.parseImgUrl("/api/img?"))
    }

    @Test
    fun `a full query is parsed`() {
        assertEquals(
            ImgQuery("sushi platter", 3, 800, 440),
            Images.parseImgUrl("/api/img?q=sushi+platter&seed=3&w=800&h=440"),
        )
    }

    @Test
    fun `key-only pairs are skipped entirely, unlike parseGenosUrl`() {
        // /api/img?q&seed=2 → q is ABSENT from params, so the default applies.
        assertEquals(
            ImgQuery("abstract gradient", 2, 800, 500),
            Images.parseImgUrl("/api/img?q&seed=2"),
        )
    }

    @Test
    fun `an empty value falls back to the default like a JS falsy check`() {
        assertEquals(
            ImgQuery("abstract gradient", 1, 800, 500),
            Images.parseImgUrl("/api/img?q=&seed=&w=&h="),
        )
    }

    @Test
    fun `q is sanitized to the safe charset`() {
        // spec: caf%C3%A9 "neon"! → caf neon
        assertEquals("caf neon", Images.parseImgUrl("/api/img?q=caf%C3%A9+%22neon%22!")?.q)
        assertEquals("a1, b-c", Images.parseImgUrl("/api/img?q=a1,%20b-c")?.q)
        // Everything strippable leaves an empty q (NOT the default — the default
        // is chosen before sanitizing).
        assertEquals("", Images.parseImgUrl("/api/img?q=%E2%82%AC%E2%82%AC")?.q)
    }

    @Test
    fun `a bad percent escape is kept raw then sanitized`() {
        assertEquals("100zz", Images.parseImgUrl("/api/img?q=100%zz")?.q)
    }

    @Test
    fun `clamps and NaN fall to the min bound`() {
        assertEquals(ImgQuery("abstract gradient", 1, 40, 40), Images.parseImgUrl("/api/img?seed=0&w=1&h=-5"))
        assertEquals(
            ImgQuery("abstract gradient", 10000, 1600, 1600),
            Images.parseImgUrl("/api/img?seed=99999&w=9999&h=9999"),
        )
        // parseInt("abc") is NaN → the min bound.
        assertEquals(ImgQuery("abstract gradient", 1, 40, 40), Images.parseImgUrl("/api/img?seed=abc&w=x&h=y"))
    }

    @Test
    fun `an NBSP-prefixed seed skips the full JS whitespace set`() {
        // node: parseInt("\u00A07", 10) === 7.
        assertEquals(7, Images.parseImgUrl("/api/img?seed=%C2%A07")?.seed)
    }

    @Test
    fun `overflow-length seeds saturate through Double like JS`() {
        // A 23-digit seed is a huge FINITE double → clamps to max.
        assertEquals(10000, Images.parseImgUrl("/api/img?seed=12345678901234567890123")?.seed)
        // 400 digits overflow to Infinity → Number.isFinite is false → min.
        assertEquals(1, Images.parseImgUrl("/api/img?seed=${"9".repeat(400)}")?.seed)
    }

    @Test
    fun `combining marks glued to delimiters parse like JS`() {
        // Kotlin String is UTF-16, so startsWith/split/indexOf behave exactly
        // like the JS originals here.
        assertNull(Images.parseImgUrl("/api/im\u0301g?q=x"))
        assertEquals("x", Images.parseImgUrl("/api/img\u0301?q=x")?.q)
        val parsed = Images.parseImgUrl("/api/img?q=a&\u0301seed=5")
        assertEquals("a", parsed?.q)
        assertEquals(1, parsed?.seed, "the key is \"\\u0301seed\", not \"seed\"")
    }

    @Test
    fun `duplicate keys - the last one wins like a JS object assignment`() {
        assertEquals(9, Images.parseImgUrl("/api/img?seed=2&seed=9")?.seed)
    }
}

class ImageResolutionTest {
    @Test
    fun `loremflickr URL construction`() {
        assertEquals(
            "https://loremflickr.com/800/440/sushi%2Cplatter?lock=3",
            Images.loremflickrUrl(ImgQuery("sushi platter", 3, 800, 440)),
        )
    }

    @Test
    fun `loremflickr collapses space and comma runs to a single comma`() {
        assertEquals(
            "https://loremflickr.com/40/40/a%2Cb%2Cc?lock=1",
            Images.loremflickrUrl(ImgQuery("a , ,  b,c", 1, 40, 40)),
        )
    }

    @Test
    fun `the unsplash pick is seed-indexed with the crop suffix`() {
        val candidates = listOf("https://img/0?x=1", "https://img/1?x=1", "https://img/2?x=1")
        assertEquals(
            "https://img/1?x=1&w=800&h=500&fit=crop&q=80",
            Images.resolveUnsplash(ImgQuery("q", 4, 800, 500), candidates),
        )
        assertEquals(
            "https://img/0?x=1&w=800&h=500&fit=crop&q=80",
            Images.resolveUnsplash(ImgQuery("q", 3, 800, 500), candidates),
        )
    }

    @Test
    fun `empty candidates fall back to loremflickr`() {
        assertEquals(
            Images.loremflickrUrl(ImgQuery("beach", 2, 400, 300)),
            Images.resolveUnsplash(ImgQuery("beach", 2, 400, 300), emptyList()),
        )
    }
}

class UnsplashCacheTest {
    private fun photosResponse(vararg raws: String): ScriptedResponse =
        ScriptedResponse.json(
            "{\"results\":[" + raws.joinToString(",") { "{\"urls\":{\"raw\":\"$it\"}}" } + "]}",
        )

    @Test
    fun `a successful search caches the raw urls`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(photosResponse("https://a", "https://b"))
        val cache = UnsplashCache(http, "unsplash-key", appScope())
        assertNull(cache.cached("beach"))
        cache.ensure("beach")
        assertEquals(listOf("https://a", "https://b"), cache.cached("beach"))
        val request = http.requests.single()
        assertEquals("https://api.unsplash.com/search/photos?query=beach&per_page=10", request.url)
        assertEquals("GET", request.method)
        assertEquals("Client-ID unsplash-key", request.headers["Authorization"])
    }

    @Test
    fun `the query is percent-encoded in the search url`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(photosResponse("https://a"))
        UnsplashCache(http, "k", appScope()).ensure("sushi platter, neon")
        assertEquals(
            "https://api.unsplash.com/search/photos?query=sushi%20platter%2C%20neon&per_page=10",
            http.requests.single().url,
        )
    }

    @Test
    fun `entries without a raw url are dropped`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(
            ScriptedResponse.json(
                "{\"results\":[{\"urls\":{\"raw\":\"https://a\"}},{\"urls\":{}},{}," +
                    "{\"urls\":{\"raw\":\"\"}}]}",
            ),
        )
        val cache = UnsplashCache(http, "k", appScope())
        cache.ensure("q")
        assertEquals(listOf("https://a"), cache.cached("q"))
    }

    @Test
    fun `concurrent ensures for the same query share one fetch`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(photosResponse("https://a"))
        val cache = UnsplashCache(http, "k", appScope())
        val a = launch { cache.ensure("shared") }
        val b = launch { cache.ensure("shared") }
        a.join()
        b.join()
        testScheduler.advanceUntilIdle()
        assertEquals(1, http.requests.size, "one shared fetch, never duplicated")
        assertEquals(listOf("https://a"), cache.cached("shared"))
    }

    @Test
    fun `the pending entry clears so a later ensure refetches`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(photosResponse("https://first"))
        http.enqueue(photosResponse("https://second"))
        val cache = UnsplashCache(http, "k", appScope())
        cache.ensure("q")
        testScheduler.advanceUntilIdle()
        cache.ensure("q")
        testScheduler.advanceUntilIdle()
        assertEquals(2, http.requests.size)
        assertEquals(listOf("https://second"), cache.cached("q"))
    }

    @Test
    fun `a failed search caches empty for the loremflickr fallback`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse(status = 401, errorBody = "nope"))
        val cache = UnsplashCache(http, "k", appScope())
        cache.ensure("q")
        assertEquals(emptyList(), cache.cached("q"))
        assertEquals(
            Images.loremflickrUrl(ImgQuery("q", 1, 800, 500)),
            Images.resolveUnsplash(ImgQuery("q", 1, 800, 500), cache.cached("q")!!),
        )
    }

    @Test
    fun `a thrown fetch and malformed JSON both cache empty`() = runTest {
        val http = ScriptedHttp()
        val cache = UnsplashCache(http, "k", appScope())
        cache.ensure("thrown") // nothing enqueued → the transport throws
        assertEquals(emptyList(), cache.cached("thrown"))
        http.enqueue(ScriptedResponse.json("<html/>"))
        cache.ensure("malformed")
        assertEquals(emptyList(), cache.cached("malformed"))
    }

    @Test
    fun `store seeds the cache without any network`() = runTest {
        val http = ScriptedHttp()
        val cache = UnsplashCache(http, "k", appScope())
        cache.store("preset", listOf("https://seeded"))
        assertEquals(listOf("https://seeded"), cache.cached("preset"))
        assertTrue(http.requests.isEmpty())
    }

    @Test
    fun `a null access key still sends a Client-ID header like RN`() = runTest {
        val http = ScriptedHttp()
        http.enqueue(photosResponse("https://a"))
        UnsplashCache(http, null, appScope()).ensure("q")
        assertEquals("Client-ID ", http.requests.single().headers["Authorization"])
    }
}
