package dev.appless.app.compose

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.appless.app.shell.GenOSShell
import dev.appless.app.shell.ShellHost
import dev.appless.genoscore.Apps
import dev.appless.genoscore.ChatMessage
import dev.appless.genoscore.GenOSCancellable
import dev.appless.genoscore.GenOSClock
import dev.appless.genoscore.GenOSController
import dev.appless.genoscore.KeyStore
import dev.appless.genoscore.ScreenStore
import dev.appless.genoscore.ScreenStreaming
import dev.appless.genoscore.SecureStore
import dev.appless.genoscore.StreamCancelToken
import dev.appless.genoscore.StreamEndInfo
import dev.appless.genoscore.StreamHandlers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The OS shell, driven THROUGH THE COMPOSITION: home grid → open an app → push
 * a screen → back → home.
 *
 * `ShellStateTest` already covers the reducer, and covers it well. What it
 * cannot cover is the wiring: which callback the home grid's icon is bound to,
 * whether `BackOrHomePill` chooses back or home from the CURRENT stack depth,
 * whether an action dispatched by a rendered `Button` reaches
 * `ActionRouter.route` with the right `hasActiveScreen`/`generating` flags, and
 * whether the screen that comes back is actually composed. Every one of those
 * is a `GenOSShell.kt` bug that `ShellStateTest` passes through.
 *
 * The whole graph is real except the network: [FakeStreamer] answers every
 * generation synchronously with openui-lang source, which is what makes the
 * test deterministic (no clock advancing, no `waitUntil`, no flake) while still
 * exercising `GenOSController`'s cache, `ScreenStore`'s notification path and
 * the real `StreamingParser`.
 */
@RunWith(RobolectricTestRunner::class)
class ShellCompositionTest {

    @get:Rule
    val compose = createComposeRule()

    // ------------------------------------------------------------ test doubles

    /** Deterministic time: nothing in these tests depends on real elapsed ms. */
    private class FixedClock : GenOSClock {
        override val now: Double = 0.0

        /**
         * Runs the callback IMMEDIATELY rather than after `afterMs`.
         *
         * The only scheduled work the shell path reaches is `ScreenStore`'s
         * 50 ms streaming flush, whose entire purpose is to coalesce notifies —
         * collapsing it to zero removes the coalescing without changing any
         * observable state, and keeps the test off `mainClock` manipulation.
         */
        override fun schedule(afterMs: Double, work: () -> Unit): GenOSCancellable {
            work()
            return object : GenOSCancellable {
                override fun cancel() = Unit
            }
        }
    }

    /**
     * Answers every generation synchronously from a request -> source table.
     *
     * A request with no entry gets [defaultScreen], so the controller's
     * speculative PREFETCH (which fires for every `@ToAssistant` message on a
     * done screen) is satisfied too instead of hanging in PENDING.
     */
    private class FakeStreamer(
        private val screens: Map<String, String>,
        private val defaultScreen: String,
    ) : ScreenStreaming {

        /** Every request the shell asked the model for, in order. */
        val requests: MutableList<String> = mutableListOf()

        override fun stream(
            messages: List<ChatMessage>,
            handlers: StreamHandlers,
            token: StreamCancelToken,
        ) {
            val request = messages.last().content
            requests += request
            if (token.isCancelled) return
            handlers.onDelta(screens[request] ?: defaultScreen)
            handlers.onDone(StreamEndInfo())
        }
    }

    private object NoopSecureStore : SecureStore {
        override suspend fun read(key: String): String? = null
        override suspend fun write(key: String, value: String?) = Unit
    }

    // --------------------------------------------------------------- fixtures

    private val weather = Apps.all.first { it.id == "weather" }

    private val weatherHome = """
        root = Card([h, hero, list])
        h = CardHeader("Weather", "Tokyo")
        hero = HeroStat("18°", "RIGHT NOW", "Feels like 16°")
        list = ListBlock([r], "HOURLY")
        r = ListItem("Tonight", "Clear", "moon", "12°", Action([@ToAssistant("Open the hourly forecast")]))
    """.trimIndent()

