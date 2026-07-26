package dev.appless.genoscore

import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** src/genos/telemetry.ts parity. */
class TelemetryTest {
    @Test
    fun `opt-out accepts 1 and true case-insensitively`() {
        assertTrue(Telemetry.optedOut(mapOf("POSTHOG_DISABLED" to "1")))
        assertTrue(Telemetry.optedOut(mapOf("POSTHOG_DISABLED" to "true")))
        assertTrue(Telemetry.optedOut(mapOf("POSTHOG_DISABLED" to "TRUE")))
        assertTrue(Telemetry.optedOut(mapOf("DO_NOT_TRACK" to "1")))
        assertTrue(Telemetry.optedOut(mapOf("DO_NOT_TRACK" to "True")))
        assertTrue(!Telemetry.optedOut(emptyMap()))
        assertTrue(!Telemetry.optedOut(mapOf("POSTHOG_DISABLED" to "0")))
        assertTrue(!Telemetry.optedOut(mapOf("POSTHOG_DISABLED" to "yes")))
        assertTrue(!Telemetry.optedOut(mapOf("POSTHOG_DISABLED" to "")))
    }

    @Test
    fun `single launch event shape`() {
        val event = Telemetry.launchEvent("abc", "android")
        assertEquals("appless_app_launched", event.event)
        assertEquals("abc", event.distinctId)
        assertEquals("appless-native", event.lib)
        assertEquals("android", event.platform)
    }

    @Test
    fun `launch request matches telemetry ts exactly`() {
        val request = Telemetry.launchRequest("id-1", "android")
        assertEquals("https://us.i.posthog.com/i/v0/e/", request.url)
        assertEquals("POST", request.method)
        assertEquals(mapOf("Content-Type" to "application/json"), request.headers)
        // JSON.stringify insertion order, byte for byte.
        assertEquals(
            "{\"api_key\":\"phc_3OLW53x09ZTVZSV6BEpj5uycj3ooqR6KOemOjx04e3D\"," +
                "\"event\":\"appless_app_launched\",\"distinct_id\":\"id-1\"," +
                "\"properties\":{\"\$lib\":\"appless-native\",\"platform\":\"android\"}}",
            request.bodyText,
        )
    }

    @Test
    fun `the committed ingestion key and host match the RN source`() {
        val source = File("../../src/genos/telemetry.ts").readText()
        assertTrue(source.contains(Telemetry.POSTHOG_KEY))
        assertTrue(source.contains(Telemetry.POSTHOG_HOST))
        assertTrue(source.contains(Telemetry.EVENT_NAME))
        assertTrue(source.contains(Telemetry.LIB))
        assertTrue(source.contains(Telemetry.ID_STORAGE_KEY))
    }

    @Test
    fun `fallback id matches the JS anon shape`() {
        val id = Telemetry.fallbackId(1_700_000_000_000.0, 0.5)
        assertTrue(id.startsWith("anon-1700000000000-"))
        assertTrue(Regex("\\Aanon-[0-9]+-[0-9a-z]*\\z").matches(id))
        // Date.now() is an integer millisecond count; numberString must not
        // render it in exponential form.
        assertTrue(!id.contains("e+"))
    }

    @Test
    fun `base36 fraction digits - pinned deviation from V8 dtoa`() {
        // node: (0.5).toString(36) === "0.i" and (0.1).toString(36) ===
        // "0.3lllllllllm". The greedy expansion agrees on 0.5 and diverges on
        // 0.1 (16 digits, unrounded tail) — accepted, since the string only
        // appears inside an opaque analytics id.
        assertEquals("i", Telemetry.base36FractionDigits(0.5))
        assertEquals("3llllllllllqsn8t", Telemetry.base36FractionDigits(0.1))
        assertEquals("", Telemetry.base36FractionDigits(0.0))
        assertEquals("", Telemetry.base36FractionDigits(7.0))
        assertTrue(Regex("\\A[0-9a-z]*\\z").matches(Telemetry.base36FractionDigits(0.987654321)))
    }

