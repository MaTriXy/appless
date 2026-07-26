package dev.appless.uicore

import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropValue
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The chart numbers, pinned against `src/genos/ui/shared/charts.tsx`.
 *
 * Every expectation in `niceMax` / `formatTick` / `labelStride` / `truncate` was
 * produced by running the TypeScript functions themselves under node and pasted
 * in verbatim.
 */
class ChartDataTest {

    private fun series(category: String, vararg values: Double): PropValue =
        PropValue.Element(
            ElementNode(
                component = "Series",
                props = mapOf(
                    "category" to PropValue.Str(category),
                    "values" to PropValue.Arr(values.map { PropValue.Num(it) }),
                ),
            )
        )

    private fun seriesProp(vararg entries: PropValue): PropValue = PropValue.Arr(entries.toList())

    // ---------------------------------------------------------- layout pinning

    @Test
    fun `layout constants match the RN literals`() {
        val charts = RepoSources.text("src/genos/ui/shared/charts.tsx")
        assertTrue(charts.contains("const CHART_HEIGHT = 170;"))
        assertTrue(charts.contains("const GUTTER_L = 36;"))
        assertTrue(charts.contains("const GUTTER_B = 20;"))
        assertTrue(charts.contains("const GUTTER_T = 8;"))
        assertTrue(charts.contains("const GUTTER_R = 8;"))
        assertTrue(charts.contains("const rowH = 26;"))
        assertEquals(170.0, ChartData.HEIGHT)
        assertEquals(36.0, ChartData.GUTTER_LEFT)
        assertEquals(20.0, ChartData.GUTTER_BOTTOM)
        assertEquals(8.0, ChartData.GUTTER_TOP)
        assertEquals(8.0, ChartData.GUTTER_RIGHT)
        assertEquals(26.0, ChartData.HORIZONTAL_ROW_HEIGHT)
        // `CHART_HEIGHT - GUTTER_T - GUTTER_B` — charts.tsx L150.
        assertEquals(142.0, ChartData.PLOT_HEIGHT)
        assertEquals(listOf(0.0, 0.5, 1.0), ChartData.tickFractions)
        // `GUTTER_T + labels.length * rowH + 24` — charts.tsx L213.
        assertEquals(8.0 + 5 * 26.0 + 24.0, ChartData.horizontalHeight(5))
        assertEquals(110.0, ChartData.SEMI_CIRCULAR_HEIGHT)
    }

    // ------------------------------------------------------------ series decode

    @Test
    fun `readSeries clamps non-numbers, non-finites AND negatives to zero`() {
        val decoded = ChartData.readSeries(
            PropValue.Arr(
                listOf(
                    PropValue.Element(
                        ElementNode(
                            component = "Series",
                            props = mapOf(
                                "category" to PropValue.Str("Revenue"),
                                "values" to PropValue.Arr(
                                    listOf(
                                        PropValue.Num(3.0),
                                        PropValue.Num(-4.0),          // Math.max(0, v)
                                        PropValue.Str("nope"),        // not a number
                                        PropValue.Num(Double.NaN),    // not finite
                                        PropValue.Num(Double.POSITIVE_INFINITY),
                                        PropValue.Null,
                                    )
                                ),
                            ),
                        )
                    )
                )
            )
        )
        assertEquals(1, decoded.size)
        assertEquals("Revenue", decoded[0].category)
        assertEquals(listOf(3.0, 0.0, 0.0, 0.0, 0.0, 0.0), decoded[0].values)
    }

    @Test
    fun `readSeries coerces category and drops empty series`() {
        val decoded = ChartData.readSeries(
            seriesProp(
                series("A", 1.0),
                PropValue.Element(
                    ElementNode("Series", props = mapOf("values" to PropValue.Arr(emptyList())))
                ), // dropped: no values
                PropValue.Element(
                    ElementNode(
                        "Series",
                        props = mapOf(
                            "category" to PropValue.Num(7.0), // String(7) === "7"
                            "values" to PropValue.Arr(listOf(PropValue.Num(2.0))),
                        ),
                    )
                ),
                PropValue.Str("junk"), // not an element
            )
        )
        assertEquals(listOf("A", "7"), decoded.map { it.category })
        // A missing `category` would be `String(undefined ?? "")` === "".
        assertEquals(
            "",
            ChartData.readSeries(
                seriesProp(
                    PropValue.Element(
                        ElementNode("Series", props = mapOf("values" to PropValue.Arr(listOf(PropValue.Num(1.0)))))
                    )
                )
            ).single().category,
        )
    }

    // ------------------------------------------------------------------ domain

    @Test
    fun `niceMax matches the node-derived table`() {
        val expected = listOf(
            0.0 to 1.0,
            -5.0 to 1.0,
            0.4 to 0.5,
            1.0 to 1.0,
            1.5 to 2.0,
            2.0 to 2.0,
            2.4 to 2.5,
            2.5 to 2.5,
            3.0 to 5.0,
            5.0 to 5.0,
            5.1 to 10.0,
            7.0 to 10.0,
            10.0 to 10.0,
            12.0 to 20.0,
            99.0 to 100.0,
            100.0 to 100.0,
            101.0 to 200.0,
            1234.0 to 2000.0,
            999_999.0 to 1_000_000.0,
        )
        for ((input, want) in expected) {
            assertEquals(want, ChartData.niceMax(input), 1e-9, "niceMax($input)")
        }
        assertEquals(1.0, ChartData.niceMax(Double.NaN))
    }

