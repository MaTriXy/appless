package dev.appless.app.render.material

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.get
import dev.appless.app.render.stringItems
import dev.appless.app.render.stringOrNull
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.ChartData
import dev.appless.uicore.ChartTheme
import dev.appless.uicore.Tokens
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The five chart renderers — `src/genos/ui/shared/charts.tsx`.
 *
 * RN draws with `react-native-svg`; Compose draws with `Canvas`, so the DRAWING
 * is not portable. Every number that decides what a chart SAYS is, and all of
 * it comes from `ui-core`'s [ChartData] — series decoding and the
 * negatives-clamp, `niceMax` domain rounding, the `1.2M` / `3.4k` tick format,
 * stacked-vs-grouped totals, the x-label thinning stride and elision, pie wedge
 * angles with the 0.008 rad hairline gap, and the palette index.
 *
 * NOTHING numeric is recomputed in this file — the geometry below only turns
 * those values into pixels.
 */

// ---------------------------------------------------------------- shared parts

@Composable
private fun chartTheme(): ChartTheme = Tokens.chartTheme(LocalMdTheme.current.dark)

/** `YAxisTitle` — `charts.tsx` L110-114. */
@Composable
private fun YAxisTitle(label: String?) {
    if (label.isNullOrEmpty()) return
    Text(
        text = label,
        color = chartTheme().ink2.toColor(),
        fontSize = 10.sp,
        modifier = Modifier.padding(bottom = 2.dp),
    )
}

/** `AxisTitles` — `charts.tsx` L100-108. */
@Composable
private fun XAxisTitle(label: String?) {
    if (label.isNullOrEmpty()) return
    Text(
        text = label,
        color = chartTheme().ink2.toColor(),
        fontSize = 10.sp,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 2.dp),
    )
}

/**
 * `Legend` — `charts.tsx` L76-98. Only multi-series charts get one
 * ([ChartData.showsLegend]).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Legend(categories: List<String>, showAlways: Boolean = false) {
    val t = chartTheme()
    if (!showAlways && !ChartData.showsLegend(categories.size)) return
    FlowRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        categories.forEachIndexed { index, category ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier
                        .size(7.dp)
                        .background(
                            ChartData.paletteColor(index, t).toColor(),
                            RoundedCornerShape(4.dp),
                        ),
                )
                Text(text = category, color = t.ink2.toColor(), fontSize = 10.5.sp)
            }
        }
    }
}

/** Axis tick text, drawn into the canvas the way `<SvgText>` was. */
private fun DrawScope.drawAxisText(
    measurer: TextMeasurer,
    text: String,
    x: Float,
    baselineY: Float,
    color: Color,
    anchor: TextAnchor,
) {
    val style = TextStyle(color = color, fontSize = ChartData.AXIS_FONT_SIZE.sp)
    val measured = measurer.measure(text, style)
    val left = when (anchor) {
        TextAnchor.START -> x
        TextAnchor.MIDDLE -> x - measured.size.width / 2f
        TextAnchor.END -> x - measured.size.width
    }
    // SVG's `y` is the BASELINE; Compose places text by its top edge.
    drawText(measured, topLeft = Offset(left, baselineY - measured.firstBaseline))
}

private enum class TextAnchor { START, MIDDLE, END }

// ------------------------------------------------------------ cartesian frame

/**
 * `CartesianFrame` — `charts.tsx` L136-183: three gridlines with their tick
 * labels, and the thinned x-axis category labels.
 */
private fun DrawScope.drawCartesianFrame(
    measurer: TextMeasurer,
    width: Float,
    domainMax: Double,
    labels: List<String>,
    theme: ChartTheme,
    xCenters: List<Float>,
) {
    val plotH = ChartData.PLOT_HEIGHT.toFloat().dp.toPx()
    val gutterL = ChartData.GUTTER_LEFT.dp.toPx()
    val gutterR = ChartData.GUTTER_RIGHT.dp.toPx()
    val gutterT = ChartData.GUTTER_TOP.dp.toPx()
    val sep = theme.sep.toColor()
    val ink2 = theme.ink2.toColor()

    for (fraction in ChartData.tickFractions) {
        val y = gutterT + plotH * (1f - fraction.toFloat())
        drawLine(sep, Offset(gutterL, y), Offset(width - gutterR, y), strokeWidth = 0.75f.dp.toPx())
        drawAxisText(
            measurer,
            ChartData.formatTick(domainMax * fraction),
            gutterL - 5.dp.toPx(),
            y + 3.dp.toPx(),
            ink2,
            TextAnchor.END,
        )
    }

    val stride = ChartData.labelStride(labels.size, width / density.toDouble())
    labels.forEachIndexed { index, label ->
        if (index % stride != 0) return@forEachIndexed
        val center = xCenters.getOrNull(index) ?: return@forEachIndexed
        drawAxisText(
            measurer,
            ChartData.truncateAxisLabel(label),
            center,
            ChartData.HEIGHT.dp.toPx() - 6.dp.toPx(),
            ink2,
            TextAnchor.MIDDLE,
        )
    }
}

