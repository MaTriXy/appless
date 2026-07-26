package dev.appless.uicore

import dev.appless.openuilang.PropValue
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToLong

/**
 * Chart shaping ported from `src/genos/ui/shared/charts.tsx`: series decoding,
 * domain rounding, tick formatting, stacking, pie geometry and the variant
 * tables.
 *
 * Compose draws with its own canvas instead of `react-native-svg`, so the
 * DRAWING is not portable — but every number that decides what the chart SAYS
 * is, and it lives here where it can be tested against the TypeScript.
 *
 * NO Compose in this file.
 */
public object ChartData {

    /** One decoded `Series` element — `charts.tsx` `SeriesData`. */
    public data class SeriesData(val category: String, val values: List<Double>)

    // ------------------------------------------- layout constants (L69-73 etc.)

    /** `CHART_HEIGHT` — `charts.tsx` L69. */
    public const val HEIGHT: Double = 170.0

    /** `GUTTER_L` — `charts.tsx` L70. */
    public const val GUTTER_LEFT: Double = 36.0

    /** `GUTTER_B` — `charts.tsx` L71. */
    public const val GUTTER_BOTTOM: Double = 20.0

    /** `GUTTER_T` — `charts.tsx` L72. */
    public const val GUTTER_TOP: Double = 8.0

    /** `GUTTER_R` — `charts.tsx` L73. */
    public const val GUTTER_RIGHT: Double = 8.0

    /** `HorizontalBarChart` row height — `charts.tsx` L212 (`const rowH = 26`). */
    public const val HORIZONTAL_ROW_HEIGHT: Double = 26.0

    /** A semi-circular `PieChart` is shorter than the standard chart box — `charts.tsx` L465. */
    public const val SEMI_CIRCULAR_HEIGHT: Double = 110.0

    /** Axis tick text size — `charts.tsx` L165, L176. */
    public const val AXIS_FONT_SIZE: Double = 10.0

    /** The plot area's height: `CHART_HEIGHT - GUTTER_T - GUTTER_B` — `charts.tsx` L150. */
    public const val PLOT_HEIGHT: Double = HEIGHT - GUTTER_TOP - GUTTER_BOTTOM

    /** Gridline fractions the y axis draws — `charts.tsx` L151 (`const ticks = [0, 0.5, 1]`). */
    public val tickFractions: List<Double> = listOf(0.0, 0.5, 1.0)

    /**
     * `HorizontalBarChart` total height: `GUTTER_T + labels.length * rowH + 24`
     * — `charts.tsx` L213.
     */
    public fun horizontalHeight(labelCount: Int): Double =
        GUTTER_TOP + labelCount * HORIZONTAL_ROW_HEIGHT + 24.0

    // ------------------------------------------------------------ series decode

    /**
     * `readSeries` — `charts.tsx` L38-51.
     *
     * Each `Series` element contributes `{ category: String(p.category ?? ""),
     * values }`, where every value is clamped: non-numbers and non-finites
     * become 0, and NEGATIVES ARE CLAMPED TO 0 too (`Math.max(0, v)`, L44-46 —
     * the contract documents cartesian charts as non-negative). Series with no
     * values at all are dropped (L50).
     */
    public fun readSeries(prop: PropValue?): List<SeriesData> =
        (prop as? PropValue.Arr)?.items.orEmpty().mapNotNull { entry ->
            val props = when (entry) {
                is PropValue.Element -> entry.node.props
                is PropValue.Obj -> entry.entries.entries.toMap()
                else -> return@mapNotNull null
            }
            val values = ((props["values"] as? PropValue.Arr)?.items ?: emptyList()).map { v ->
                val n = (v as? PropValue.Num)?.value
                if (n != null && n.isFinite()) maxOf(0.0, n) else 0.0
            }
            SeriesData(category = jsStringOrEmpty(props["category"]), values = values)
        }.filter { it.values.isNotEmpty() }

    /** `String(p.category ?? "")` — `charts.tsx` L48. */
    private fun jsStringOrEmpty(value: PropValue?): String = when (value) {
        null, PropValue.Null -> ""
        is PropValue.Str -> value.value
        is PropValue.Bool -> if (value.value) "true" else "false"
        is PropValue.Num -> formatJsNumber(value.value)
        else -> ""
    }

    /**
     * `readSeries` drops series with no values at all — the chart-side filter
     * applied on top of a decode that kept them.
     */
    public fun usableSeries(series: List<SeriesData>): List<SeriesData> =
        series.filter { it.values.isNotEmpty() }

    // ------------------------------------------------------------------ domain

