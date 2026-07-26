package dev.appless.app.shell

import androidx.compose.runtime.Immutable
import dev.appless.genoscore.AppDef
import dev.appless.genoscore.Apps
import dev.appless.genoscore.OSCommand
import dev.appless.genoscore.OSCommandKind

/**
 * The OS shell's navigation state, as a pure value.
 *
 * `GenOS.tsx` keeps six `useState` hooks (`sessions`, `activeApp`,
 * `recentOrder`, `appMeta`, `minimizedIds`, `switcherOpen`) and mutates them
 * from callbacks. Collapsing them into ONE immutable value with pure
 * transitions is what lets every rule below — the back-stack arithmetic, the
 * "switching away backgrounds the previous app" rule, the `@OS(back)`
 * never-empty-the-stack guard — be unit-tested on the JVM with no device.
 *
 * `genos-core` owns everything about SCREENS (generation, caching, prefetch);
 * this owns only which screen is on top of which app.
 */

/** `AppMeta` — `GenOS.tsx` L48-52. The tile gradient stops are kept as raw hex. */
@Immutable
public data class AppMeta(
    val name: String,
    val emoji: String,
    val tileStart: String,
    val tileEnd: String,
) {
    public companion object {
        public fun of(app: AppDef): AppMeta =
            AppMeta(app.name, app.emoji, app.tileStart, app.tileEnd)
    }
}

/** `RunningApp` — `shell/Switcher.tsx` L9-14. */
@Immutable
public data class RunningApp(
    val id: String,
    val name: String,
    val emoji: String,
    val tileStart: String,
    val tileEnd: String,
)

/** Which transition the next screen mount plays — `NavDir`, `GenOS.tsx` L56. */
public enum class NavDir { LAUNCH, PUSH, POP }

