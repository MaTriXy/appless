package dev.appless.genoscore

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** src/genos/store.ts controller: caches, prefetch, retry, context building. */
class ControllerOpenAppTest {
    @Test
    fun `openApp launches a pending screen and starts a stream`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        val screen = h.store.get(id)!!
        assertEquals("screen-1", id)
        assertEquals("weather", screen.appId)
        assertEquals("Weather", screen.appName)
        assertEquals(sampleApp.request, screen.request)
        assertEquals(ScreenStatus.PENDING, screen.status)
        assertTrue(!screen.speculative)
        assertNull(screen.parentId)
        assertEquals(1, h.streamer.count)
    }

    @Test
    fun `openApp reuses a done home screen without regenerating`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.finishLast("root = Card()")
        assertEquals(id, h.controller.openApp(sampleApp))
        assertEquals(1, h.streamer.count)
    }

    @Test
    fun `openApp reuses an in-flight screen until it goes stale`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.clock.advance(GenOSConstants.STALE_MS)
        assertEquals(id, h.controller.openApp(sampleApp))
        assertEquals(1, h.streamer.count)
    }

    @Test
    fun `a screen stuck past STALE_MS retries in place`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.clock.advance(GenOSConstants.STALE_MS + 1)
        assertEquals(id, h.controller.openApp(sampleApp), "same id — retried in place")
        assertEquals(2, h.streamer.count)
        assertEquals(GenOSConstants.STALE_MS + 1, h.store.get(id)?.startedAt)
    }

    @Test
    fun `an errored home screen retries in place`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onError(StreamException("boom"))
        assertEquals(ScreenStatus.ERROR, h.store.get(id)?.status)
        assertEquals(id, h.controller.openApp(sampleApp))
        assertEquals(2, h.streamer.count)
        assertEquals(ScreenStatus.PENDING, h.store.get(id)?.status)
        assertNull(h.store.get(id)?.error)
    }

    @Test
    fun `screen ids increment monotonically`() {
        val h = ControllerHarness()
        val a = h.controller.openApp(sampleApp)
        val b = h.controller.openApp(sampleApp.copy(id = "notes", name = "Notes"))
        assertEquals("screen-1", a)
        assertEquals("screen-2", b)
    }
}

class ControllerDeepLinkTest {
    @Test
    fun `deep links cache by lower-cased appId and request`() {
        val h = ControllerHarness(apps = Apps.all)
        val id = h.controller.openDeepLink("Music", "play jazz")
        h.finishLast("root = Card()")
        assertEquals(id, h.controller.openDeepLink("music", "play jazz"))
        assertEquals(1, h.streamer.count)
        // A different request is a different cache entry.
        assertNotEquals(id, h.controller.openDeepLink("music", "play rock"))
        assertEquals(2, h.streamer.count)
    }

    @Test
    fun `a known appId resolves its catalog name`() {
        val h = ControllerHarness(apps = Apps.all)
        val id = h.controller.openDeepLink("WEATHER", "forecast")
        assertEquals("weather", h.store.get(id)?.appId)
        assertEquals("Weather", h.store.get(id)?.appName)
    }

    @Test
    fun `an unknown appId gets a capitalized fallback name`() {
        val h = ControllerHarness(apps = Apps.all)
        val id = h.controller.openDeepLink("plants", "water schedule")
        assertEquals("plants", h.store.get(id)?.appId)
        assertEquals("Plants", h.store.get(id)?.appName)
    }

    @Test
    fun `a stale deep-linked screen retries in place`() {
        val h = ControllerHarness(apps = Apps.all)
        val id = h.controller.openDeepLink("music", "play jazz")
        h.streamer.last!!.handlers.onError(StreamException("nope"))
        assertEquals(id, h.controller.openDeepLink("music", "play jazz"))
        assertEquals(2, h.streamer.count)
    }