    @Test
    fun `grouped domain takes the max of every value, stacked takes the max column`() {
        val s = listOf(
            ChartData.SeriesData("a", listOf(3.0, 4.0, 9.0)),
            ChartData.SeriesData("b", listOf(2.0, 2.0, 1.0)),
        )
        // grouped: max value anywhere is 9 -> niceMax(9) = 10
        assertEquals(10.0, ChartData.domainMax(s, labelCount = 3, stacked = false))
        // stacked: column totals are 5, 6, 10 -> niceMax(10) = 10
        assertEquals(10.0, ChartData.domainMax(s, labelCount = 3, stacked = true))
        // Values PAST labels.length still count for the grouped domain
        // (`series.flatMap(s => s.values)` ignores labels entirely)…
        assertEquals(10.0, ChartData.domainMax(s, labelCount = 2, stacked = false))
        // …but not for the stacked one, which only sums the label indices.
        assertEquals(10.0, ChartData.domainMax(s, labelCount = 2, stacked = true))
        assertEquals(1.0, ChartData.domainMax(emptyList(), labelCount = 3, stacked = false))
        assertEquals(1.0, ChartData.domainMax(emptyList(), labelCount = 3, stacked = true))
        // Ragged series: `s.values[i] ?? 0`.
        val ragged = listOf(
            ChartData.SeriesData("a", listOf(1.0, 1.0, 1.0)),
            ChartData.SeriesData("b", listOf(50.0)),
        )
        // column totals 51, 1, 1 -> niceMax(51) = 100 (fraction 5.1 rounds to 10x10^1)
        assertEquals(100.0, ChartData.domainMax(ragged, labelCount = 3, stacked = true))
    }

    @Test
    fun `formatTick matches the node-derived table`() {
        val expected = listOf(
            0.0 to "0",
            1.0 to "1",
            12.5 to "12.5",
            999.0 to "999",
            1000.0 to "1k",
            1234.0 to "1.2k",
            1500.0 to "1.5k",
            999_999.0 to "1000k",
            1_000_000.0 to "1M",
            1_234_567.0 to "1.2M",
            2_500_000.0 to "2.5M",
            -1234.0 to "-1.2k",
            0.05 to "0.1",
            12.34 to "12.3",
            15_000.0 to "15k",
        )
        for ((input, want) in expected) {
            assertEquals(want, ChartData.formatTick(input), "formatTick($input)")
        }
    }

    // ------------------------------------------------------------- axis labels

    @Test
    fun `labelStride matches the node-derived table`() {
        val expected = listOf(
            Triple(12, 360.0, 2),
            Triple(12, 100.0, 6),
            Triple(3, 360.0, 1),
            Triple(30, 300.0, 5),
            Triple(7, 44.0, 7),
            Triple(7, 43.0, 7),
            Triple(1, 10.0, 1),
            Triple(20, 1000.0, 1),
        )
        for ((count, width, want) in expected) {
            assertEquals(want, ChartData.labelStride(count, width), "labelStride($count, $width)")
        }
    }

    @Test
    fun `truncate elides at 8 for axis labels and 9 for row labels`() {
        assertEquals("January", ChartData.truncateAxisLabel("January"))
        assertEquals("Septemb…", ChartData.truncateAxisLabel("September"))
        assertEquals("abcdefgh", ChartData.truncateAxisLabel("abcdefgh"))
        assertEquals("abcdefg…", ChartData.truncateAxisLabel("abcdefghi"))
        assertEquals("Wednesday", ChartData.truncateRowLabel("Wednesday"))
        assertEquals("Wednesda…", ChartData.truncateRowLabel("Wednesdayy"))
    }

    // ---------------------------------------------------------------- variants

    @Test
    fun `variant tables match the RN ternaries`() {
        assertEquals(ChartData.BarLayout.STACKED, ChartData.barLayout("stacked"))
        assertEquals(ChartData.BarLayout.GROUPED, ChartData.barLayout("grouped"))
        assertEquals(ChartData.BarLayout.GROUPED, ChartData.barLayout(null))
        assertEquals(ChartData.BarLayout.GROUPED, ChartData.barLayout("Stacked"))

        assertEquals(ChartData.LineInterpolation.NATURAL, ChartData.lineInterpolation("natural"))
        assertEquals(ChartData.LineInterpolation.STEP, ChartData.lineInterpolation("step"))
        assertEquals(ChartData.LineInterpolation.LINEAR, ChartData.lineInterpolation("linear"))
        assertEquals(ChartData.LineInterpolation.LINEAR, ChartData.lineInterpolation(null))

        assertEquals(0.6, ChartData.innerRadiusFactor("donut"))
        assertEquals(0.0, ChartData.innerRadiusFactor("pie"))
        assertEquals(0.0, ChartData.innerRadiusFactor(null))

        assertTrue(ChartData.isSemiCircular("semiCircular"))
        assertFalse(ChartData.isSemiCircular("semicircular"))
        assertFalse(ChartData.isSemiCircular(null))
    }

