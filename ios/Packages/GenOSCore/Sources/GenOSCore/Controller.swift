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

    private var idCounter = 0
    private var currentActiveScreenId: String?
    /// `${parentId} ${actionMessage}` → child screen id.
    private var actionIndex: [String: String] = [:]
    /// appId → home screen id (reopening an app from the grid is instant).
    private var appHomeIndex: [String: String] = [:]
    /// `${appId} ${request}` → screen id (repeated deep links reuse a screen).
    private var deepLinkIndex: [String: String] = [:]
    /// screen id → cancellation token for its in-flight generation.
    private var inflight: [String: StreamCancelToken] = [:]

    public init(store: ScreenStore, streamer: ScreenStreaming, clock: GenOSClock, apps: [AppDef]) {
        self.store = store
        self.streamer = streamer
        self.clock = clock
        self.apps = apps
    }

    private func newId() -> String {
        idCounter += 1
        return "screen-\(idCounter)"
    }

    private func actionKey(_ parentId: String, _ message: String) -> String {
        "\(parentId) \(message)"
    }

    // MARK: - Context

    /// Walk parents up to CONTEXT_DEPTH ancestors; replay each ancestor as
    /// user request + (if content) assistant cleanLang(content); final turn
    /// is the screen's own request. Text-only.
    public func buildMessages(for screen: Screen) -> [ChatMessage] {
        var chain: [Screen] = [screen]
        var cur = screen
        while let parentId = cur.parentId, chain.count <= GenOSConstants.contextDepth {
            guard let parent = store.get(parentId) else { break }
            chain.insert(parent, at: 0)
            cur = parent
        }

        var messages: [ChatMessage] = []
        for s in chain.dropLast() {
            // Ancestors replay text-only - re-sending images would burn
            // tokens per hop.
            messages.append(ChatMessage(role: .user, content: s.request))
            if !s.content.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: Lang.cleanLang(s.content)))
            }
        }
        messages.append(ChatMessage(role: .user, content: screen.request))
        return messages
    }

    // MARK: - Stream lifecycle

    private func startStream(_ id: String) {
        guard let screen = store.get(id) else { return }
        inflight[id]?.cancel()

        // Callbacks from a superseded stream (a retry replaced this token)
        // must not touch the screen or delete the new stream's token.
        final class TokenBox {
            var token: StreamCancelToken?
        }
        let box = TokenBox()
        let stale: @MainActor () -> Bool = { [weak self] in
            guard let self, let token = box.token else { return true }
            return self.inflight[id] !== token
        }

        let handlers = StreamHandlers(
            onDelta: { [weak self] delta in
                guard let self, !stale() else { return }
                self.store.append(id, delta: delta)
            },
            onDone: { [weak self] info in
                guard let self, !stale() else { return }
                self.inflight.removeValue(forKey: id)
                let s = self.store.get(id)
                if info.dropped {
                    // The stream died mid-flight - a partial screen looks
                    // complete but is missing content; surface it as retryable.
                    self.store.patch(id) {
                        $0.status = .error
                        $0.error = "The connection dropped mid-screen - retry"
                        $0.searching = false
                    }
                    return
                }
                let genMs = s.map { Int((self.clock.now - $0.startedAt).rounded()) }
                let osCommand = s.flatMap { Lang.parseOsCommand($0.content) }
                self.store.patch(id) {
                    $0.status = .done
                    $0.genMs = genMs
                    $0.truncated = info.truncated
                    $0.osCommand = osCommand
                    $0.searching = false
                }
                if osCommand == nil { self.maybePrefetch(id) }
            },
            onError: { [weak self] error in
                guard let self, !stale() else { return }
                self.inflight.removeValue(forKey: id)
                let message = (error as? StreamError)?.message ?? String(describing: error)
                self.store.patch(id) {
                    $0.status = .error
                    $0.error = message
                    $0.searching = false
                }
            },
            onToolRound: { [weak self] _ in
                // The model wants tools (web_search). Refuse on speculative
                // prefetch - quota only burns on screens the user actually
                // opens; the errored cache entry regenerates fresh
                // (non-speculative, tools allowed) on tap.
                guard let self, !stale() else { return .abort }
                if self.store.get(id)?.speculative == true { return .abort }
                self.store.patch(id) {
                    $0.content = ""
                    $0.status = .pending
                    $0.searching = true
                }
                return .proceed
            }
        )

        // RN ordering: inflight.set(id, controller) BEFORE streamScreen(...).
        // The token is created and registered first so even a ScreenStreaming
        // impl that fires handlers synchronously is not dropped as stale.
        let token = StreamCancelToken()
        box.token = token
        inflight[id] = token
        streamer.stream(messages: buildMessages(for: screen), handlers: handlers, token: token)
    }

    private struct LaunchInput {
        var appId: String
        var appName: String
        var request: String
        var parentId: String?
        var speculative: Bool
    }

    private func launchScreen(_ input: LaunchInput) -> String {
        let id = newId()
        store.upsert(Screen(
            id: id,
            appId: input.appId,
            appName: input.appName,
            request: input.request,
            parentId: input.parentId,
            content: "",
            status: .pending,
            speculative: input.speculative,
            startedAt: clock.now
        ))
        startStream(id)
        return id
    }

    /// A cached screen is reusable unless it errored or looks stuck mid-stream.
    private func reusable(_ screen: Screen?) -> Bool {
        guard let screen else { return false }
        if screen.status == .error { return false }
        if (screen.status == .pending || screen.status == .streaming),
           clock.now - screen.startedAt > GenOSConstants.staleMs {
            return false
        }
        return true
    }

    // MARK: - Navigation entry points

    /// Open an app from the home grid - reuses the app's existing home
    /// screen when reusable; retries in place when stuck/errored.
    @discardableResult
    public func openApp(_ app: AppDef) -> String {
        if let existing = appHomeIndex[app.id] {
            let screen = store.get(existing)
            if reusable(screen) { return existing }
            if screen != nil {
                retryScreen(existing)
                return existing
            }
        }
        let id = launchScreen(LaunchInput(
            appId: app.id,
            appName: app.name,
            request: app.request,
            parentId: nil,
            speculative: false
        ))
        appHomeIndex[app.id] = id
        return id
    }

    /// Open a screen in another app via a genos://open deep link. Cache key
    /// "\(appId.lowercased()) \(request)"; unknown appIds get a capitalized
    /// fallback name.
    @discardableResult
    public func openDeepLink(appId: String, request: String) -> String {
        let key = "\(appId.lowercased()) \(request)"
        if let existing = deepLinkIndex[key] {
            let screen = store.get(existing)
            if reusable(screen) { return existing }
            if screen != nil {
                retryScreen(existing)
                return existing
            }
        }
        let app = apps.first { $0.id == appId.lowercased() }
        // RN: appId.charAt(0).toUpperCase() + appId.slice(1). Grapheme
        // prefix(1)/dropFirst() is provably equivalent for every BMP input:
        // uppercasing is scalar-wise, so "e\u{301}…" → "E\u{301}…" both ways,
        // and surrogate halves that JS splits and rejoins unchanged come out
        // identical too. The only divergence is a non-BMP FIRST character
        // with a case mapping (e.g. Deseret), where JS's lone-surrogate
        // charAt(0) can't uppercase but Swift can - kept grapheme-level
        // deliberately, since the UTF-16 spelling would corrupt such ids
        // into U+FFFD (Swift cannot hold JS's lone surrogates).
        let fallbackName = appId.prefix(1).uppercased() + appId.dropFirst()
        let id = launchScreen(LaunchInput(
            appId: app?.id ?? appId.lowercased(),
            appName: app?.name ?? fallbackName,
            request: request,
            parentId: nil,
            speculative: false
        ))
        deepLinkIndex[key] = id
        return id
    }

    /// Resolve a tapped action: prefetched screen when one exists, fresh
    /// generation otherwise. Form submissions bypass the cache both ways and
    /// append "\n\nSubmitted form values: " + JSON to the request.
    ///
    /// `formState` is an ORDERED key/value list: RN's JSON.stringify emits
    /// keys in object-insertion order, so the shell passes form values in UI
    /// insertion order and the request JSON preserves it.
    @discardableResult
    public func resolveAction(parentId: String, message: String, formState: [(String, JSONValue)]? = nil) -> String {
        let parent = store.get(parentId)
        let hasFormValues = !(formState ?? []).isEmpty
        let key = actionKey(parentId, message)

        if !hasFormValues, let hit = actionIndex[key] {
            if let hitScreen = store.get(hit) {
                if reusable(hitScreen) {
                    store.patch(hit) {
                        $0.speculative = false
                        $0.prefetched = hitScreen.speculative && hitScreen.status == .done
                    }
                    return hit
                }
                retryScreen(hit)
                return hit
            }
        }

        let request: String
        if hasFormValues, let formState {
            request = "\(message)\n\nSubmitted form values: \(JSONValue.stringifyOrdered(formState))"
        } else {
            request = message
        }
        let id = launchScreen(LaunchInput(
            appId: parent?.appId ?? "unknown",
            appName: parent?.appName ?? "App",
            request: request,
            parentId: parentId,
            speculative: false
        ))
        if !hasFormValues { actionIndex[key] = id }
        return id
    }

    /// Re-generate a failed or stuck screen in place: clears content/error/
    /// flags, resets startedAt, speculative → false (re-enables tools).
    public func retryScreen(_ id: String) {
        guard store.get(id) != nil else { return }
        let now = clock.now
        store.patch(id) {
            $0.content = ""
            $0.status = .pending
            $0.error = nil
            $0.genMs = nil
            $0.prefetched = nil
            $0.truncated = nil
            $0.startedAt = now
            // A user-initiated retry is never speculative - this also
            // re-enables tools for prefetched screens that errored with
            // NEEDS_LIVE_DATA.
            $0.speculative = false
            $0.searching = false
        }
        startStream(id)
    }

    /// The shell reports which screen is on top; prefetch only ever runs for
    /// the visible screen.
    public func setActiveScreen(_ id: String?) {
        currentActiveScreenId = id
        if let id, store.get(id)?.status == .done {
            maybePrefetch(id)
        }
    }

    /// Currently visible screen id as last reported by the shell.
    public var activeScreenId: String? {
        currentActiveScreenId
    }

    private func maybePrefetch(_ id: String) {
        guard currentActiveScreenId == id else { return }
        guard let screen = store.get(id), screen.status == .done else { return }

        for message in Lang.extractActions(Lang.cleanLang(screen.content)).prefix(GenOSConstants.maxPrefetch) {
            let key = actionKey(id, message)
            if actionIndex[key] != nil { continue }
            let childId = launchScreen(LaunchInput(
                appId: screen.appId,
                appName: screen.appName,
                request: message,
                parentId: id,
                speculative: true
            ))
            actionIndex[key] = childId
        }
    }
}