    @Test
    fun `the fallback name capitalizes at UTF-16 unit level like JS`() {
        val h = ControllerHarness()
        // A non-BMP first character: JS charAt(0) takes the lone HIGH surrogate,
        // which uppercases to itself, so the name is unchanged. Kotlin's
        // substring(0, 1) does exactly the same (Swift's grapheme prefix does not).
        val id = h.controller.openDeepLink("𐐀abc", "x")
        assertEquals("𐐀abc", h.store.get(id)?.appName)
    }

    /**
     * FINDING 4, the audit's exact repro: a LOWERCASE astral first character,
     * which JS cannot uppercase (charAt(0) yields a lone high surrogate) but
     * Swift's grapheme-level prefix(1) DID uppercase, to U+10400.
     */
    @Test
    fun `an astral first character is left alone in the fallback name`() {
        val h = ControllerHarness()
        // node: "\u{10428}eseret".charAt(0).toUpperCase() + slice(1)
        //       === "\u{10428}eseret"
        val id = h.controller.openDeepLink("\uD801\uDC28eseret", "show")
        assertEquals("\uD801\uDC28eseret", h.store.get(id)?.appName)
        assertEquals("\uD801\uDC28eseret", h.store.get(id)?.appId)
        // The BMP path the fix must not break, including a combining mark.
        val bmp = h.controller.openDeepLink("e\u0301cho", "show")
        assertEquals("E\u0301cho", h.store.get(bmp)?.appName)
    }
}

class ControllerResolveActionTest {
    @Test
    fun `resolveAction launches a child inheriting the parent identity`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val child = h.controller.resolveAction(parent, "show tomorrow")
        val screen = h.store.get(child)!!
        assertEquals("weather", screen.appId)
        assertEquals("Weather", screen.appName)
        assertEquals(parent, screen.parentId)
        assertEquals("show tomorrow", screen.request)
        assertTrue(!screen.speculative)
    }

    @Test
    fun `resolveAction without a parent falls back to unknown app`() {
        val h = ControllerHarness()
        val id = h.controller.resolveAction("ghost", "do a thing")
        assertEquals("unknown", h.store.get(id)?.appId)
        assertEquals("App", h.store.get(id)?.appName)
    }

    @Test
    fun `a cache hit returns the same screen without a new stream`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val first = h.controller.resolveAction(parent, "show tomorrow")
        h.finishLast("root = Card()")
        val second = h.controller.resolveAction(parent, "show tomorrow")
        assertEquals(first, second)
        assertEquals(2, h.streamer.count)
    }

    @Test
    fun `form submissions bypass the cache both ways`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val cached = h.controller.resolveAction(parent, "submit")
        h.finishLast("root = Card()")

        val form = listOf("city" to JsonValue.Str("Goa"))
        val withForm = h.controller.resolveAction(parent, "submit", form)
        assertNotEquals(cached, withForm, "never READS the cache")

        // ...and never WRITES it: the plain action still resolves to the
        // original cached screen.
        assertEquals(cached, h.controller.resolveAction(parent, "submit"))
        // A second identical form submission generates fresh again.
        val secondForm = h.controller.resolveAction(parent, "submit", form)
        assertNotEquals(withForm, secondForm)
    }

    @Test
    fun `form submissions append the JSON appendix to the request`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val id = h.controller.resolveAction(
            parent,
            "book it",
            listOf("guests" to JsonValue.Num(2.0), "note" to JsonValue.Str("window \"seat\"")),
        )
        assertEquals(
            "book it\n\nSubmitted form values: " +
                "{\"guests\":2,\"note\":\"window \\\"seat\\\"\"}",
            h.store.get(id)?.request,
        )
    }

    /**
     * FINDING 1 where it actually bites: real form state is THREE levels deep
     * (`{formName: {fieldName: {value, componentType}}}`), and the request
     * string built here is what the MODEL reads. The Swift port alphabetized
     * the nested keys; the same case is pinned in its suite.
     */
    @Test
    fun `form JSON preserves insertion order at every depth`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val id = h.controller.resolveAction(
            parent,
            "sign up",
            listOf(
                "signup" to JsonValue.obj(
                    "email" to JsonValue.obj(
                        "value" to JsonValue.Str("a@b.c"),
                        "componentType" to JsonValue.Str("TextField"),
                    ),
                    "age" to JsonValue.obj(
                        "value" to JsonValue.Num(30.0),
                        "componentType" to JsonValue.Str("Slider"),
                    ),
                ),
            ),
        )
        // node: "sign up\n\nSubmitted form values: " + JSON.stringify(formState)
        assertEquals(
            "sign up\n\nSubmitted form values: " +
                "{\"signup\":{\"email\":{\"value\":\"a@b.c\",\"componentType\":\"TextField\"}," +
                "\"age\":{\"value\":30,\"componentType\":\"Slider\"}}}",
            h.store.get(id)?.request,
        )
    }

    @Test
    fun `form JSON preserves insertion order`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val id = h.controller.resolveAction(
            parent,
            "x",
            listOf(
                "zeta" to JsonValue.Str("1"),
                "alpha" to JsonValue.Str("2"),
                "mid" to JsonValue.Bool(true),
            ),
        )
        assertTrue(
            h.store.get(id)!!.request.endsWith(
                "{\"zeta\":\"1\",\"alpha\":\"2\",\"mid\":true}",
            ),
        )
    }

    @Test
    fun `an empty formState behaves like a plain action`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val first = h.controller.resolveAction(parent, "tap", emptyList())
        h.finishLast("root = Card()")
        assertEquals("tap", h.store.get(first)?.request)
        // It WAS written to the cache, so the next plain tap reuses it.
        assertEquals(first, h.controller.resolveAction(parent, "tap"))
    }

    @Test
    fun `a stale cached action screen retries in place`() {
        val h = ControllerHarness()
        val parent = h.controller.openApp(sampleApp)
        val child = h.controller.resolveAction(parent, "later")
        h.clock.advance(GenOSConstants.STALE_MS + 1)
        assertEquals(child, h.controller.resolveAction(parent, "later"))
        assertEquals(3, h.streamer.count)
        assertEquals(ScreenStatus.PENDING, h.store.get(child)?.status)
    }
}

