package dev.appless.genoscore

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** src/config.ts KeyStore parity: env override, hydration race, stale-key guard. */
class KeyStoreTest {
    @Test
    fun `env key wins immediately without hydration`() = runTest {
        val store = MemorySecureStore()
        store.seed(KeyStore.STORAGE_KEY, "persisted")
        val keys = KeyStore("  env-key  ", store, backgroundScope)
        assertEquals(KeyStatus.PRESENT, keys.status)
        assertEquals("env-key", keys.get()) // trimmed
        keys.hydrate()
        advanceUntilIdle()
        // Hydration must not overwrite the env key.
        assertEquals("env-key", keys.get())
        assertEquals(KeyStatus.PRESENT, keys.status)
    }

    @Test
    fun `a blank env key is treated as absent`() = runTest {
        val keys = KeyStore("   \u00A0 ", MemorySecureStore(), backgroundScope)
        assertEquals(KeyStatus.LOADING, keys.status)
        assertNull(keys.get())
    }

    @Test
    fun `hydration finds the persisted key`() = runTest {
        val store = MemorySecureStore()
        store.seed(KeyStore.STORAGE_KEY, "  stored-key\n")
        val keys = KeyStore(null, store, backgroundScope)
        assertEquals(KeyStatus.LOADING, keys.status)
        keys.hydrate()
        advanceUntilIdle()
        assertEquals(KeyStatus.PRESENT, keys.status)
        assertEquals("stored-key", keys.get())
    }

    @Test
    fun `hydration with nothing stored ends missing`() = runTest {
        val keys = KeyStore(null, MemorySecureStore(), backgroundScope)
        keys.hydrate()
        advanceUntilIdle()
        assertEquals(KeyStatus.MISSING, keys.status)
        assertNull(keys.get())
    }

    @Test
    fun `a whitespace-only persisted key hydrates as missing`() = runTest {
        val store = MemorySecureStore()
        store.seed(KeyStore.STORAGE_KEY, "\uFEFF \t")
        val keys = KeyStore(null, store, backgroundScope)
        keys.hydrate()
        advanceUntilIdle()
        assertEquals(KeyStatus.MISSING, keys.status)
        assertNull(keys.get())
    }

    @Test
    fun `a failing read ends missing`() = runTest {
        val store = MemorySecureStore()
        store.failReads = true
        val keys = KeyStore(null, store, backgroundScope)
        keys.hydrate()
        advanceUntilIdle()
        assertEquals(KeyStatus.MISSING, keys.status)
    }

    @Test
    fun `hydrate is idempotent - a second call does not re-read`() = runTest {
        val store = MemorySecureStore()
        store.seed(KeyStore.STORAGE_KEY, "k1")
        val keys = KeyStore(null, store, backgroundScope)
        keys.hydrate()
        advanceUntilIdle()
        store.seed(KeyStore.STORAGE_KEY, "k2")
        keys.hydrate()
        advanceUntilIdle()
        assertEquals("k1", keys.get())
    }

    @Test
    fun `set trims, persists and notifies`() = runTest {
        val store = MemorySecureStore()
        val keys = KeyStore(null, store, backgroundScope)
        var notifies = 0
        val unsubscribe = keys.subscribe { notifies++ }

        keys.set("  fresh-key  ")
        assertEquals("fresh-key", keys.get())
        assertEquals(KeyStatus.PRESENT, keys.status)
        assertEquals(1, notifies)
        advanceUntilIdle()
        assertEquals("fresh-key", store.values[KeyStore.STORAGE_KEY])

        unsubscribe()
        keys.set("another")
        assertEquals(1, notifies)
    }

    @Test
    fun `set trims the exact ECMAScript whitespace set`() = runTest {
        val keys = KeyStore(null, MemorySecureStore(), backgroundScope)
        // U+FEFF and NBSP are JS whitespace; U+0085 is NOT.
        keys.set("\uFEFF\u00A0key\u00A0\uFEFF")
        assertEquals("key", keys.get())
        keys.set("key")
        assertEquals("key", keys.get())
    }

    @Test
    fun `a whitespace-only set stores empty with status present`() = runTest {
        val keys = KeyStore(null, MemorySecureStore(), backgroundScope)
        keys.set("   ")
        // RN parity: the trimmed value is stored even when empty, and the
        // status flips to present unconditionally.
        assertEquals("", keys.get())
        assertEquals(KeyStatus.PRESENT, keys.status)
    }

    @Test
    fun `markRejected drops the key and clears persistence`() = runTest {
        val store = MemorySecureStore()
        store.seed(KeyStore.STORAGE_KEY, "bad-key")
        val keys = KeyStore("bad-key", store, backgroundScope)
        keys.markRejected("bad-key")
        assertNull(keys.get())
        assertEquals(KeyStatus.REJECTED, keys.status)
        advanceUntilIdle()
        assertNull(store.values[KeyStore.STORAGE_KEY])
    }

    @Test
    fun `markRejected is a no-op for a stale key`() = runTest {
        val store = MemorySecureStore()
        val keys = KeyStore("old-key", store, backgroundScope)
        keys.set("new-key")
        advanceUntilIdle()
        // A stale in-flight stream reports the OLD key as rejected.
        keys.markRejected("old-key")
        assertEquals("new-key", keys.get())
        assertEquals(KeyStatus.PRESENT, keys.status)
        advanceUntilIdle()
        assertEquals("new-key", store.values[KeyStore.STORAGE_KEY])
    }

    @Test
    fun `a key entered while hydration is in flight wins`() = runTest {
        val store = MemorySecureStore()
        store.seed(KeyStore.STORAGE_KEY, "stale-persisted")
        store.gateReads()
        val keys = KeyStore(null, store, backgroundScope)

        val hydration = launch { keys.hydrate() }
        advanceUntilIdle() // the read is parked on the gate
        assertEquals(KeyStatus.LOADING, keys.status)

        keys.set("typed-by-user")
        assertEquals(KeyStatus.PRESENT, keys.status)

        store.releaseReads()
        hydration.join()
        advanceUntilIdle()
        // The late-arriving persisted key must NOT overwrite the typed one.
        assertEquals("typed-by-user", keys.get())
        assertEquals(KeyStatus.PRESENT, keys.status)
    }

    @Test
    fun `statusFlow mirrors the status transitions`() = runTest {
        val store = MemorySecureStore()
        val keys = KeyStore(null, store, backgroundScope)
        assertEquals(KeyStatus.LOADING, keys.statusFlow.value)
        keys.hydrate()
        advanceUntilIdle()
        assertEquals(KeyStatus.MISSING, keys.statusFlow.value)
        keys.set("k")
        assertEquals(KeyStatus.PRESENT, keys.statusFlow.value)
        keys.markRejected("k")
        assertEquals(KeyStatus.REJECTED, keys.statusFlow.value)
    }

    @Test
    fun `listeners fire in insertion order and survive removal mid-notify`() = runTest {
        val keys = KeyStore(null, MemorySecureStore(), backgroundScope)
        val order = mutableListOf<String>()
        var unsubB: (() -> Unit)? = null
        keys.subscribe { order.add("a") }
        unsubB = keys.subscribe {
            order.add("b")
            unsubB?.invoke()
        }
        keys.subscribe { order.add("c") }
        keys.set("x")
        assertEquals(listOf("a", "b", "c"), order)
        keys.set("y")
        assertEquals(listOf("a", "b", "c", "a", "c"), order)
        assertTrue(order.isNotEmpty())
    }
}
