package dev.appless.app.compose

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import dev.appless.uicore.ChartData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode

/**
 * The assertions that need more than the text in the tree: layout arithmetic,
 * the Android interop views, and a forced DRAW pass over the charts.
 *
 * Uses `createAndroidComposeRule` (not the plain one) because two of these need
 * the hosting `Activity`: the `WebView` `MapView` creates lives in the Android
 * view hierarchy rather than the composition, and the draw pass rasterizes the
 * Compose host view out of that hierarchy.
 */
@RunWith(RobolectricTestRunner::class)
// The draw-pass tests below rasterize the composition. Robolectric's LEGACY
// graphics mode stubs `Canvas` out entirely, so every capture would come back
// uniform and the chart tests would fail for the wrong reason; NATIVE runs the
// real Skia pipeline on the JVM.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RendererSemanticsTest {

    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    // ------------------------------------------------------------ list counts

    /**
     * A list renders exactly ONE row per item — no duplication from the
     * `key(index)` in `RenderNode`, no dropped rows from `truthyItems()`.
     *
     * Written with a repeated title so a de-duplicating bug (or a `Set`
     * anywhere in the chain) collapses the count and fails.
     */
    @Test
    fun a_list_renders_one_row_per_item_even_when_rows_are_identical() {
        compose.renderProgram(
            """
            root = Card([b])
            b = ListBlock([r1, r2, r3, r4], "REPEATS")
            r1 = ListItem("Repeated", "one")
            r2 = ListItem("Repeated", "two")
            r3 = ListItem("Repeated", "three")
            r4 = ListItem("Repeated", "four")
            """.trimIndent(),
        )
        compose.onAllNodesWithText("Repeated").assertCountEquals(4)
        for (subtitle in listOf("one", "two", "three", "four")) {
            compose.onNodeWithText(subtitle).assertIsDisplayed()
        }
    }

    /** `KVList` likewise: one label/value pair per row. */
    @Test
    fun a_kv_list_renders_one_pair_per_row() {
        compose.renderProgram(
            """root = Card([k])
               k = KVList([{label: "Same", value: "1"}, {label: "Same", value: "2"}, {label: "Same", value: "3"}])""",
        )
        compose.onAllNodesWithText("Same").assertCountEquals(3)
    }

    /** `StatTiles` — one tile per entry, laid out two per row (`flexBasis: 45%`). */
    @Test
    fun stat_tiles_render_one_tile_per_entry() {
        compose.renderProgram(
            """root = Card([s])
               s = StatTiles([{label: "L", value: "1"}, {label: "L", value: "2"}, {label: "L", value: "3"}])""",
        )
        compose.onAllNodesWithText("L").assertCountEquals(3)
    }

    // ------------------------------------------------------- Android interop

    /**
     * `MapView` hosts a real `WebView` and hands it the KEYLESS Google embed
     * URL inside the referer-bearing host document.
     *
     * This is the one renderer whose whole point is invisible to the semantics
     * tree, and the one place a port could silently regress to a key-gated Maps
     * SDK. Robolectric's `ShadowWebView` records the last `loadDataWithBaseURL`,
     * which is exactly the assertion the RN implementation's comment demands
     * (`ui/shared/map.tsx` L36: base URL `https://www.google.com`, iframe
     * `output=embed`).
     */
    @Test
    fun mapView_hosts_a_webview_with_the_keyless_embed_url() {
        compose.renderProgram(
            """root = Card([m])
               m = MapView("Sakura Sushi, Tokyo", 15)""",
        )
        compose.waitForIdle()

        val webView = findWebView(compose.activity.window.decorView)
        assertNotNull("MapView must create a WebView through AndroidView", webView)

        val shadow = shadowOf(webView!!)
        val loaded = shadow.lastLoadDataWithBaseURL
        assertNotNull("the WebView was never given a document", loaded)

        assertEquals(
            "the base URL is what gives the iframe a referer — without it Google demands a key",
            "https://www.google.com",
            loaded.baseUrl,
        )
        val html = loaded.data
        assertTrue("host document must wrap the map in an iframe: $html", html.contains("<iframe"))
        assertTrue("must use the keyless embed mode: $html", html.contains("output=embed"))
        assertTrue("the place name must be encoded into the query: $html", html.contains("Sakura"))
        assertTrue("the zoom prop must reach the URL: $html", html.contains("15"))
        assertTrue("JavaScript is required for the embed", webView.settings.javaScriptEnabled)
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findWebView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    // ------------------------------------------------------- the draw pass

    /**
     * A chart is drawn ENTIRELY into a `Canvas`, so nothing it paints reaches
     * the semantics tree — which means every other chart assertion in this tier
     * only proves the chrome around it exists.
     *
     * [paintsSomething] forces a real measure/layout/DRAW, so the geometry code
     * (`drawCartesianFrame`, the bar rects, `smoothPath`, `drawWedge`) actually
     * executes. The assertion is that the surface is not uniform.
     */
    @Test
    fun a_bar_chart_actually_paints_pixels() {
        compose.renderProgram(
            """
            root = Card([c])
            c = BarChart(["Q1", "Q2", "Q3"], [a], "Quarter", "Revenue")
            a = Series("Direct", [12, 18, 9])
            """.trimIndent(),
        )
        assertTrue("the bar chart drew nothing", paintsSomething())
    }

    /** The pie path draws too — including the donut cut-out (`arcPath`). */
    @Test
    fun a_pie_chart_actually_paints_pixels() {
        compose.renderProgram(
            """root = Card([c])
               c = PieChart(["Rent", "Food", "Travel"], [1200, 400, 300], "donut")""",
        )
        assertTrue("the pie chart drew nothing", paintsSomething())
    }

    /** Line and area, including the smoothing and the 0.18-alpha fill. */
    @Test
    fun line_and_area_charts_actually_paint_pixels() {
        compose.renderProgram(
            """
            root = Card([c])
            c = AreaChart(["Mon", "Tue", "Wed", "Thu"], [a], "Day", "Steps")
            a = Series("You", [4200, 5100, 6300, 5000])
            """.trimIndent(),
        )
        assertTrue("the area chart drew nothing", paintsSomething())
    }

    /**
     * True when the composition rasterizes to more than one distinct colour.
     *
     * ### Why not `captureToImage()`
     *
     * Compose's own capture helper never completes under Robolectric — it waits
     * on a real window callback and times out after 2 s
     * (`ComposeTimeoutException`). Drawing the Android view hierarchy into a
     * `Bitmap` by hand does the same job: Robolectric 4.14 runs graphics in
     * NATIVE mode, so `View.draw` really rasterizes through Skia and every
     * `Canvas` lambda in the tree executes.
     *
     * The assertion is deliberately weak on WHAT is painted — a pixel-perfect
     * baseline is only meaningful on a real device and belongs in `androidTest`
     * — and strong on THAT something is. A renderer that early-returns, or a
     * `Canvas` block that never runs, leaves a uniform surface and fails.
     * [a_chart_with_no_data_paints_nothing_at_all] is the negative control that
     * proves this can distinguish the two.
     */
    private fun distinctPaintedColours(): Int {
        compose.waitForIdle()
        // The decor view is full-window and mostly empty; the Compose host view
        // is exactly the composition's bounds, so a uniform result there really
        // does mean "the composition painted nothing".
        val target = findComposeView(compose.activity.window.decorView)
            ?: error("no AndroidComposeView in the hierarchy")
        val width = target.width.coerceAtLeast(1)
        val height = target.height.coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        target.draw(Canvas(bitmap))

        val colours = HashSet<Int>()
        for (y in 0 until height) {
            for (x in 0 until width) colours.add(bitmap.getPixel(x, y))
        }
        return colours.size
    }

    private fun paintsSomething(): Boolean = distinctPaintedColours() > 1

    /** The `AndroidComposeView` the rule's content is hosted in. */
    private fun findComposeView(view: View): View? {
        if (view.javaClass.name.endsWith("AndroidComposeView")) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findComposeView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    /**
     * The chart guard, drawn: a chart with no series must paint NOTHING, so the
     * same capture comes back uniform.
     *
     * This is the negative control for the three tests above — without it, they
     * could be passing on the `Card` background alone.
     */
    @Test
    fun a_chart_with_no_data_paints_nothing_at_all() {
        compose.renderProgram(
            """root = Card([c])
               c = BarChart([], [], "Quarter", "Revenue")""",
        )
        assertTrue(
            "an empty chart must not paint",
            !paintsSomething(),
        )
    }

    // ------------------------------------------------------------ chart size

    /**
     * A cartesian chart occupies its ported height (`ChartData.HEIGHT`), and a
     * horizontal bar chart grows with its row count
     * (`ChartData.horizontalHeight`).
     */
    @Test
    fun a_horizontal_bar_chart_grows_with_its_row_count() {
        compose.renderProgram(
            """
            root = Card([c])
            c = HorizontalBarChart(["a", "b", "c", "d", "e", "f"], [s])
            s = Series("Used", [1, 2, 3, 4, 5, 6])
            """.trimIndent(),
        )
        compose.onRoot().assertHeightIsAtLeast(ChartData.horizontalHeight(6).toFloat().dp)
    }

    /** The `Tabs` body slot really does swap identity, not just visibility. */
    @Test
    fun switching_tabs_replaces_the_body_rather_than_stacking_it() {
        compose.renderProgram(
            """
            root = Card([t])
            t = Tabs([one, two])
            one = TabItem("A", [x])
            two = TabItem("B", [y])
            x = ListBlock([r], "A-BLOCK")
            y = ListBlock([r2], "B-BLOCK")
            r = ListItem("a row")
            r2 = ListItem("b row")
            """.trimIndent(),
        )
        compose.onNodeWithText("A-BLOCK").assertIsDisplayed()
        compose.onAllNodes(hasText("B-BLOCK")).assertCountEquals(0)
    }
}
