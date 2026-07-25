import Foundation

/// Anonymous run counter (src/genos/telemetry.ts): one best-effort
/// "appless_app_launched" event on startup, opt-out via env.
public struct TelemetryEvent: Sendable, Equatable {
    public var event: String
    public var distinctId: String
    public var lib: String
    public var platform: String

    public init(event: String, distinctId: String, lib: String, platform: String) {
        self.event = event
        self.distinctId = distinctId
        self.lib = lib
        self.platform = platform
    }
}

public enum Telemetry {
    /// Write-only PostHog ingestion key; safe to commit (telemetry.ts).
    public static let posthogKey = "phc_3OLW53x09ZTVZSV6BEpj5uycj3ooqR6KOemOjx04e3D"
    public static let posthogHost = "https://us.i.posthog.com"
    public static let eventName = "appless_app_launched"
    public static let lib = "appless-native"
    /// Stable anonymous id storage key (SecureStore analog of telemetry.ts).
    public static let idStorageKey = "appless.analytics-id"

    private static func isTruthy(_ v: String?) -> Bool {
        v == "1" || v?.lowercased() == "true"
    }

    /// Opted out when POSTHOG_DISABLED or DO_NOT_TRACK is "1" or "true"
    /// (case-insensitive).
    public static func optedOut(env: [String: String]) -> Bool {
        isTruthy(env["POSTHOG_DISABLED"]) || isTruthy(env["DO_NOT_TRACK"])
    }

    /// The single launch event payload.
    public static func launchEvent(distinctId: String, platform: String) -> TelemetryEvent {
        TelemetryEvent(
            event: eventName,
            distinctId: distinctId,
            lib: lib,
            platform: platform
        )
    }

    /// telemetry.ts newId() fallback: `anon-${Date.now()}-${Math.random()
    /// .toString(36).slice(2)}` (base-36 fraction digits of `random`).
    public static func fallbackId(nowMs: Double, random: Double) -> String {
        "anon-\(JSONValue.numberString(nowMs))-\(base36FractionDigits(random))"
    }

    /// Math.random().toString(36).slice(2) analog: the base-36 digits of the
    /// fractional part (no "0." prefix), capped at 16 digits.
    ///
    /// KNOWN DEVIATION (pinned in TelemetryTests): JS Number.toString(36)
    /// emits shortest-round-trip digits with a rounded final digit -
    /// (0.1).toString(36) === "0.3lllllllllm" (11 fraction digits) - while
    /// this greedy expansion of the same binary double yields the 16-digit
    /// "3llllllllllqsn8t". The string is only ever embedded in the OPAQUE
    /// fallback analytics id (`anon-<ms>-<digits>`); nothing parses it and
    /// both shapes match [0-9a-z]*, so the deviation is accepted rather
    /// than reimplementing V8's dtoa.
    static func base36FractionDigits(_ value: Double) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var frac = value - value.rounded(.down)
        var out = ""
        var i = 0
        while frac > 0, i < 16 {
            frac *= 36
            let digit = min(35, max(0, Int(frac)))
            out.append(digits[digit])
            frac -= Double(digit)
            i += 1
        }
        return out
    }

    /// The exact telemetry.ts request: POST {POSTHOG_HOST}/i/v0/e/ with
    /// JSON body {api_key, event, distinct_id, properties: {$lib, platform}}
    /// in JSON.stringify insertion order.
    public static func launchRequest(distinctId: String, platform: String) -> HTTPRequest {
        let body: JSONValue = .object([
            "api_key": .string(posthogKey),
            "event": .string(eventName),
            "distinct_id": .string(distinctId),
            "properties": .object([
                "$lib": .string(lib),
                "platform": .string(platform),
            ]),
        ])
        let keyOrder = ["api_key", "event", "distinct_id", "properties", "$lib", "platform"]
        return HTTPRequest(
            url: "\(posthogHost)/i/v0/e/",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data(body.stringified(keyOrder: keyOrder).utf8)
        )
    }

    /// Stable anonymous id (telemetry.ts deviceId): the persisted id when one
    /// exists, else a fresh `newId()` persisted best-effort. Any storage
    /// failure degrades to a fresh id.
    public static func deviceId(store: SecureStore, newId: () -> String) async -> String {
        do {
            if let existing = try await store.read(idStorageKey), !existing.isEmpty {
                return existing
            }
            let id = newId()
            // RN fires SecureStore.setItemAsync(KEY, id).catch(() => {})
            // WITHOUT awaiting - the persist is fire-and-forget so a hung
            // store write can never delay the launch event.
            Task { try? await store.write(idStorageKey, value: id) }
            return id
        } catch {
            return newId()
        }
    }

    /// initTelemetry analog: no-op when opted out, else fire one launch event
    /// through the injected HTTPFetching seam, swallowing every failure.
    public static func initTelemetry(
        env: [String: String],
        platform: String,
        store: SecureStore,
        http: HTTPFetching,
        newId: () -> String
    ) async {
        if optedOut(env: env) { return }
        let id = await deviceId(store: store, newId: newId)
        let request = launchRequest(distinctId: id, platform: platform)
        // RN fires fetch(...).catch(() => {}) WITHOUT awaiting - the launch
        // event is fire-and-forget, so a hung network can never delay
        // initTelemetry's return (same shape as the detached store write).
        Task { _ = try? await http.fetch(request) }
    }
}
