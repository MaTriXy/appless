//
//  ChartData.swift
//  AppLessCore
//
//  Chart shaping ported from `src/genos/ui/shared/charts.tsx`: domain rounding,
//  tick formatting, stacking, pie geometry and the variant tables.
//
//  The Swift renderers draw with Swift Charts instead of react-native-svg, so
//  the DRAWING is not portable - but every number that decides what the chart
//  says is, and it lives here where Linux can test it against the TypeScript.
//
//  NO SwiftUI in this file.
//

import Foundation
import OpenUILang

public enum ChartData {

    // MARK: - Layout constants (shared/charts.tsx L69-73, L212, L466)

    /// `CHART_HEIGHT`.
    public static let height: Double = 170
    /// Plot gutters: left / bottom / top / right.
    public static let gutterLeft: Double = 36
    public static let gutterBottom: Double = 20
    public static let gutterTop: Double = 8
    public static let gutterRight: Double = 8
    /// `HorizontalBarChart` row height and its wider category gutter.
    public static let horizontalRowHeight: Double = 26
    public static let horizontalGutterLeft: Double = 64
    /// A semi-circular `PieChart` is shorter than the standard chart box.
    public static let semiCircularHeight: Double = 110
    /// Legend swatch, legend text size, axis tick text size.
    public static let legendSwatch: Double = 7
    public static let legendFontSize: Double = 10.5
    public static let axisFontSize: Double = 10
    /// The filled area under an `AreaChart` line.
    public static let areaOpacity: Double = 0.18
    /// Line stroke width and the point radius drawn for short series.
    public static let lineWidth: Double = 2
    public static let pointRadius: Double = 2.4
    /// Points are only drawn when the series is short enough not to look noisy.
    public static let maxPointsWithMarkers = 16

    // MARK: - Domain

    /// Round a domain max up to a "nice" tick value (1 / 2 / 2.5 / 5 × 10^k).
    /// `shared/charts.tsx` L53-60.
    public static func niceMax(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let nice: Double
        if fraction <= 1 {
            nice = 1
        } else if fraction <= 2 {
            nice = 2
        } else if fraction <= 2.5 {
            nice = 2.5
        } else if fraction <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * base
    }

    /// The chart's y (or x, when horizontal) domain maximum.
    ///
    /// Grouped/line/area take the max of EVERY value in every series (RN
    /// `Math.max(...series.flatMap(s => s.values))` - values past
    /// `labels.count` count too); stacked takes the max column total across
    /// label indices. `shared/charts.tsx` L204-208.
    public static func domainMax(
        series: [StructuralProps.Series],
        labelCount: Int,
        stacked: Bool
    ) -> Double {
        if stacked {
            guard labelCount > 0, !series.isEmpty else { return niceMax(0) }
            let totals = (0..<labelCount).map { index in
                series.reduce(0.0) { $0 + ($1.values.indices.contains(index) ? $1.values[index] : 0) }
            }
            return niceMax(totals.max() ?? 0)
        }
        let all = series.flatMap(\.values)
        return niceMax(all.max() ?? 0)
    }

    /// Tick labels: `1.2M` / `3.4k` / `12.5`, with a trailing `.0` stripped
    /// (the RN unary `+` on `toFixed(1)`). `shared/charts.tsx` L62-67.
    public static func formatTick(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1_000_000 { return trimmed(value / 1_000_000) + "M" }
        if magnitude >= 1_000 { return trimmed(value / 1_000) + "k" }
        return trimmed(value)
    }

    /// `+(x.toFixed(1))` - one decimal, then drop it when it is zero.
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    /// x-axis labels are thinned so they never collide (~44pt each).
    /// `shared/charts.tsx` L153. Returns the stride: keep label `i` when
    /// `i % stride == 0`.
    public static func labelStride(labelCount: Int, width: Double) -> Int {
        let slots = max(1, Int(floor(width / 44)))
        return max(1, Int(ceil(Double(labelCount) / Double(slots))))
    }

    /// Long category labels are elided: x labels at 8 characters, horizontal
    /// row labels at 9. `shared/charts.tsx` L181, L254.
    public static func truncate(_ label: String, limit: Int) -> String {
        guard label.count > limit else { return label }
        return String(label.prefix(limit - 1)) + "\u{2026}"
    }

    public static func truncateAxisLabel(_ label: String) -> String { truncate(label, limit: 8) }
    public static func truncateRowLabel(_ label: String) -> String { truncate(label, limit: 9) }

    // MARK: - Variants

    /// `BarChart` / `HorizontalBarChart` `variant`. Anything but `"stacked"`
    /// is grouped (`props.variant === "stacked"`). `shared/charts.tsx` L203.
    public enum BarLayout: Sendable, Equatable {
        case grouped
        case stacked
    }

    public static func barLayout(_ variant: String?) -> BarLayout {
        variant == "stacked" ? .stacked : .grouped
    }

