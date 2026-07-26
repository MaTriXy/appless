package dev.appless.app

import dev.appless.app.shell.AppMeta
import dev.appless.app.shell.BackAction
import dev.appless.app.shell.NavDir
import dev.appless.app.shell.ShellBack
import dev.appless.app.shell.ShellState
import dev.appless.genoscore.Apps
import dev.appless.genoscore.OSCommand
import dev.appless.genoscore.OSCommandKind
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The shell's navigation rules, tested against `src/genos/GenOS.tsx`.
 *
 * These are the rules that produce user-visible bugs when they drift: an app
 * that vanishes from the home grid, a back gesture that empties a stack, a
 * duplicated frame from a double-dispatched action.
 */
class ShellStateTest {

    private val messages = Apps.find("messages")!!
    private val food = Apps.find("food")!!

    private fun opened(vararg apps: Pair<String, String>): ShellState {
        var state = ShellState()
        for ((appId, screenId) in apps) {
            state = state.startSession(appId, screenId).activate(appId)
        }
        return state
    }

    // ------------------------------------------------------------- activation

    @Test
    fun `switching away backgrounds the previous app into the home grid`() {
        // GenOS.tsx L266-271: without this, the first app is reachable only
        // from the switcher and looks lost.
        val state = opened("messages" to "s1", "food" to "s2")
        assertEquals("food", state.activeApp)
        assertTrue("messages" in state.minimizedIds)
        assertTrue("food" !in state.minimizedIds)
    }

    @Test
    fun `re-activating the current app does not minimize it`() {
        val state = opened("messages" to "s1").activate("messages")
        assertTrue(state.minimizedIds.isEmpty())
    }

    @Test
    fun `activate moves the app to the front of the recency order`() {
        val state = opened("messages" to "s1", "food" to "s2").activate("messages")
        assertEquals(listOf("messages", "food"), state.recentOrder)
    }

    @Test
    fun `activate always plays the launch transition`() {
        val state = opened("messages" to "s1")
            .pushScreen("messages", "s2")
            .activate("messages")
        // Resuming must not replay whatever direction the last interaction left.
        assertEquals(NavDir.LAUNCH, state.navAnim)
    }

    // ------------------------------------------------------------------ stack

    @Test
    fun `pushing the same screen twice does not stack a duplicate frame`() {
        // GenOS.tsx L284-288: double action events / dev double-invocation.
        val state = opened("messages" to "s1")
            .pushScreen("messages", "s2")
            .pushScreen("messages", "s2")
        assertEquals(listOf("s1", "s2"), state.sessions["messages"])
    }

    @Test
    fun `back pops one screen but never the root`() {
        var state = opened("messages" to "s1").pushScreen("messages", "s2")
        state = state.goBack()
        assertEquals(listOf("s1"), state.sessions["messages"])
        state = state.goBack()
        assertEquals(listOf("s1"), state.sessions["messages"], "the root screen is never popped")
        assertEquals("messages", state.activeApp)
    }

    @Test
    fun `back sets the pop transition`() {
        val state = opened("messages" to "s1").pushScreen("messages", "s2").goBack()
        assertEquals(NavDir.POP, state.navAnim)
    }

    @Test
    fun `startSession is a no-op when the app already has a stack`() {
        val state = opened("messages" to "s1").startSession("messages", "s9")
        assertEquals(listOf("s1"), state.sessions["messages"])
    }

    // -------------------------------------------------------- home and close

    @Test
    fun `minimize adds the icon and clears the active app`() {
        val state = opened("messages" to "s1").commitMinimize("messages")
        assertNull(state.activeApp)
        assertTrue("messages" in state.minimizedIds)
        // The session SURVIVES: home minimizes, it does not close.
        assertEquals(listOf("s1"), state.sessions["messages"])
    }

    @Test
    fun `minimize only dismisses the app it started with`() {
        // The user activated something else mid-animation — GenOS.tsx L339.
        val state = opened("messages" to "s1", "food" to "s2").commitMinimize("messages")
        assertEquals("food", state.activeApp, "the newly activated app must survive")
        assertTrue("messages" in state.minimizedIds)
    }

    @Test
    fun `closing a session removes it everywhere`() {
        val state = opened("messages" to "s1").commitMinimize("messages").closeSession("messages")
        assertNull(state.sessions["messages"])
        assertTrue(state.recentOrder.isEmpty())
        assertTrue(state.minimizedIds.isEmpty())
        assertTrue(state.runningApps.isEmpty())
    }