class ControllerLifecycleTest {
    @Test
    fun `retryScreen resets every piece of generation state`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.finishLast("partial", truncated = true)
        h.store.patch(id) {
            it.copy(speculative = true, prefetched = true, error = "old", searching = true)
        }
        h.clock.advance(500.0)

        h.controller.retryScreen(id)
        val s = h.store.get(id)!!
        assertEquals("", s.content)
        assertEquals(ScreenStatus.PENDING, s.status)
        assertNull(s.error)
        assertNull(s.genMs)
        assertNull(s.prefetched)
        assertNull(s.truncated)
        assertEquals(500.0, s.startedAt)
        assertTrue(!s.speculative)
        assertEquals(false, s.searching)
        assertEquals(2, h.streamer.count)
    }

    @Test
    fun `retryScreen on a missing screen is a no-op`() {
        val h = ControllerHarness()
        h.controller.retryScreen("ghost")
        assertEquals(0, h.streamer.count)
    }

    @Test
    fun `retry aborts the previous in-flight stream`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        val first = h.streamer.started[0].token
        assertTrue(!first.isCancelled)
        h.controller.retryScreen(id)
        assertTrue(first.isCancelled)
        assertTrue(!h.streamer.started[1].token.isCancelled)
    }

    @Test
    fun `superseded stream callbacks are ignored`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        val superseded = h.streamer.started[0].handlers
        h.controller.retryScreen(id)

        superseded.onDelta("zombie text")
        assertEquals("", h.store.get(id)?.content)
        superseded.onDone(StreamEndInfo(truncated = true, dropped = false))
        assertEquals(ScreenStatus.PENDING, h.store.get(id)?.status)
        superseded.onError(StreamException("zombie error"))
        assertEquals(ScreenStatus.PENDING, h.store.get(id)?.status)
        assertNull(h.store.get(id)?.error)

        // The live stream still works.
        h.streamer.started[1].handlers.onDelta("real")
        assertEquals("real", h.store.get(id)?.content)
    }

    @Test
    fun `a superseded tool round aborts instead of mutating the screen`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        val superseded = h.streamer.started[0].handlers
        h.controller.retryScreen(id)
        h.store.patch(id) { it.copy(content = "live content") }
        assertEquals(
            ToolRoundDecision.ABORT,
            superseded.onToolRound!!(listOf(ToolRoundCall("web_search", emptyMap()))),
        )
        assertEquals("live content", h.store.get(id)?.content)
    }

    @Test
    fun `a synchronously firing streamer is not dropped as stale`() {
        // Regression double for the RN inflight-before-stream ordering.
        val clock = ManualClock()
        val store = ScreenStore(clock)
        val controller = GenOSController(store, SyncFiringStreamer(), clock, emptyList())
        val id = controller.openApp(sampleApp)
        assertEquals("sync delta", store.get(id)?.content)
        assertEquals(ScreenStatus.DONE, store.get(id)?.status)
    }

    @Test
    fun `done sets genMs, truncated and status`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.clock.advance(1234.4)
        h.finishLast("root = Card()", truncated = true)
        val s = h.store.get(id)!!
        assertEquals(ScreenStatus.DONE, s.status)
        assertEquals(1234, s.genMs)
        assertEquals(true, s.truncated)
        assertEquals(false, s.searching)
        assertNull(s.osCommand)
    }

    @Test
    fun `a dropped stream surfaces a retryable error`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onDelta("half a screen")
        h.streamer.last!!.handlers.onDone(StreamEndInfo(truncated = false, dropped = true))
        val s = h.store.get(id)!!
        assertEquals(ScreenStatus.ERROR, s.status)
        assertEquals("The connection dropped mid-screen - retry", s.error)
        assertNull(s.genMs)
    }

    @Test
    fun `a stream error patches the screen to error`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onError(StreamException(GenOSConstants.NEEDS_LIVE_DATA))
        assertEquals(ScreenStatus.ERROR, h.store.get(id)?.status)
        assertEquals("needs live data", h.store.get(id)?.error)
        assertEquals(false, h.store.get(id)?.searching)
    }

    /**
     * FINDING 6: RN patches the bare `err.message`. `error.toString()` leaked
     * the fully-qualified JVM class name into `Screen.error`, which the user
     * reads and which the Swift port spelled differently again.
     */
    @Test
    fun `a non-StreamException degrades to the bare message`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onError(IllegalStateException("network unreachable"))
        assertEquals(ScreenStatus.ERROR, h.store.get(id)?.status)
        assertEquals("network unreachable", h.store.get(id)?.error)
        // No class decoration of any kind reached the screen.
        assertTrue(!h.store.get(id)?.error!!.contains("IllegalStateException"))
    }

    /**
     * FINDING 5: `genMs` uses JS `Math.round`, whose ties go toward +INFINITY,
     * and must CLAMP rather than throw. `roundToInt()` threw
     * IllegalArgumentException on NaN and saturated silently; the Swift port
     * trapped and broke ties away from zero. The same cases are pinned in the
     * Swift suite so the two ports cannot drift apart.
     */
    @Test
    fun `genMs uses JS Math round and clamps`() {
        // node: Math.round(1234.5) === 1235 (a positive tie rounds up).
        val up = ControllerHarness()
        val upId = up.controller.openApp(sampleApp)
        up.clock.advance(1234.5)
        up.streamer.last!!.handlers.onDone(StreamEndInfo(truncated = false, dropped = false))
        assertEquals(1235, up.store.get(upId)?.genMs)

        // node: Math.round(-0.5) === -0, Math.round(-2.5) === -2,
        // Math.round(-1.5) === -1 - for a clock that went backwards (NTP step,
        // monotonic-source swap).
        for ((elapsed, expected) in listOf(-0.5 to 0, -2.5 to -2, -1.5 to -1)) {
            val h = ControllerHarness()
            val id = h.controller.openApp(sampleApp)
            h.clock.advance(elapsed)
            h.streamer.last!!.handlers.onDone(StreamEndInfo(truncated = false, dropped = false))
            assertEquals(expected, h.store.get(id)?.genMs, "elapsed $elapsed")
        }

        // Out of Int range: clamped, not silently saturated by roundToInt and
        // not a trap (which is what the Swift port used to do).
        val huge = ControllerHarness()
        val hugeId = huge.controller.openApp(sampleApp)
        huge.clock.advance(1e30)
        huge.streamer.last!!.handlers.onDone(StreamEndInfo(truncated = false, dropped = false))
        assertEquals(Int.MAX_VALUE, huge.store.get(hugeId)?.genMs)
    }

    @Test
    fun `an OS command is parsed on done and suppresses prefetch`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("```\n@OS(open, \"music\")\n```")
        assertEquals(OSCommand(OSCommandKind.OPEN, "music"), h.store.get(id)?.osCommand)
        assertEquals(1, h.streamer.count, "osCommand screens never trigger prefetch")
    }

    @Test
    fun `a non-speculative tool round resets the screen to searching`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onDelta("draft that will be discarded")
        val decision = h.streamer.last!!.handlers.onToolRound!!(
            listOf(ToolRoundCall("web_search", mapOf("query" to JsonValue.Str("goa")))),
        )
        assertEquals(ToolRoundDecision.PROCEED, decision)
        val s = h.store.get(id)!!
        assertEquals("", s.content)
        assertEquals(ScreenStatus.PENDING, s.status)
        assertEquals(true, s.searching)
        // Content flowing again flips searching back off.
        h.streamer.last!!.handlers.onDelta("real")
        assertEquals(false, h.store.get(id)?.searching)
    }
}

