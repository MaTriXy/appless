import Foundation

/// Observable screen store (src/genos/store.ts ScreenStore): content is
/// buffered synchronously (read-your-writes), subscriber notifications are
/// coalesced to at most one per STREAM_FLUSH_MS during streaming; patch()
/// (status/metadata change) flushes immediately, cancelling any pending
/// buffered notify.
@MainActor
public final class ScreenStore {
    let clock: GenOSClock
    private var listeners: [UUID: @MainActor () -> Void] = [:]

    public init(clock: GenOSClock) {
        self.clock = clock
    }

    /// Monotonically increasing change counter; bumps once per notify.
    public var version: Int {
        0 // STUB
    }

    public func subscribe(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = fn
        return { [weak self] in self?.listeners.removeValue(forKey: id) }
    }

    public func get(_ id: String) -> Screen? {
        nil // STUB
    }

    public func all() -> [Screen] {
        [] // STUB
    }

    /// Insert/replace a screen; notifies immediately.
    public func upsert(_ screen: Screen) {
        // STUB
    }

    /// Mutate an existing screen (no-op when absent); notifies immediately,
    /// flushing any buffered streaming notify with it.
    public func patch(_ id: String, _ mutate: (inout Screen) -> Void) {
        // STUB
    }

    /// Append streamed content: synchronously updates content, flips status
    /// to .streaming and searching to false; schedules a coalesced notify.
    public func append(_ id: String, delta: String) {
        // STUB
    }
}