// --------------------------------------------------------------------- bars

@Composable
private fun BarChartView(node: ElementNode, horizontal: Boolean) {
    val theme = chartTheme()
    val measurer = rememberTextMeasurer()
    val labels = node["labels"].stringItems()
    val series = ChartData.readSeries(node["series"])
    // `if (!labels.length || !series.length) return null` — L201.
    if (!ChartData.hasCartesianData(labels, series)) return

    val stacked = ChartData.barLayout(node["variant"].stringOrNull()) == ChartData.BarLayout.STACKED
    val domainMax = ChartData.domainMax(series, labels.size, stacked)

    Column(Modifier.fillMaxWidth()) {
        YAxisTitle(node["yLabel"].stringOrNull())
        if (horizontal) {
            HorizontalBars(measurer, labels, series, domainMax, stacked, theme)
        } else {
            VerticalBars(measurer, labels, series, domainMax, stacked, theme)
        }
        Legend(series.map { it.category })
        XAxisTitle(node["xLabel"].stringOrNull())
    }
}

@Composable
private fun VerticalBars(
    measurer: TextMeasurer,
    labels: List<String>,
    series: List<ChartData.SeriesData>,
    domainMax: Double,
    stacked: Boolean,
    theme: ChartTheme,
) {
    Canvas(
        Modifier
            .fillMaxWidth()
            .height(ChartData.HEIGHT.dp),
    ) {
        val width = size.width
        // `width > 40 ? children(width) : null` — ChartBox, L124.
        if (width <= 40.dp.toPx()) return@Canvas
        val gutterL = ChartData.GUTTER_LEFT.dp.toPx()
        val gutterR = ChartData.GUTTER_RIGHT.dp.toPx()
        val gutterT = ChartData.GUTTER_TOP.dp.toPx()
        val plotW = width - gutterL - gutterR
        val plotH = ChartData.PLOT_HEIGHT.toFloat().dp.toPx()
        val slot = plotW / labels.size
        val groupW = min(slot * 0.66f, 34.dp.toPx())
        val xCenters = labels.indices.map { gutterL + slot * it + slot / 2 }

        drawCartesianFrame(measurer, width, domainMax, labels, theme, xCenters)

        val barW = if (stacked) groupW else groupW / series.size
        labels.indices.forEach { i ->
            var acc = 0.0
            series.forEachIndexed { si, s ->
                val v = s.values.getOrElse(i) { 0.0 }
                val h = (v / domainMax).toFloat() * plotH
                val x = if (stacked) {
                    xCenters[i] - groupW / 2
                } else {
                    xCenters[i] - groupW / 2 + si * barW
                }
                val y = if (stacked) {
                    gutterT + plotH - h - (acc / domainMax).toFloat() * plotH
                } else {
                    gutterT + plotH - h
                }
                if (stacked) acc += v
                drawRoundRect(
                    color = ChartData.paletteColor(si, theme).toColor(),
                    topLeft = Offset(x, y),
                    size = Size(max(1f, barW - 1f), max(0f, h)),
                    cornerRadius = CornerRadius(3.dp.toPx(), 3.dp.toPx()),
                )
            }
        }
    }
}