    @Test
    fun `device id is persisted once and reused`() = runTest {
        val store = MemorySecureStore()
        var made = 0
        val newId = { made++; "generated-$made" }

        val first = Telemetry.deviceId(store, backgroundScope, newId)
        advanceUntilIdle()
        assertEquals("generated-1", first)
        assertEquals("generated-1", store.values[Telemetry.ID_STORAGE_KEY])

        val second = Telemetry.deviceId(store, backgroundScope, newId)
        advanceUntilIdle()
        assertEquals("generated-1", second)
        assertEquals(1, made)
    }

    @Test
    fun `a failing store read degrades to a fresh id`() = runTest {
        val store = MemorySecureStore()
        store.failReads = true
        val id = Telemetry.deviceId(store, backgroundScope) { "fresh" }
        advanceUntilIdle()
        assertEquals("fresh", id)
        assertNull(store.values[Telemetry.ID_STORAGE_KEY])
    }

    @Test
    fun `a hung store write does not delay the launch event`() = runTest {
        val store = MemorySecureStore()
        store.gateWrites()
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.json("{}"))

        var dispatched: HttpRequest? = null
        val job = Telemetry.initTelemetry(
            env = emptyMap(),
            platform = "android",
            store = store,
            http = http,
            scope = backgroundScope,
            newId = { "anon-x" },
            onDispatch = { dispatched = it },
        )
        advanceUntilIdle()
        // The write is still gated, yet the event already went out.
        assertNotNull(job)
        assertNotNull(dispatched)
        assertEquals(1, http.requests.size)
        store.releaseWrites()
        advanceUntilIdle()
        assertEquals("anon-x", store.values[Telemetry.ID_STORAGE_KEY])
    }

    @Test
    fun `a hung fetch does not delay initTelemetry's return`() = runTest {
        val store = MemorySecureStore()
        val http = HangingHttp()
        var dispatched: HttpRequest? = null
        val job = Telemetry.initTelemetry(
            env = emptyMap(),
            platform = "ios",
            store = store,
            http = http,
            scope = backgroundScope,
            newId = { "anon-y" },
            onDispatch = { dispatched = it },
        )
        advanceUntilIdle()
        // initTelemetry returned even though the fetch never completes.
        assertNotNull(job)
        assertTrue(job.isActive)
        assertNotNull(dispatched)
        assertEquals(1, http.requests.size)
        assertEquals("ios", JsonValue.parse(http.requests[0].bodyText)!!["properties"]!!["platform"]!!.str)
    }

    @Test
    fun `initTelemetry sends exactly one event through the seam`() = runTest {
        val store = MemorySecureStore()
        store.seed(Telemetry.ID_STORAGE_KEY, "persisted-id")
        val http = ScriptedHttp()
        http.enqueue(ScriptedResponse.json("{\"status\":1}"))

        val job = Telemetry.initTelemetry(
            env = mapOf("SOMETHING_ELSE" to "1"),
            platform = "android",
            store = store,
            http = http,
            scope = backgroundScope,
            newId = { "unused" },
        )
        job?.join()
        assertEquals(1, http.requests.size)
        val body = JsonValue.parse(http.requests[0].bodyText)!!
        assertEquals("persisted-id", body["distinct_id"]?.str)
        assertEquals("appless-native", body["properties"]?.get("\$lib")?.str)
    }

    @Test
    fun `opted out sends nothing and touches no storage`() = runTest {
        val store = MemorySecureStore()
        val http = ScriptedHttp()
        val job = Telemetry.initTelemetry(
            env = mapOf("DO_NOT_TRACK" to "true"),
            platform = "android",
            store = store,
            http = http,
            scope = backgroundScope,
            newId = { "nope" },
        )
        advanceUntilIdle()
        assertNull(job)
        assertTrue(http.requests.isEmpty())
        assertTrue(store.values.isEmpty())
    }

    @Test
    fun `a failing launch fetch is swallowed`() = runTest {
        val store = MemorySecureStore()
        val http = ScriptedHttp() // nothing enqueued → fetch throws
        val job = Telemetry.initTelemetry(
            env = emptyMap(),
            platform = "android",
            store = store,
            http = http,
            scope = backgroundScope,
            newId = { "anon-z" },
        )
        job?.join()
        assertTrue(job!!.isCompleted)
        assertTrue(!job.isCancelled)
    }
}