class ControllerPrefetchTest {
    private val actions = (1..8).joinToString("\n") { "b$it = Button(\"x\", @ToAssistant(\"msg $it\"))" }

    @Test
    fun `a visible done screen prefetches up to MAX_PREFETCH children`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast(actions)
        assertEquals(1 + GenOSConstants.MAX_PREFETCH, h.streamer.count)
        val children = h.store.all().filter { it.parentId == id }
        assertEquals(6, children.size)
        assertTrue(children.all { it.speculative })
        assertEquals((1..6).map { "msg $it" }, children.map { it.request })
        assertTrue(children.all { it.appId == "weather" && it.appName == "Weather" })
    }

    @Test
    fun `no prefetch when the screen is not active`() {
        val h = ControllerHarness()
        h.controller.openApp(sampleApp)
        h.finishLast(actions)
        assertEquals(1, h.streamer.count)
    }

    @Test
    fun `becoming active while already done triggers prefetch`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.finishLast("a = Button(\"x\", @ToAssistant(\"one\"))")
        assertEquals(1, h.streamer.count)
        h.controller.setActiveScreen(id)
        assertEquals(2, h.streamer.count)
        assertEquals(id, h.controller.activeScreenId)
    }

    @Test
    fun `setActiveScreen null clears the active screen and prefetches nothing`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.finishLast("a = Button(\"x\", @ToAssistant(\"one\"))")
        h.controller.setActiveScreen(null)
        assertNull(h.controller.activeScreenId)
        assertEquals(1, h.streamer.count)
        assertTrue(h.store.get(id) != null)
    }

    @Test
    fun `prefetch skips actions already in the index`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        val home = h.streamer.started[0].handlers
        h.controller.setActiveScreen(id)
        // The user taps one action before the home screen finishes.
        h.controller.resolveAction(id, "msg 1")
        home.onDelta(actions)
        home.onDone(StreamEndInfo())
        // 1 home + 1 tapped + 5 remaining prefetches (msg 1 already indexed).
        assertEquals(7, h.streamer.count)
        assertEquals(
            listOf("msg 1", "msg 2", "msg 3", "msg 4", "msg 5", "msg 6"),
            h.store.all().filter { it.parentId == id }.map { it.request },
        )
    }

    @Test
    fun `a speculative stream refuses the tool round`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("a = Button(\"x\", @ToAssistant(\"needs data\"))")
        val prefetch = h.streamer.last!!
        assertEquals(
            ToolRoundDecision.ABORT,
            prefetch.handlers.onToolRound!!(listOf(ToolRoundCall("web_search", emptyMap()))),
        )
    }

    @Test
    fun `tapping an errored prefetch regenerates it non-speculatively`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("a = Button(\"x\", @ToAssistant(\"needs data\"))")
        val prefetchStart = h.streamer.last!!
        prefetchStart.handlers.onError(StreamException(GenOSConstants.NEEDS_LIVE_DATA))
        val childId = h.store.all().first { it.parentId == id }.id
        assertEquals(ScreenStatus.ERROR, h.store.get(childId)?.status)

        val resolved = h.controller.resolveAction(id, "needs data")
        assertEquals(childId, resolved, "retried in place, same id")
        val s = h.store.get(childId)!!
        assertTrue(!s.speculative, "the retry re-enables tools")
        assertEquals(ScreenStatus.PENDING, s.status)
        assertNull(s.error)
        assertEquals(3, h.streamer.count)
    }

    @Test
    fun `tapping a completed prefetch marks it prefetched`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("a = Button(\"x\", @ToAssistant(\"go deeper\"))")
        val childStart = h.streamer.last!!
        childStart.handlers.onDelta("root = Card()")
        childStart.handlers.onDone(StreamEndInfo())

        val childId = h.store.all().first { it.parentId == id }.id
        assertEquals(childId, h.controller.resolveAction(id, "go deeper"))
        val s = h.store.get(childId)!!
        assertTrue(!s.speculative)
        assertEquals(true, s.prefetched)
    }

    @Test
    fun `tapping a still-streaming prefetch flips speculative without the prefetched flag`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("a = Button(\"x\", @ToAssistant(\"go deeper\"))")
        h.streamer.last!!.handlers.onDelta("half")

        val childId = h.store.all().first { it.parentId == id }.id
        assertEquals(childId, h.controller.resolveAction(id, "go deeper"))
        val s = h.store.get(childId)!!
        assertTrue(!s.speculative)
        assertEquals(false, s.prefetched, "not a COMPLETED prefetch")
        assertEquals(ScreenStatus.STREAMING, s.status)
    }

    @Test
    fun `prefetch reads cleaned content so fenced programs still yield actions`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("```openui\na = Button(\"x\", @ToAssistant(\"fenced action\"))\n```")
        assertEquals(2, h.streamer.count)
        assertEquals("fenced action", h.store.all().first { it.parentId == id }.request)
    }

    @Test
    fun `a done screen with no actions prefetches nothing`() {
        val h = ControllerHarness()
        val id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.finishLast("root = Card(TextContent(\"static\"))")
        assertEquals(1, h.streamer.count)
    }
}

