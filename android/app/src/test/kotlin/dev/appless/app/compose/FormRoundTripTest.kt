package dev.appless.app.compose

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import dev.appless.app.render.toControllerFormState
import dev.appless.genoscore.JsonValue as CoreJson
import dev.appless.uicore.FormStateModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The form round trip, end to end through a REAL composition: type into an
 * `Input`, tap a `Button`, and inspect the payload the shell would ship to the
 * model.
 *
 * This is the highest-value suite in the tier, for two reasons.
 *
 * 1. Every other form test in this repo starts at `FormStateModel` — it writes
 *    fields by calling `set(...)` directly, in whatever order the test author
 *    chose. That cannot catch the bug that actually matters, which is the
 *    Compose renderers writing fields in a DIFFERENT order than they appear on
 *    screen (a `LaunchedEffect`-seeded default racing a user edit, a `Form`
 *    scoping to the wrong name, a `remember` key that resets a field). Only a
 *    composition can order the writes the way a user does.
 *
 * 2. Key ORDER is load-bearing and invisible. The request the model receives is
 *    `"\n\nSubmitted form values: " + JSON.stringify(formState)`
 *    (`spec/openui-lang.md` §9.4 step 6), so the field order in that JSON is
 *    what the model reads as "the order of the form". React-lang stores the
 *    payload as a plain JS object (`store.set(formName, {...formData, [name]:
 *    wrapped})`, react-lang `hooks/useOpenUIState.js`), which means
 *    `JSON.stringify` enumerates it with `OrdinaryOwnPropertyKeys`: canonical
 *    array-index keys FIRST in ascending numeric order, then the remaining keys
 *    in insertion order.
 */
@RunWith(RobolectricTestRunner::class)
class FormRoundTripTest {

    @get:Rule
    val compose = createComposeRule()

    /** The submitted payload as `[form -> [field -> [key -> value]]]`. */
    private fun payloadOf(actions: RecordingActions): List<Pair<String, CoreJson>> =
        actions.last.formState.toControllerFormState()

    private fun fields(form: CoreJson): List<String> =
        (form as CoreJson.Obj).values.keys.toList()

    private fun field(form: CoreJson, name: String): CoreJson.Obj =
        (form as CoreJson.Obj).values.getValue(name) as CoreJson.Obj

    private fun str(value: CoreJson?): String = (value as CoreJson.Str).value

    // ------------------------------------------------------- the round trip

