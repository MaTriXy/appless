package dev.appless.app

import dev.appless.app.shell.ActionRoute
import dev.appless.app.shell.ActionRouter
import dev.appless.app.shell.CommandRouter
import dev.appless.app.shell.ShellCommand
import dev.appless.app.shell.TileIcons
import dev.appless.uicore.ActionEvent
import dev.appless.uicore.OrderedJson
import dev.appless.openuilang.JsonValue
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * The two routing tables, tested against `GenOS.tsx`'s `handleAction` and
 * `routeCommand`.
 *
 * These guards are what stop the model being asked to generate a fake home
 * screen or a stale copy of the previous one, so they are worth pinning
 * exactly.
 */
class RoutingTest {

    private fun event(
        message: String = "",
        url: String? = null,
        formState: OrderedJson = OrderedJson(),
    ): ActionEvent = if (url != null) {
        ActionEvent(
            type = ActionEvent.Kind.OPEN_URL,
            params = mapOf("url" to JsonValue.Str(url)),
            humanFriendlyMessage = message,
            formState = formState,
        )
    } else {
        ActionEvent(
            type = ActionEvent.Kind.CONTINUE_CONVERSATION,
            humanFriendlyMessage = message,
            formState = formState,
        )
    }

    // ------------------------------------------------------- genos:// routing

    @Test
    fun `toast deep link uses its text`() {
        val route = ActionRouter.route(event(url = "genos://toast?text=Saved"), true, false)
        assertEquals(ActionRoute.Toast("Saved"), route)
    }

    @Test
    fun `an empty toast text falls back to the default`() {
        // `params.text || "Done ✓"` — an EMPTY string is falsy in JS.
        assertEquals(
            ActionRoute.Toast(ActionRouter.DEFAULT_TOAST),
            ActionRouter.route(event(url = "genos://toast?text="), true, false),
        )
        assertEquals(
            ActionRoute.Toast(ActionRouter.DEFAULT_TOAST),
            ActionRouter.route(event(url = "genos://toast"), true, false),
        )
    }

    @Test
    fun `open deep link needs both app and request`() {
        assertEquals(
            ActionRoute.DeepLink("food", "show my orders"),
            ActionRouter.route(event(url = "genos://open?app=food&request=show+my+orders"), true, false),
        )
        assertEquals(
            ActionRoute.Ignore,
            ActionRouter.route(event(url = "genos://open?app=food"), true, false),
        )
    }

    @Test
    fun `back and home deep links route to the shell`() {
        assertEquals(ActionRoute.Back, ActionRouter.route(event(url = "genos://back"), true, false))
        assertEquals(ActionRoute.Home, ActionRouter.route(event(url = "genos://home"), true, false))
    }

    @Test
    fun `an unparsable genos url is ignored, never opened externally`() {
        assertEquals(
            ActionRoute.Ignore,
            ActionRouter.route(event(url = "genos://not a command"), true, false),
        )
    }

    @Test
    fun `a real url leaves the app`() {
        val route = ActionRouter.route(event(url = "https://example.com"), true, false)
        assertEquals(ActionRoute.OpenExternalUrl("https://example.com"), route)
    }

    // ------------------------------------------------------- message routing

    @Test
    fun `a tap mid-stream is toasted, never silently dropped`() {
        val route = ActionRouter.route(event(message = "Show details"), true, generating = true)
        assertEquals(ActionRoute.StillGenerating(ActionRouter.STILL_GENERATING), route)
    }

    @Test
    fun `navigation-shaped requests go to the OS, not the model`() {
        for (message in listOf(
            "genos home",
            "genoshome",
            "Take me to all your apps",
            "open the app drawer",
            "show the app grid",
            "back to the main menu",
        )) {
            assertEquals(ActionRoute.Home, ActionRouter.route(event(message), true, false), message)
        }
    }

    @Test
    fun `an app home screen is NOT an OS home request`() {
        // "Settings home screen" must still reach the model — that is an app
        // home, not the OS one.
        val route = ActionRouter.route(event("Open the Settings home screen"), true, false)
        assertIs<ActionRoute.Resolve>(route)
    }

    @Test
    fun `back-shaped messages pop instead of generating`() {
        for (message in listOf(
            "back",
            "Back",
            "go back",
            "return back",
            "navigate back to the previous screen",
            "back to previous",
        )) {
            assertEquals(ActionRoute.Back, ActionRouter.route(event(message), true, false), message)
        }
    }

    @Test
    fun `back as part of a longer request still generates`() {
        val route = ActionRouter.route(event("take me back to my orders"), true, false)
        assertIs<ActionRoute.Resolve>(route)
    }

    @Test
    fun `an empty or whitespace message is ignored`() {
        assertEquals(ActionRoute.Ignore, ActionRouter.route(event("   "), true, false))
        assertEquals(ActionRoute.Ignore, ActionRouter.route(event(""), true, false))
    }

    @Test
    fun `a message with no active screen is ignored`() {
        assertEquals(
            ActionRoute.Ignore,
            ActionRouter.route(event("Show details"), hasActiveScreen = false, generating = false),
        )
    }