class ControllerContextTest {
    private fun chainOfThree(h: ControllerHarness): Triple<String, String, String> {
        val root = h.controller.openApp(sampleApp)
        h.finishLast("ROOT BODY")
        val mid = h.controller.resolveAction(root, "second")
        h.finishLast("MID BODY")
        val leaf = h.controller.resolveAction(mid, "third")
        return Triple(root, mid, leaf)
    }

    @Test
    fun `a root screen replays just its own request`() {
        val h = ControllerHarness()
        h.controller.openApp(sampleApp)
        val messages = h.streamer.started[0].messages
        assertEquals(1, messages.size)
        assertEquals(ChatRole.USER, messages[0].role)
        assertEquals(sampleApp.request, messages[0].content)
    }

    @Test
    fun `ancestors replay text-only as user then assistant turns`() {
        val h = ControllerHarness()
        val root = h.controller.openApp(sampleApp)
        h.finishLast("ROOT BODY")
        h.controller.resolveAction(root, "second")
        val messages = h.streamer.last!!.messages
        assertEquals(3, messages.size)
        assertEquals(ChatMessage(ChatRole.USER, sampleApp.request), messages[0])
        assertEquals(ChatMessage(ChatRole.ASSISTANT, "ROOT BODY"), messages[1])
        assertEquals(ChatMessage(ChatRole.USER, "second"), messages[2])
        assertTrue(messages.all { it.toolCalls == null && it.toolCallId == null })
    }

