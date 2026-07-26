package dev.appless.genoscore

import java.util.concurrent.atomic.AtomicReference

/**
 * FINDING 8: the single-threaded contract was written down but ENFORCED
 * NOWHERE.
 *
 * [GenOSClock] says "Implementations are single-threaded by contract: the
 * store, controller and key store are confined to one dispatcher", and every
 * one of those classes relies on it — `ScreenStore` holds bare
 * `LinkedHashMap`s and an unsynchronized `flushTimer`, `KeyStore` mutates
 * `key`/`hydrationJob` without a lock, `GenOSController` walks a plain
 * `inflight` map. None of them asserted anything, so a caller that handed the
 * library a multi-threaded dispatcher got silent data races.
 *
 * The Swift sibling has no such gap: `ScreenStore`, `GenOSController`,
 * `KeyStore`, `StreamClient` and `StreamCancelToken` are all `@MainActor`, so
 * the confinement is a COMPILE-TIME error there. This class is the closest the
 * JVM gets — a runtime assertion — and the asymmetry is documented in both
 * READMEs.
 *
 * Confinement is checked PER INSTANCE, not globally: the contract is that one
 * object is driven by one dispatcher, and per-instance checking lets
 * independent objects (parallel tests, several controllers) live on different
 * threads without false positives.
 *
 * Enabled whenever JVM assertions are (`-ea`, which Gradle's `Test` task sets
 * by default), so the whole behavioral suite runs under the check; off in a
 * release build, where it must cost nothing.
 */
public object GenOSDebug {
    /**
     * Whether confinement assertions run. Defaults to the JVM's `-ea` state.
     * Settable so an app can force it on in a debug build (or off in a test
     * that deliberately hops threads).
     */
    @Volatile
    @JvmStatic
    public var threadChecksEnabled: Boolean = GenOSDebug::class.java.desiredAssertionStatus()
}

/**
 * Per-instance single-thread confinement assertion. The first [check] records
 * the owning thread; every later one must come from that same thread.
 *
 * Deliberately NOT a lock: the point is to make a contract violation LOUD, not
 * to make the violating code work.
 */
internal class ConfinementCheck(private val component: String) {
    private val owner = AtomicReference<Thread?>(null)

    fun check() {
        if (!GenOSDebug.threadChecksEnabled) return
        val current = Thread.currentThread()
        // compareAndSet succeeds only on the very first call.
        if (owner.compareAndSet(null, current)) return
        val existing = owner.get()
        if (existing !== current) {
            throw IllegalStateException(
                "$component is single-threaded by contract but was touched from two threads: " +
                    "first \"${existing?.name}\", now \"${current.name}\". Confine it to one " +
                    "dispatcher (Dispatchers.Main in the app, the test dispatcher in tests).",
            )
        }
    }

    /** Forget the owner — for a test that deliberately rebinds the dispatcher. */
    fun reset() {
        owner.set(null)
    }
}