    /// `LineChart` / `AreaChart` `variant`. Anything but `"natural"` / `"step"`
    /// is linear. `shared/charts.tsx` L358-369.
    public enum LineInterpolation: Sendable, Equatable {
        case linear
        /// Catmull-Rom smoothing.
        case natural
        /// Hold the previous value to the next x, then jump - a step at the END
        /// of each interval (RN `H x V y`).
        case step
    }

    public static func lineInterpolation(_ variant: String?) -> LineInterpolation {
        switch variant {
        case "natural": return .natural
        case "step": return .step
        default: return .linear
        }
    }

    /// `PieChart` `variant`: donut carves an inner radius at 60% of the outer.
    /// `shared/charts.tsx` L472.
    public static func innerRadiusFactor(variant: String?) -> Double {
        variant == "donut" ? 0.6 : 0
    }

    /// `PieChart` `appearance`: `semiCircular` draws a half disc anchored to the
    /// bottom edge. `shared/charts.tsx` L465.
    public static func isSemiCircular(appearance: String?) -> Bool {
        appearance == "semiCircular"
    }

    // MARK: - Pie geometry

    /// One pie/donut wedge, in radians, measured the way the RN `arcPath`
    /// measures: 0 points right (+x) and angles increase clockwise on screen
    /// (+y is down).
    public struct PieSlice: Sendable, Equatable {
        /// Index into the original `values` array - also the palette index.
        public let index: Int
        public let value: Double
        public let startAngle: Double
        public let endAngle: Double

        public init(index: Int, value: Double, startAngle: Double, endAngle: Double) {
            self.index = index
            self.value = value
            self.startAngle = startAngle
            self.endAngle = endAngle
        }

        /// The angle actually stroked: RN shaves a hairline off the end so
        /// adjacent wedges read as separate. `shared/charts.tsx` L488.
        public var drawnEndAngle: Double { endAngle - PieSlice.gap }

        /// `a1 - 0.008` in `shared/charts.tsx` L488.
        public static let gap: Double = 0.008
    }

    /// Non-positive and non-finite values are dropped to 0 before the total is
    /// taken (`typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0`),
    /// and a zero total renders nothing at all. `shared/charts.tsx` L460-465.
    public static func pieValues(_ values: [Double]) -> [Double] {
        values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    }

    /// Wedges for a pie/donut. Zero-valued entries produce no slice but still
    /// consume their palette index, exactly like the RN `if (v <= 0) return null`
    /// inside the accumulating loop.
    public static func pieSlices(values: [Double], semiCircular: Bool) -> [PieSlice] {
        let cleaned = pieValues(values)
        let total = cleaned.reduce(0, +)
        guard total > 0 else { return [] }
        let start = semiCircular ? Double.pi : -Double.pi / 2
        let span = semiCircular ? Double.pi : Double.pi * 2
        var angle = start
        var slices: [PieSlice] = []
        for (index, value) in cleaned.enumerated() {
            let next = angle + (value / total) * span
            defer { angle = next }
            guard value > 0 else { continue }
            slices.append(
                PieSlice(index: index, value: value, startAngle: angle, endAngle: next))
        }
        return slices
    }

    // MARK: - Palette

    /// `chartPalette[i % chartPalette.length]` - the categorical color for
    /// series / slice `index`.
    public static func paletteColor(_ index: Int, theme: CdsTheme) -> CdsColor {
        let palette = theme.chartPalette
        guard !palette.isEmpty else { return theme.tint }
        return palette[index % palette.count]
    }

    /// `readSeries` drops series with no values at all
    /// (`.filter(s => !!s && s.values.length > 0)`, `shared/charts.tsx` L49).
    /// ``StructuralProps/series(of:)`` decodes every `Series` element; this is
    /// the chart-side filter applied on top of it.
    public static func usableSeries(_ series: [StructuralProps.Series]) -> [StructuralProps.Series] {
        series.filter { !$0.values.isEmpty }
    }

    /// `PieChart.values`, decoded POSITIONALLY: a non-number entry becomes 0
    /// and keeps its slot (and therefore its palette color and its label),
    /// which is what `values.map(...)` does in RN - unlike a compacting decode,
    /// which would shift every later slice onto the wrong label.
    /// `shared/charts.tsx` L460-462.
    public static func pieValues(from prop: PropValue?) -> [Double] {
        (prop?.arrayValue ?? []).map { entry in
            guard let n = entry.finiteNumberValue, n > 0 else { return 0 }
            return n
        }
    }

    /// A cartesian chart renders NOTHING without both labels and series -
    /// `if (!labels.length || !series.length) return null`.
    /// `shared/charts.tsx` L201, L375.
    public static func hasCartesianData(labels: [String], series: [StructuralProps.Series]) -> Bool {
        !labels.isEmpty && !series.isEmpty
    }

    /// The legend only appears for multi-series charts. `shared/charts.tsx` L77.
    public static func showsLegend(seriesCount: Int) -> Bool { seriesCount > 1 }
}
