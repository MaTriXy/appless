package dev.appless.genoscore

/**
 * Generation, navigation cache and speculative prefetch controller
 * (src/genos/store.ts module-level controller functions).
 *
 * Single-threaded by contract: confine it (and the [store], [clock] and
 * streamer it is given) to one dispatcher.
 */
public class GenOSController(
    public val store: ScreenStore,
    private val streamer: ScreenStreaming,
    private val clock: GenOSClock,
    /** App catalog used by [openDeepLink] lookups (`Apps.all` in production). */
    private val apps: List<AppDef>,
) {
    private var idCounter = 0

    /** `${parentId} ${actionMessage}` → child screen id. */
    private val actionIndex = HashMap<String, String>()

    /** appId → home screen id (reopening an app from the grid is instant). */
    private val appHomeIndex = HashMap<String, String>()

    /** `${appId} ${request}` → screen id (repeated deep links reuse a screen). */
    private val deepLinkIndex = HashMap<String, String>()

    /** screen id → cancellation token for its in-flight generation. */
    private val inflight = HashMap<String, StreamCancelToken>()

    /** Currently visible screen id as last reported by the shell. */
    public var activeScreenId: String? = null
        private set

    private fun newId(): String {
        idCounter++
        return "screen-$idCounter"
    }

    private fun actionKey(parentId: String, message: String): String = "$parentId $message"

    // Context

    /**
     * Walk parents up to `CONTEXT_DEPTH` ancestors; replay each ancestor as a
     * user request + (if content) an assistant `cleanLang(content)` turn; the
     * final turn is the screen's own request. Text-only.
     */
    public fun buildMessages(screen: Screen): List<ChatMessage> {
        val chain = ArrayList<Screen>()
        chain.add(screen)
        var cur = screen
        while (cur.parentId != null && chain.size <= GenOSConstants.CONTEXT_DEPTH) {
            val parent = store.get(cur.parentId!!) ?: break
            chain.add(0, parent)
            cur = parent
        }

        val messages = ArrayList<ChatMessage>()
        for (s in chain.dropLast(1)) {
            // Ancestors replay text-only — re-sending images would burn tokens
            // per hop.
            messages.add(ChatMessage(ChatRole.USER, s.request))
            if (s.content.isNotEmpty()) {
                messages.add(ChatMessage(ChatRole.ASSISTANT, Lang.cleanLang(s.content)))
            }
        }
        messages.add(ChatMessage(ChatRole.USER, screen.request))
        return messages
    }

    // Stream lifecycle

    private fun startStream(id: String) {
        val screen = store.get(id) ?: return
        inflight[id]?.cancel()

        // Callbacks from a superseded stream (a retry replaced this token) must
        // not touch the screen or delete the new stream's token.
        val token = StreamCancelToken()
        val stale = { inflight[id] !== token }

        val handlers = StreamHandlers(
            onDelta = { delta ->
                if (!stale()) store.append(id, delta)
            },
            onDone = { info ->
                if (!stale()) {
                    inflight.remove(id)
                    val s = store.get(id)
                    if (info.dropped) {
                        // The stream died mid-flight — a partial screen looks
                        // complete but is missing content; surface it as
                        // retryable instead.
                        store.patch(id) {
                            it.copy(
                                status = ScreenStatus.ERROR,
                                error = "The connection dropped mid-screen - retry",
                                searching = false,
                            )
                        }
                    } else {
                        // RN: Math.round(performance.now() - s.startedAt).
                        // roundToInt() THREW on NaN and saturated silently at
                        // Int.MAX_VALUE; jsRoundToInt runs the same JS
                        // Math.round + clamp the Swift port runs.
                        val genMs = s?.let { jsRoundToInt(clock.now - it.startedAt) }
                        val osCommand = s?.let { Lang.parseOsCommand(it.content) }
                        store.patch(id) {
                            it.copy(
                                status = ScreenStatus.DONE,
                                genMs = genMs,
                                truncated = info.truncated,
                                osCommand = osCommand,
                                searching = false,
                            )
                        }
                        if (osCommand == null) maybePrefetch(id)
                    }
                }
            },
            onError = { error ->
                if (!stale()) {
                    inflight.remove(id)
                    // RN emits the bare err.message; toString() would prefix
                    // the fully-qualified class name.
                    val message = jsErrorMessage(error)
                    store.patch(id) {
                        it.copy(status = ScreenStatus.ERROR, error = message, searching = false)
                    }
                }
            },
            onToolRound = {
                // The model wants tools (web_search). Refuse on speculative
                // prefetch — quota only burns on screens the user actually
                // opens; the errored cache entry regenerates fresh
                // (non-speculative, tools allowed) on tap.
                when {
                    stale() -> ToolRoundDecision.ABORT
                    store.get(id)?.speculative == true -> ToolRoundDecision.ABORT
                    else -> {
                        store.patch(id) {
                            it.copy(
                                content = "",
                                status = ScreenStatus.PENDING,
                                searching = true,
                            )
                        }
                        ToolRoundDecision.PROCEED
                    }
                }
            },
        )

        // RN ordering: inflight.set(id, controller) BEFORE streamScreen(...).
        // The token is registered first so even a ScreenStreaming impl that
        // fires handlers synchronously is not dropped as stale.
        inflight[id] = token
        streamer.stream(buildMessages(screen), handlers, token)
    }

    private fun launchScreen(
        appId: String,
        appName: String,
        request: String,
        parentId: String?,
        speculative: Boolean,
    ): String {
        val id = newId()
        store.upsert(
            Screen(
                id = id,
                appId = appId,
                appName = appName,
                request = request,
                parentId = parentId,
                content = "",
                status = ScreenStatus.PENDING,
                speculative = speculative,
                startedAt = clock.now,
            ),
        )
        startStream(id)
        return id
    }

    /** A cached screen is reusable unless it errored or looks stuck mid-stream. */
    private fun reusable(screen: Screen?): Boolean {
        if (screen == null) return false
        if (screen.status == ScreenStatus.ERROR) return false
        if ((screen.status == ScreenStatus.PENDING || screen.status == ScreenStatus.STREAMING) &&
            clock.now - screen.startedAt > GenOSConstants.STALE_MS
        ) {
            return false
        }
        return true
    }

    // Navigation entry points

    /**
     * Open an app from the home grid — reuses the app's existing home screen
     * when reusable; retries in place when stuck/errored.
     */
    public fun openApp(app: AppDef): String {
        appHomeIndex[app.id]?.let { existing ->
            val screen = store.get(existing)
            if (reusable(screen)) return existing
            if (screen != null) {
                retryScreen(existing)
                return existing
            }
        }
        val id = launchScreen(
            appId = app.id,
            appName = app.name,
            request = app.request,
            parentId = null,
            speculative = false,
        )
        appHomeIndex[app.id] = id
        return id
    }

    /**
     * Open a screen in another app via a `genos://open` deep link. Cache key
     * "${appId.lowercase()} $request"; unknown appIds get a capitalized
     * fallback name.
     */
    public fun openDeepLink(appId: String, request: String): String {
        val key = "${appId.lowercase()} $request"
        deepLinkIndex[key]?.let { existing ->
            val screen = store.get(existing)
            if (reusable(screen)) return existing
            if (screen != null) {
                retryScreen(existing)
                return existing
            }
        }
        val app = apps.firstOrNull { it.id == appId.lowercase() }
        // RN: appId.charAt(0).toUpperCase() + appId.slice(1) — a UTF-16 CODE
        // UNIT split, so an astral first character (a lone high surrogate) has
        // no case mapping and is left alone. Swift's grapheme-level prefix(1)
        // used to uppercase it; both ports now call the same named helper.
        val fallbackName = jsCapitalizeFirst(appId)
        val id = launchScreen(
            appId = app?.id ?: appId.lowercase(),
            appName = app?.name ?: fallbackName,
            request = request,
            parentId = null,
            speculative = false,
        )
        deepLinkIndex[key] = id
        return id
    }

    /**
     * Resolve a tapped action: a prefetched screen when one exists, a fresh
     * generation otherwise. Form submissions bypass the cache both ways and
     * append "\n\nSubmitted form values: " + JSON to the request.
     *
     * [formState] is an ORDERED key/value list: RN's `JSON.stringify` emits keys
     * in object-insertion order, so the shell passes form values in UI insertion
     * order and the request JSON preserves it.
     */
    public fun resolveAction(
        parentId: String,
        message: String,
        formState: List<Pair<String, JsonValue>>? = null,
    ): String {
        val parent = store.get(parentId)
        val hasFormValues = !formState.isNullOrEmpty()
        val key = actionKey(parentId, message)

        if (!hasFormValues) {
            actionIndex[key]?.let { hit ->
                val hitScreen = store.get(hit)
                if (hitScreen != null) {
                    if (reusable(hitScreen)) {
                        store.patch(hit) {
                            it.copy(
                                speculative = false,
                                prefetched = hitScreen.speculative &&
                                    hitScreen.status == ScreenStatus.DONE,
                            )
                        }
                        return hit
                    }
                    retryScreen(hit)
                    return hit
                }
            }
        }

        val request = if (hasFormValues) {
            "$message\n\nSubmitted form values: ${JsonValue.stringifyOrdered(formState.orEmpty())}"
        } else {
            message
        }
        val id = launchScreen(
            appId = parent?.appId ?: "unknown",
            appName = parent?.appName ?: "App",
            request = request,
            parentId = parentId,
            speculative = false,
        )
        if (!hasFormValues) actionIndex[key] = id
        return id
    }

    /**
     * Re-generate a failed or stuck screen in place: clears content/error/flags,
     * resets `startedAt`, sets `speculative` false (which re-enables tools).
     */
    public fun retryScreen(id: String) {
        if (store.get(id) == null) return
        val now = clock.now
        store.patch(id) {
            it.copy(
                content = "",
                status = ScreenStatus.PENDING,
                error = null,
                genMs = null,
                prefetched = null,
                truncated = null,
                startedAt = now,
                // A user-initiated retry is never speculative — this also
                // re-enables tools for prefetched screens that errored with
                // NEEDS_LIVE_DATA.
                speculative = false,
                searching = false,
            )
        }
        startStream(id)
    }

    /**
     * The shell reports which screen is on top; prefetch only ever runs for the
     * visible screen, and kicks in when it (a) becomes visible already-complete
     * or (b) finishes generating while visible.
     */
    public fun setActiveScreen(id: String?) {
        activeScreenId = id
        if (id != null && store.get(id)?.status == ScreenStatus.DONE) maybePrefetch(id)
    }

    private fun maybePrefetch(id: String) {
        if (activeScreenId != id) return
        val screen = store.get(id) ?: return
        if (screen.status != ScreenStatus.DONE) return

        val messages = Lang.extractActions(Lang.cleanLang(screen.content))
            .take(GenOSConstants.MAX_PREFETCH)
        for (message in messages) {
            val key = actionKey(id, message)
            if (actionIndex.containsKey(key)) continue
            val childId = launchScreen(
                appId = screen.appId,
                appName = screen.appName,
                request = message,
                parentId = id,
                speculative = true,
            )
            actionIndex[key] = childId
        }
    }
}
