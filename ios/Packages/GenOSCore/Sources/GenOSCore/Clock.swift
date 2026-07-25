import Foundation

/// Cancellation handle for a scheduled callback.
@MainActor
public protocol GenOSCancellable {
    func cancel()
}

/// Time + scheduling seam so the 50 ms flush, STALE_MS staleness, and toast
/// timings are deterministically testable. All milliseconds, monotonic.
@MainActor
public protocol GenOSClock: AnyObject {
    /// Monotonic now in milliseconds (performance.now analog).
    var now: Double { get }
    /// Run `work` after `afterMs` milliseconds (setTimeout analog).
    @discardableResult
    func schedule(afterMs: Double, _ work: @escaping @MainActor () -> Void) -> GenOSCancellable
}
