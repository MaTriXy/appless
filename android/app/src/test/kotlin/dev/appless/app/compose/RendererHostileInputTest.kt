package dev.appless.app.compose

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import dev.appless.app.render.material.MaterialRenderers
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropObject
import dev.appless.openuilang.PropValue
import dev.appless.uicore.RenderableComponent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The renderers under HOSTILE input — the half of the contract a happy-path
 * suite never touches.
 *
 * Why this matters more than it looks: the screen is re-parsed on every
 * streamed chunk (`spec/openui-lang.md` §10), so EVERY renderer is composed
 * dozens of times against a half-written program. A `CardHeader` with no title
 * yet, a `ListBlock` whose `items` is still the string the model was midway
 * through typing, a `Series` that arrived before its `labels` — all of these
 * are NORMAL, not pathological. The RN renderers survive them because JSX
 * coerces (`{props.title}` renders nothing for `undefined` and nothing for a
 * boolean) and because every list-shaped prop is read through
 * `(x ?? []).filter(Boolean)`.
 *
 * Each test asserts the DEGRADATION, not merely the absence of a crash: what
 * the RN renderer would put on screen for that input is what must be here.
 *
 * Nodes are built directly rather than parsed, because a hand-written program
 * cannot express "the `on` prop is a string" — the point is to hand the
 * renderer the exact shape a partial parse produces.
 */
@RunWith(RobolectricTestRunner::class)
class RendererHostileInputTest {

    @get:Rule
    val compose = createComposeRule()

    private val host by lazy { NodeHost(compose) }

    private fun node(component: String, vararg props: Pair<String, PropValue>) =
        ElementNode(component = component, props = props.toMap())

    private fun arr(vararg items: PropValue) = PropValue.Arr(items.toList())

    private fun obj(vararg pairs: Pair<String, PropValue>) =
        PropValue.Obj(PropObject(pairs.toList()))

    private fun element(node: ElementNode) = PropValue.Element(node)

    // ------------------------------------------------------- the blanket sweep

    /**
     * EVERY registered renderer, composed with NO props at all.
     *
     * This is the shape the very first streamed chunk produces: the parser has
     * seen `x = ListItem(` and nothing else. React renders such a component
     * without throwing (missing props are `undefined`, and `{undefined}` is
     * legal in JSX); a Compose renderer doing `node["title"]!!` or `.first()`
     * would blow up here instead.
     */
    @Test
    fun every_renderer_composes_with_no_props_at_all() {
        val failures = sweep { component -> ElementNode(component = component.name) }
        assertEquals("renderers that threw on an empty prop set:\n${failures.joinToString("\n")}", 0, failures.size)

        // Guard the guard: were the registry ever to empty, the sweep above
        // would vacuously pass.
        assertEquals(30, RenderableComponent.ALL.size)
        assertEquals(30, MaterialRenderers.table.size)
    }

    /**
     * EVERY renderer again, with every list-shaped prop holding garbage:
     * a string where an array belongs, a number, a boolean, `null`, and an
     * array of falsy entries.
     *
     * `(props.items ?? []).filter(Boolean)` degrades all of these to an empty
     * list in RN; `PropValue.truthyItems()` is the port of that rule, and this
     * proves no renderer bypasses it.
     */
    @Test
    fun every_renderer_composes_when_its_list_props_are_not_lists() {
        val garbage = listOf(
            PropValue.Str("not an array"),
            PropValue.Num(42.0),
            PropValue.Bool(true),
            PropValue.Null,
            arr(PropValue.Null, PropValue.Bool(false), PropValue.Str("")),
        )
        val listy = listOf(
            "items", "rows", "series", "labels", "values", "buttons", "fields",
            "messages", "images", "defaultValue", "input", "action",
        )
        val failures = mutableListOf<String>()
        for (value in garbage) {
            failures += sweep(" with $value") { component ->
                ElementNode(
                    component = component.name,
                    props = listy.associateWith { value },
                    children = value,
                )
            }
        }
        assertEquals("renderers that threw on non-list list props:\n${failures.joinToString("\n")}", 0, failures.size)
    }

