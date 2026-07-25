import Foundation

/// src/config.ts KeyStore parity.
public enum KeyStatus: String, Sendable, Equatable {
    case loading, missing, present, rejected
}

/// BYOK key gate: env override → persisted key, with the hydration race rule
/// (a key entered while hydration is in flight wins) and the stale-key guard
/// on markRejected.
@MainActor
public final class KeyStore {
    public static let storageKey = "genos.cerebras-key"

    private var listeners: [UUID: @MainActor () -> Void] = [:]

    /// - Parameters:
    ///   - envKey: build-time key override (EXPO_PUBLIC_CEREBRAS_API_KEY
    ///     analog). Trimmed; empty treated as absent.
    ///   - store: persistence seam.
    public init(envKey: String?, store: SecureStore) {
        // STUB
    }

    /// Current gate status. Starts "present" with an env key, else "loading".
    public var status: KeyStatus {
        .loading // STUB
    }

    /// The usable key, nil when missing/rejected/still loading.
    public func get() -> String? {
        nil // STUB
    }

    /// Kick off the persisted-key read. Idempotent. Await to know hydration
    /// settled; a key entered while the read is in flight must win.
    public func hydrate() async {
        // STUB
    }

    /// User entered a key: trim, mark present synchronously, persist
    /// best-effort in the background.
    public func set(_ key: String) {
        // STUB
    }

    /// The API rejected `rejectedKey` (401/403) - drop it and re-show the
    /// gate. No-ops if the user already replaced the key.
    public func markRejected(_ rejectedKey: String) {
        // STUB
    }

    /// Subscribe to status changes; returns an unsubscribe closure.
    public func subscribe(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = fn
        return { [weak self] in self?.listeners.removeValue(forKey: id) }
    }
}
