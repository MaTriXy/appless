package dev.appless.genoscore

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.floor

/**
 * Anonymous run counter (src/genos/telemetry.ts): one best-effort
 * "appless_app_launched" event on startup, opt-out via env.
 */
public data class TelemetryEvent(
    val event: String,
    val distinctId: String,
    val lib: String,
    val platform: String,
)

public object Telemetry {
    /** Write-only PostHog ingestion key; safe to commit (telemetry.ts). */
    public const val POSTHOG_KEY: String = "phc_3OLW53x09ZTVZSV6BEpj5uycj3ooqR6KOemOjx04e3D"
    public const val POSTHOG_HOST: String = "https://us.i.posthog.com"
    public const val EVENT_NAME: String = "appless_app_launched"
    public const val LIB: String = "appless-native"

    /** Stable anonymous id storage key (SecureStore analog of telemetry.ts). */
    public const val ID_STORAGE_KEY: String = "appless.analytics-id"

    private fun isTruthy(v: String?): Boolean = v == "1" || v?.lowercase() == "true"

    /**
     * Opted out when `POSTHOG_DISABLED` or `DO_NOT_TRACK` is "1" or "true"
     * (case-insensitive).
     */
    public fun optedOut(env: Map<String, String>): Boolean =
        isTruthy(env["POSTHOG_DISABLED"]) || isTruthy(env["DO_NOT_TRACK"])

    /** The single launch event payload. */
    public fun launchEvent(distinctId: String, platform: String): TelemetryEvent =
        TelemetryEvent(event = EVENT_NAME, distinctId = distinctId, lib = LIB, platform = platform)

    /**
     * telemetry.ts `newId()` fallback:
     * `anon-${Date.now()}-${Math.random().toString(36).slice(2)}`.
     */
    public fun fallbackId(nowMs: Double, random: Double): String =
        "anon-${JsonValue.numberString(nowMs)}-${base36FractionDigits(random)}"

    /**
     * `Math.random().toString(36).slice(2)` analog: the base-36 digits of the
     * fractional part (no "0." prefix), capped at 16 digits.
     *
     * KNOWN DEVIATION (pinned in the telemetry tests): JS `Number.toString(36)`
     * emits shortest-round-trip digits with a rounded final digit —
     * `(0.1).toString(36) === "0.3lllllllllm"` (11 fraction digits) — while this
     * greedy expansion of the same binary double yields the 16-digit
     * "3llllllllllqsn8t". The string only ever appears inside the OPAQUE
     * fallback analytics id (`anon-<ms>-<digits>`); nothing parses it and both
     * shapes match `[0-9a-z]*`, so the deviation is accepted rather than
     * reimplementing V8's dtoa.
     */
    internal fun base36FractionDigits(value: Double): String {
        val digits = "0123456789abcdefghijklmnopqrstuvwxyz"
        var frac = value - floor(value)
        val out = StringBuilder()
        var i = 0
        while (frac > 0 && i < 16) {
            frac *= 36
            val digit = minOf(35, maxOf(0, frac.toInt()))
            out.append(digits[digit])
            frac -= digit.toDouble()
            i++
        }
        return out.toString()
    }

    /**
     * The exact telemetry.ts request: `POST {POSTHOG_HOST}/i/v0/e/` with the
     * JSON body `{api_key, event, distinct_id, properties: {$lib, platform}}` in
     * `JSON.stringify` insertion order.
     */
    public fun launchRequest(distinctId: String, platform: String): HttpRequest {
        val body = JsonValue.obj(
            "api_key" to JsonValue.Str(POSTHOG_KEY),
            "event" to JsonValue.Str(EVENT_NAME),
            "distinct_id" to JsonValue.Str(distinctId),
            "properties" to JsonValue.obj(
                "\$lib" to JsonValue.Str(LIB),
                "platform" to JsonValue.Str(platform),
            ),
        )
        return HttpRequest(
            url = "$POSTHOG_HOST/i/v0/e/",
            method = "POST",
            headers = mapOf("Content-Type" to "application/json"),
            body = body.stringified().toByteArray(Charsets.UTF_8),
        )
    }

    /**
     * Stable anonymous id (telemetry.ts `deviceId`): the persisted id when one
     * exists, else a fresh `newId()` persisted best-effort. Any storage failure
     * degrades to a fresh id.
     */
    public suspend fun deviceId(
        store: SecureStore,
        scope: CoroutineScope,
        newId: () -> String,
    ): String {
        return try {
            val existing = store.read(ID_STORAGE_KEY)
            if (!existing.isNullOrEmpty()) return existing
            val id = newId()
            // RN fires SecureStore.setItemAsync(KEY, id).catch(() => {}) WITHOUT
            // awaiting — the persist is fire-and-forget so a hung store write
            // can never delay the launch event.
            scope.launch {
                try {
                    store.write(ID_STORAGE_KEY, id)
                } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    // best effort
                }
            }
            id
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            newId()
        }
    }

    /**
     * `initTelemetry` analog: a no-op when opted out, else one launch event
     * fired through the injected [HttpFetching] seam, swallowing every failure.
     *
     * Returns the detached fetch [Job] (null when opted out) so callers and
     * tests can join it; [onDispatch] is invoked from inside that job with the
     * exact request immediately before the fetch is awaited, which proves the
     * event was dispatched WITHOUT awaiting a possibly hung fetch.
     */
    public suspend fun initTelemetry(
        env: Map<String, String>,
        platform: String,
        store: SecureStore,
        http: HttpFetching,
        scope: CoroutineScope,
        newId: () -> String,
        onDispatch: ((HttpRequest) -> Unit)? = null,
    ): Job? {
        if (optedOut(env)) return null
        val id = deviceId(store, scope, newId)
        val request = launchRequest(id, platform)
        // RN fires fetch(...).catch(() => {}) WITHOUT awaiting — the launch
        // event is fire-and-forget, so a hung network can never delay
        // initTelemetry's return (same shape as the detached store write).
        return scope.launch {
            onDispatch?.invoke(request)
            try {
                http.fetch(request)
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                throw e
            } catch (e: Throwable) {
                // swallowed
            }
        }
    }
}
