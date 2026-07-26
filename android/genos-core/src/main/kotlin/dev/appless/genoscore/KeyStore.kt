package dev.appless.genoscore

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** src/config.ts `KeyStore` parity. */
public enum class KeyStatus { LOADING, MISSING, PRESENT, REJECTED }

/**
 * BYOK key gate: env override → persisted key, with the hydration race rule (a
 * key entered while hydration is in flight wins) and the stale-key guard on
 * [markRejected].
 *
 * Single-threaded by contract (see [GenOSClock]); [scope] must be confined to
 * the caller's dispatcher.
 */
public class KeyStore(
    envKey: String?,
    private val store: SecureStore,
    private val scope: CoroutineScope,
) {
    public companion object {
        public const val STORAGE_KEY: String = "genos.cerebras-key"
    }

    /** FINDING 8: the single-threaded contract, actually enforced. */
    private val confinement = ConfinementCheck("KeyStore")

    private var key: String?
    private val statusFlowInternal: MutableStateFlow<KeyStatus>
    private var hydrationJob: Job? = null

    /**
     * Insertion-ordered listeners — JS `Set` iteration order. A `HashMap` would
     * notify in arbitrary order; the store mirrors [ScreenStore] here.
     */
    private val listeners = LinkedHashMap<Int, () -> Unit>()
    private var nextListenerId = 0

    init {
        // RN: ENV_KEY?.trim() || null.
        val trimmed = envKey?.let { jsTrim(it) }
        if (!trimmed.isNullOrEmpty()) {
            key = trimmed
            statusFlowInternal = MutableStateFlow(KeyStatus.PRESENT)
        } else {
            key = null
            statusFlowInternal = MutableStateFlow(KeyStatus.LOADING)
        }
    }

    /** Current gate status. Starts PRESENT with an env key, else LOADING. */
    public val status: KeyStatus
        get() = statusFlowInternal.value

    /** Compose-friendly view of [status]. */
    public val statusFlow: StateFlow<KeyStatus> = statusFlowInternal.asStateFlow()

    /**
     * The usable key: null when missing/rejected/still loading. May be "" after
     * [set] of a whitespace-only key (RN parity); callers must treat empty as
     * missing, mirroring JS falsy checks.
     */
    public fun get(): String? {
        confinement.check()
        return key
    }

    /**
     * Kick off the persisted-key read. Idempotent. Await to know hydration
     * settled; a key entered while the read is in flight must win.
     */
    public suspend fun hydrate() {
        if (hydrationJob == null) {
            hydrationJob = scope.launch {
                val stored = try {
                    store.read(STORAGE_KEY)
                } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    setStatus(KeyStatus.MISSING)
                    return@launch
                }
                // A key entered while hydration was in flight wins.
                if (status != KeyStatus.LOADING) return@launch
                // RN: this.key = stored?.trim() || null.
                val trimmed = stored?.let { jsTrim(it) }
                key = if (!trimmed.isNullOrEmpty()) trimmed else null
                setStatus(if (key != null) KeyStatus.PRESENT else KeyStatus.MISSING)
            }
        }
        hydrationJob?.join()
    }

    /**
     * User entered a key: trim, mark present synchronously, persist
     * best-effort in the background.
     *
     * RN parity (config.ts `set()`): the TRIMMED value is stored even when it is
     * empty, and the status flips to PRESENT unconditionally — a whitespace-only
     * key therefore reads back as "" (non-null). The stream client treats an
     * empty key as missing (JS falsy check), so no request ever goes out with a
     * blank Authorization header.
     */
    public fun set(newKey: String) {
        confinement.check()
        val trimmed = jsTrim(newKey)
        key = trimmed
        setStatus(KeyStatus.PRESENT)
        scope.launch { runCatchingWrite(trimmed) }
    }

    /**
     * The API rejected [rejectedKey] (401/403) — drop it and re-show the gate.
     * No-ops if the user already replaced the key (a stale in-flight stream must
     * not wipe a newly entered valid key).
     */
    public fun markRejected(rejectedKey: String) {
        confinement.check()
        if (key != rejectedKey) return
        key = null
        setStatus(KeyStatus.REJECTED)
        scope.launch { runCatchingWrite(null) }
    }

    private suspend fun runCatchingWrite(value: String?) {
        try {
            store.write(STORAGE_KEY, value)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            // Best-effort persistence: RN swallows write failures too.
        }
    }

    /** Subscribe to status changes; returns an unsubscribe function. */
    public fun subscribe(fn: () -> Unit): () -> Unit {
        confinement.check()
        val id = nextListenerId++
        listeners[id] = fn
        return { listeners.remove(id) }
    }

    private fun setStatus(s: KeyStatus) {
        statusFlowInternal.value = s
        for (fn in listeners.values.toList()) fn()
    }
}