    @Test
    fun `ancestor content is cleanLang-stripped`() {
        val h = ControllerHarness()
        val root = h.controller.openApp(sampleApp)
        h.finishLast("```openui\nPROG\n```")
        h.controller.resolveAction(root, "second")
        assertEquals("PROG", h.streamer.last!!.messages[1].content)
    }

    @Test
    fun `a contentless ancestor replays its user turn only`() {
        val h = ControllerHarness()
        val root = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onDone(StreamEndInfo())
        h.controller.resolveAction(root, "second")
        val messages = h.streamer.last!!.messages
        assertEquals(2, messages.size)
        assertEquals(ChatRole.USER, messages[0].role)
        assertEquals(ChatRole.USER, messages[1].role)
    }

    @Test
    fun `an errored ancestor with partial content still replays it`() {
        val h = ControllerHarness()
        val root = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onDelta("```openui\nHALF")
        h.streamer.last!!.handlers.onError(StreamException("dropped"))
        h.controller.resolveAction(root, "second")
        val messages = h.streamer.last!!.messages
        assertEquals(3, messages.size)
        assertEquals("HALF", messages[1].content)
    }

    @Test
    fun `a still-streaming ancestor replays its partial content`() {
        val h = ControllerHarness()
        val root = h.controller.openApp(sampleApp)
        h.streamer.last!!.handlers.onDelta("PARTIAL")
        h.controller.resolveAction(root, "second")
        assertEquals("PARTIAL", h.streamer.last!!.messages[1].content)
    }

