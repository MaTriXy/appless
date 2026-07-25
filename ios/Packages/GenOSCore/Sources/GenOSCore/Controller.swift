import Foundation

/// Generation, navigation cache, and speculative prefetch controller
/// (src/genos/store.ts module-level controller functions).
@MainActor
public final class GenOSController {
    public let store: ScreenStore
    let streamer: ScreenStreaming
    let clock: GenOSClock
    /// App catalog used by openDeepLink lookups (Apps.all in production).
    let apps: [AppDef]

    public init(store: ScreenStore, streamer: ScreenStreaming, clock: GenOSClock, apps: [AppDef]) {
        self.store = store
        self.streamer = streamer
        self.clock = clock
        self.apps = apps
    }

    // MARK: - Context

    /// Walk parents up to CONTEXT_DEPTH ancestors; replay each ancestor as
    /// user request + (if content) assistant cleanLang(content); final turn
    /// is the screen's own request. Text-only.
    public func buildMessages(for screen: Screen) -> [ChatMessage] {
        [] // STUB
    }

    // MARK: - Navigation entry points

    /// Open an app from the home grid - reuses the app's existing home
    /// screen when reusable; retries in place when stuck/errored.
    @discardableResult
    public func openApp(_ app: AppDef) -> String {
        "" // STUB
    }

    /// Open a screen in another app via a genos://open deep link. Cache key
    /// "\(appId.lowercased()) \(request)"; unknown appIds get a capitalized
    /// fallback name.
    @discardableResult
    public func openDeepLink(appId: String, request: String) -> String {
        "" // STUB
    }

    /// Resolve a tapped action: prefetched screen when one exists, fresh
    /// generation otherwise. Form submissions bypass the cache both ways and
    /// append "\n\nSubmitted form values: " + JSON to the request.
    @discardableResult
    public func resolveAction(parentId: String, message: String, formState: [String: JSONValue]? = nil) -> String {
        "" // STUB
    }

    /// Re-generate a failed or stuck screen in place: clears content/error/
    /// flags, resets startedAt, speculative → false (re-enables tools).
    public func retryScreen(_ id: String) {
        // STUB
    }

    /// The shell reports which screen is on top; prefetch only ever runs for
    /// the visible screen.
    public func setActiveScreen(_ id: String?) {
        // STUB
    }

    /// Currently visible screen id as last reported by the shell.
    public var activeScreenId: String? {
        nil // STUB
    }
}
