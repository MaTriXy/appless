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
    public static let posthogHost = "https://us.i.posthog.com"

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
            event: "appless_app_launched",
            distinctId: distinctId,
            lib: "appless-native",
            platform: platform
        )
    }
}
