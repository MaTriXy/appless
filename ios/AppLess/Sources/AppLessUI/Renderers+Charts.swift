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
        if let text, !text.isEmpty {
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
        let rows = Array(entries.indices).cdsChunked(into: 3)
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

/// One plotted point, flattened so Swift Charts can iterate it.
struct ChartPoint: Identifiable {
    let id: Int
    let seriesIndex: Int
    let category: String
    let label: String
    let value: Double
}

/// The `{labels, series, variant, xLabel, yLabel}` bundle every cartesian
/// chart decodes, plus the flattened points Swift Charts plots.
struct CartesianInput {
    let labels: [String]
    let series: [StructuralProps.Series]
    let variant: String?
    let xLabel: String?
    let yLabel: String?

    init(node: ElementNode) {
        let p = PropReader(node)
        labels = p.strings("labels")
        series = ChartData.usableSeries(StructuralProps.series(of: node))
        variant = p.string("variant")
        xLabel = p.string("xLabel")
        yLabel = p.string("yLabel")
    }

    var hasData: Bool { ChartData.hasCartesianData(labels: labels, series: series) }
    var categories: [String] { series.map(\.category) }

    /// Every (series, label) cell, with a missing value read as 0 - the RN
    /// `s.values[i] ?? 0`.
    var points: [ChartPoint] {
        var out: [ChartPoint] = []
        var id = 0
        for (seriesIndex, entry) in series.enumerated() {
            for (labelIndex, label) in labels.enumerated() {
                let value =
                    entry.values.indices.contains(labelIndex) ? entry.values[labelIndex] : 0
                out.append(
                    ChartPoint(
                        id: id,
                        seriesIndex: seriesIndex,
                        category: entry.category,
                        label: label,
                        value: value))
                id += 1
            }
        }
        return out
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
        let input = CartesianInput(node: node)
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
    private func positionKey(_ point: ChartPoint, layout: ChartData.BarLayout) -> String {
        layout == .grouped ? point.category : ""
    }

    @ViewBuilder
    private func plot(
        _ input: CartesianInput,
        layout: ChartData.BarLayout,
        domainMax: Double
    ) -> some View {
        #if canImport(Charts)
        if horizontal {
            let height =
                ChartData.gutterTop
                + Double(input.labels.count) * ChartData.horizontalRowHeight + 24
            Chart(input.points) { point in
                BarMark(
                    x: .value("Value", point.value),
                    y: .value("Category", ChartData.truncateRowLabel(point.label))
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
                    x: .value("Category", ChartData.truncateAxisLabel(point.label)),
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
        let input = CartesianInput(node: node)
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
    private func plot(_ input: CartesianInput, domainMax: Double) -> some View {
        #if canImport(Charts)
        let showsPoints = input.labels.count <= ChartData.maxPointsWithMarkers
        Chart(input.points) { point in
            if area {
                AreaMark(
                    x: .value("Category", ChartData.truncateAxisLabel(point.label)),
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
                x: .value("Category", ChartData.truncateAxisLabel(point.label)),
                y: .value("Value", point.value),
                series: .value("Series", point.category)
            )
            .interpolationMethod(interpolation(input.variant))
            .lineStyle(StrokeStyle(lineWidth: ChartData.lineWidth))
            .foregroundStyle(
                Color(ChartData.paletteColor(point.seriesIndex, theme: ctx.theme)))

            if showsPoints {
                PointMark(
                    x: .value("Category", ChartData.truncateAxisLabel(point.label)),
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
    private var pointSymbolArea: CGFloat {
        let radius = CGFloat(ChartData.pointRadius)
        return CGFloat.pi * radius * radius
    }

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
        let labels = p.strings("labels")
        let semiCircular = ChartData.isSemiCircular(appearance: p.string("appearance"))
        let innerFactor = ChartData.innerRadiusFactor(variant: p.string("variant"))
        let slices = ChartData.pieSlices(values: values, semiCircular: semiCircular)
        if !slices.isEmpty {
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
                .frame(
                    maxWidth: .infinity,
                    minHeight: semiCircular
                        ? ChartData.semiCircularHeight : ChartData.height,
                    maxHeight: semiCircular
                        ? ChartData.semiCircularHeight : ChartData.height)

                // The legend lists every label - including zero-value slices,
                // which keep their palette color. shared/charts.tsx L507-519.
                ChartLegend(
                    entries: Array(labels.prefix(values.count)),
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
        let radius: CGFloat =
            semiCircular
            ? min(rect.width / 2 - 8, 92)
            : min(rect.height / 2 - 8, 78)
        guard radius > 0 else { return Path() }
        let center = CGPoint(
            x: rect.midX,
            y: semiCircular ? rect.maxY - 6 : rect.midY)
        let inner = radius * innerRadiusFactor
        let start = Angle(radians: slice.startAngle)
        let end = Angle(radians: slice.drawnEndAngle)

        var path = Path()
        if inner <= 0 {
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