@Composable
private fun HorizontalBars(
    measurer: TextMeasurer,
    labels: List<String>,
    series: List<ChartData.SeriesData>,
    domainMax: Double,
    stacked: Boolean,
    theme: ChartTheme,
) {
    val totalHeight = ChartData.horizontalHeight(labels.size)
    Canvas(
        Modifier
            .fillMaxWidth()
            .height(totalHeight.dp),
    ) {
        val width = size.width
        if (width <= 40.dp.toPx()) return@Canvas
        val height = size.height
        val gutterL = 64.dp.toPx() // `const gutterL = 64` — L227.
        val gutterT = ChartData.GUTTER_TOP.dp.toPx()
        val gutterR = ChartData.GUTTER_RIGHT.dp.toPx()
        val rowH = ChartData.HORIZONTAL_ROW_HEIGHT.dp.toPx()
        val plotW = width - gutterL - gutterR
        val ink2 = theme.ink2.toColor()

        for (fraction in ChartData.tickFractions) {
            val x = gutterL + plotW * fraction.toFloat()
            drawLine(
                theme.sep.toColor(),
                Offset(x, gutterT),
                Offset(x, height - 20.dp.toPx()),
                strokeWidth = 0.75f.dp.toPx(),
            )
            drawAxisText(
                measurer,
                ChartData.formatTick(domainMax * fraction),
                x,
                height - 7.dp.toPx(),
                ink2,
                TextAnchor.MIDDLE,
            )
        }

        labels.forEachIndexed { i, label ->
            val y0 = gutterT + i * rowH
            val inner = if (stacked) rowH - 10.dp.toPx() else (rowH - 10.dp.toPx()) / series.size
            var acc = 0.0
            drawAxisText(
                measurer,
                ChartData.truncateRowLabel(label),
                gutterL - 6.dp.toPx(),
                y0 + rowH / 2 + 3.dp.toPx(),
                ink2,
                TextAnchor.END,
            )
            series.forEachIndexed { si, s ->
                val v = s.values.getOrElse(i) { 0.0 }
                val w = (v / domainMax).toFloat() * plotW
                val x = if (stacked) gutterL + (acc / domainMax).toFloat() * plotW else gutterL
                if (stacked) acc += v
                val y = if (stacked) y0 + 5.dp.toPx() else y0 + 5.dp.toPx() + si * inner
                drawRoundRect(
                    color = ChartData.paletteColor(si, theme).toColor(),
                    topLeft = Offset(x, y),
                    size = Size(
                        max(0f, w),
                        if (stacked) rowH - 10.dp.toPx() else max(1f, inner - 1f),
                    ),
                    cornerRadius = CornerRadius(3.dp.toPx(), 3.dp.toPx()),
                )
            }
        }
    }
}

// -------------------------------------------------------------- lines & areas

/** `smoothPath` — Catmull-Rom to cubic bezier, `charts.tsx` L104-120 (variant `natural`). */
private fun smoothPath(points: List<Offset>): Path {
    val path = Path()
    if (points.size < 2) return path
    path.moveTo(points[0].x, points[0].y)
    for (i in 0 until points.size - 1) {
        val p0 = points[max(0, i - 1)]
        val p1 = points[i]
        val p2 = points[i + 1]
        val p3 = points[min(points.size - 1, i + 2)]
        path.cubicTo(
            p1.x + (p2.x - p0.x) / 6f, p1.y + (p2.y - p0.y) / 6f,
            p2.x - (p3.x - p1.x) / 6f, p2.y - (p3.y - p1.y) / 6f,
            p2.x, p2.y,
        )
    }
    return path
}

/** `linePath` — `charts.tsx` L122-133. */
private fun linePath(points: List<Offset>, interpolation: ChartData.LineInterpolation): Path {
    if (points.size < 2) return Path()
    return when (interpolation) {
        ChartData.LineInterpolation.NATURAL -> smoothPath(points)
        ChartData.LineInterpolation.STEP -> Path().apply {
            moveTo(points[0].x, points[0].y)
            for (i in 1 until points.size) {
                // `H x V y`: hold the previous value, then jump at the END of
                // the interval.
                lineTo(points[i].x, points[i - 1].y)
                lineTo(points[i].x, points[i].y)
            }
        }
        ChartData.LineInterpolation.LINEAR -> Path().apply {
            moveTo(points[0].x, points[0].y)
            for (i in 1 until points.size) lineTo(points[i].x, points[i].y)
        }
    }
}

@Composable
private fun LineChartView(node: ElementNode, area: Boolean) {
    val theme = chartTheme()
    val measurer = rememberTextMeasurer()
    val labels = node["labels"].stringItems()
    val series = ChartData.readSeries(node["series"])
    if (!ChartData.hasCartesianData(labels, series)) return

    // Line/area always take the flat max — never a stacked total (L375-377).
    val domainMax = ChartData.domainMax(series, labels.size, stacked = false)
    val interpolation = ChartData.lineInterpolation(node["variant"].stringOrNull())

    Column(Modifier.fillMaxWidth()) {
        YAxisTitle(node["yLabel"].stringOrNull())
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(ChartData.HEIGHT.dp),
        ) {
            val width = size.width
            if (width <= 40.dp.toPx()) return@Canvas
            val gutterL = ChartData.GUTTER_LEFT.dp.toPx()
            val gutterR = ChartData.GUTTER_RIGHT.dp.toPx()
            val gutterT = ChartData.GUTTER_TOP.dp.toPx()
            val plotW = width - gutterL - gutterR
            val plotH = ChartData.PLOT_HEIGHT.toFloat().dp.toPx()
            val n = max(labels.size - 1, 1)
            val xCenters = labels.indices.map { gutterL + (plotW * it) / n }

            drawCartesianFrame(measurer, width, domainMax, labels, theme, xCenters)

            series.forEachIndexed { si, s ->
                val points = s.values.take(labels.size).mapIndexed { i, v ->
                    Offset(xCenters[i], gutterT + plotH - (v / domainMax).toFloat() * plotH)
                }
                val color = ChartData.paletteColor(si, theme).toColor()
                val path = linePath(points, interpolation)
                val baseline = gutterT + plotH
                if (area && points.size >= 2) {
                    val filled = Path().apply {
                        addPath(path)
                        lineTo(points.last().x, baseline)
                        lineTo(points.first().x, baseline)
                        close()
                    }
                    drawPath(filled, color, alpha = 0.18f) // L410
                }
                drawPath(path, color, style = Stroke(width = 2.dp.toPx()))
                // Dots only on sparse series — `pts.length <= 16`, L414.
                if (points.size <= 16) {
                    for (p in points) drawCircle(color, radius = 2.4f.dp.toPx(), center = p)
                }
            }
        }
        Legend(series.map { it.category })
        XAxisTitle(node["xLabel"].stringOrNull())
    }
}

