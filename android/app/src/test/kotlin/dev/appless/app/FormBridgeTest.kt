package dev.appless.app

import dev.appless.app.render.toControllerFormState
import dev.appless.uicore.FormStateModel
import dev.appless.uicore.FormValue
import org.junit.jupiter.api.Test
import dev.appless.genoscore.JsonValue as CoreJson
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * The one bridge between `:openui-lang`'s `JsonValue` (the contract/prop world)
 * and `:genos-core`'s (the wire world).
 *
 * The two types deliberately do not know about each other. The property that
 * matters is KEY ORDER: `spec/openui-lang.md` §9.4 says the submitted payload
 * lists fields in UI insertion order, and the request the model sees is a
 * `JSON.stringify` of it — so an order-losing bridge would silently reorder
 * every form submission.
 */
class FormBridgeTest {

    @Test
    fun `form payloads cross the bridge in UI order`() {
        val model = FormStateModel()
        model.set("signup", "email", "Input", FormValue.Str("a@b.co"))
        model.set("signup", "plan", "Select", FormValue.Str("pro"))
        model.set("signup", "seats", "Slider", FormValue.Numbers(listOf(3.0)))

        val bridged = model.payload("signup").toControllerFormState()

        assertEquals(listOf("signup"), bridged.map { it.first })
        val form = bridged.single().second
        assertIs<CoreJson.Obj>(form)
        assertEquals(listOf("email", "plan", "seats"), form.values.keys.toList())
    }

    @Test
    fun `each field keeps its value and componentType wrapper`() {
        val model = FormStateModel()
        model.set("f", "note", "TextArea", FormValue.Str("hi"))

        val form = model.payload("f").toControllerFormState().single().second
        val field = (form as CoreJson.Obj).values.getValue("note") as CoreJson.Obj
        assertEquals(listOf("value", "componentType"), field.values.keys.toList())
        assertEquals("hi", (field.values.getValue("value") as CoreJson.Str).value)
        assertEquals("TextArea", (field.values.getValue("componentType") as CoreJson.Str).value)
    }

    @Test
    fun `a slider submits a number array, not a scalar`() {
        // react-lang's range-slider convention (material/forms.tsx L199-201).
        val model = FormStateModel()
        model.set("f", "seats", "Slider", FormValue.Numbers(listOf(3.0)))

        val form = model.payload("f").toControllerFormState().single().second
        val field = (form as CoreJson.Obj).values.getValue("seats") as CoreJson.Obj
        val value = field.values.getValue("value")
        assertIs<CoreJson.Arr>(value)
        assertEquals(1, value.values.size)
        assertEquals(3.0, (value.values.single() as CoreJson.Num).value)
    }

    @Test
    fun `a named form with no data falls back to the whole store snapshot`() {
        // spec §9.4 step 1 — this is what makes a Button inside an empty Form
        // still submit fields written outside it.
        val model = FormStateModel()
        model.set("other", "x", "Input", FormValue.Str("1"))

        val bridged = model.payload("empty-form").toControllerFormState()
        assertEquals(listOf("other"), bridged.map { it.first })
    }

    @Test
    fun `fields written outside any Form land in the unscoped bucket`() {
        val model = FormStateModel()
        model.set(FormStateModel.UNSCOPED_FORM_NAME, "q", "Input", FormValue.Str("tea"))

        val bridged = model.payload(null).toControllerFormState()
        assertEquals(listOf(FormStateModel.UNSCOPED_FORM_NAME), bridged.map { it.first })
    }

    @Test
    fun `an empty store bridges to an empty list`() {
        assertTrue(FormStateModel().payload(null).toControllerFormState().isEmpty())
    }

    @Test
    fun `overwriting a field keeps its original position`() {
        val model = FormStateModel()
        model.set("f", "a", "Input", FormValue.Str("1"))
        model.set("f", "b", "Input", FormValue.Str("2"))
        model.set("f", "a", "Input", FormValue.Str("3"))

        val form = model.payload("f").toControllerFormState().single().second as CoreJson.Obj
        assertEquals(listOf("a", "b"), form.values.keys.toList())
    }
}
