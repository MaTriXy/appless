package dev.appless.app.compose

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.appless.app.render.ScreenView
import dev.appless.app.render.toControllerFormState
import dev.appless.genoscore.JsonValue as CoreJson
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * A screen ARRIVING — the incremental parse, driven through the real
 * [ScreenView] exactly as `GenOSShell` drives it.
 *
 * This is the only suite that composes the production streaming entry point
 * (fence stripping, one cached `StreamingParser` per screen, full accumulated
 * text on every pass — `spec/openui-lang.md` §10). Everything else in the tier
 * hands the renderers an already-parsed tree.
 */
@RunWith(RobolectricTestRunner::class)
class StreamingSeedTest {

    @get:Rule
    val compose = createComposeRule()

    private val actions = RecordingActions()

    private var content by mutableStateOf("")
    private var streaming by mutableStateOf(true)

    private fun start() {
        compose.setThemedContent {
            ScreenView(
                content = content,
                isStreaming = streaming,
                schema = Harness.schema,
                formStore = actions.store,
                dispatcher = actions.dispatcher,
            )
        }
    }

    /** Feed the accumulated text so far, as the stream would. */
    private fun stream(text: String) {
        content = text
        compose.waitForIdle()
    }

    /** The stream ends: full text, `isStreaming` drops to false. */
    private fun finish(text: String) {
        content = text
        streaming = false
        compose.waitForIdle()
    }

    private val program = """
        root = Card([f])
        f = Form("edit", btns, [a])
        a = Input("name", "placeholder", "text", null, "Maya Chen")
        btns = Buttons([save])
        save = Button("Save")
    """.trimIndent()

    /**
     * The whole stream replayed character by character, then settled — and the
     * value the model finally gets is the COMPLETE one.
     *
     * This is the end-to-end shape of the streaming path: ~370 incremental
     * parses through the real cached `StreamingParser`, a composition per
     * frame, and one submission at the end. It is the integration counterpart
     * of the two focused tests below.
     */
    @Test
    fun a_screen_replayed_character_by_character_submits_the_finished_value() {
        start()
        for (end in 0..program.length) {
            stream(program.substring(0, end))
        }
        finish(program)

        compose.onNodeWithText("Maya Chen").assertIsDisplayed()

        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        val form = actions.last.formState.toControllerFormState().single().second as CoreJson.Obj
        val name = form.values.getValue("name") as CoreJson.Obj
        assertEquals("Maya Chen", (name.values.getValue("value") as CoreJson.Str).value)
    }

    /**
     * A prefilled field shows its PLACEHOLDER while the screen is generating,
     * and adopts the model-supplied value only once the stream settles.
     *
     * react-lang's `useSetDefaultValue` is
     * `if (!isStreaming && existingValue === undefined && defaultValue !== undefined)`
     * (`context.js` L81-98). Both guards are load-bearing and they guard
     * different things; the port originally carried only the second, so a
     * prefill appeared as soon as any parse resolved the prop.
     *
     * Seeding is one-shot — the `existingValue === undefined` guard refuses
     * every later write — so whatever gets seeded from a mid-stream parse is
     * permanent. `!isStreaming` is what guarantees it came from the finished
     * tree. This test fails without it.
     */
    @Test
    fun a_field_shows_its_placeholder_until_the_stream_settles() {
        start()
        stream(program)

        compose.onNodeWithText("placeholder").assertIsDisplayed()
        compose.onAllNodesWithText("Maya Chen").assertCountEquals(0)

        finish(program)
        compose.onNodeWithText("Maya Chen").assertIsDisplayed()
    }

    /**
     * What the user typed is never clobbered by the seed that arrives when the
     * stream settles — the `existingValue === undefined` half of the guard.
     */
    @Test
    fun typing_while_the_screen_streams_survives_the_settle() {
        start()
        stream(program)

        compose.onNodeWithText("placeholder").performTextInput("Sora Ito")
        compose.waitForIdle()

        finish(program)

        compose.onNodeWithText("Sora Ito").assertIsDisplayed()
        compose.onAllNodesWithText("Maya Chen").assertCountEquals(0)
    }

    /**
     * §11.1 — a program the model wrapped in a markdown fence is stripped
     * before parsing (`Lang.cleanLang`), including while the fence is still
     * unterminated mid-stream.
     */
    @Test
    fun a_fenced_program_is_stripped_and_rendered() {
        start()
        finish("```\n$program\n```")
        compose.onNodeWithText("Maya Chen").assertIsDisplayed()
        compose.onAllNodesWithText("```").assertCountEquals(0)
    }

    /** No renderable root yet means an EMPTY composition, not a crash. */
    @Test
    fun a_program_with_no_root_yet_renders_nothing() {
        start()
        stream("f = Form(\"edit\", btns, [a])")
        assertEquals(emptyList<String>(), compose.renderedText())
    }
}