    /**
     * EVERY renderer with its scalar props holding the WRONG primitive type.
     *
     * The RN reference is protected by JS coercion: `{props.title}` stringifies
     * a number and renders NOTHING for a boolean (React skips booleans). The
     * port's `reactText()` is that rule and `stringOrNull()`/`numberOrNull()`
     * are the `typeof x === "…"` guards. A renderer that casts fails here.
     */
    @Test
    fun every_renderer_composes_when_its_scalar_props_have_the_wrong_type() {
        val wrong = listOf(
            PropValue.Bool(true),
            PropValue.Num(Double.NaN),
            PropValue.Num(Double.POSITIVE_INFINITY),
            obj(),
            arr(PropValue.Str("x")),
        )
        val scalars = listOf(
            "title", "subtitle", "text", "label", "value", "sublabel", "header",
            "caption", "src", "placeName", "zoom", "name", "placeholder", "type",
            "variant", "style", "size", "direction", "mode", "on", "icon",
            "leading", "trailing", "min", "max", "step", "rows", "hint",
            "xLabel", "yLabel", "appearance", "description",
        )
        val failures = mutableListOf<String>()
        for (value in wrong) {
            failures += sweep(" with $value") { component ->
                ElementNode(component = component.name, props = scalars.associateWith { value })
            }
        }
        assertEquals(
            "renderers that threw on wrong-typed scalar props:\n${failures.joinToString("\n")}",
            0,
            failures.size,
        )
    }

    /** Compose one node per contract component; collect what threw. */
    private fun sweep(suffix: String = "", build: (RenderableComponent) -> ElementNode): List<String> {
        val failures = mutableListOf<String>()
        for (component in RenderableComponent.ALL.sortedBy { it.name }) {
            try {
                host.show(build(component))
            } catch (t: Throwable) {
                failures += "${component.name}$suffix: ${t::class.java.name}: ${t.message}"
            }
        }
        return failures
    }

    // --------------------------------------------------- specific degradations

    /**
     * `{props.title}` where title is a BOOLEAN renders nothing — React skips
     * booleans. A port using `toString()` would print "true" on the screen.
     */
    @Test
    fun a_boolean_text_prop_renders_nothing_rather_than_the_word_true() {
        host.show(
            node(
                "CardHeader",
                "title" to PropValue.Bool(true),
                "subtitle" to PropValue.Bool(false),
            ),
        )
        assertEquals(listOf(""), compose.renderedText())
    }

    /** `{props.value}` where value is a NUMBER stringifies the JS way. */
    @Test
    fun a_numeric_text_prop_stringifies_the_javascript_way() {
        // JS `String(125)` is "125", NOT Kotlin's "125.0".
        host.show(node("HeroStat", "value" to PropValue.Num(125.0)))
        assertEquals(listOf("125"), compose.renderedText())
    }

    /** `String(NaN)` is "NaN" and `String(Infinity)` is "Infinity", not "null". */
    @Test
    fun non_finite_numbers_spell_themselves_out_like_javascript_String() {
        host.show(node("HeroStat", "value" to PropValue.Num(Double.NaN)))
        assertEquals(listOf("NaN"), compose.renderedText())

        host.show(node("HeroStat", "value" to PropValue.Num(Double.NEGATIVE_INFINITY)))
        assertEquals(listOf("-Infinity"), compose.renderedText())
    }

    /**
     * `CardHeader` with an EMPTY-STRING subtitle draws no overline:
     * `!!props.subtitle` is JS truthiness and `""` is falsy
     * (`components.tsx` L62).
     */
    @Test
    fun an_empty_string_subtitle_is_falsy_and_draws_no_overline() {
        host.show(
            node(
                "CardHeader",
                "title" to PropValue.Str("Only the title"),
                "subtitle" to PropValue.Str(""),
            ),
        )
        // Exactly ONE text node: the title. A truthiness check that used
        // `!= null` would produce two.
        assertEquals(listOf("Only the title"), compose.renderedText())
    }

    /** The mirror image: a NON-empty subtitle does produce the overline. */
    @Test
    fun a_non_empty_subtitle_does_draw_the_overline() {
        host.show(
            node(
                "CardHeader",
                "title" to PropValue.Str("Title"),
                "subtitle" to PropValue.Str("OVERLINE"),
            ),
        )
        assertEquals(listOf("OVERLINE", "Title"), compose.renderedText())
    }

