package dev.appless.genoscore

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow

/**
 * Observable screen store (src/genos/store.ts `ScreenStore`): content is
 * buffered synchronously (read-your-writes), subscriber notifications are
 * coalesced to at most one per `STREAM_FLUSH_MS` during streaming; [patch] (a
 * status/metadata change) flushes immediately, cancelling any pending buffered
 * notify.
 *
 * Compose consumers collect [versionFlow] (or [updates]) and re-read [all] /
 * [get] — the same "tick, then re-read" contract RN's `useSyncExternalStore`
 * has, which is what makes the 50 ms coalescing meaningful.
 */
public class ScreenStore(internal val clock: GenOSClock) {

    /** Insertion-ordered listeners — JS `Set` iteration order. */
    private val listeners = LinkedHashMap<Int, () -> Unit>()
    private var nextListenerId = 0

    /** Insertion-ordered (JS `Map` iteration parity for [all]). */
    private val screens = LinkedHashMap<String, Screen>()

    private val versionState = MutableStateFlow(0)
    private var flushTimer: GenOSCancellable? = null

    /** Monotonically increasing change counter; bumps once per notify. */
    public val version: Int
        get() = versionState.value

    /** Compose-friendly change feed: a new value per subscriber notify. */
    public val versionFlow: StateFlow<Int> = versionState.asStateFlow()

    public fun subscribe(fn: () -> Unit): () -> Unit {
        val id = nextListenerId++
        listeners[id] = fn
        return { listeners.remove(id) }
    }

    /**
     * Change feed as a cold [Flow]: yields once per subscriber notify (same
     * coalescing as [subscribe]). Each collection registers its own listener and
     * unregisters when the collector completes or is cancelled.
     *
     * Ticks carry no payload (consumers re-read the store), so a slow consumer
     * keeps at most ONE buffered tick — bursts of notifies coalesce instead of
     * queueing an unbounded backlog of stale wake-ups.
     */
    public val updates: Flow<Unit>
        get() = callbackFlow {
            val unsubscribe = subscribe { trySend(Unit) }
            awaitClose { unsubscribe() }
        }.buffer(Channel.CONFLATED)

    /** Number of active subscribers (subscribe closures + updates collectors). */
    internal val listenerCount: Int
        get() = listeners.size

    public fun get(id: String): Screen? = screens[id]

    public fun all(): List<Screen> = screens.values.toList()

    /** Insert/replace a screen; notifies immediately. */
    public fun upsert(screen: Screen) {
        screens[screen.id] = screen
        bump()
    }

    /**
     * Mutate an existing screen (no-op when absent); notifies immediately,
     * flushing any buffered streaming notify with it.
     */
    public fun patch(id: String, mutate: (Screen) -> Screen) {
        val screen = screens[id] ?: return
        screens[id] = mutate(screen)
        // A status/metadata change (done, error, prefetch flip) is meaningful —
        // flush any buffered streaming notify with it, immediately.
        bump()
    }

    /**
     * Append streamed content: synchronously updates content, flips status to
     * STREAMING and `searching` to false; schedules a coalesced notify.
     */
    public fun append(id: String, delta: String) {
        val screen = screens[id] ?: return
        // Content is updated synchronously so get()/onDone always see the
        // latest; only the subscriber notification is throttled. Content flowing
        // also means any tool round is over — flip "searching" back.
        screens[id] = screen.copy(
            content = screen.content + delta,
            status = ScreenStatus.STREAMING,
            searching = false,
        )
        scheduleFlush()
    }

    /** Notify subscribers at most once per `STREAM_FLUSH_MS` during streaming. */
    private fun scheduleFlush() {
        if (flushTimer != null) return
        flushTimer = clock.schedule(GenOSConstants.STREAM_FLUSH_MS) {
            flushTimer = null
            bump()
        }
    }

    private fun bump() {
        flushTimer?.let {
            it.cancel()
            flushTimer = null
        }
        versionState.value = versionState.value + 1
        // JS Set.forEach fires in insertion order — iterate the ordered map
        // (a HashMap would notify in nondeterministic order). Snapshot first so
        // a listener that unsubscribes during the notify does not break it.
        for (fn in listeners.values.toList()) fn()
    }
}
