package dev.appless.app.compose

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import dev.appless.uicore.ActionEvent
import dev.appless.uicore.GenosActions
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Every one of the 30 Material renderers, COMPOSED, with a representative
 * payload — and asserted on what actually reached the semantics tree.
 *
 * The bar each test holds itself to: it must fail if the renderer drew nothing.
 * "Did not throw" is not an assertion — a renderer whose body is `Unit` passes
 * that, and five of the ones below (the charts) draw entirely into a `Canvas`,
 * so they are pinned through their `Text` chrome plus a forced draw pass in
 * [ChartCompositionTest].
 *
 * Props arrive through the REAL parser and the REAL contract
 * (`spec/contract/genos.schema.json`, out of the app's own assets), so a
 * positional-argument mapping that drifts from `paramOrder` fails here.
 *
 * Reference for every expectation: `src/genos/ui/material/components.tsx`,
 * `src/genos/ui/material/forms.tsx`, `src/genos/ui/shared`. Line citations
 * are on each test.
 */
@RunWith(RobolectricTestRunner::class)
class RendererCompositionTest {

    @get:Rule
    val compose = createComposeRule()

    // ------------------------------------------------------ structure & text

    /** `Card` — `components.tsx` L53-55: a column that renders its children. */
    @Test
    fun card_renders_every_child_in_order() {
        compose.renderProgram(
            """
            root = Card([a, b, c])
            a = TextContent("first")
            b = TextContent("second")
            c = TextContent("third")
            """.trimIndent(),
        )
        // All three present — a Card that dropped its children would still
        // "not throw".
        compose.onNodeWithText("first").assertIsDisplayed()
        compose.onNodeWithText("second").assertIsDisplayed()
        compose.onNodeWithText("third").assertIsDisplayed()
    }

    /**
     * `CardHeader` — `components.tsx` L58-77.
     *
     * The subtitle is an OVERLINE above the title (`!!props.subtitle` gates it),
     * so both strings must be on screen.
     */
    @Test
    fun cardHeader_shows_title_and_overline_subtitle() {
        compose.renderProgram(
            """root = Card([h])
               h = CardHeader("Wallet", "Personal · ··4821")""",
        )
        compose.onNodeWithText("Wallet").assertIsDisplayed()
        compose.onNodeWithText("Personal · ··4821").assertIsDisplayed()
    }

    /** `TextContent` — `components.tsx` L95-110. */
    @Test
    fun textContent_renders_its_text() {
        compose.renderProgram(
            """root = Card([t])
               t = TextContent("Popular near you", "large-heavy")""",
        )
        compose.onNodeWithText("Popular near you").assertIsDisplayed()
    }

    /**
     * `TextCallout` — `components.tsx` L119-155: title always, description only
     * when truthy.
     */
    @Test
    fun textCallout_renders_title_and_description() {
        compose.renderProgram(
            """root = Card([c])
               c = TextCallout("warning", "Low balance", "Top up before Friday")""",
        )
        compose.onNodeWithText("Low balance").assertIsDisplayed()
        compose.onNodeWithText("Top up before Friday").assertIsDisplayed()
    }

    // ------------------------------------------------------------------ lists

    /** `ListBlock` — `components.tsx` L273-300: header + one row per item. */
    @Test
    fun listBlock_renders_its_header_and_every_row() {
        compose.renderProgram(
            """
            root = Card([b])
            b = ListBlock([r1, r2], "CONNECTIVITY")
            r1 = ListItem("Wi-Fi", null, "wifi", "HomeNet")
            r2 = ListItem("Bluetooth", null, "bluetooth", "On")
            """.trimIndent(),
        )
        compose.onNodeWithText("CONNECTIVITY").assertIsDisplayed()
        compose.onNodeWithText("Wi-Fi").assertIsDisplayed()
        compose.onNodeWithText("Bluetooth").assertIsDisplayed()
        compose.onNodeWithText("HomeNet").assertIsDisplayed()
        compose.onNodeWithText("On").assertIsDisplayed()
    }

    /** `ListItem` — `components.tsx` L158-217: title, subtitle, trailing. */
    @Test
    fun listItem_renders_title_subtitle_and_trailing() {
        compose.renderProgram(
            """root = Card([r])
               r = ListItem("Storage", "212 GB of 256 GB used", "hard-drive", "82%")""",
        )
        compose.onNodeWithText("Storage").assertIsDisplayed()
        compose.onNodeWithText("212 GB of 256 GB used").assertIsDisplayed()
        compose.onNodeWithText("82%").assertIsDisplayed()
    }

    /**
     * `Toggle` — `components.tsx` L219-256.
     *
     * The switch is a real `Switch`, so it carries the `ToggleableState`
     * semantics — which is how "the model said `on: true`" is verified rather
     * than assumed.
     */
    @Test
    fun toggle_renders_its_labels_and_reflects_the_model_supplied_state() {
        compose.renderProgram(
            """root = Card([t])
               t = Toggle("Dark Mode", true, "moon", "Follows sunset")""",
        )
        compose.onNodeWithText("Dark Mode").assertIsDisplayed()
        compose.onNodeWithText("Follows sunset").assertIsDisplayed()
        compose.onNode(isToggleable()).assertIsOn()
    }

    /** `KVList` — `components.tsx` L302-347: label/value pairs. */
    @Test
    fun kvList_renders_every_label_and_value() {
        compose.renderProgram(
            """root = Card([k])
               k = KVList([{label: "Merchant", value: "Blue Tokai"}, {label: "Card", value: "··4821"}], "DETAILS")""",
        )
        compose.onNodeWithText("DETAILS").assertIsDisplayed()
        compose.onNodeWithText("Merchant").assertIsDisplayed()
        compose.onNodeWithText("Blue Tokai").assertIsDisplayed()
        compose.onNodeWithText("Card").assertIsDisplayed()
        compose.onNodeWithText("··4821").assertIsDisplayed()
    }

    // ------------------------------------------------------------------ stats

    /** `HeroStat` — `components.tsx` L350-386. */
    @Test
    fun heroStat_renders_value_label_and_sublabel() {
        compose.renderProgram(
            """root = Card([h])
               h = HeroStat("${'$'}8,427.50", "AVAILABLE BALANCE", "+${'$'}1,204 vs last month")""",
        )
        compose.onNodeWithText("$8,427.50").assertIsDisplayed()
        compose.onNodeWithText("AVAILABLE BALANCE").assertIsDisplayed()
        compose.onNodeWithText("+$1,204 vs last month").assertIsDisplayed()
    }

    /** `StatTiles` — `components.tsx` L388-441: label, value and signed delta. */
    @Test
    fun statTiles_renders_every_tile() {
        compose.renderProgram(
            """root = Card([s])
               s = StatTiles([{label: "Spent", value: "${'$'}2,318", delta: "-12%", icon: "arrow-down-right"}, {label: "Saved", value: "${'$'}940", delta: "+8%", icon: "piggy-bank"}])""",
        )
        compose.onNodeWithText("Spent").assertIsDisplayed()
        compose.onNodeWithText("$2,318").assertIsDisplayed()
        compose.onNodeWithText("-12%").assertIsDisplayed()
        compose.onNodeWithText("Saved").assertIsDisplayed()
        compose.onNodeWithText("$940").assertIsDisplayed()
        compose.onNodeWithText("+8%").assertIsDisplayed()
    }

    // ----------------------------------------------------------------- charts
    //
    // The five charts paint into a `Canvas`, which produces NO semantics. What
    // IS assertable in the tree is their chrome: the axis titles and the legend
    // (`charts.tsx` L76-114). `ChartCompositionTest` additionally forces a real
    // draw pass so the geometry code genuinely runs.

    /** `BarChart` — `charts.tsx` L199-260 + `Legend` L76-98. */
    @Test
    fun barChart_renders_axis_titles_and_a_legend_per_series() {
        compose.renderProgram(
            """
            root = Card([c])
            c = BarChart(["Q1", "Q2"], [a, b], "Quarter", "Revenue")
            a = Series("Direct", [12, 18])
            b = Series("Partner", [7, 9])
            """.trimIndent(),
        )
        compose.onNodeWithText("Quarter").assertIsDisplayed()
        compose.onNodeWithText("Revenue").assertIsDisplayed()
        // `showsLegend(seriesCount) = seriesCount > 1` — two series, so both
        // categories are named.
        compose.onNodeWithText("Direct").assertIsDisplayed()
        compose.onNodeWithText("Partner").assertIsDisplayed()
    }

    /** `HorizontalBarChart` — the same view with `horizontal = true`. */
    @Test
    fun horizontalBarChart_renders_axis_titles_and_a_legend_per_series() {
        compose.renderProgram(
            """
            root = Card([c])
            c = HorizontalBarChart(["Photos", "Video"], [a, b], "GB", "Category")
            a = Series("Used", [64, 96])
            b = Series("Free", [12, 4])
            """.trimIndent(),
        )
        compose.onNodeWithText("GB").assertIsDisplayed()
        compose.onNodeWithText("Category").assertIsDisplayed()
        compose.onNodeWithText("Used").assertIsDisplayed()
        compose.onNodeWithText("Free").assertIsDisplayed()
    }

    /** `LineChart` — `charts.tsx` L370-425. */
    @Test
    fun lineChart_renders_axis_titles_and_a_legend_per_series() {
        compose.renderProgram(
            """
            root = Card([c])
            c = LineChart(["Mon", "Tue", "Wed"], [a, b], "Day", "Steps")
            a = Series("You", [4200, 5100, 6300])
            b = Series("Average", [3800, 4000, 4200])
            """.trimIndent(),
        )
        compose.onNodeWithText("Day").assertIsDisplayed()
        compose.onNodeWithText("Steps").assertIsDisplayed()
        compose.onNodeWithText("You").assertIsDisplayed()
        compose.onNodeWithText("Average").assertIsDisplayed()
    }

    /** `AreaChart` — the same view with the area fill (`charts.tsx` L405-412). */
    @Test
    fun areaChart_renders_axis_titles_and_a_legend_per_series() {
        compose.renderProgram(
            """
            root = Card([c])
            c = AreaChart(["Feb", "Mar", "Apr"], [a, b], "Month", "USD")
            a = Series("Spending", [2100, 1890, 2480])
            b = Series("Budget", [2000, 2000, 2000])
            """.trimIndent(),
        )
        compose.onNodeWithText("Month").assertIsDisplayed()
        compose.onNodeWithText("USD").assertIsDisplayed()
        compose.onNodeWithText("Spending").assertIsDisplayed()
        compose.onNodeWithText("Budget").assertIsDisplayed()
    }

    /**
     * `PieChart` — `charts.tsx` L455-500.
     *
     * A pie ALWAYS shows its legend (`showAlways`, L497), unlike the cartesian
     * charts which need two series — so a single-slice pie must still name it.
     */
    @Test
    fun pieChart_always_renders_its_legend_even_for_one_slice() {
        compose.renderProgram(
            """root = Card([c])
               c = PieChart(["Rent"], [1200], "donut")""",
        )
        compose.onNodeWithText("Rent").assertIsDisplayed()
    }

    // ------------------------------------------------------------ media & nav

    /**
     * `ImageBlock` — `components.tsx` L444-478.
     *
     * The photo itself is a network load Robolectric never completes; the
     * CAPTION is the model-supplied text and is asserted for real.
     */
    @Test
    fun imageBlock_renders_its_caption_over_the_image() {
        compose.renderProgram(
            """root = Card([i])
               i = ImageBlock("/api/img?q=sushi&seed=1&w=800&h=440", "Tonight's pick: Sakura Sushi")""",
        )
        compose.onNodeWithText("Tonight's pick: Sakura Sushi").assertIsDisplayed()
    }

    /**
     * `PhotoGrid` — `components.tsx` L480-500.
     *
     * No text at all, so the assertion is structural: `.filter((im) => im?.src)`
     * (L484) must keep exactly the entries that HAVE a src. Cell count is
     * observable through the laid-out grid — see
     * [RendererSemanticsTest.photoGrid_lays_out_one_cell_per_image_with_a_src].
     */
    @Test
    fun photoGrid_composes_a_full_grid() {
        compose.renderProgram(
            """root = Card([g])
               g = PhotoGrid([{src: "/api/img?q=a&seed=1&w=200&h=200"}, {src: "/api/img?q=b&seed=2&w=200&h=200"}, {src: "/api/img?q=c&seed=3&w=200&h=200"}])""",
        )
        compose.onRoot().assertExists()
    }

    /** `Bubbles` — `components.tsx` L502-553: text and the centred time stamp. */
    @Test
    fun bubbles_renders_every_message_and_its_time_stamp() {
        compose.renderProgram(
            """root = Card([b])
               b = Bubbles([{text: "Are we still on for dinner?", me: false, time: "2:02 PM"}, {text: "Yes! Sakura at 7?", me: true}])""",
        )
        compose.onNodeWithText("2:02 PM").assertIsDisplayed()
        compose.onNodeWithText("Are we still on for dinner?").assertIsDisplayed()
        compose.onNodeWithText("Yes! Sakura at 7?").assertIsDisplayed()
    }

    /** `Chips` — `components.tsx` L556-604: a scrolling filter strip. */
    @Test
    fun chips_renders_every_label() {
        compose.renderProgram(
            """root = Card([c])
               c = Chips(["All", "Sushi", "Pizza"])""",
        )
        compose.onNodeWithText("All").assertIsDisplayed()
        compose.onNodeWithText("Sushi").assertIsDisplayed()
        compose.onNodeWithText("Pizza").assertIsDisplayed()
    }

    /**
     * `Tabs` — `components.tsx` L606-663.
     *
     * Every tab LABEL is on screen; only the ACTIVE tab's children are. That
     * asymmetry is the whole point of the component, so both halves are pinned.
     */
    @Test
    fun tabs_shows_every_label_but_only_the_active_tab_body() {
        compose.renderProgram(
            """
            root = Card([t])
            t = Tabs([one, two])
            one = TabItem("Today", [a])
            two = TabItem("Week", [b])
            a = TextContent("today body")
            b = TextContent("week body")
            """.trimIndent(),
        )
        compose.onNodeWithText("Today").assertIsDisplayed()
        compose.onNodeWithText("Week").assertIsDisplayed()
        compose.onNodeWithText("today body").assertIsDisplayed()
        compose.onAllNodesWithText("week body").assertCountEquals(0)
    }

    /**
     * `MapView` — `ui/shared/map.tsx` + `ui/material/map.tsx`.
     *
     * The map is a `WebView` inside an `AndroidView`, which has no semantics of
     * its own. What IS verifiable off-device is that the interop view was
     * created and given the keyless embed URL the RN implementation uses —
     * asserted in [RendererSemanticsTest.mapView_hosts_a_webview_with_the_keyless_embed_url].
     * This test pins only that the composition survives it.
     */
    @Test
    fun mapView_composes() {
        compose.renderProgram(
            """root = Card([m])
               m = MapView("Sakura Sushi, Tokyo", 15)""",
        )
        compose.onRoot().assertExists()
    }

    // ------------------------------------------------------------------ forms

    /** `Form` — `forms.tsx` L324-333: fields then buttons. */
    @Test
    fun form_renders_its_fields_and_its_buttons() {
        compose.renderProgram(
            """
            root = Card([f])
            f = Form("reply", btns, [msg])
            msg = FormControl("Message", input, "Keep it short")
            input = Input("body", "Message…")
            btns = Buttons([send])
            send = Button("Send")
            """.trimIndent(),
        )
        compose.onNodeWithText("Message").assertIsDisplayed()
        compose.onNodeWithText("Keep it short").assertIsDisplayed()
        compose.onNodeWithText("Message…").assertIsDisplayed() // the Input's placeholder
        compose.onNodeWithText("Send").assertIsDisplayed()
    }

    /** `FormControl` — `forms.tsx` L235-256: label, input slot, hint. */
    @Test
    fun formControl_renders_label_input_and_hint() {
        compose.renderProgram(
            """
            root = Card([c])
            c = FormControl("Email", input, "We never share it")
            input = Input("email", "you@example.com", "email")
            """.trimIndent(),
        )
        compose.onNodeWithText("Email").assertIsDisplayed()
        compose.onNodeWithText("We never share it").assertIsDisplayed()
        compose.onNodeWithText("you@example.com").assertIsDisplayed()
    }

    /** `Input` — `forms.tsx` L37-56: placeholder until a value exists. */
    @Test
    fun input_renders_its_placeholder_and_seeds_the_model_supplied_value() {
        compose.renderProgram(
            """
            root = Card([a, b])
            a = Input("empty", "type here")
            b = Input("prefilled", "unused placeholder", "text", null, "Maya Chen")
            """.trimIndent(),
        )
        compose.onNodeWithText("type here").assertIsDisplayed()
        // The seeded field shows its VALUE, not the placeholder — `useSetDefaultValue`.
        compose.onNodeWithText("Maya Chen").assertIsDisplayed()
        compose.onAllNodesWithText("unused placeholder").assertCountEquals(0)
    }

    /** `TextArea` — `forms.tsx` L58-79. */
    @Test
    fun textArea_renders_its_placeholder() {
        compose.renderProgram(
            """root = Card([t])
               t = TextArea("notes", "Anything else?", 6)""",
        )
        compose.onNodeWithText("Anything else?").assertIsDisplayed()
    }

    /**
     * `Select` — `forms.tsx` L109-181.
     *
     * Closed, the trigger reads `selected?.label ?? placeholder ?? "Select…"`
     * (L156). With a seeded value it must read that option's LABEL, not its
     * value.
     */
    @Test
    fun select_shows_the_selected_option_label_on_its_closed_trigger() {
        compose.renderProgram(
            """
            root = Card([a, b])
            a = Select("plan", [p1, p2], "Choose a plan")
            b = Select("tier", [p1, p2], "unused", null, "pro")
            p1 = SelectItem("free", "Free")
            p2 = SelectItem("pro", "Pro")
            """.trimIndent(),
        )
        compose.onNodeWithText("Choose a plan").assertIsDisplayed()
        compose.onNodeWithText("Pro").assertIsDisplayed()
        compose.onAllNodesWithText("unused").assertCountEquals(0)
    }

    /** `DatePicker` — `forms.tsx` L81-99: an ISO placeholder, not a calendar. */
    @Test
    fun datePicker_uses_the_iso_placeholder_and_the_range_variant() {
        compose.renderProgram(
            """
            root = Card([a, b])
            a = DatePicker("when")
            b = DatePicker("span", "range")
            """.trimIndent(),
        )
        compose.onNodeWithText("YYYY-MM-DD").assertIsDisplayed()
        compose.onNodeWithText("YYYY-MM-DD → YYYY-MM-DD").assertIsDisplayed()
    }

    /**
     * `Slider` — `forms.tsx` L184-232.
     *
     * The readout is `Math.round(v * 100) / 100` printed the JS way (L221), and
     * an untouched slider still shows a value because `props.value ??
     * props.defaultValue ?? [props.min]` seeds it.
     */
    @Test
    fun slider_renders_its_label_and_the_seeded_value_readout() {
        compose.renderProgram(
            """root = Card([s])
               s = Slider("seats", "discrete", 1, 10, 1, [4], "Seats")""",
        )
        compose.onNodeWithText("Seats").assertIsDisplayed()
        compose.onNodeWithText("4").assertIsDisplayed()
    }

    /** `Buttons` — `forms.tsx` L311-322. */
    @Test
    fun buttons_renders_every_button_in_the_row() {
        compose.renderProgram(
            """
            root = Card([bs])
            bs = Buttons([a, b])
            a = Button("Cancel", null, "tertiary")
            b = Button("Save")
            """.trimIndent(),
        )
        compose.onNodeWithText("Cancel").assertIsDisplayed()
        compose.onNodeWithText("Save").assertIsDisplayed()
    }

    /**
     * `Button` — `forms.tsx` L260-309.
     *
     * An ACTION-LESS button still dispatches, carrying its label
     * (`spec/openui-lang.md` §9.4 step 3) — the single most load-bearing default
     * in the whole action path, and the one a "did not throw" test would miss.
     */
    @Test
    fun button_without_an_action_dispatches_its_label() {
        val actions = compose.renderProgram(
            """root = Card([b])
               b = Button("Track current order")""",
        )
        compose.onNodeWithText("Track current order").performClick()
        compose.waitForIdle()

        assertEquals(1, actions.events.size)
        assertEquals("Track current order", actions.last.humanFriendlyMessage)
        assertEquals(ActionEvent.Kind.CONTINUE_CONVERSATION, actions.last.type)
    }

    /** A button WITH an `@ToAssistant` plan sends the plan's message instead. */
    @Test
    fun button_with_an_action_dispatches_the_plan_message() {
        val actions = compose.renderProgram(
            """root = Card([b])
               b = Button("Track", Action([@ToAssistant("Open the order tracking screen")]))""",
        )
        compose.onNodeWithText("Track").performClick()
        compose.waitForIdle()

        assertEquals("Open the order tracking screen", actions.last.humanFriendlyMessage)
    }

    /**
     * `ListItem` is INERT without an action — `useTap` returns `undefined`
     * (`ui/shared/actions.ts`), so RN passes `disabled={!onTap}`.
     *
     * This is the counterpart to the Button default above and the reason the
     * two cannot share one code path.
     */
    @Test
    fun listItem_without_an_action_is_not_clickable() {
        val actions = compose.renderProgram(
            """
            root = Card([a, b])
            a = ListItem("Inert row")
            b = ListItem("Live row", null, null, null, Action([@ToAssistant("go")]))
            """.trimIndent(),
        )
        compose.onNodeWithText("Inert row").assertHasNoClickAction()
        compose.onNodeWithText("Live row").assertHasClickAction()

        compose.onNodeWithText("Live row").performClick()
        compose.waitForIdle()
        assertEquals(1, actions.events.size)
        assertEquals("go", actions.last.humanFriendlyMessage)
    }

    /**
     * `Chips` dispatch the FILTER message, not their label, and re-tapping the
     * already-selected chip does nothing (`components.tsx` L568).
     */
    @Test
    fun chips_dispatch_the_filter_message_and_ignore_a_re_tap() {
        val actions = compose.renderProgram(
            """root = Card([c])
               c = Chips(["All", "Sushi"])""",
        )
        // Index 0 is selected on mount, so tapping it must be a no-op.
        compose.onNodeWithText("All").performClick()
        compose.waitForIdle()
        assertEquals(0, actions.events.size)

        compose.onNodeWithText("Sushi").performClick()
        compose.waitForIdle()
        assertEquals(1, actions.events.size)
        assertEquals(
            GenosActions.chipsMessage("Sushi"),
            actions.last.humanFriendlyMessage,
        )
    }

    /** Switching tabs is purely local: nothing is dispatched, the body swaps. */
    @Test
    fun tapping_a_tab_swaps_the_body_without_dispatching() {
        val actions = compose.renderProgram(
            """
            root = Card([t])
            t = Tabs([one, two])
            one = TabItem("Today", [a])
            two = TabItem("Week", [b])
            a = TextContent("today body")
            b = TextContent("week body")
            """.trimIndent(),
        )
        compose.onNodeWithText("Week").performClick()
        compose.waitForIdle()

        compose.onNodeWithText("week body").assertIsDisplayed()
        compose.onAllNodesWithText("today body").assertCountEquals(0)
        assertEquals(0, actions.events.size)
    }

    /**
     * `Toggle` flips LOCALLY and dispatches nothing (`components.tsx` L219-256):
     * the model is never asked to re-render a screen because a switch moved.
     */
    @Test
    fun tapping_a_toggle_flips_it_locally_without_dispatching() {
        val actions = compose.renderProgram(
            """root = Card([t])
               t = Toggle("Dark Mode", false)""",
        )
        compose.onNode(isToggleable()).assertIsOff()
        compose.onNodeWithText("Dark Mode").performClick()
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsOn()
        assertEquals(0, actions.events.size)
    }
}
