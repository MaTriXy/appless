package dev.appless.app.shell

import dev.appless.genoscore.AppDef
import dev.appless.genoscore.Apps
import dev.appless.genoscore.Lang
import dev.appless.genoscore.jsTrim
import dev.appless.uicore.ActionEvent
import dev.appless.uicore.OrderedJson

/**
 * Command and action ROUTING — the shell's two decision tables, as pure
 * functions.
 *
 * `GenOS.tsx` inlines both inside `useCallback`s (`handleAction` L413-464,
 * `routeCommand` L488-525). Lifting them out is what makes the OS-intent
 * guards — "genos home" must never reach the model, "back" must not generate a
 * screen, a typed command with no active app summons an app instead of
 * pushing — testable without a device.
 *
 * `genos-core` owns the PARSING (`Lang.parseGenosUrl`, `Lang.parseOsCommand`);
 * this owns only what the shell does with the result.
 */

// ------------------------------------------------------------- JS regex bits

/**
 * ECMAScript `\s` — `WhiteSpace ∪ LineTerminator`.
 *
 * `genos-core`'s `JsRegex` spells the same set but is `internal` to that
 * module. Java's `\s` is ASCII-only and its `UNICODE_CHARACTER_CLASS` variant
 * ADDS U+0085, which JS does not treat as whitespace — so the set is spelled
 * out rather than trusting either.
 */
private const val WS =
    "[\\t\\n\\x0B\\u000C\\r\\u0020\\u00A0\\u1680\\u2000-\\u200A" +
        "\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"

/** JS `.` (no `s` flag) excludes exactly these four; Java's also excludes U+0085. */
private const val DOT = "[^\\n\\r\\u2028\\u2029]"

private val IGNORE_CASE = setOf(RegexOption.IGNORE_CASE)

// -------------------------------------------------------------- action routing

/** What a tapped element's [ActionEvent] makes the shell do. */
public sealed interface ActionRoute {

    /** `genos://toast?text=…` — `params.text || "Done ✓"`. */
    public data class Toast(val text: String) : ActionRoute

    /** `genos://open?app=…&request=…`. */
    public data class DeepLink(val appId: String, val request: String) : ActionRoute

    /** `genos://back`. */
    public data object Back : ActionRoute

    /** `genos://home`, and the navigation-shaped-message guard. */
    public data object Home : ActionRoute

    /** A real URL: hand it to the system browser. */
    public data class OpenExternalUrl(val url: String) : ActionRoute

    /** A tap arrived while the parent screen was still streaming. */
    public data class StillGenerating(val toast: String) : ActionRoute

    /** Generate a child screen from `message`. */
    public data class Resolve(val message: String, val formState: OrderedJson) : ActionRoute

    /** Nothing to do (empty message, unparsable genos:// URL, no active app). */
    public data object Ignore : ActionRoute
}

public object ActionRouter {

    /** The toast a tap gets when the parent screen is not finished — L436. */
    public const val STILL_GENERATING: String = "Still materializing - try again in a second"

    /** `params.text || "Done ✓"` — L419. */
    public const val DEFAULT_TOAST: String = "Done ✓"

    /**
     * Navigation-shaped requests go to the OS, never to the model — L444-450.
     *
     * Without this the model happily generates a FAKE home screen or a stale
     * copy of the previous one. ("Settings home screen" is an app home, not OS
     * home, which is why the pattern requires the `genos` prefix there.)
     */
    private val OS_HOME_REQUEST = Regex(
        "genos${WS}*home|all (your |the )?apps|app (list|grid|drawer|launcher)|main menu",
        IGNORE_CASE,
    )

    /** `^(go |return |navigate )?back( to( the)? previous( screen)?)?$` — L451. */
    private val BACK_REQUEST = Regex(
        "(go |return |navigate )?back( to( the)? previous( screen)?)?",
        IGNORE_CASE,
    )

    /**
     * `handleAction(ev)` — `GenOS.tsx` L413-464, in source order.
     *
     * @param hasActiveScreen the shell has both an active app and a top screen
     * @param generating the top screen is still pending/streaming
     */
    public fun route(
        event: ActionEvent,
        hasActiveScreen: Boolean,
        generating: Boolean,
    ): ActionRoute {
        val url = event.url

        // 1. genos:// deep links are handled entirely in-process.
        if (url != null && url.startsWith("genos://")) {
            val parsed = Lang.parseGenosUrl(url) ?: return ActionRoute.Ignore
            val params = parsed.params
            return when (parsed.cmd) {
                "toast" -> ActionRoute.Toast(
                    params["text"].takeUnless { it.isNullOrEmpty() } ?: DEFAULT_TOAST,
                )
                "open" -> {
                    val app = params["app"]
                    val request = params["request"]
                    // Both must be present AND non-empty (a JS truthiness test).
                    if (!app.isNullOrEmpty() && !request.isNullOrEmpty()) {
                        ActionRoute.DeepLink(app, request)
                    } else {
                        ActionRoute.Ignore
                    }
                }
                "back" -> ActionRoute.Back
                "home" -> ActionRoute.Home
                else -> ActionRoute.Ignore
            }
        }

        // 2. Any other non-empty URL leaves the app.
        if (!url.isNullOrEmpty()) return ActionRoute.OpenExternalUrl(url)

        // 3. Otherwise it is a message for the model.
        val message = jsTrim(event.humanFriendlyMessage)
        if (message.isEmpty() || !hasActiveScreen) return ActionRoute.Ignore

        // A tap mid-stream would give the model a TRUNCATED parent as context.
        // Never dropped silently — that reads as "broken buttons".
        if (generating) return ActionRoute.StillGenerating(STILL_GENERATING)

        if (OS_HOME_REQUEST.containsMatchIn(message)) return ActionRoute.Home
        if (BACK_REQUEST.matches(message)) return ActionRoute.Back

        return ActionRoute.Resolve(message, event.formState)
    }
}