    private val hourly = """
        root = Card([h])
        h = CardHeader("Hourly forecast", "Next 12 hours")
    """.trimIndent()

    private val fallback = """
        root = Card([h])
        h = CardHeader("Some other screen")
    """.trimIndent()

    private lateinit var streamer: FakeStreamer
    private lateinit var host: ShellHost

    private fun startShell(
        screens: Map<String, String> = mapOf(
            weather.request to weatherHome,
            "Open the hourly forecast" to hourly,
        ),
    ) {
        val clock = FixedClock()
        val store = ScreenStore(clock)
        streamer = FakeStreamer(screens, fallback)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        host = ShellHost(
            screenStore = store,
            // A non-empty env key puts the gate straight in PRESENT, so the
            // KeyGate overlay is not covering the shell. That is the production
            // path for a developer-injected key, not a test-only branch.
            keyStore = KeyStore(envKey = "csk-test", store = NoopSecureStore, scope = scope),
            controller = GenOSController(
                store = store,
                streamer = streamer,
                clock = clock,
                apps = Apps.all,
            ),
        )
        compose.setThemedContent { GenOSShell(app = host, schema = Harness.schema) }
        compose.waitForIdle()
    }

    // ------------------------------------------------------------------ tests

    /**
     * The home screen is what a cold start shows — wordmark, tagline, ask bar
     * and the rotating suggestions (`shell/HomeScreen.tsx`).
     */
    @Test
    fun a_cold_start_shows_the_home_screen_and_no_app() {
        startShell()
        compose.onNodeWithText("appless").assertIsDisplayed()
        compose.onNodeWithText("Just ask.").assertIsDisplayed()
        compose.onNodeWithText("Ask for anything…").assertIsDisplayed()
        // Nothing generated yet.
        assertTrue(streamer.requests.isEmpty())
    }

    /**
     * home → open an app → back → home, entirely through taps.
     *
     * Each hop asserts what is on screen, so a wiring bug (the pill calling
     * `goBack` when the stack is 1 deep, `HomeScreen` not un-covering) fails
     * here rather than passing a reducer test.
     */
    @Test
    fun open_an_app_push_a_screen_go_back_then_go_home() {
        startShell()

        // 1. Type a command into the ask bar — `CommandRouter.route` resolves
        //    "open weather" to the built-in app.
        compose.onNodeWithText("Ask for anything…").performTextInput("open weather")
        compose.waitForIdle()
        compose.onNodeWithText("open weather").performImeAction()
        compose.waitForIdle()

        // The app's home screen was generated and composed.
        assertEquals(listOf(weather.request), streamer.requests.take(1))
        compose.onNodeWithText("Weather").assertIsDisplayed()
        compose.onNodeWithText("18°").assertIsDisplayed()

        // 2. Tap a row inside the generated screen: its `@ToAssistant` action
        //    pushes a child screen.
        compose.onNodeWithText("Tonight").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Hourly forecast").assertIsDisplayed()

        // 3. Back — the stack is 2 deep, so the top-left pill pops rather than
        //    minimizing (`ShellBack.action` / `BackOrHomePill(isBack = …)`).
        compose.onNodeWithText("‹").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Weather").assertIsDisplayed()
        compose.onAllNodesWithText("Hourly forecast").assertCountEquals(0)

        // 4. Back again at the root — this time it minimizes to the home grid,
        //    where the app becomes an icon (`homeApps` = MINIMIZED sessions).
        compose.onNodeWithText("‹").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("appless").assertIsDisplayed()
        compose.onNodeWithText("Weather").assertIsDisplayed() // the home-grid tile label
    }

    /**
     * A minimized app resumes from its icon INSTANTLY — no second generation.
     *
     * The controller's `appHomeIndex` is what makes that true; the assertion is
     * on the streamer's request log, which is the only place a redundant
     * generation would show up.
     */
    @Test
    fun resuming_a_minimized_app_from_the_home_grid_does_not_regenerate_it() {
        startShell()
        openWeather()
        val afterOpen = streamer.requests.size

        // Minimize.
        compose.onNodeWithText("‹").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("appless").assertIsDisplayed()

        // Tap the icon.
        compose.onNodeWithText("Weather").performClick()
        compose.waitForIdle()

        compose.onNodeWithText("18°").assertIsDisplayed()
        assertEquals(
            "resuming must reuse the cached home screen",
            afterOpen,
            streamer.requests.size,
        )
    }

