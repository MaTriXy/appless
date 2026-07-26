package dev.appless.uicore

import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropValue
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The form-state model and the `{ value, componentType }` payload
 * (`spec/openui-lang.md` §9.4 step 1), plus the input behavior and SelectItem
 * decoding shared by every design system (`src/genos/ui/shared/forms.ts`).
 */
class FormStateTest {

    @Test
    fun `fields are wrapped with their component type`() {
        val state = FormStateModel()
        state.set("signup", "email", "Input", FormValue.Str("a@b.co"))
        assertEquals(
            """{"value":"a@b.co","componentType":"Input"}""",
            JsonWriter.write(state.field("signup", "email")!!.wrapped),
        )
    }

    @Test
    fun `fields keep UI insertion order inside a form`() {
        val state = FormStateModel()
        state.set("signup", "email", "Input", FormValue.Str("a@b.co"))
        state.set("signup", "plan", "Select", FormValue.Str("pro"))
        state.set("signup", "seats", "Slider", FormValue.Numbers(listOf(3.0)))
        // Overwriting keeps the original position.
        state.set("signup", "email", "Input", FormValue.Str("c@d.co"))
        assertEquals(listOf("email", "plan", "seats"), state.fields("signup").map { it.name })
        assertEquals(
            """{"signup":{"email":{"value":"c@d.co","componentType":"Input"},""" +
                """"plan":{"value":"pro","componentType":"Select"},""" +
                """"seats":{"value":[3],"componentType":"Slider"}}}""",
            state.payload("signup").stringified(),
        )
    }

    @Test
    fun `a form with data submits only that form, otherwise the whole store`() {
        val state = FormStateModel()
        state.set("a", "x", "Input", FormValue.Str("1"))
        state.set("b", "y", "Input", FormValue.Str("2"))
        assertEquals(listOf("a"), state.payload("a").keys)
        assertEquals(listOf("a", "b"), state.payload(null).keys, "whole-store snapshot, in form order")
        // A form name with NO data falls back to the whole store.
        assertEquals(listOf("a", "b"), state.payload("empty").keys)
    }

    @Test
    fun `unscoped fields live in their own bucket and still submit`() {
        val state = FormStateModel()
        state.set(FormStateModel.UNSCOPED_FORM_NAME, "query", "Input", FormValue.Str("hi"))
        assertEquals("", FormStateModel.UNSCOPED_FORM_NAME)
        assertEquals(
            """{"":{"query":{"value":"hi","componentType":"Input"}}}""",
            state.payload(null).stringified(),
        )
    }

    @Test
    fun `seeding only applies to a field with no value yet`() {
        val state = FormStateModel()
        assertTrue(state.seedDefault("f", "name", "Input", FormValue.Str("Ada")))
        assertFalse(state.seedDefault("f", "name", "Input", FormValue.Str("Grace")))
        assertEquals(FormValue.Str("Ada"), state.value("f", "name"))
    }

    @Test
    fun `reset drops named fields, or the whole form when unnamed`() {
        val state = FormStateModel()
        state.set("f", "a", "Input", FormValue.Str("1"))
        state.set("f", "b", "Input", FormValue.Str("2"))
        state.reset("f", listOf("a"))
        assertEquals(listOf("b"), state.fields("f").map { it.name })
        state.reset("f")
        assertTrue(state.isEmpty)
        assertEquals(emptyList<String>(), state.formNames)
        state.reset("nonexistent") // must not throw
    }