// ------------------------------------------------------------- command routing

/** What a typed/spoken command from the ask bar or a suggestion chip does. */
public sealed interface ShellCommand {
    public data object Back : ShellCommand
    public data object Home : ShellCommand

    /** "close this app" ENDS the session, unlike Home which minimizes it. */
    public data object CloseApp : ShellCommand
    public data object OpenSwitcher : ShellCommand

    /** Jump to a known built-in app. */
    public data class Launch(val app: AppDef) : ShellCommand

    /** Generate a child of the current screen. */
    public data class Continue(val text: String) : ShellCommand

    /** Invent an app for a free-text request. */
    public data class Summon(val app: AppDef) : ShellCommand

    public data object Ignore : ShellCommand
}

public object CommandRouter {

    // All four match against the LOWER-CASED, punctuation-stripped text, so no
    // `i` flag is needed — exactly as in `GenOS.tsx` L494-511.
    private val BACK = Regex("(go |navigate |take me )?back")
    private val HOME = Regex("(go |take me |go to )?home( screen)?")
    private val CLOSE_APP = Regex("close( this| the)? app")
    private val SWITCHER = Regex("(open |show )?(the )?(app )?(switcher|recent apps)")
    private val OPEN_APP = Regex("(?:open|launch|switch to|go to)${WS}+($DOT+)")

    /** `[.!?,]+$` with no `m` flag — `\z`, since Java's `$` also matches before a final newline. */
    private val TRAILING_PUNCTUATION = Regex("[.!?,]+\\z")

    /** The prompt a summoned free-text request carries — `GenOS.tsx` L521-523. */
    public fun summonRequest(text: String): String =
        "Open the perfect app screen for this request: \"$text\". " +
            "Invent a polished, realistic screen that fulfils it."

    /** `summonApp(text.length > 24 ? text.slice(0, 24) + "…" : text)` — L520. */
    public fun summonName(text: String): String =
        if (text.length > 24) text.take(24) + "…" else text

    /**
     * `routeCommand(transcript)` — `GenOS.tsx` L488-525, in source order.
     *
     * @param hasTopScreen there is an active app AND a screen on top of it
     */
    public fun route(
        transcript: String,
        activeApp: String?,
        hasTopScreen: Boolean,
        catalog: List<AppDef> = Apps.all,
    ): ShellCommand {
        val text = jsTrim(transcript)
        if (text.isEmpty()) return ShellCommand.Ignore

        val lower = jsTrim(TRAILING_PUNCTUATION.replace(text.lowercase(), ""))

        if (BACK.matches(lower) || lower == "previous screen") return ShellCommand.Back
        if (HOME.matches(lower)) return ShellCommand.Home
        if (CLOSE_APP.matches(lower)) {
            return if (activeApp != null) ShellCommand.CloseApp else ShellCommand.Ignore
        }
        if (SWITCHER.matches(lower)) return ShellCommand.OpenSwitcher

        // "open/launch/switch to <app>" jumps to a known app from anywhere; a
        // BARE app name only launches when nothing is open (otherwise "weather"
        // inside an app is a request, not a jump) — L513-517.
        val openMatch = OPEN_APP.matchEntire(lower)
        val haystack = openMatch?.groupValues?.getOrNull(1) ?: lower
        val known = catalog.firstOrNull { haystack.contains(it.name.lowercase()) }
        if (known != null && (openMatch != null || activeApp == null)) {
            return ShellCommand.Launch(known)
        }

        if (activeApp != null && hasTopScreen) return ShellCommand.Continue(text)

        val summoned = Apps.summonApp(summonName(text))
        return ShellCommand.Summon(summoned.copy(request = summonRequest(text)))
    }

    /**
     * `@OS(open, "<arg>")` target resolution — `GenOS.tsx` L406-410: a built-in
     * matched by id OR display name, otherwise a summoned app named by the arg.
     */
    public fun resolveOsOpen(arg: String, catalog: List<AppDef> = Apps.all): AppDef {
        val target = arg.lowercase()
        return catalog.firstOrNull { it.id == target || it.name.lowercase() == target }
            ?: Apps.summonApp(arg)
    }
}