@Immutable
public data class ShellState(
    /** appId -> stack of screen ids (a per-app session, like iOS multitasking). */
    val sessions: Map<String, List<String>> = emptyMap(),
    val activeApp: String? = null,
    /** Most-recently-activated first — the switcher's order. */
    val recentOrder: List<String> = emptyList(),
    val appMeta: Map<String, AppMeta> = emptyMap(),
    /** Apps sent home; only these show as icons on the home screen. */
    val minimizedIds: List<String> = emptyList(),
    val switcherOpen: Boolean = false,
    val navAnim: NavDir = NavDir.LAUNCH,
) {

    /** The active app's screen stack. */
    public val stack: List<String> get() = activeApp?.let { sessions[it] } ?: emptyList()

    /** The visible screen id. */
    public val topId: String? get() = stack.lastOrNull()

    // --------------------------------------------------------- meta & catalog

    /** `rememberMeta` — first write wins, so a summoned rename is not undone. */
    public fun rememberMeta(appId: String, meta: AppMeta): ShellState =
        if (appMeta.containsKey(appId)) this else copy(appMeta = appMeta + (appId to meta))

    /**
     * Adopt the title the model gave a summoned app's first screen —
     * `GenOS.tsx` L234-249. The gate (summon- prefix, stack depth 1) lives in
     * `genos-core`'s `Lang.summonedAppTitle`; this only applies the result.
     */
    public fun renameApp(appId: String, title: String): ShellState {
        val current = appMeta[appId] ?: return this
        if (current.name == title) return this
        return copy(appMeta = appMeta + (appId to current.copy(name = title)))
    }

    // ------------------------------------------------------------- activation

    /**
     * `activate` — `GenOS.tsx` L262-275.
     *
     * Switching away from a live session BACKGROUNDS it: the previous app joins
     * the minimized set so it stays reachable from the home grid, not only from
     * the switcher.
     */
    public fun activate(appId: String): ShellState {
        val minimized = if (activeApp != null && activeApp != appId && activeApp !in minimizedIds) {
            minimizedIds + activeApp
        } else {
            minimizedIds
        }
        return copy(
            navAnim = NavDir.LAUNCH,
            minimizedIds = minimized,
            activeApp = appId,
            switcherOpen = false,
            recentOrder = listOf(appId) + recentOrder.filter { it != appId },
        )
    }

    /**
     * `pushScreen` — `GenOS.tsx` L282-289.
     *
     * Idempotent: a duplicate dispatch of the SAME resolved screen must not
     * stack a second identical frame.
     */
    public fun pushScreen(appId: String, screenId: String): ShellState {
        val current = sessions[appId] ?: emptyList()
        if (current.lastOrNull() == screenId) return copy(navAnim = NavDir.PUSH)
        return copy(navAnim = NavDir.PUSH, sessions = sessions + (appId to current + screenId))
    }

    /** Seed an app's stack when it is opened for the first time — `launch`, L303-311. */
    public fun startSession(appId: String, screenId: String): ShellState {
        if (!sessions[appId].isNullOrEmpty()) return this
        return copy(sessions = sessions + (appId to listOf(screenId)))
    }

    /** `goBack` — `GenOS.tsx` L346-354: the root screen is never popped. */
    public fun goBack(): ShellState {
        val app = activeApp ?: return this
        val current = sessions[app] ?: emptyList()
        if (current.size <= 1) return copy(navAnim = NavDir.POP)
        return copy(navAnim = NavDir.POP, sessions = sessions + (app to current.dropLast(1)))
    }

    /**
     * The COMMIT half of `goHome` — `GenOS.tsx` L330-343, run when the
     * minimize animation finishes.
     *
     * `appId` is captured when the animation STARTS, so activating something
     * else mid-flight does not get dismissed along with it.
     */
    public fun commitMinimize(appId: String): ShellState = copy(
        minimizedIds = if (appId in minimizedIds) minimizedIds else minimizedIds + appId,
        activeApp = if (activeApp == appId) null else activeApp,
    )

    /**
     * `closeSession` — `GenOS.tsx` L356-367. Ends the thread outright, unlike
     * Home (which minimizes it into an icon).
     */
    public fun closeSession(appId: String): ShellState = copy(
        sessions = sessions - appId,
        recentOrder = recentOrder.filter { it != appId },
        minimizedIds = minimizedIds.filter { it != appId },
        activeApp = if (activeApp == appId) null else activeApp,
    )

    public fun setSwitcher(open: Boolean): ShellState = copy(switcherOpen = open)

    // ------------------------------------------------------------ OS commands

    /**
     * `@OS(...)` execution — `GenOS.tsx` L390-404.
     *
     * The screen that CARRIED the command is removed from the stack first
     * (it holds a command, not UI), then the navigation applies. `@OS(back)`
     * with only the root left must NOT empty the stack: an active app with zero
     * screens renders nothing and traps the user.
     */
    public fun applyOsCommand(screenId: String, command: OSCommand): ShellState {
        val app = activeApp ?: return this
        val remaining = (sessions[app] ?: emptyList()).filter { it != screenId }
        val next = if (command.cmd == OSCommandKind.BACK && remaining.size > 1) {
            remaining.dropLast(1)
        } else {
            remaining
        }
        return copy(navAnim = NavDir.POP, sessions = sessions + (app to next))
    }

    // -------------------------------------------------------------- projections

    /** `runningApps` — `GenOS.tsx` L527-540: every app with a live session. */
    public val runningApps: List<RunningApp>
        get() = recentOrder
            .filter { !sessions[it].isNullOrEmpty() }
            .map { id ->
                val meta = appMeta[id]
                RunningApp(
                    id = id,
                    name = meta?.name ?: capitalize(id),
                    emoji = meta?.emoji ?: "✨",
                    tileStart = meta?.tileStart ?: Apps.DEFAULT_TILE_START,
                    tileEnd = meta?.tileEnd ?: Apps.DEFAULT_TILE_END,
                )
            }

    /** `homeApps` — L541-544: only MINIMIZED sessions become home-screen icons. */
    public val homeApps: List<RunningApp>
        get() = runningApps.filter { it.id in minimizedIds }

    public fun withNavAnim(dir: NavDir): ShellState = copy(navAnim = dir)

    public companion object {
        /** `capitalize` — `GenOS.tsx` L54, UTF-16 exact (see `Controller.openDeepLink`). */
        public fun capitalize(s: String): String =
            if (s.isEmpty()) s else s.substring(0, 1).uppercase() + s.substring(1)
    }
}

/**
 * What Android's back gesture (predictive or hardware) does — `BackHandler`,
 * `GenOS.tsx` L466-481.
 *
 * Returning [BackAction.NOT_HANDLED] lets the system finish the activity, which
 * is RN's `return false`.
 */
public enum class BackAction {
    /** The switcher is open: close it. */
    CLOSE_SWITCHER,

    /** Mid-minimize: swallow the gesture so the animation is not raced. */
    CONSUME,

    /** Pop one screen off the active app's stack. */
    BACK,

    /** Minimize the active app into its home-screen icon. */
    HOME,

    /** Nothing to do — let Android leave the app. */
    NOT_HANDLED,
}

public object ShellBack {
    /** `hardwareBackPress` — `GenOS.tsx` L467-479, in evaluation order. */
    public fun action(state: ShellState, minimizing: Boolean): BackAction = when {
        state.switcherOpen -> BackAction.CLOSE_SWITCHER
        minimizing -> BackAction.CONSUME
        state.activeApp == null -> BackAction.NOT_HANDLED
        state.stack.size > 1 -> BackAction.BACK
        else -> BackAction.HOME
    }
}