    /**
     * A free-text request with no matching built-in SUMMONS an app
     * (`CommandRouter.route`'s final branch) and the request carries the
     * summon prompt.
     */
    @Test
    fun a_free_text_request_summons_an_app() {
        startShell(screens = emptyMap())

        compose.onNodeWithText("Ask for anything…").performTextInput("plan a birthday party")
        compose.waitForIdle()
        compose.onNodeWithText("plan a birthday party").performImeAction()
        compose.waitForIdle()

        assertEquals(1, streamer.requests.size)
        assertTrue(
            "summoned request was: ${streamer.requests.single()}",
            streamer.requests.single().contains(
                "Open the perfect app screen for this request: \"plan a birthday party\"",
            ),
        )
        compose.onNodeWithText("Some other screen").assertIsDisplayed()
    }

    /**
     * Tapping a suggestion line runs the same command path as the ask bar.
     */
    @Test
    fun tapping_a_suggestion_row_dispatches_its_command() {
        startShell(screens = emptyMap())
        val first = Apps.suggestions[0]

        compose.onNodeWithText(first.label).performClick()
        compose.waitForIdle()

        assertEquals(1, streamer.requests.size)
        assertTrue(streamer.requests.single().contains(first.command))
    }

    /**
     * The app switcher lists every LIVE session (not just the minimized ones)
     * and closing one from there ends the thread — `closeSession`, which is
     * different from Home's minimize.
     */
    @Test
    fun the_switcher_lists_running_apps_and_closing_one_ends_the_session() {
        startShell()
        openWeather()

        compose.onNodeWithText("⧉").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Weather").assertIsDisplayed()

        compose.onNodeWithText("✕").performClick()
        compose.waitForIdle()

        // No sessions left: the switcher's empty state, and the home grid has
        // no icon.
        compose.onNodeWithText("No open apps").assertIsDisplayed()
    }

    /**
     * `genos://toast` is handled entirely in-process: it shows a toast and
     * never reaches the model (`ActionRouter.route` step 1).
     */
    @Test
    fun a_genos_toast_deep_link_toasts_and_generates_nothing() {
        startShell(
            screens = mapOf(
                weather.request to """
                    root = Card([b])
                    b = Button("Save", Action([@OpenUrl("genos://toast?text=Saved%20it")]))
                """.trimIndent(),
            ),
        )
        openWeather(assertContent = false)
        val before = streamer.requests.size

        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        compose.onNodeWithText("Saved it").assertIsDisplayed()
        assertEquals("a toast must not generate a screen", before, streamer.requests.size)
    }

    /**
     * A navigation-shaped MESSAGE goes to the OS, never to the model
     * (`ActionRouter.route` step 5). Without this guard the model happily
     * generates a fake home screen.
     */
    @Test
    fun a_button_asking_for_the_os_home_minimizes_instead_of_generating() {
        startShell(
            screens = mapOf(
                weather.request to """
                    root = Card([b])
                    b = Button("Go to genos home")
                """.trimIndent(),
            ),
        )
        openWeather(assertContent = false)
        val before = streamer.requests.size

        compose.onNodeWithText("Go to genos home").performClick()
        compose.waitForIdle()

        compose.onNodeWithText("appless").assertIsDisplayed()
        assertEquals(before, streamer.requests.size)
    }

    /** Open the Weather app through the ask bar. */
    private fun openWeather(assertContent: Boolean = true) {
        compose.onNodeWithText("Ask for anything…").performTextInput("open weather")
        compose.waitForIdle()
        compose.onNodeWithText("open weather").performImeAction()
        compose.waitForIdle()
        if (assertContent) compose.onNodeWithText("18°").assertIsDisplayed()
    }
}
