//
//  Renderers+Charts.swift
//  AppLessUI
//
//  BarChart, HorizontalBarChart, LineChart, AreaChart, PieChart.
//  Port of `src/genos/ui/shared/charts.tsx`.
//
//  The four cartesian charts are drawn with Swift Charts; `PieChart` is drawn
//  with a `Shape`, because `SectorMark` is iOS 17 and this package targets
//  iOS 16. Every number - domain rounding, tick text, stacking, slice angles,
//  the variant tables - comes from `AppLessCore.ChartData`, which Linux tests
//  pin against the TypeScript.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

#if canImport(Charts)
import Charts
#endif

// MARK: - Shared chart chrome

/// `yLabel` caption above the plot. `shared/charts.tsx` L114-118.
struct ChartAxisTitle: View {
    let text: String?
    let theme: CdsTheme
    let alignment: Alignment

    var body: some View {
        if ChartData.showsAxisTitle(text), let text {
            Text(text)
                .font(.system(size: ChartData.axisFontSize))
                .foregroundStyle(Color(theme.ink2))
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

/// Centered swatch legend. `shared/charts.tsx` L75-103.
///
/// RN wraps it with `flexWrap`; SwiftUI has no wrapping stack before iOS 16's
/// `Layout`, so the entries are chunked three to a line - enough for the
/// six-color palette at phone widths.
struct ChartLegend: View {
    let entries: [String]
    let theme: CdsTheme

    var body: some View {
        let rows = FlexWrap.rows(
            count: entries.count, perRow: ChartData.legendEntriesPerRow)
        VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 12) {
                    ForEach(rows[rowIndex], id: \.self) { entryIndex in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(ChartData.paletteColor(entryIndex, theme: theme)))
                                .frame(
                                    width: ChartData.legendSwatch,
                                    height: ChartData.legendSwatch)
                            Text(entries[entryIndex])
                                .font(.system(size: ChartData.legendFontSize))
                                .foregroundStyle(Color(theme.ink2))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }
}

// MARK: - Bar charts

/// `BarChart` and `HorizontalBarChart`: the same data, rotated.
/// `shared/charts.tsx` L191-338.
struct CartesianBarChartView: View {
    let node: ElementNode
    let ctx: RenderContext
    let horizontal: Bool

    var body: some View {
        let input = CartesianChartInput(node: node, horizontal: horizontal)
        if input.hasData {
            let layout = ChartData.barLayout(input.variant)
            let domainMax = ChartData.domainMax(
                series: input.series,
                labelCount: input.labels.count,
                stacked: layout == .stacked)
            VStack(spacing: 2) {
                ChartAxisTitle(text: input.yLabel, theme: ctx.theme, alignment: .leading)
                plot(input, layout: layout, domainMax: domainMax)
                if ChartData.showsLegend(seriesCount: input.series.count) {
                    ChartLegend(entries: input.categories, theme: ctx.theme)
                }
                ChartAxisTitle(text: input.xLabel, theme: ctx.theme, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Grouped bars get one position group per series; stacked bars share a
    /// single group, which is what makes Swift Charts stack them.
    private func positionKey(_ point: CartesianChartInput.Point, layout: ChartData.BarLayout)
        -> String
    {
        ChartData.barPositionKey(category: point.category, layout: layout)
    }

    @ViewBuilder
    private func plot(
        _ input: CartesianChartInput,
        layout: ChartData.BarLayout,
        domainMax: Double
    ) -> some View {
        #if canImport(Charts)
        if horizontal {
            let height = ChartData.horizontalChartHeight(labelCount: input.labels.count)
            Chart(input.points) { point in
                BarMark(
                    x: .value("Value", point.value),
                    y: .value("Category", point.label)
                )
                .foregroundStyle(
                    Color(ChartData.paletteColor(point.seriesIndex, theme: ctx.theme))
                )
                .position(by: .value("Series", positionKey(point, layout: layout)))
                .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .chartXScale(domain: 0...domainMax)
            .chartXAxis { valueAxis(domainMax: domainMax) }
            .chartYAxis { categoryAxis() }
            .frame(height: height)
        } else {
            Chart(input.points) { point in
                BarMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(
                    Color(ChartData.paletteColor(point.seriesIndex, theme: ctx.theme))
                )
                .position(by: .value("Series", positionKey(point, layout: layout)))
                .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...domainMax)
            .chartYAxis { valueAxis(domainMax: domainMax) }
            .chartXAxis { categoryAxis() }
            .frame(height: ChartData.height)
        }
        #else
        // No Swift Charts (a platform older than iOS 16 / macOS 13): render
        // nothing rather than a broken frame.
        EmptyView()
        #endif
    }

    #if canImport(Charts)
    /// Three gridlines at 0 / 50% / 100% of the domain, labelled with the RN
    /// tick formatter. `shared/charts.tsx` L151-170.
    private func valueAxis(domainMax: Double) -> some AxisContent {
        AxisMarks(values: [0, domainMax / 2, domainMax]) { value in
            AxisGridLine().foregroundStyle(Color(ctx.theme.sep))
            AxisValueLabel {
                Text(ChartData.formatTick(value.as(Double.self) ?? 0))
                    .font(.system(size: ChartData.axisFontSize))
                    .foregroundStyle(Color(ctx.theme.ink2))
            }
        }
    }

    private func categoryAxis() -> some AxisContent {
        AxisMarks { value in
            AxisValueLabel {
                Text(value.as(String.self) ?? "")
                    .font(.system(size: ChartData.axisFontSize))
                    .foregroundStyle(Color(ctx.theme.ink2))
            }
        }
    }
    #endif
}

// MARK: - Line and area charts

/// `LineChart` and `AreaChart`. `shared/charts.tsx` L371-422.
struct CartesianLineChartView: View {
    let node: ElementNode
    let ctx: RenderContext
    let area: Bool

    var body: some View {
        let input = CartesianChartInput(node: node)
        if input.hasData {
            // Lines never stack: the domain is always the raw maximum.
            let domainMax = ChartData.domainMax(
                series: input.series,
                labelCount: input.labels.count,
                stacked: false)
            VStack(spacing: 2) {
                ChartAxisTitle(text: input.yLabel, theme: ctx.theme, alignment: .leading)
                plot(input, domainMax: domainMax)
                if ChartData.showsLegend(seriesCount: input.series.count) {
                    ChartLegend(entries: input.categories, theme: ctx.theme)
                }
                ChartAxisTitle(text: input.xLabel, theme: ctx.theme, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func plot(_ input: CartesianChartInput, domainMax: Double) -> some View {
        #if canImport(Charts)
        let showsPoints = ChartData.showsPointMarkers(labelCount: input.labels.count)
        Chart(input.points) { point in
            if area {
                AreaMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value),
                    series: .value("Series", point.category)
                )
                .interpolationMethod(interpolation(input.variant))
                .foregroundStyle(
                    Color(ChartData.paletteColor(point.seriesIndex, theme: ctx.theme))
                )
                .opacity(ChartData.areaOpacity)
            }

            LineMark(
                x: .value("Category", point.label),
                y: .value("Value", point.value),
                series: .value("Series", point.category)
            )
            .interpolationMethod(interpolation(input.variant))
            .lineStyle(StrokeStyle(lineWidth: ChartData.lineWidth))
            .foregroundStyle(
                Color(ChartData.paletteColor(point.seriesIndex, theme: ctx.theme)))

            if showsPoints {
                PointMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .symbolSize(pointSymbolArea)
                .foregroundStyle(
                    Color(ChartData.paletteColor(point.seriesIndex, theme: ctx.theme)))
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...domainMax)
        .chartYAxis {
            AxisMarks(values: [0, domainMax / 2, domainMax]) { value in
                AxisGridLine().foregroundStyle(Color(ctx.theme.sep))
                AxisValueLabel {
                    Text(ChartData.formatTick(value.as(Double.self) ?? 0))
                        .font(.system(size: ChartData.axisFontSize))
                        .foregroundStyle(Color(ctx.theme.ink2))
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    Text(value.as(String.self) ?? "")
                        .font(.system(size: ChartData.axisFontSize))
                        .foregroundStyle(Color(ctx.theme.ink2))
                }
            }
        }
        .frame(height: ChartData.height)
        #else
        EmptyView()
        #endif
    }

    /// `symbolSize` is an AREA; RN draws a radius-2.4 dot.
    private var pointSymbolArea: CGFloat { CGFloat(ChartData.pointSymbolArea) }

    #if canImport(Charts)
    /// `linear` / `natural` (Catmull-Rom) / `step` - RN's step holds the
    /// previous value to the next x, i.e. a step at the END of the interval.
    private func interpolation(_ variant: String?) -> InterpolationMethod {
        switch ChartData.lineInterpolation(variant) {
        case .linear: return .linear
        case .natural: return .catmullRom
        case .step: return .stepEnd
        }
    }
    #endif
}

// MARK: - Pie chart

/// `PieChart`, drawn as wedges. `shared/charts.tsx` L457-523.
struct PieChartView: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        let p = PropReader(node)
        let values = ChartData.pieValues(from: p.value("values"))
        let labels = ChartData.axisLabels(p.value("labels"))
        let semiCircular = ChartData.isSemiCircular(appearance: p.string("appearance"))
        let innerFactor = ChartData.innerRadiusFactor(variant: p.string("variant"))
        let slices = ChartData.pieSlices(values: values, semiCircular: semiCircular)
        let boxHeight = ChartData.pieChartHeight(semiCircular: semiCircular)
        if ChartData.rendersPie(values: values) {
            VStack(spacing: 0) {
                ZStack {
                    ForEach(slices, id: \.index) { slice in
                        PieSliceShape(
                            slice: slice,
                            innerRadiusFactor: innerFactor,
                            semiCircular: semiCircular
                        )
                        .fill(Color(ChartData.paletteColor(slice.index, theme: ctx.theme)))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: boxHeight, maxHeight: boxHeight)

                // The legend lists every label - including zero-value slices,
                // which keep their palette color. shared/charts.tsx L507-519.
                ChartLegend(
                    entries: ChartData.pieLegendEntries(
                        labels: labels, valueCount: values.count),
                    theme: ctx.theme)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One wedge, positioned exactly like the RN `arcPath`: the disc is centered
/// horizontally, and a semi-circular chart is anchored 6pt above the bottom
/// edge. `shared/charts.tsx` L424-438, L471-476.
struct PieSliceShape: Shape {
    let slice: ChartData.PieSlice
    let innerRadiusFactor: Double
    let semiCircular: Bool

    func path(in rect: CGRect) -> Path {
        let disc = ChartData.pieDisc(
            width: Double(rect.width),
            height: Double(rect.height),
            semiCircular: semiCircular,
            innerRadiusFactor: innerRadiusFactor)
        guard disc.isDrawable else { return Path() }
        let radius = CGFloat(disc.radius)
        let center = CGPoint(
            x: rect.minX + CGFloat(disc.centerX),
            y: rect.minY + CGFloat(disc.centerY))
        let inner = CGFloat(disc.innerRadius)
        let start = Angle(radians: slice.startAngle)
        let end = Angle(radians: slice.drawnEndAngle)

        var path = Path()
        if !disc.isDonut {
            path.move(to: center)
            path.addArc(
                center: center, radius: radius,
                startAngle: start, endAngle: end, clockwise: false)
            path.closeSubpath()
        } else {
            path.addArc(
                center: center, radius: radius,
                startAngle: start, endAngle: end, clockwise: false)
            path.addArc(
                center: center, radius: inner,
                startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
        }
        return path
    }
}

#endif
