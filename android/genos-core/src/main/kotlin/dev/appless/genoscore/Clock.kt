package dev.appless.genoscore

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Cancellation handle for a scheduled callback. */
public interface GenOSCancellable {
    public fun cancel()
}

/**
 * Time + scheduling seam so the 50 ms flush, `STALE_MS` staleness and toast
 * timings are deterministically testable. All milliseconds, monotonic.
 *
 * Implementations are single-threaded by contract: the store, controller and
 * key store are confined to one dispatcher (`Dispatchers.Main` in the app, the
 * test dispatcher here), so no internal locking is needed anywhere.
 *
 * That contract used to be documentation only. [ScreenStore], [KeyStore] and
 * [GenOSController] now each hold a `ConfinementCheck` that throws when a
 * second thread touches them, enabled whenever JVM assertions are (see
 * [GenOSDebug]). It is a RUNTIME check: the Swift sibling gets the same
 * guarantee at COMPILE time from `@MainActor`, and that asymmetry — plus the
 * fact that [StreamClient] still invokes handlers on whatever `CoroutineScope`
 * it is handed — is recorded in the README.
 */
public interface GenOSClock {
    /** Monotonic now in milliseconds (`performance.now()` analog). */
    public val now: Double

    /** Run [work] after [afterMs] milliseconds (`setTimeout` analog). */
    public fun schedule(afterMs: Double, work: () -> Unit): GenOSCancellable
}

/**
 * Production clock: `System.nanoTime` for the monotonic reading, a coroutine
 * `delay` on [scope] for scheduling. The scope must be confined to the same
 * dispatcher as the store it drives.
 */
public class CoroutineClock(private val scope: CoroutineScope) : GenOSClock {
    private val origin = System.nanoTime()

    override val now: Double
        get() = (System.nanoTime() - origin) / 1_000_000.0

    override fun schedule(afterMs: Double, work: () -> Unit): GenOSCancellable {
        val job: Job = scope.launch {
            delay(afterMs.toLong())
            work()
        }
        return object : GenOSCancellable {
            override fun cancel() {
                job.cancel()
            }
        }
    }
}