    @Test
    fun `the chain caps at exactly CONTEXT_DEPTH ancestors`() {
        val h = ControllerHarness()
        val (_, _, _) = chainOfThree(h)
        val messages = h.streamer.last!!.messages
        // 2 ancestors × (user + assistant) + the leaf's own user turn.
        assertEquals(5, messages.size)
        assertEquals(sampleApp.request, messages[0].content)
        assertEquals("ROOT BODY", messages[1].content)
        assertEquals("second", messages[2].content)
        assertEquals("MID BODY", messages[3].content)
        assertEquals("third", messages[4].content)
    }

    @Test
    fun `a fourth generation drops the oldest ancestor`() {
        val h = ControllerHarness()
        val (_, _, leaf) = chainOfThree(h)
        h.finishLast("LEAF BODY")
        h.controller.resolveAction(leaf, "fourth")
        val messages = h.streamer.last!!.messages
        assertEquals(5, messages.size)
        assertEquals("second", messages[0].content, "the root request is dropped")
        assertEquals("MID BODY", messages[1].content)
        assertEquals("third", messages[2].content)
        assertEquals("LEAF BODY", messages[3].content)
        assertEquals("fourth", messages[4].content)
    }

    @Test
    fun `a missing parent breaks the chain early`() {
        val h = ControllerHarness()
        val orphan = Screen(
            id = "orphan",
            appId = "x",
            appName = "X",
            request = "orphan request",
            parentId = "does-not-exist",
        )
        assertEquals(
            listOf(ChatMessage(ChatRole.USER, "orphan request")),
            h.controller.buildMessages(orphan),
        )
    }
}
