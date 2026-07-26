package dev.appless.genoscore

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * FINDING 8. The single-threaded contract in [GenOSClock]'s KDoc was enforced
 * nowhere: `ScreenStore`, `KeyStore` and `GenOSController` all rely on it and
 * all asserted nothing, while the Swift sibling gets the same guarantee from
 * `@MainActor` at COMPILE time.
 *
 * These tests probe BOTH paths — the check must fire across threads AND must
 * not fire for legitimate same-thread use, which is what the other 306 tests
 * in this suite exercise while the check is live.
 */
class ConfinementTest {
    private fun screenFixture(id: String) =
        Screen(id = id, appId = "notes", appName = "Notes", request = "r")

    /** Run [body] on a single foreign thread and return what it threw, if any. */
    private fun onOtherThread(body: () -> Unit): Throwable? {
        val pool = Executors.newSingleThreadExecutor()
        try {
            var caught: Throwable? = null
            pool.submit {
                caught = runCatching(body).exceptionOrNull()
            }.get(10, TimeUnit.SECONDS)
            return caught
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun `assertions are actually enabled while the suite runs`() {
        // If this ever goes false the confinement checks silently stop
        // running and every test below becomes vacuous.
        assertTrue(
            GenOSDebug.threadChecksEnabled,
            "JVM assertions are off, so the confinement checks are inert",
        )
    }

    @Test
    fun `a ScreenStore touched from a second thread throws`() = runTest {
        val store = ScreenStore(ManualClock())
        store.upsert(screenFixture("s1")) // binds the owning thread
        val thrown = onOtherThread { store.upsert(screenFixture("s2")) }
        assertTrue(thrown is IllegalStateException, "expected IllegalStateException, got $thrown")
        assertTrue(
            thrown.message!!.contains("ScreenStore is single-threaded by contract"),
            "unexpected message: ${thrown.message}",
        )
        // A pure READ from the foreign thread is caught too - reads race the
        // LinkedHashMap just as writes do.
        val store2 = ScreenStore(ManualClock())
        store2.upsert(screenFixture("s1"))
        assertTrue(onOtherThread { store2.get("s1") } is IllegalStateException)
    }

    @Test
    fun `a KeyStore touched from a second thread throws`() = runTest {
        val keyStore = makeKeyStore(scope = appScope())
        keyStore.get()
        val thrown = onOtherThread { keyStore.set("another") }
        assertTrue(thrown is IllegalStateException, "expected IllegalStateException, got $thrown")
        assertTrue(thrown.message!!.contains("KeyStore is single-threaded by contract"))
    }

    @Test
    fun `a GenOSController touched from a second thread throws`() = runTest {
        val harness = ControllerHarness()
        harness.controller.setActiveScreen(null)
        val thrown = onOtherThread { harness.controller.setActiveScreen(null) }
        assertTrue(thrown is IllegalStateException, "expected IllegalStateException, got $thrown")
        assertTrue(thrown.message!!.contains("GenOSController is single-threaded by contract"))
    }

    /**
     * PROBE the path the check does NOT take: repeated use from ONE thread —
     * including a thread that is not the one the object was constructed on —
     * must stay silent. A check that fired on construction rather than on
     * first use would break every real caller that builds the store on one
     * thread and drives it from a dispatcher.
     */
    @Test
    fun `single-thread use never trips the check`() {
        val store = ScreenStore(ManualClock())
        val thrown = onOtherThread {
            // Constructed above on the JUnit thread, first TOUCHED here.
            store.upsert(screenFixture("s1"))
            store.append("s1", "x")
            store.patch("s1") { it.copy(status = ScreenStatus.DONE) }
            store.get("s1")
            store.all()
            store.subscribe { }
        }
        assertEquals(null, thrown, "same-thread use must not trip the check")
    }

    /** The escape hatch has to work, or a legitimately threaded host is stuck. */
    @Test
    fun `the check can be disabled`() {
        val previous = GenOSDebug.threadChecksEnabled
        try {
            GenOSDebug.threadChecksEnabled = false
            val store = ScreenStore(ManualClock())
            store.upsert(screenFixture("s1"))
            assertEquals(null, onOtherThread { store.upsert(screenFixture("s2")) })
        } finally {
            GenOSDebug.threadChecksEnabled = previous
        }
    }
}
