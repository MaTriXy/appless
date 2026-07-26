package dev.appless.uicore

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * The semantic-image policy (`src/genos/tools/images.ts`): `/api/img?...`
 * references resolve to a real photo URL, anything else passes through.
 */
class SemanticImageTest {

    @Test
    fun `only api img references are semantic`() {
        assertNull(Images.parseImgUrl("https://example.com/a.png"))
        assertNull(Images.parseImgUrl(""))
        assertEquals(
            ImgQuery(q = "mountain lake", seed = 7, w = 900, h = 600),
            Images.parseImgUrl("/api/img?q=mountain+lake&seed=7&w=900&h=600"),
        )
    }

    @Test
    fun `defaults and clamps match the RN parser`() {
        // `params.q || "abstract gradient"`, seed 1, w 800, h 500.
        assertEquals(
            ImgQuery("abstract gradient", 1, 800, 500),
            Images.parseImgUrl("/api/img"),
        )
        assertEquals(
            ImgQuery("abstract gradient", 1, 800, 500),
            Images.parseImgUrl("/api/img?q="),
        )
        // clamp(n, min, max); an unparsable number falls to `min`.
        assertEquals(
            ImgQuery("x", 1, 40, 1600),
            Images.parseImgUrl("/api/img?q=x&seed=0&w=1&h=99999"),
        )
        assertEquals(
            ImgQuery("x", 10_000, 40, 40),
            Images.parseImgUrl("/api/img?q=x&seed=999999&w=nope&h=nope"),
        )
    }

    @Test
    fun `the keyword filter strips everything outside the allowed set`() {
        // `.replace(/\+/g, " ").replace(/[^a-zA-Z0-9, -]/g, "").trim()`
        assertEquals("caf latte 2", Images.parseImgUrl("/api/img?q=caf%C3%A9+latte+%232")!!.q)
        assertEquals("sunset, beach", Images.parseImgUrl("/api/img?q=sunset%2C+beach")!!.q)
        assertEquals("a-bc", Images.parseImgUrl("/api/img?q=a-b_c")!!.q, "underscores are not in the allowed set")
    }

    @Test
    fun `LoremFlickr URLs collapse spaces and commas into keyword separators`() {
        // `encodeURIComponent` percent-encodes the separator comma (`%2C`) — node-verified.
        assertEquals(
            "https://loremflickr.com/900/600/mountain%2Clake?lock=7",
            Images.loremflickrUrl(ImgQuery("mountain lake", 7, 900, 600)),
        )
        assertEquals(
            "https://loremflickr.com/800/500/sunset%2Cbeach?lock=1",
            Images.loremflickrUrl(ImgQuery("sunset, beach", 1, 800, 500)),
        )
    }

    @Test
    fun `without a key every semantic src resolves to LoremFlickr`() {
        assertEquals(
            SemanticImage.Resolution.Url("https://loremflickr.com/800/500/abstract%2Cgradient?lock=1"),
            SemanticImage.resolve("/api/img"),
        )
        assertEquals(
            SemanticImage.Resolution.Url("https://cdn.example.com/hero.jpg"),
            SemanticImage.resolve("https://cdn.example.com/hero.jpg"),
            "a non-semantic src passes through untouched",
        )
        assertEquals(SemanticImage.Resolution.None, SemanticImage.resolve(null))
        assertEquals(SemanticImage.Resolution.None, SemanticImage.resolve(""))
    }

    @Test
    fun `with a key an in-flight search shows the placeholder, never a double load`() {
        val src = "/api/img?q=ramen&seed=3&w=600&h=400"
        assertEquals(SemanticImage.Resolution.Pending, SemanticImage.resolve(src, unsplashCandidates = null))
        // An empty cache entry means the search FAILED — fall back to LoremFlickr.
        assertEquals(
            SemanticImage.Resolution.Url("https://loremflickr.com/600/400/ramen?lock=3"),
            SemanticImage.resolve(src, unsplashCandidates = emptyList()),
        )
        // `candidates[seed % candidates.length]` + the sizing query.
        assertEquals(
            SemanticImage.Resolution.Url("https://img/b&w=600&h=400&fit=crop&q=80"),
            SemanticImage.resolve(src, unsplashCandidates = listOf("https://img/a?x=1", "https://img/b")),
        )
        // A non-semantic src ignores the cache entirely.
        assertEquals(
            SemanticImage.Resolution.Url("https://cdn/x.png"),
            SemanticImage.resolve("https://cdn/x.png", unsplashCandidates = null),
        )
    }

    @Test
    fun `query exposes the parsed reference for cache warming`() {
        assertEquals(ImgQuery("ramen", 3, 600, 400), SemanticImage.query("/api/img?q=ramen&seed=3&w=600&h=400"))
        assertNull(SemanticImage.query("https://cdn/x.png"))
        assertNull(SemanticImage.query(null))
    }
}
