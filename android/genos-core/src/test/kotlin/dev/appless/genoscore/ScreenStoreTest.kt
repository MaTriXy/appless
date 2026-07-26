package dev.appless.genoscore

import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** src/genos/store.ts ScreenStore: STREAM_FLUSH_MS coalescing + read-your-writes. */
class ScreenStoreTest {
    private fun screen(id: String = "s1", startedAt: Double = 0.0) = Screen(
        id = id,
        appId = "weather",
        appName = "Weather",
        request = "r",
        startedAt = startedAt,
    )

    @Test
    fun `upsert notifies immediately`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        var notifies = 0
        store.subscribe { notifies++ }
        store.upsert(screen())
        assertEquals(1, notifies)
        assertEquals(1, store.version)
    }

    @Test
    fun `appends within the window coalesce to one notify`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen())
        var notifies = 0
        store.subscribe { notifies++ }

        store.append("s1", "a")
        store.append("s1", "b")
        store.append("s1", "c")
        assertEquals(0, notifies, "nothing notified before the flush window elapses")
        assertEquals(1, clock.pendingCount)

        clock.advance(GenOSConstants.STREAM_FLUSH_MS)
        assertEquals(1, notifies)
        assertEquals(0, clock.pendingCount)
    }

    @Test
    fun `append content is synchronous - read-your-writes`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen())
        store.append("s1", "hello ")
        store.append("s1", "world")
        // No flush has fired, yet get() already sees everything.
        assertEquals("hello world", store.get("s1")?.content)
        assertEquals(0, store.version - 1)
    }

    @Test
    fun `append flips status to streaming and clears searching`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen().copy(status = ScreenStatus.PENDING, searching = true))
        store.append("s1", "x")
        assertEquals(ScreenStatus.STREAMING, store.get("s1")?.status)
        assertEquals(false, store.get("s1")?.searching)
    }

    @Test
    fun `patch flushes the buffered notify immediately`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen())
        var notifies = 0
        store.subscribe { notifies++ }

        store.append("s1", "partial")
        assertEquals(1, clock.pendingCount)
        store.patch("s1") { it.copy(status = ScreenStatus.DONE) }
        assertEquals(1, notifies)
        assertEquals(0, clock.pendingCount, "the pending flush timer is cancelled, not left to fire")

        // Advancing must not produce a second, duplicate notify.
        clock.advance(GenOSConstants.STREAM_FLUSH_MS * 2)
        assertEquals(1, notifies)
    }

    @Test
    fun `an append after a flush opens a new window`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen())
        var notifies = 0
        store.subscribe { notifies++ }

        store.append("s1", "a")
        clock.advance(GenOSConstants.STREAM_FLUSH_MS)
        assertEquals(1, notifies)
        store.append("s1", "b")
        assertEquals(1, notifies)
        clock.advance(GenOSConstants.STREAM_FLUSH_MS)
        assertEquals(2, notifies)
    }

    @Test
    fun `a flush just before the window boundary does not fire`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen())
        var notifies = 0
        store.subscribe { notifies++ }
        store.append("s1", "a")
        clock.advance(GenOSConstants.STREAM_FLUSH_MS - 1)
        assertEquals(0, notifies)
        clock.advance(1.0)
        assertEquals(1, notifies)
    }

    @Test
    fun `patch and append on a missing screen are no-ops`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        var notifies = 0
        store.subscribe { notifies++ }
        store.patch("ghost") { it.copy(status = ScreenStatus.DONE) }
        store.append("ghost", "x")
        assertEquals(0, notifies)
        assertEquals(0, store.version)
        assertNull(store.get("ghost"))
    }

    @Test
    fun `all preserves insertion order and upsert replaces in place`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen("a"))
        store.upsert(screen("b"))
        store.upsert(screen("c"))
        assertEquals(listOf("a", "b", "c"), store.all().map { it.id })
        store.upsert(screen("b").copy(request = "changed"))
        assertEquals(listOf("a", "b", "c"), store.all().map { it.id })
        assertEquals("changed", store.get("b")?.request)
    }

    @Test
    fun `listeners notify in insertion order and survive removal mid-notify`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        val order = mutableListOf<String>()
        store.subscribe { order.add("a") }
        var unsubB: (() -> Unit)? = null
        unsubB = store.subscribe {
            order.add("b")
            unsubB?.invoke()
        }
        store.subscribe { order.add("c") }

        store.upsert(screen())
        assertEquals(listOf("a", "b", "c"), order)
        store.upsert(screen("s2"))
        assertEquals(listOf("a", "b", "c", "a", "c"), order)
        assertEquals(2, store.listenerCount)
    }

    @Test
    fun `versionFlow ticks once per notify`() = runTest {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        assertEquals(0, store.versionFlow.value)
        store.upsert(screen())
        assertEquals(1, store.versionFlow.value)
        store.append("s1", "a")
        store.append("s1", "b")
        assertEquals(1, store.versionFlow.value, "buffered appends do not tick")
        clock.advance(GenOSConstants.STREAM_FLUSH_MS)
        assertEquals(2, store.versionFlow.value)
    }

    @Test
    fun `updates flow yields per notify including the coalesced flush`() = runTest {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        var ticks = 0
        val collector = appScope().launch { store.updates.collect { ticks++ } }
        testScheduler.advanceUntilIdle()
        assertEquals(1, store.listenerCount)

        store.upsert(screen())
        testScheduler.advanceUntilIdle()
        assertEquals(1, ticks)

        store.append("s1", "a")
        store.append("s1", "b")
        testScheduler.advanceUntilIdle()
        assertEquals(1, ticks, "buffered appends do not tick")

        clock.advance(GenOSConstants.STREAM_FLUSH_MS)
        testScheduler.advanceUntilIdle()
        assertEquals(2, ticks)

        collector.cancel()
        testScheduler.advanceUntilIdle()
        assertEquals(0, store.listenerCount, "cancelling the collector unsubscribes")
    }

    @Test
    fun `updates flow buffers only the newest tick for slow consumers`() = runTest {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        var ticks = 0
        // A deliberately slow consumer: it is suspended for the whole burst, so
        // the CONFLATED buffer must keep at most ONE pending wake-up rather than
        // queueing a backlog of 50 stale ticks.
        val collector = appScope().launch {
            store.updates.collect {
                ticks++
                delay(1_000)
            }
        }
        testScheduler.advanceUntilIdle()
        assertEquals(0, ticks)

        repeat(50) { store.upsert(screen("s$it")) }
        testScheduler.advanceUntilIdle()
        // Exactly two deliveries: the one in flight when the burst started, plus
        // the single conflated survivor. An unbounded (or even 2-deep) buffer
        // would deliver all 50 stale wake-ups here.
        assertEquals(2, ticks, "50 notifies collapse into one buffered wake-up")
        assertEquals(50, store.all().size, "every upsert still landed in the store")

        collector.cancel()
        testScheduler.advanceUntilIdle()
        assertEquals(0, store.listenerCount)
    }

    @Test
    fun `patch is a pure copy - the previous snapshot is untouched`() {
        val clock = ManualClock()
        val store = ScreenStore(clock)
        store.upsert(screen())
        val before = store.get("s1")!!
        store.patch("s1") { it.copy(status = ScreenStatus.ERROR, error = "boom") }
        assertEquals(ScreenStatus.PENDING, before.status)
        assertNull(before.error)
        assertEquals(ScreenStatus.ERROR, store.get("s1")?.status)
    }
}