    /**
     * `.filter(Boolean)` — a list whose entries are `null`/`false`/`""` renders
     * NO rows, not empty ones (`components.tsx` L282).
     */
    @Test
    fun falsy_list_entries_are_dropped_not_rendered_as_blanks() {
        host.show(
            node(
                "ListBlock",
                "header" to PropValue.Str("GROUP"),
                "items" to arr(
                    PropValue.Null,
                    PropValue.Bool(false),
                    PropValue.Str(""),
                    element(node("ListItem", "title" to PropValue.Str("real row"))),
                ),
            ),
        )
        assertEquals(listOf("GROUP", "real row"), compose.renderedText())
    }

    /** An EMPTY `Card` composes to a Card with nothing in it — not a crash. */
    @Test
    fun an_empty_card_composes_to_an_empty_column() {
        host.show(ElementNode("Card", children = arr()))
        assertEquals(emptyList<String>(), compose.renderedText())
    }

    /**
     * A bare string in a child slot is DROPPED.
     *
     * RN throws here ("Text strings must be rendered within a <Text>");
     * dropping is the port's deliberate degradation for a partial stream
     * (`RenderNode`'s `else -> Unit` branch). It must be silent AND must not
     * leak the string onto the screen.
     */
    @Test
    fun a_bare_string_child_is_dropped_rather_than_rendered() {
        host.show(
            ElementNode(
                "Card",
                children = arr(
                    PropValue.Str("loose text"),
                    element(node("TextContent", "text" to PropValue.Str("kept"))),
                ),
            ),
        )
        assertEquals(listOf("kept"), compose.renderedText())
    }

    /**
     * An unknown component resolves to nothing — `RenderElement` returns early,
     * matching `component: () => null` for anything outside the contract.
     */
    @Test
    fun an_unknown_component_renders_nothing() {
        host.show(
            ElementNode(
                "Card",
                children = arr(
                    element(node("Fabricated", "text" to PropValue.Str("should not appear"))),
                    element(node("TextContent", "text" to PropValue.Str("kept"))),
                ),
            ),
        )
        assertEquals(listOf("kept"), compose.renderedText())
    }

    /**
     * The three STRUCTURAL placeholders (`Series`, `SelectItem`, `TabItem`) are
     * consumed by their parents and render nothing on their own —
     * `ui/contract.tsx` gives all three `component: () => null`.
     *
     * A port that registered renderers for them would draw a stray label under
     * every chart and inside every `Select`.
     */
    @Test
    fun structural_placeholders_render_nothing_when_reached_directly() {
        for (name in listOf("Series", "SelectItem", "TabItem")) {
            host.show(
                ElementNode(
                    "Card",
                    children = arr(
                        element(
                            node(
                                name,
                                "category" to PropValue.Str("stray-$name"),
                                "label" to PropValue.Str("stray-$name"),
                                "value" to PropValue.Str("stray-$name"),
                            ),
                        ),
                    ),
                ),
            )
            assertEquals("$name must render nothing", emptyList<String>(), compose.renderedText())
        }
    }

    /**
     * A chart with NO series renders nothing at all —
     * `if (!labels.length || !series.length) return null` (`charts.tsx` L201),
     * ported as `ChartData.hasCartesianData`.
     *
     * The assertion has teeth because a naive port emits the axis titles BEFORE
     * that guard: without the early return, "Quarter" would be on screen.
     */
    @Test
    fun a_chart_with_no_series_renders_nothing_including_its_axis_titles() {
        for (chart in listOf("BarChart", "LineChart", "AreaChart", "HorizontalBarChart")) {
            host.show(
                node(
                    chart,
                    "labels" to arr(PropValue.Str("Q1"), PropValue.Str("Q2")),
                    "series" to arr(),
                    "xLabel" to PropValue.Str("Quarter"),
                    "yLabel" to PropValue.Str("Revenue"),
                ),
            )
            assertEquals("$chart with no series", emptyList<String>(), compose.renderedText())
        }
    }