    // ------------------------------------------------------------ pie geometry

    @Test
    fun `a full pie sweeps 2pi starting at minus half pi`() {
        val slices = ChartData.pieSlices(listOf(1.0, 1.0, 2.0), semiCircular = false)
        assertEquals(3, slices.size)
        assertEquals(-Math.PI / 2, slices[0].startAngle, 1e-12)
        assertEquals(-Math.PI / 2 + Math.PI / 2, slices[0].endAngle, 1e-12)
        assertEquals(slices[0].endAngle, slices[1].startAngle, 1e-12)
        assertEquals(-Math.PI / 2 + 2 * Math.PI, slices.last().endAngle, 1e-12)
        // The hairline gap RN shaves off the drawn end — charts.tsx L489.
        assertEquals(0.008, ChartData.PieSlice.GAP)
        assertEquals(slices[0].endAngle - 0.008, slices[0].drawnEndAngle, 1e-12)
    }

    @Test
    fun `a semi-circular pie sweeps pi starting at pi`() {
        val slices = ChartData.pieSlices(listOf(3.0, 1.0), semiCircular = true)
        assertEquals(Math.PI, slices[0].startAngle, 1e-12)
        assertEquals(Math.PI + Math.PI * 0.75, slices[0].endAngle, 1e-12)
        assertEquals(2 * Math.PI, slices.last().endAngle, 1e-12)
    }

    @Test
    fun `zero and negative values consume their palette index but draw nothing`() {
        val slices = ChartData.pieSlices(listOf(1.0, 0.0, -3.0, 1.0), semiCircular = false)
        assertEquals(listOf(0, 3), slices.map { it.index }, "palette slots must not shift")
        assertEquals(2, slices.size)
        // Each drawn slice is half the circle: the zeroed entries contribute nothing to the total.
        assertEquals(Math.PI, slices[0].endAngle - slices[0].startAngle, 1e-12)
    }

    @Test
    fun `a zero total renders nothing at all`() {
        assertTrue(ChartData.pieSlices(listOf(0.0, 0.0), semiCircular = false).isEmpty())
        assertTrue(ChartData.pieSlices(emptyList(), semiCircular = false).isEmpty())
        assertTrue(
            ChartData.pieSlices(listOf(Double.NaN, Double.NEGATIVE_INFINITY), semiCircular = false).isEmpty()
        )
    }

    @Test
    fun `pie values decode positionally so labels never shift`() {
        val decoded = ChartData.pieValues(
            PropValue.Arr(
                listOf(
                    PropValue.Num(4.0),
                    PropValue.Str("8"),            // not a number -> 0, keeps its slot
                    PropValue.Num(-1.0),           // not positive -> 0
                    PropValue.Num(Double.NaN),     // not finite  -> 0
                    PropValue.Num(6.0),
                )
            )
        )
        assertEquals(listOf(4.0, 0.0, 0.0, 0.0, 6.0), decoded)
    }

    @Test
    fun `pie radius follows the RN min expressions`() {
        // semi: min(width / 2 - 8, 92); full: min(height / 2 - 8, 78)
        assertEquals(92.0, ChartData.pieRadius(width = 400.0, height = 110.0, semiCircular = true))
        assertEquals(42.0, ChartData.pieRadius(width = 100.0, height = 110.0, semiCircular = true))
        assertEquals(77.0, ChartData.pieRadius(width = 400.0, height = 170.0, semiCircular = false))
    }

    // ----------------------------------------------------------------- palette

    @Test
    fun `palette color wraps modulo the palette length`() {
        val theme = Tokens.chartTheme(dark = false)
        assertEquals(Tokens.MD_LIGHT.chartPalette[0], ChartData.paletteColor(0, theme))
        assertEquals(Tokens.MD_LIGHT.chartPalette[5], ChartData.paletteColor(5, theme))
        assertEquals(Tokens.MD_LIGHT.chartPalette[0], ChartData.paletteColor(6, theme))
        assertEquals(Tokens.MD_LIGHT.chartPalette[1], ChartData.paletteColor(13, theme))
        val dark = Tokens.chartTheme(dark = true)
        assertEquals(Tokens.MD_DARK.chartPalette[2], ChartData.paletteColor(8, dark))
    }

    // --------------------------------------------------------------- emptiness

    @Test
    fun `a cartesian chart renders nothing without both labels and series`() {
        val s = listOf(ChartData.SeriesData("a", listOf(1.0)))
        assertTrue(ChartData.hasCartesianData(listOf("Jan"), s))
        assertFalse(ChartData.hasCartesianData(emptyList(), s))
        assertFalse(ChartData.hasCartesianData(listOf("Jan"), emptyList()))
    }

    @Test
    fun `the legend appears only for multi-series charts`() {
        assertFalse(ChartData.showsLegend(0))
        assertFalse(ChartData.showsLegend(1))
        assertTrue(ChartData.showsLegend(2))
    }
}