    @Test
    fun `seed decodes the model-supplied value prop, and absent stays absent`() {
        assertNull(FormValue.seed(null))
        assertNull(FormValue.seed(PropValue.Null), "an explicit null must not submit null")
        assertEquals(FormValue.Str("x"), FormValue.seed(PropValue.Str("x")))
        assertEquals(FormValue.Num(3.0), FormValue.seed(PropValue.Num(3.0)))
        assertEquals(FormValue.Bool(true), FormValue.seed(PropValue.Bool(true)))
        assertEquals(
            FormValue.Numbers(listOf(1.0, 5.0)),
            FormValue.seed(PropValue.Arr(listOf(PropValue.Num(1.0), PropValue.Num(5.0)))),
        )
        assertNull(FormValue.seed(PropValue.Arr(emptyList())))
        assertNull(
            FormValue.seed(PropValue.Arr(listOf(PropValue.Num(1.0), PropValue.Str("2")))),
            "a mixed array is not a slider range",
        )
    }

    @Test
    fun `text and numbers accessors apply the RN guards`() {
        assertEquals("x", FormValue.Str("x").textValue)
        assertEquals("", FormValue.Num(1.0).textValue, "non-strings hand TextInput an empty string")
        assertEquals("", FormValue.Null.textValue)
        assertEquals(listOf(2.0), FormValue.Numbers(listOf(2.0)).numbersValue)
        assertEquals(listOf(2.0), FormValue.Num(2.0).numbersValue)
        assertNull(FormValue.Str("2").numbersValue)
    }

    @Test
    fun `values serialize with JS JSON semantics`() {
        assertEquals("3", JsonWriter.write(FormValue.Num(3.0).json))
        assertEquals("3.5", JsonWriter.write(FormValue.Num(3.5).json))
        assertEquals("null", JsonWriter.write(FormValue.Num(Double.NaN).json), "JSON.stringify(NaN) is null")
        assertEquals("null", JsonWriter.write(FormValue.Null.json))
        assertEquals("true", JsonWriter.write(FormValue.Bool(true).json))
        assertEquals("[1,2.5]", JsonWriter.write(FormValue.Numbers(listOf(1.0, 2.5)).json))
        assertEquals("\"a\\\"b\\n\"", JsonWriter.string("a\"b\n"))
    }

    // ------------------------------------------------------------- forms.ts

    @Test
    fun `input behavior matches the KEYBOARD table`() {
        assertEquals("email-address", InputBehavior.keyboardType("email"))
        assertEquals("numeric", InputBehavior.keyboardType("number"))
        assertEquals("url", InputBehavior.keyboardType("url"))
        assertEquals("default", InputBehavior.keyboardType("text"))
        assertEquals("default", InputBehavior.keyboardType(null))
        assertEquals("default", InputBehavior.keyboardType("password"))

        assertTrue(InputBehavior.isSecure("password"))
        assertFalse(InputBehavior.isSecure("text"))
        assertFalse(InputBehavior.isSecure(null))

        assertEquals("none", InputBehavior.autoCapitalize("email"))
        assertEquals("none", InputBehavior.autoCapitalize("url"))
        assertEquals("sentences", InputBehavior.autoCapitalize("text"))
        assertEquals("sentences", InputBehavior.autoCapitalize(null))
    }

    @Test
    fun `readSelectItems decodes SelectItem elements and drops the rest`() {
        val items = PropValue.Arr(
            listOf(
                PropValue.Element(
                    ElementNode(
                        "SelectItem",
                        props = mapOf("value" to PropValue.Str("pro"), "label" to PropValue.Str("Pro")),
                    )
                ),
                PropValue.Element(
                    ElementNode("SelectItem", props = mapOf("value" to PropValue.Str("free")))
                ),
                PropValue.Str("junk"),
                PropValue.Null,
            )
        )
        val options = readSelectItems(items)
        assertEquals(2, options.size)
        assertEquals(SelectOption("pro", "Pro"), options[0])
        // `it.label ?? it.value` — material/forms.tsx L175.
        assertEquals("Pro", options[0].displayLabel)
        assertEquals("free", options[1].displayLabel)
        assertEquals(emptyList<SelectOption>(), readSelectItems(null))
        assertEquals(emptyList<SelectOption>(), readSelectItems(PropValue.Str("nope")))
    }
}