    /**
     * Type, tap, and read the payload.
     *
     * Every hop is real: `BasicTextField.onValueChange` -> `FormStore.set` ->
     * `FormStateModel` -> `ActionDispatcher` -> `GenosActions.outcomes` ->
     * `ActionEvent.formState` -> the `:genos-core` bridge.
     */
    @Test
    fun typing_into_an_input_and_tapping_a_button_submits_the_typed_value() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("signup", btns, [c1])
            c1 = FormControl("Email", email)
            email = Input("email", "you@example.com", "email")
            btns = Buttons([send])
            send = Button("Create account", Action([@ToAssistant("Create the account")]))
            """.trimIndent(),
        )

        compose.onNodeWithText("you@example.com").performTextInput("maya@example.com")
        compose.onNodeWithText("Create account").performClick()
        compose.waitForIdle()

        val payload = payloadOf(actions)
        // Scoped to the enclosing Form's name — `Button` is the only renderer
        // that passes `formName` (`forms.tsx` L260-309).
        assertEquals(listOf("signup"), payload.map { it.first })
        assertEquals("signup", actions.last.formName)

        val form = payload.single().second
        assertEquals(listOf("email"), fields(form))
        val email = field(form, "email")
        // `{ value, componentType }` — in that order, spec §9.4 step 1.
        assertEquals(listOf("value", "componentType"), email.values.keys.toList())
        assertEquals("maya@example.com", str(email.values["value"]))
        assertEquals("Input", str(email.values["componentType"]))

        // And the message is the action's, not the button's label.
        assertEquals("Create the account", actions.last.humanFriendlyMessage)
    }

    /**
     * Fields reach the model in FIRST-WRITE order — not in screen order.
     *
     * React-lang appends each newly written field to a plain object
     * (`store.set(formName, { ...formData, [name]: wrapped })`, react-lang
     * `useOpenUIState.js`), and a key that does not yet exist lands at the END.
     * So the order the model sees is the order the fields were first touched,
     * which for a typed form is the TYPING order.
     *
     * Written as a probe: the three inputs sit on screen as `name, email, city`
     * and are typed into back to front. Screen order would give
     * `name, email, city`; the RN behavior gives `city, email, name`, and that
     * is what is asserted. (Seeded fields are the other half of this rule — see
     * the Slider in
     * [each_renderer_stamps_its_own_componentType_and_value_shape].)
     */
    @Test
    fun fields_are_submitted_in_first_write_order_not_screen_order() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("profile", btns, [a, b, c])
            a = Input("name", "name")
            b = Input("email", "email")
            c = Input("city", "city")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("city").performTextInput("Tokyo")
        compose.onNodeWithText("email").performTextInput("m@x.co")
        compose.onNodeWithText("name").performTextInput("Maya")
        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        val form = payloadOf(actions).single().second
        assertEquals(
            "first-write order, i.e. the typing order — NOT the screen order",
            listOf("city", "email", "name"),
            fields(form),
        )
    }

    /**
     * A form whose field names are canonical ARRAY INDICES.
     *
     * `JSON.stringify` on react-lang's plain-object store hoists integer-index
     * keys ahead of every string key, in ascending NUMERIC order
     * (`OrdinaryOwnPropertyKeys`, ES 10.1.11.1 — the same rule
     * `spec/fixtures/075-object-key-index-order` pins for the tree serializer).
     * So `"2"` precedes `"10"`, and `"4294967295"` is NOT an index and stays in
     * the string group.
     *
     * This is not a hypothetical: the model names fields freely, and a
     * questionnaire screen numbering its questions `1`, `2`, `10` is exactly
     * the shape the prompt encourages.
     */
    @Test
    fun canonical_array_index_field_names_are_hoisted_and_sorted_numerically() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("quiz", btns, [q10, qz, q2, qbig, q0])
            q10 = Input("10", "ten")
            qz = Input("zeta", "zeta")
            q2 = Input("2", "two")
            qbig = Input("4294967295", "not an index")
            q0 = Input("0", "zero")
            btns = Buttons([save])
            save = Button("Submit")
            """.trimIndent(),
        )

        for (placeholder in listOf("ten", "zeta", "two", "not an index", "zero")) {
            compose.onNodeWithText(placeholder).performTextInput("v")
        }
        compose.onNodeWithText("Submit").performClick()
        compose.waitForIdle()

        val form = payloadOf(actions).single().second
        assertEquals(
            "indices ascend numerically and precede the string keys, which keep insertion order",
            listOf("0", "2", "10", "zeta", "4294967295"),
            fields(form),
        )
    }

    /** The same rule applies to the OUTER level: the form names themselves. */
    @Test
    fun numeric_form_names_are_hoisted_in_the_whole_store_snapshot() {
        val actions = compose.renderProgram(
            """
            root = Card([f10, fa, f2, btns])
            f10 = Form("10", none, [i1])
            fa = Form("alpha", none, [i2])
            f2 = Form("2", none, [i3])
            i1 = Input("x", "ten field")
            i2 = Input("x", "alpha field")
            i3 = Input("x", "two field")
            none = Buttons([])
            btns = Buttons([submit])
            submit = Button("Send")
            """.trimIndent(),
        )

        compose.onNodeWithText("ten field").performTextInput("a")
        compose.onNodeWithText("alpha field").performTextInput("b")
        compose.onNodeWithText("two field").performTextInput("c")
        // The button sits OUTSIDE every Form, so it has no form name and the
        // payload is the whole-store snapshot (spec §9.4 step 1).
        compose.onNodeWithText("Send").performClick()
        compose.waitForIdle()

        assertEquals(null, actions.last.formName)
        assertEquals(listOf("2", "10", "alpha"), payloadOf(actions).map { it.first })
    }

    /**
     * Two forms on one screen may use the SAME field name without colliding —
     * that scoping is the only thing `Form` does beyond layout
     * (`forms.tsx` L324-333), and a `Button` submits only its own form.
     */
    @Test
    fun two_forms_scope_the_same_field_name_independently() {
        val actions = compose.renderProgram(
            """
            root = Card([one, two])
            one = Form("login", b1, [i1])
            two = Form("signup", b2, [i2])
            i1 = Input("email", "login email")
            i2 = Input("email", "signup email")
            b1 = Buttons([s1])
            b2 = Buttons([s2])
            s1 = Button("Log in")
            s2 = Button("Sign up")
            """.trimIndent(),
        )

        compose.onNodeWithText("login email").performTextInput("old@user.co")
        compose.onNodeWithText("signup email").performTextInput("new@user.co")
        compose.onNodeWithText("Sign up").performClick()
        compose.waitForIdle()

        val payload = payloadOf(actions)
        assertEquals(listOf("signup"), payload.map { it.first })
        assertEquals("new@user.co", str(field(payload.single().second, "email").values["value"]))
    }

    /**
     * A field written OUTSIDE any `Form` lands in the unscoped bucket
     * (react-lang's `useFormName()` is `undefined` there) and a bare `Button`
     * still submits it.
     */
    @Test
    fun a_bare_input_and_button_outside_any_form_still_round_trip() {
        val actions = compose.renderProgram(
            """
            root = Card([q, btns])
            q = Input("query", "search")
            btns = Buttons([go])
            go = Button("Go")
            """.trimIndent(),
        )

        compose.onNodeWithText("search").performTextInput("green tea")
        compose.onNodeWithText("Go").performClick()
        compose.waitForIdle()

        val payload = payloadOf(actions)
        assertEquals(listOf(FormStateModel.UNSCOPED_FORM_NAME), payload.map { it.first })
        assertEquals("green tea", str(field(payload.single().second, "query").values["value"]))
    }

    /**
     * Every input type carries its own `componentType`, and a `Slider` submits
     * a number ARRAY rather than a scalar (react-lang's range-slider
     * convention, `forms.tsx` L199-201).
     *
     * Composed rather than modelled because the `componentType` string is
     * chosen INSIDE each renderer — the one place a copy-paste between
     * `InputRenderer` and `TextAreaRenderer` would go unnoticed.
     */
    @Test
    fun each_renderer_stamps_its_own_componentType_and_value_shape() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("mix", btns, [a, b, c, d, e])
            a = Input("plain", "plain")
            b = TextArea("notes", "notes")
            c = DatePicker("day")
            d = Select("plan", [p], "pick")
            e = Slider("seats", "continuous", 0, 10, 1, [4], "Seats")
            p = SelectItem("pro", "Pro")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("plain").performTextInput("A")
        compose.onNodeWithText("notes").performTextInput("B")
        compose.onNodeWithText("YYYY-MM-DD").performTextInput("2026-07-26")
        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        val form = payloadOf(actions).single().second
        // Order is FIRST-WRITE order (see
        // `fields_are_submitted_in_first_write_order_not_screen_order`), and the
        // Slider's seed is written by an effect when the screen settles —
        // BEFORE anyone types. So `seats` leads, then the three typed fields in
        // typing order. The Select was never touched and is absent entirely.
        assertEquals(listOf("seats", "plain", "notes", "day"), fields(form))
        assertEquals("Input", str(field(form, "plain").values["componentType"]))
        assertEquals("TextArea", str(field(form, "notes").values["componentType"]))
        assertEquals("DatePicker", str(field(form, "day").values["componentType"]))
        assertEquals("Slider", str(field(form, "seats").values["componentType"]))

        val seats = field(form, "seats").values.getValue("value")
        assertTrue("a Slider submits an array, not a scalar: $seats", seats is CoreJson.Arr)
        assertEquals(1, (seats as CoreJson.Arr).values.size)
        assertEquals(4.0, (seats.values.single() as CoreJson.Num).value, 0.0)
    }

    /**
     * A model-supplied `value` prop SEEDS the field, so an untouched prefilled
     * edit screen still submits what it showed the user
     * (`useSetDefaultValue`, `shared/forms.ts` L24-30).
     */
    @Test
    fun a_model_supplied_value_is_seeded_into_the_submitted_payload_untouched() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("edit", btns, [a])
            a = Input("name", "placeholder", "text", null, "Maya Chen")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("Maya Chen").assertIsDisplayed()
        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        val form = payloadOf(actions).single().second
        assertEquals("Maya Chen", str(field(form, "name").values["value"]))
    }

    /**
     * Typing over a seeded value wins, and the seed does NOT come back.
     *
     * This is the exact bug `useSetDefaultValue`'s "only when the field has no
     * value" guard exists to prevent: the screen re-parses ~20 times a second
     * while streaming, and a seed that re-applied would erase the user's typing
     * mid-sentence.
     */
    @Test
    fun typing_over_a_seeded_value_is_not_clobbered_by_the_seed() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("edit", btns, [a])
            a = Input("name", "placeholder", "text", null, "Maya Chen")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("Maya Chen").performTextReplacement("Sora Ito")
        compose.waitForIdle()
        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        val form = payloadOf(actions).single().second
        assertEquals("Sora Ito", str(field(form, "name").values["value"]))
    }

    /**
     * Choosing an option in a `Select` writes its VALUE (not its label) —
     * `option.value?.let { field.set(...) }` — and the trigger then shows the
     * label.
     */
    @Test
    fun choosing_a_select_option_submits_its_value_and_shows_its_label() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("plan", btns, [s])
            s = Select("tier", [p1, p2], "Choose")
            p1 = SelectItem("free", "Free")
            p2 = SelectItem("pro", "Pro plan")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("Choose").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Pro plan").performClick()
        compose.waitForIdle()

        // The closed trigger now reads the LABEL.
        compose.onNodeWithText("Pro plan").assertIsDisplayed()

        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        val form = payloadOf(actions).single().second
        assertEquals("pro", str(field(form, "tier").values["value"]))
        assertEquals("Select", str(field(form, "tier").values["componentType"]))
    }

    /**
     * An empty form submits an EMPTY payload, and the shell drops it
     * (`route.formState.toControllerFormState().ifEmpty { null }`) so the
     * request carries no "Submitted form values:" suffix at all.
     */
    @Test
    fun a_form_with_no_touched_fields_submits_nothing() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("empty", btns, [a])
            a = Input("untouched", "type here")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        assertTrue(actions.last.formState.isEmpty)
        assertTrue(payloadOf(actions).isEmpty())
    }

    /**
     * The whole payload, serialized exactly as the controller serializes it.
     *
     * This is the byte-level statement of everything above: `JSON.stringify` of
     * the wrapped, ordered payload. If any of the three properties (wrapper
     * shape, wrapper key order, field order) regressed, this one string would
     * change.
     */
    @Test
    fun the_serialized_payload_is_byte_for_byte_what_the_model_receives() {
        val actions = compose.renderProgram(
            """
            root = Card([f])
            f = Form("signup", btns, [a, b])
            a = Input("email", "email")
            b = Slider("seats", "continuous", 1, 10, 1, [3], "Seats")
            btns = Buttons([save])
            save = Button("Save")
            """.trimIndent(),
        )

        compose.onNodeWithText("email").performTextInput("a@b.co")
        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()

        assertEquals(
            // `seats` leads because its default is seeded when the screen
            // settles, before the email is typed — first-write order.
            """{"signup":{"seats":{"value":[3],"componentType":"Slider"},""" +
                """"email":{"value":"a@b.co","componentType":"Input"}}}""",
            actions.last.formState.stringified(),
        )
    }
}