    /**
     * Round a domain max up to a "nice" tick value (1 / 2 / 2.5 / 5 x 10^k) —
     * `charts.tsx` L53-60. `v <= 0` (and NaN, which fails the comparison) is 1.
     */
    public fun niceMax(value: Double): Double {
        if (!(value > 0.0) || !value.isFinite()) return 1.0
        val exponent = floor(log10(value))
        val base = 10.0.pow(exponent)
        val fraction = value / base
        val nice = when {
            fraction <= 1 -> 1.0
            fraction <= 2 -> 2.0
            fraction <= 2.5 -> 2.5
            fraction <= 5 -> 5.0
            else -> 10.0
        }
        return nice * base
    }

    /**
     * The chart's y (or x, when horizontal) domain maximum — `charts.tsx` L204-207.
     *
     * Grouped / line / area take the max of EVERY value in every series
     * (`Math.max(...series.flatMap(s => s.values))` — values past
     * `labels.length` count too); stacked takes the max column total across
     * label indices (`labels.map((_, i) => series.reduce(...s.values[i] ?? 0))`).
     */
    public fun domainMax(series: List<SeriesData>, labelCount: Int, stacked: Boolean): Double {
        if (stacked) {
            if (labelCount <= 0 || series.isEmpty()) return niceMax(0.0)
            val totals = (0 until labelCount).map { i ->
                series.sumOf { it.values.getOrElse(i) { 0.0 } }
            }
            return niceMax(totals.max())
        }
        val all = series.flatMap { it.values }
        return niceMax(all.maxOrNull() ?: 0.0)
    }

    /**
     * Tick labels: `1.2M` / `3.4k` / `12.5`, with a trailing `.0` stripped (the
     * RN unary `+` on `toFixed(1)`) — `charts.tsx` L62-67.
     */
    public fun formatTick(value: Double): String {
        if (!value.isFinite()) return if (value.isNaN()) "NaN" else if (value > 0) "Infinity" else "-Infinity"
        val magnitude = abs(value)
        if (magnitude >= 1_000_000) return trimmed(value / 1_000_000) + "M"
        if (magnitude >= 1_000) return trimmed(value / 1_000) + "k"
        return trimmed(value)
    }

    /** `+(x.toFixed(1))` — one decimal, then drop it when it is zero. */
    private fun trimmed(value: Double): String {
        val rounded = (value * 10).roundToLong() / 10.0
        return formatJsNumber(rounded)
    }

    /** `String(n)` for the small, well-behaved magnitudes tick text produces. */
    private fun formatJsNumber(n: Double): String {
        if (!n.isFinite()) return if (n.isNaN()) "NaN" else if (n > 0) "Infinity" else "-Infinity"
        if (n == 0.0) return "0" // JS prints -0 as "0"
        if (n == floor(n) && abs(n) < 1e21) return n.toLong().toString()
        val s = n.toString()
        return if (s.endsWith(".0")) s.dropLast(2) else s
    }

    // ------------------------------------------------------------- axis labels

    /**
     * x-axis labels are thinned so they never collide (~44px each) —
     * `charts.tsx` L153:
     * `Math.max(1, Math.ceil(labels.length / Math.max(1, Math.floor(width / 44))))`.
     * Returns the stride: keep label `i` when `i % stride == 0`.
     */
    public fun labelStride(labelCount: Int, width: Double): Int {
        val slots = maxOf(1, floor(width / 44.0).toInt())
        return maxOf(1, ceil(labelCount.toDouble() / slots).toInt())
    }

    /**
     * Long category labels are elided — `charts.tsx` L173 (x labels, 8) and
     * L251 (horizontal row labels, 9): `l.length > N ? l.slice(0, N-1) + "…" : l`.
     */
    public fun truncate(label: String, limit: Int): String =
        if (label.length > limit) label.take(limit - 1) + "…" else label

    public fun truncateAxisLabel(label: String): String = truncate(label, 8)

    public fun truncateRowLabel(label: String): String = truncate(label, 9)

    // ---------------------------------------------------------------- variants

    /**
     * `BarChart` / `HorizontalBarChart` `variant`. Anything but `"stacked"` is
     * grouped (`props.variant === "stacked"`) — `charts.tsx` L202.
     */
    public enum class BarLayout { GROUPED, STACKED }

    public fun barLayout(variant: String?): BarLayout =
        if (variant == "stacked") BarLayout.STACKED else BarLayout.GROUPED

    /**
     * `LineChart` / `AreaChart` `variant`. Anything but `"natural"` / `"step"`
     * is linear — `charts.tsx` L122-133 (`linePath`).
     */
    public enum class LineInterpolation {
        LINEAR,

        /** Catmull-Rom smoothing (`smoothPath`). */
        NATURAL,

