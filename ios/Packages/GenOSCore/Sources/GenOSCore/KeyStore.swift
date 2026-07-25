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

    private let store: SecureStore
    private var key: String?
    private var currentStatus: KeyStatus
    private var hydrationTask: Task<Void, Never>?
    private var listeners: [UUID: @MainActor () -> Void] = [:]

    /// - Parameters:
    ///   - envKey: build-time key override (EXPO_PUBLIC_CEREBRAS_API_KEY
    ///     analog). Trimmed; empty treated as absent.
    ///   - store: persistence seam.
    public init(envKey: String?, store: SecureStore) {
        self.store = store
        // RN: ENV_KEY?.trim() || null.
        let trimmed = envKey.map(jsTrim)
        if let trimmed, !trimmed.isEmpty {
            key = trimmed
            currentStatus = .present
        } else {
            key = nil
            currentStatus = .loading
        }
    }

    /// Current gate status. Starts "present" with an env key, else "loading".
    public var status: KeyStatus {
        currentStatus
    }

    /// The usable key, nil when missing/rejected/still loading. May be ""
    /// after set() of a whitespace-only key (RN parity); callers must treat
    /// empty as missing, mirroring JS falsy checks.
    public func get() -> String? {
        key
    }

    /// Kick off the persisted-key read. Idempotent. Await to know hydration
    /// settled; a key entered while the read is in flight must win.
    public func hydrate() async {
        if hydrationTask == nil {
            let store = self.store
            hydrationTask = Task { @MainActor [weak self] in
                do {
                    let stored = try await store.read(KeyStore.storageKey)
                    guard let self, self.currentStatus == .loading else { return }
                    // RN: this.key = stored?.trim() || null.
                    let trimmed = stored.map(jsTrim)
                    self.key = (trimmed?.isEmpty == false) ? trimmed : nil
                    self.setStatus(self.key != nil ? .present : .missing)
                } catch {
                    self?.setStatus(.missing)
                }
            }
        }
        await hydrationTask?.value
    }

    /// User entered a key: trim, mark present synchronously, persist
    /// best-effort in the background.
    ///
    /// RN parity (config.ts set()): the TRIMMED value is stored even when it
    /// is empty, and status flips to .present unconditionally - a
    /// whitespace-only key therefore reads back as "" (non-nil). The stream
    /// client treats an empty key as missing (JS falsy check), so no request
    /// ever goes out with a blank Authorization header.
    public func set(_ key: String) {
        let trimmed = jsTrim(key)
        self.key = trimmed
        setStatus(.present)
        let store = self.store
        Task { try? await store.write(KeyStore.storageKey, value: trimmed) }
    }

    /// The API rejected `rejectedKey` (401/403) - drop it and re-show the
    /// gate. No-ops if the user already replaced the key.
    public func markRejected(_ rejectedKey: String) {
        guard key == rejectedKey else { return }
        key = nil
        setStatus(.rejected)
        let store = self.store
        Task { try? await store.write(KeyStore.storageKey, value: nil) }
    }

    /// Subscribe to status changes; returns an unsubscribe closure.
    public func subscribe(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = fn
        return { [weak self] in self?.listeners.removeValue(forKey: id) }
    }

    private func setStatus(_ s: KeyStatus) {
        currentStatus = s
        for fn in listeners.values { fn() }
    }
}
