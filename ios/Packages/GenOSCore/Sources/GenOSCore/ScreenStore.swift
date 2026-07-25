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
    private var screens: [String: Screen] = [:]
    /// Insertion order (JS Map iteration parity for all()).
    private var order: [String] = []
    private var versionCounter = 0
    private var flushTimer: GenOSCancellable?

    public init(clock: GenOSClock) {
        self.clock = clock
    }

    /// Monotonically increasing change counter; bumps once per notify.
    public var version: Int {
        versionCounter
    }

    public func subscribe(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = fn
        return { [weak self] in self?.listeners.removeValue(forKey: id) }
    }

    /// SwiftUI-friendly change feed: yields once per subscriber notify (same
    /// coalescing as subscribe()). Each access creates an independent stream;
    /// terminating/cancelling its consumer unsubscribes automatically.
    public var updates: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let id = UUID()
        listeners[id] = { continuation.yield(()) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.listeners.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// Number of active subscribers (subscribe closures + updates streams).
    var listenerCount: Int {
        listeners.count
    }

    public func get(_ id: String) -> Screen? {
        screens[id]
    }

    public func all() -> [Screen] {
        order.compactMap { screens[$0] }
    }

    /// Insert/replace a screen; notifies immediately.
    public func upsert(_ screen: Screen) {
        if screens[screen.id] == nil {
            order.append(screen.id)
        }
        screens[screen.id] = screen
        bump()
    }

    /// Mutate an existing screen (no-op when absent); notifies immediately,
    /// flushing any buffered streaming notify with it.
    public func patch(_ id: String, _ mutate: (inout Screen) -> Void) {
        guard var screen = screens[id] else { return }
        mutate(&screen)
        screens[id] = screen
        // A status/metadata change (done, error, prefetch flip) is meaningful -
        // flush any buffered streaming notify with it, immediately.
        bump()
    }

    /// Append streamed content: synchronously updates content, flips status
    /// to .streaming and searching to false; schedules a coalesced notify.
    public func append(_ id: String, delta: String) {
        guard var screen = screens[id] else { return }
        // Content is updated synchronously so get()/onDone always see the
        // latest; only the subscriber notification is throttled. Content
        // flowing also means any tool round is over - flip "searching" back.
        screen.content += delta
        screen.status = .streaming
        screen.searching = false
        screens[id] = screen
        scheduleFlush()
    }

    /// Notify subscribers at most once per STREAM_FLUSH_MS during streaming.
    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = clock.schedule(afterMs: GenOSConstants.streamFlushMs) { [weak self] in
            guard let self else { return }
            self.flushTimer = nil
            self.bump()
        }
    }

    private func bump() {
        if let timer = flushTimer {
            timer.cancel()
            flushTimer = nil
        }
        versionCounter += 1
        for fn in listeners.values { fn() }
    }
}