        /** `H x V y` — hold the previous value, then jump at the END of the interval. */
        STEP,
    }

    public fun lineInterpolation(variant: String?): LineInterpolation = when (variant) {
        "natural" -> LineInterpolation.NATURAL
        "step" -> LineInterpolation.STEP
        else -> LineInterpolation.LINEAR
    }

    /**
     * `PieChart` `variant`: donut carves an inner radius at 60% of the outer —
     * `charts.tsx` L473 (`props.variant === "donut" ? r * 0.6 : 0`).
     */
    public fun innerRadiusFactor(variant: String?): Double = if (variant == "donut") 0.6 else 0.0

    /**
     * `PieChart` `appearance`: `semiCircular` draws a half disc anchored to the
     * bottom edge — `charts.tsx` L466.
     */
    public fun isSemiCircular(appearance: String?): Boolean = appearance == "semiCircular"

    // ------------------------------------------------------------ pie geometry

    /**
     * One pie/donut wedge, in radians, measured the way the RN `arcPath`
     * measures: 0 points right (+x) and angles increase clockwise on screen
     * (+y is down).
     */
    public data class PieSlice(
        /** Index into the original `values` array — also the palette index. */
        val index: Int,
        val value: Double,
        val startAngle: Double,
        val endAngle: Double,
    ) {
        /**
         * The angle actually stroked: RN shaves a hairline off the end so
         * adjacent wedges read as separate — `charts.tsx` L489 (`a1 - 0.008`).
         */
        public val drawnEndAngle: Double get() = endAngle - GAP

        public companion object {
            /** `a1 - 0.008` — `charts.tsx` L489. */
            public const val GAP: Double = 0.008
        }
    }

    /**
     * Non-positive and non-finite values are dropped to 0 before the total is
     * taken (`typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0`) —
     * `charts.tsx` L461-463.
     */
    public fun pieValues(values: List<Double>): List<Double> =
        values.map { if (it.isFinite() && it > 0) it else 0.0 }

    /**
     * `PieChart.values`, decoded POSITIONALLY: a non-number entry becomes 0 and
     * keeps its slot (and therefore its palette color and its label), which is
     * what `values.map(...)` does in RN — unlike a compacting decode, which
     * would shift every later slice onto the wrong label.
     */
    public fun pieValues(prop: PropValue?): List<Double> =
        (prop as? PropValue.Arr)?.items.orEmpty().map { entry ->
            val n = (entry as? PropValue.Num)?.value
            if (n != null && n.isFinite() && n > 0) n else 0.0
        }

    /**
     * Wedges for a pie/donut — `charts.tsx` L464-483.
     *
     * A zero total renders nothing at all (`if (!total) return null`, L464).
     * Zero-valued entries produce no slice but still ADVANCE the palette index,
     * exactly like the RN `if (v <= 0) return null` inside the accumulating map.
     */
    public fun pieSlices(values: List<Double>, semiCircular: Boolean): List<PieSlice> {
        val cleaned = pieValues(values)
        val total = cleaned.sum()
        if (total <= 0.0) return emptyList()
        val start = if (semiCircular) Math.PI else -Math.PI / 2
        val span = if (semiCircular) Math.PI else Math.PI * 2
        var angle = start
        val slices = mutableListOf<PieSlice>()
        for ((index, value) in cleaned.withIndex()) {
            val next = angle + (value / total) * span
            if (value > 0) slices += PieSlice(index, value, angle, next)
            angle = next
        }
        return slices
    }

    /** Pie outer radius — `charts.tsx` L472. */
    public fun pieRadius(width: Double, height: Double, semiCircular: Boolean): Double =
        if (semiCircular) minOf(width / 2 - 8, 92.0) else minOf(height / 2 - 8, 78.0)

    // ----------------------------------------------------------------- palette

    /**
     * `chartPalette[i % chartPalette.length]` — the categorical color for
     * series / slice `index` (`charts.tsx` L480).
     */
    public fun paletteColor(index: Int, theme: ChartTheme): MdColor {
        val palette = theme.chartPalette
        if (palette.isEmpty()) return theme.ink2
        return palette[index % palette.size]
    }

    // --------------------------------------------------------------- emptiness

    /**
     * A cartesian chart renders NOTHING without both labels and series —
     * `if (!labels.length || !series.length) return null` (`charts.tsx` L201, L375).
     */
    public fun hasCartesianData(labels: List<String>, series: List<SeriesData>): Boolean =
        labels.isNotEmpty() && series.isNotEmpty()

    /** The legend only appears for multi-series charts — `charts.tsx` L75-76. */
    public fun showsLegend(seriesCount: Int): Boolean = seriesCount > 1
}
