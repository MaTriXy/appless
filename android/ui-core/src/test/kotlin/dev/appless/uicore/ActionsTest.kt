package dev.appless.uicore

import dev.appless.openuilang.ActionPlan
import dev.appless.openuilang.PropObject
import dev.appless.openuilang.PropValue
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * `ActionPlan -> ActionEvent`, per `spec/openui-lang.md` §9.3-§9.4.
 */
class ActionsTest {

    private fun step(vararg pairs: Pair<String, PropValue>): PropValue =
        PropValue.Obj(PropObject(pairs.toList()))

    private fun plan(vararg steps: PropValue) = ActionPlan(steps.toList())

    @Test
    fun `no plan means the element sends its own label`() {
        val outcomes = GenosActions.outcomes(plan = null, userMessage = "Book a table")
        assertEquals(1, outcomes.size)
        val event = (outcomes.single() as ActionOutcome.Dispatch).event
        assertEquals(ActionEvent.Kind.CONTINUE_CONVERSATION, event.type)
        assertEquals("continue_conversation", event.type.wire)
        assertEquals("Book a table", event.humanFriendlyMessage)
        assertTrue(event.params.isEmpty())
        assertNull(event.url)
    }

    @Test
    fun `an EMPTY plan dispatches nothing at all`() {
        assertEquals(emptyList<ActionOutcome>(), GenosActions.outcomes(plan(), userMessage = "ignored"))
    }

    @Test
    fun `ToAssistant carries its message and optional context`() {
        val outcomes = GenosActions.outcomes(
            plan(
                step(
                    "type" to PropValue.Str("continue_conversation"),
                    "message" to PropValue.Str("Show me Tuesday"),
                    "context" to PropValue.Str("calendar"),
                )
            ),
            userMessage = "label that must be ignored",
        )
        val event = (outcomes.single() as ActionOutcome.Dispatch).event
        assertEquals("Show me Tuesday", event.humanFriendlyMessage)
        assertEquals("calendar", (event.params["context"] as dev.appless.openuilang.JsonValue.Str).value)
    }

    @Test
    fun `OpenUrl dispatches an open_url event with an empty message`() {
        val outcomes = GenosActions.outcomes(
            plan(step("type" to PropValue.Str("open_url"), "url" to PropValue.Str("https://x.dev"))),
            userMessage = "Open",
        )
        val event = (outcomes.single() as ActionOutcome.Dispatch).event
        assertEquals(ActionEvent.Kind.OPEN_URL, event.type)
        assertEquals("open_url", event.type.wire)
        assertEquals("https://x.dev", event.url)
        assertEquals("", event.humanFriendlyMessage)
    }

    @Test
    fun `Set and Reset become state writes, in plan order`() {
        val outcomes = GenosActions.outcomes(
            plan(
                step("type" to PropValue.Str("set"), "target" to PropValue.Str("count"), "valueAST" to PropValue.Num(3.0)),
                step(
                    "type" to PropValue.Str("reset"),
                    "targets" to PropValue.Arr(listOf(PropValue.Str("a"), PropValue.Str("b"), PropValue.Num(1.0))),
                ),
                step("type" to PropValue.Str("run"), "statementId" to PropValue.Str("q1")),
            ),
            userMessage = "x",
        )
        assertEquals(
            listOf(
                ActionOutcome.SetState("count", PropValue.Num(3.0)),
                ActionOutcome.ResetState(listOf("a", "b")), // non-strings dropped
                ActionOutcome.RunStatement("q1"),
            ),
            outcomes,
        )
    }

    @Test
    fun `unknown and malformed steps are ignored, not fatal`() {
        val outcomes = GenosActions.outcomes(
            plan(
                step("type" to PropValue.Str("teleport")),
                step("message" to PropValue.Str("no type")),
                PropValue.Str("not an object"),
                step("type" to PropValue.Str("open_url"), "url" to PropValue.Str("https://ok")),
            ),
            userMessage = "x",
        )
        assertEquals(1, outcomes.size)
        assertEquals("https://ok", (outcomes.single() as ActionOutcome.Dispatch).event.url)
        // Decoding still SEES the unknown step, so it can be logged.
        val decoded = GenosActions.steps(
            plan(step("type" to PropValue.Str("teleport")), step("message" to PropValue.Str("no type")))
        )
        assertEquals(listOf(ActionStep.Unknown("teleport")), decoded)
    }

    @Test
    fun `String coercion matches JS for non-string step fields`() {
        val decoded = GenosActions.steps(
            plan(
                step("type" to PropValue.Str("continue_conversation"), "message" to PropValue.Num(3.0)),
                step("type" to PropValue.Str("continue_conversation"), "message" to PropValue.Bool(true)),
                step("type" to PropValue.Str("continue_conversation")),
                step("type" to PropValue.Str("continue_conversation"), "message" to PropValue.Num(Double.NaN)),
            )
        )
        assertEquals(
            listOf("3", "true", "", "NaN"),
            decoded.map { (it as ActionStep.ContinueConversation).message },
        )
    }

    @Test
    fun `events carry the form payload and form name unchanged`() {
        val state = FormStateModel()
        state.set("booking", "guests", "Slider", FormValue.Numbers(listOf(4.0)))
        val payload = state.payload("booking")
        val outcomes = GenosActions.outcomes(
            plan = null,
            userMessage = "Reserve",
            formName = "booking",
            formState = payload,
        )
        val event = (outcomes.single() as ActionOutcome.Dispatch).event
        assertEquals("booking", event.formName)
        assertEquals(
            """{"booking":{"guests":{"value":[4],"componentType":"Slider"}}}""",
            event.formState.stringified(),
        )
    }

    @Test
    fun `an element with no action is inert`() {
        assertFalse(GenosActions.isTappable(null))
        assertTrue(GenosActions.isTappable(plan()))
    }

    @Test
    fun `Chips send the filter sentence the RN renderer builds`() {
        assertEquals(
            "Apply the \"Vegan\" filter and re-render this screen with only matching content",
            GenosActions.chipsMessage("Vegan"),
        )
        // Pinned against the literal in the RN renderer.
        val components = RepoSources.text("src/genos/ui/material/components.tsx")
        assertTrue(
            components.contains("filter and re-render this screen with only matching content"),
            "the Chips message changed in material/components.tsx",
        )
    }
}