// ----------------------------------------------------------------------- pie

/** `arcPath` — `charts.tsx` L437-452, including the donut cut-out. */
private fun DrawScope.drawWedge(
    center: Offset,
    radius: Float,
    innerRadius: Float,
    startAngle: Double,
    endAngle: Double,
    color: Color,
) {
    val sweep = endAngle - startAngle
    if (sweep <= 0) return
    val rect = Rect(center = center, radius = radius)
    val wedge = Path().apply {
        if (innerRadius <= 0f) {
            moveTo(center.x, center.y)
            lineTo(
                center.x + radius * cos(startAngle).toFloat(),
                center.y + radius * sin(startAngle).toFloat(),
            )
        } else {
            moveTo(
                center.x + radius * cos(startAngle).toFloat(),
                center.y + radius * sin(startAngle).toFloat(),
            )
        }
        arcTo(rect, Math.toDegrees(startAngle).toFloat(), Math.toDegrees(sweep).toFloat(), false)
        close()
    }
    if (innerRadius > 0f) {
        // The donut hole: subtracting the inner disc keeps the wedge's two
        // radial edges exactly where `arcPath`'s inner arc put them.
        val hole = Path().apply { addOval(Rect(center = center, radius = innerRadius)) }
        val result = Path()
        result.op(wedge, hole, PathOperation.Difference)
        drawPath(result, color)
    } else {
        drawPath(wedge, color)
    }
}

@Composable
private fun PieChartView(node: ElementNode) {
    val theme = chartTheme()
    val values = ChartData.pieValues(node["values"])
    val semi = ChartData.isSemiCircular(node["appearance"].stringOrNull())
    val slices = ChartData.pieSlices(values, semi)
    // `if (!total) return null` — L464: a zero total renders nothing at all.
    if (slices.isEmpty()) return

    val innerFactor = ChartData.innerRadiusFactor(node["variant"].stringOrNull())
    val height = if (semi) ChartData.SEMI_CIRCULAR_HEIGHT else ChartData.HEIGHT
    val labels = node["labels"].stringItems()

    Column(Modifier.fillMaxWidth()) {
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(height.dp),
        ) {
            val width = size.width
            if (width <= 40.dp.toPx()) return@Canvas
            val radius = ChartData
                .pieRadius(width / density.toDouble(), height, semi)
                .toFloat().dp.toPx()
            val inner = (radius * innerFactor).toFloat()
            val center = Offset(
                x = width / 2,
                y = if (semi) size.height - 6.dp.toPx() else size.height / 2,
            )
            for (slice in slices) {
                drawWedge(
                    center = center,
                    radius = radius,
                    innerRadius = inner,
                    startAngle = slice.startAngle,
                    // `a1 - 0.008` — the hairline that separates wedges.
                    endAngle = slice.drawnEndAngle,
                    color = ChartData.paletteColor(slice.index, theme).toColor(),
                )
            }
        }
        // `labels.slice(0, values.length)` — L497: a pie ALWAYS shows its
        // legend, unlike the cartesian charts.
        Legend(labels.take(values.size), showAlways = true)
    }
}

// ------------------------------------------------------------------ renderers

internal object BarChartRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode): Unit = BarChartView(node, horizontal = false)
}

internal object HorizontalBarChartRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode): Unit = BarChartView(node, horizontal = true)
}

internal object LineChartRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode): Unit = LineChartView(node, area = false)
}

internal object AreaChartRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode): Unit = LineChartView(node, area = true)
}

internal object PieChartRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode): Unit = PieChartView(node)
}