    /** Symmetrically: series present but NO labels → nothing. */
    @Test
    fun a_chart_with_series_but_no_labels_renders_nothing() {
        host.show(
            node(
                "BarChart",
                "labels" to arr(),
                "series" to arr(
                    element(
                        node(
                            "Series",
                            "category" to PropValue.Str("Direct"),
                            "values" to arr(PropValue.Num(1.0)),
                        ),
                    ),
                ),
                "xLabel" to PropValue.Str("Quarter"),
            ),
        )
        assertEquals(emptyList<String>(), compose.renderedText())
    }

    /**
     * A pie whose values sum to ZERO renders nothing — `if (!total) return null`
     * (`charts.tsx` L464). Its legend goes with it.
     */
    @Test
    fun a_pie_chart_with_a_zero_total_renders_nothing_at_all() {
        host.show(
            node(
                "PieChart",
                "labels" to arr(PropValue.Str("Rent"), PropValue.Str("Food")),
                "values" to arr(PropValue.Num(0.0), PropValue.Num(0.0)),
            ),
        )
        assertEquals(emptyList<String>(), compose.renderedText())
    }

    /**
     * The negatives clamp: RN's chart code has no notion of a negative bar, so
     * `ChartData` clamps them. A pie of negatives therefore has no total and
     * draws nothing, rather than sweeping backwards around the circle.
     */
    @Test
    fun a_pie_chart_of_negative_values_draws_nothing() {
        host.show(
            node(
                "PieChart",
                "labels" to arr(PropValue.Str("Loss")),
                "values" to arr(PropValue.Num(-5.0)),
            ),
        )
        assertEquals(emptyList<String>(), compose.renderedText())
    }

    /** Zero tabs must render zero bodies rather than index into an empty list. */
    @Test
    fun tabs_with_no_items_renders_no_body() {
        host.show(node("Tabs", "items" to arr()))
        assertEquals(emptyList<String>(), compose.renderedText())
    }

    /**
     * A `Tabs` item with no label falls back to `Tab ${i + 1}`
     * (`it.props?.label ?? …`, `components.tsx` L645) — including an item that
     * is not an element at all.
     */
    @Test
    fun a_tab_without_a_label_falls_back_to_its_ordinal() {
        host.show(
            node(
                "Tabs",
                "items" to arr(PropValue.Str("no props here"), element(ElementNode("TabItem"))),
            ),
        )
        compose.onNodeWithText("Tab 1").assertIsDisplayed()
        compose.onNodeWithText("Tab 2").assertIsDisplayed()
    }

    /**
     * `Select` with no items still shows its trigger, reading
     * `selected?.label ?? props.placeholder ?? "Select…"` (`forms.tsx` L156).
     */
    @Test
    fun a_select_with_no_items_still_shows_its_default_trigger_label() {
        host.show(node("Select", "name" to PropValue.Str("plan")))
        assertEquals(listOf("Select…"), compose.renderedText())
    }

    /**
     * `Slider` with `min > max` and a zero `step` must not divide by zero or
     * build an inverted `valueRange`. The readout still prints, seeded from
     * `[props.min]` (`forms.tsx` L191-195).
     */
    @Test
    fun a_slider_with_an_inverted_range_and_a_zero_step_still_composes() {
        host.show(
            node(
                "Slider",
                "name" to PropValue.Str("broken"),
                "variant" to PropValue.Str("discrete"),
                "min" to PropValue.Num(10.0),
                "max" to PropValue.Num(1.0),
                "step" to PropValue.Num(0.0),
                "label" to PropValue.Str("Inverted"),
            ),
        )
        assertEquals(listOf("Inverted", "10"), compose.renderedText())
    }

    /**
     * Deeply nested children: 40 `Card`s inside each other with a marker at the
     * bottom.
     *
     * `RenderNode` recurses, so a stream that opens more containers than it
     * closes is a stack-depth question — and the depth where it breaks must be
     * far beyond anything a real screen contains.
     */
    @Test
    fun deeply_nested_children_still_reach_the_leaf() {
        var value: PropValue = element(node("TextContent", "text" to PropValue.Str("bottom")))
        repeat(40) { value = element(ElementNode("Card", children = arr(value))) }
        host.show((value as PropValue.Element).node)
        assertEquals(listOf("bottom"), compose.renderedText())
    }