    // ------------------------------------------------------------ projections

    @Test
    fun `only minimized sessions become home-screen icons`() {
        val state = opened("messages" to "s1", "food" to "s2")
            .rememberMeta("messages", AppMeta.of(messages))
            .rememberMeta("food", AppMeta.of(food))
        assertEquals(listOf("food", "messages"), state.runningApps.map { it.id })
        assertEquals(listOf("messages"), state.homeApps.map { it.id })
    }

    @Test
    fun `an app with no session is not running`() {
        val state = opened("messages" to "s1").closeSession("messages")
        assertTrue(state.runningApps.isEmpty())
    }

    @Test
    fun `unknown apps fall back to a capitalized id and the default tile`() {
        val state = ShellState().startSession("weatherly", "s1").activate("weatherly")
        val running = state.runningApps.single()
        assertEquals("Weatherly", running.name)
        assertEquals("✨", running.emoji)
        assertEquals(Apps.DEFAULT_TILE_START, running.tileStart)
        assertEquals(Apps.DEFAULT_TILE_END, running.tileEnd)
    }

    // -------------------------------------------------------------- app meta

    @Test
    fun `remembered meta is written once so a summoned rename survives`() {
        val state = ShellState()
            .rememberMeta("summon-x", AppMeta("x", "✨", "#a", "#b"))
            .renameApp("summon-x", "Trip Planner")
            .rememberMeta("summon-x", AppMeta("x", "✨", "#a", "#b"))
        assertEquals("Trip Planner", state.appMeta["summon-x"]?.name)
    }

    @Test
    fun `renaming an unknown app is a no-op`() {
        assertTrue(ShellState().renameApp("nope", "Title").appMeta.isEmpty())
    }

    // ------------------------------------------------------------ OS commands

    @Test
    fun `an OS command screen is removed from the stack`() {
        val state = opened("messages" to "s1")
            .pushScreen("messages", "s2")
            .applyOsCommand("s2", OSCommand(OSCommandKind.HOME))
        assertEquals(listOf("s1"), state.sessions["messages"])
    }

    @Test
    fun `OS back pops an additional screen`() {
        val state = opened("messages" to "s1")
            .pushScreen("messages", "s2")
            .pushScreen("messages", "s3")
            .applyOsCommand("s3", OSCommand(OSCommandKind.BACK))
        assertEquals(listOf("s1"), state.sessions["messages"])
    }

    @Test
    fun `OS back with only the root left must not empty the stack`() {
        // An active app with zero screens renders nothing and traps the user —
        // GenOS.tsx L399-401.
        val state = opened("messages" to "s1")
            .pushScreen("messages", "s2")
            .applyOsCommand("s2", OSCommand(OSCommandKind.BACK))
        assertEquals(listOf("s1"), state.sessions["messages"])
        assertTrue(state.sessions["messages"]!!.isNotEmpty())
    }

    // ---------------------------------------------------------- back gesture

    @Test
    fun `back closes the switcher first`() {
        val state = opened("messages" to "s1").setSwitcher(true)
        assertEquals(BackAction.CLOSE_SWITCHER, ShellBack.action(state, minimizing = false))
    }

    @Test
    fun `back is swallowed while minimizing`() {
        val state = opened("messages" to "s1")
        assertEquals(BackAction.CONSUME, ShellBack.action(state, minimizing = true))
    }

    @Test
    fun `back pops a deep stack and minimizes at the root`() {
        val deep = opened("messages" to "s1").pushScreen("messages", "s2")
        assertEquals(BackAction.BACK, ShellBack.action(deep, minimizing = false))

        val root = opened("messages" to "s1")
        assertEquals(BackAction.HOME, ShellBack.action(root, minimizing = false))
    }

    @Test
    fun `back on the home screen leaves the app to Android`() {
        assertEquals(BackAction.NOT_HANDLED, ShellBack.action(ShellState(), minimizing = false))
    }

    @Test
    fun `the switcher takes priority over the minimize guard`() {
        val state = opened("messages" to "s1").setSwitcher(true)
        assertEquals(BackAction.CLOSE_SWITCHER, ShellBack.action(state, minimizing = true))
    }

    // -------------------------------------------------------------- capitalize

    @Test
    fun `capitalize matches the RN UTF-16 behavior`() {
        assertEquals("Messages", ShellState.capitalize("messages"))
        assertEquals("", ShellState.capitalize(""))
        assertEquals("É", ShellState.capitalize("é"))
    }
}