    @Test
    fun `the resolve route carries the trimmed message and the form payload`() {
        val payload = OrderedJson(listOf("signup" to JsonValue.Obj(linkedMapOf())))
        val route = ActionRouter.route(event("  Submit  ", formState = payload), true, false)
        assertEquals(ActionRoute.Resolve("Submit", payload), route)
    }

    // ------------------------------------------------------- command routing

    @Test
    fun `spoken navigation commands control the shell`() {
        assertEquals(ShellCommand.Back, CommandRouter.route("go back", "messages", true))
        assertEquals(ShellCommand.Back, CommandRouter.route("Back.", "messages", true))
        assertEquals(ShellCommand.Back, CommandRouter.route("previous screen", "messages", true))
        assertEquals(ShellCommand.Home, CommandRouter.route("home screen", "messages", true))
        assertEquals(ShellCommand.Home, CommandRouter.route("take me home!", "messages", true))
        assertEquals(ShellCommand.CloseApp, CommandRouter.route("close this app", "messages", true))
        assertEquals(ShellCommand.OpenSwitcher, CommandRouter.route("recent apps", "messages", true))
        assertEquals(
            ShellCommand.OpenSwitcher,
            CommandRouter.route("open the app switcher", "messages", true),
        )
    }

    @Test
    fun `close app with nothing open is ignored`() {
        assertEquals(ShellCommand.Ignore, CommandRouter.route("close this app", null, false))
    }

    @Test
    fun `an explicit open jumps to a known app even from inside another`() {
        val route = CommandRouter.route("open weather", "messages", true)
        assertIs<ShellCommand.Launch>(route)
        assertEquals("weather", route.app.id)
    }

    @Test
    fun `a bare app name only launches when nothing is open`() {
        val fromHome = CommandRouter.route("weather", null, false)
        assertIs<ShellCommand.Launch>(fromHome)
        assertEquals("weather", fromHome.app.id)

        // Inside an app, "weather" is a REQUEST, not a jump.
        val insideApp = CommandRouter.route("weather", "messages", true)
        assertIs<ShellCommand.Continue>(insideApp)
    }

    @Test
    fun `free text inside an app continues the conversation`() {
        val route = CommandRouter.route("show my orders from last week", "food", true)
        assertEquals(ShellCommand.Continue("show my orders from last week"), route)
    }

    @Test
    fun `free text from home summons an app`() {
        val route = CommandRouter.route("plan a birthday party", null, false)
        assertIs<ShellCommand.Summon>(route)
        assertEquals("summon-plan-a-birthday-party", route.app.id)
        assertEquals("plan a birthday party", route.app.name)
        assertTrue(route.app.request.contains("Open the perfect app screen for this request"))
        assertTrue(route.app.request.contains("plan a birthday party"))
    }

    @Test
    fun `a long summon name is elided at 24 characters`() {
        val text = "find me a really excellent quiet cafe nearby"
        val route = CommandRouter.route(text, null, false)
        assertIs<ShellCommand.Summon>(route)
        assertEquals(CommandRouter.summonName(text), route.app.name)
        assertEquals(25, route.app.name.length, "24 chars plus the ellipsis")
        // The REQUEST keeps the full text — only the display name is elided.
        assertTrue(route.app.request.contains(text))
    }

    @Test
    fun `empty input is ignored`() {
        assertEquals(ShellCommand.Ignore, CommandRouter.route("   ", "messages", true))
    }

    @Test
    fun `OS open resolves by id or display name, else summons`() {
        assertEquals("weather", CommandRouter.resolveOsOpen("weather").id)
        assertEquals("weather", CommandRouter.resolveOsOpen("Weather").id)
        assertEquals("summon-tarot", CommandRouter.resolveOsOpen("Tarot").id)
    }

    // ----------------------------------------------------------- tile icons

    @Test
    fun `tile icons prefer the emoji, then keywords, then sparkle`() {
        assertEquals("BowlFood", TileIcons.tileIcon("Food", "food", "🍜"))
        assertEquals("Coffee", TileIcons.tileIcon("Coffee run", "summon-coffee-run", "✨"))
        assertEquals("Sparkle", TileIcons.tileIcon("Zzz", "summon-zzz", "✨"))
    }

    @Test
    fun `keyword matching reads the id slug too`() {
        // A summoned app's id is a slug of the original typed query.
        assertEquals("AirplaneTilt", TileIcons.tileIcon("Untitled", "summon-weekend-in-goa", "✨"))
    }

    @Test
    fun `keyword order is preserved so coffee beats trip`() {
        assertEquals("Coffee", TileIcons.tileIcon("Coffee trip", "summon-coffee-trip", "✨"))
    }

    @Test
    fun `one word names drop leading filler`() {
        assertEquals("Trip", TileIcons.oneWordName("Trip Planner"))
        assertEquals("Day", TileIcons.oneWordName("My Day"))
        assertEquals("Notes", TileIcons.oneWordName("  The Notes  "))
        assertEquals("My", TileIcons.oneWordName("My"), "an all-filler name keeps its first word")
    }
}