    /**
     * A `PhotoGrid` entry with no usable `src` is dropped
     * (`.filter((im) => im?.src)`, `components.tsx` L484) — including one whose
     * `src` is the empty string, which is falsy in JS.
     */
    @Test
    fun photoGrid_drops_entries_without_a_usable_src() {
        host.show(
            node(
                "PhotoGrid",
                "images" to arr(
                    PropValue.Null,
                    obj(),
                    obj("src" to PropValue.Str("")),
                    obj("src" to PropValue.Str("/api/img?q=a&seed=1&w=200&h=200")),
                ),
            ),
        )
        // Cell count is not text, so it is asserted by layout in
        // RendererSemanticsTest; here the point is that the falsy entries do
        // not crash the `.mapNotNull` chain.
        assertEquals(emptyList<String>(), compose.renderedText())
    }

    /**
     * `Bubbles` drops messages with no `text` (`.filter((m) => m?.text)`,
     * `components.tsx` L506) — and the dropped message's `time` stamp goes with
     * it, because the stamp is rendered inside the loop body.
     */
    @Test
    fun bubbles_drops_a_message_with_no_text_and_its_time_stamp() {
        host.show(
            node(
                "Bubbles",
                "messages" to arr(
                    obj("time" to PropValue.Str("9:99 XM")),
                    obj(
                        "text" to PropValue.Str("kept message"),
                        "time" to PropValue.Str("2:02 PM"),
                    ),
                ),
            ),
        )
        assertEquals(listOf("2:02 PM", "kept message"), compose.renderedText())
    }

    /**
     * A truncated stream: `root = Card([a, b])` where only `a` has arrived.
     *
     * The parser leaves `b` unresolved; the screen must show what it HAS rather
     * than nothing, because that progressive reveal is the whole streaming UX
     * (`spec/openui-lang.md` §10).
     */
    @Test
    fun a_half_streamed_program_renders_the_part_that_arrived() {
        val root = Harness.parseScreen(
            """
            root = Card([a, b])
            a = CardHeader("Arrived")
            """.trimIndent(),
        )
        requireNotNull(root) { "a partial program must still yield a root" }
        host.show(root)
        compose.onNodeWithText("Arrived").assertIsDisplayed()
    }

    /**
     * The stream, replayed one character at a time.
     *
     * This is the single most representative hostile input there is: it is
     * literally what the app does ~20 times a second. Every prefix must parse
     * to something composable, and the final frame must be the finished screen.
     */
    @Test
    fun every_prefix_of_a_streamed_program_composes() {
        val program = """
            root = Card([h, list, cta])
            h = CardHeader("Wallet", "Personal")
            list = ListBlock([r1], "RECENT")
            r1 = ListItem("Coffee", "Today", "local_cafe", "-6.40")
            cta = Buttons([b])
            b = Button("See all", Action([@ToAssistant("show all")]))
        """.trimIndent()

        for (end in 0..program.length) {
            val root = Harness.parseScreen(program.substring(0, end))
            host.show(root)
        }

        // The last frame is the whole screen — proving the sweep really did
        // reach the end rather than silently rendering nothing throughout.
        compose.onNodeWithText("Wallet").assertIsDisplayed()
        compose.onNodeWithText("Coffee").assertIsDisplayed()
        compose.onNodeWithText("See all").assertIsDisplayed()
    }

    /** A handful of pathological fragments the parser may reject outright. */
    @Test
    fun a_program_cut_off_mid_token_composes_without_throwing() {
        val sources = listOf(
            "root = Card([",
            "root = Card([a])\na = CardHeader(\"Half a titl",
            "root = Card([a])\na = ListBlock([r1], \"HEAD\")\nr1 = ListItem(",
            "root = Ca",
            "root = Card([a])\na = Card([b])\nb = Card([a])", // a reference cycle
            "",
        )
        for (source in sources) {
            host.show(Harness.parseScreen(source))
        }
        // The composition survived every fragment and is still usable.
        host.show(node("TextContent", "text" to PropValue.Str("still alive")))
        compose.onAllNodesWithText("still alive").assertCountEquals(1)
        assertTrue(compose.renderedText().contains("still alive"))
    }
}
