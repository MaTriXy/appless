//
//  ChartLayout.swift
//  AppLessCore
//
//  The chart work that used to live in `Renderers+Charts.swift`: decoding a
//  cartesian chart's props, flattening it into plottable cells, the pie disc's
//  geometry, and the handful of numbers the Swift Charts / `Shape` bridges
//  need. `ChartData` already owned the domain, the ticks and the variants;
//  this is the rest.
//
//  Graded against `src/genos/ui/shared/charts.tsx`.
//
//  NO SwiftUI in this file.
//

import Foundation
import OpenUILang

// MARK: - Axis labels

extension ChartData {

    /// `props.labels ?? []` (`shared/charts.tsx` L194) - decoded POSITIONALLY.
    ///
    /// RN does not filter the array: every entry keeps its slot and is handed
    /// to an `<SvgText>` child, so a numeric label renders its digits and a
    /// null one renders an empty tick. Dropping non-strings (the old
    /// `p.strings("labels")`) shortened the array, which moved every later bar
    /// onto the wrong slot - and for an all-numeric `labels` prop emptied it
    /// entirely, so `hasCartesianData` went false and the whole chart
    /// disappeared.
    ///
    /// Elision is applied only to STRING labels, because RN guards it with
    /// `l.length > 8` and `.length` is `undefined` on a number (L181, L254).
    public static func axisLabels(_ prop: PropValue?) -> [String] {
        (prop?.arrayValue ?? []).map { $0.jsText ?? "" }
    }

    /// `true` when the label at this slot came from a string and is therefore
    /// subject to the `.length > limit` elision.
    public static func isElidable(_ prop: PropValue) -> Bool {
        prop.stringValue != nil
    }

    /// The axis text for one raw label entry: elided when it is a string past
    /// `limit`, printed verbatim otherwise.
    public static func axisLabelText(_ prop: PropValue, limit: Int) -> String {
        guard let string = prop.stringValue else { return prop.jsText ?? "" }
        return truncate(string, limit: limit)
    }
}

// MARK: - Cartesian input

/// Everything the four cartesian charts read off their node, plus the
/// flattened cells a mark-based renderer iterates.
///
/// This is the whole of what `Renderers+Charts.CartesianInput` used to compute
/// inside `AppLessUI`, where no Linux test could reach it.
public struct CartesianChartInput: Sendable, Equatable {

    /// One plotted cell: series × label.
    public struct Point: Sendable, Equatable, Identifiable {
        public let id: Int
        public let seriesIndex: Int
        public let category: String
        /// The label's axis text, already elided.
        public let label: String
        public let value: Double

        public init(
            id: Int, seriesIndex: Int, category: String, label: String, value: Double
        ) {
            self.id = id
            self.seriesIndex = seriesIndex
            self.category = category
            self.label = label
            self.value = value
        }
    }

    /// Axis text per slot, elided at the caller's limit.
    public let labels: [String]
    /// `readSeries(props.series)` - series with no values at all are dropped.
    public let series: [StructuralProps.Series]
    public let variant: String?
    public let xLabel: String?
    public let yLabel: String?

    /// Decode one chart node. `horizontal` only changes the elision limit
    /// (8 characters on an x axis, 9 in a horizontal row).
    public init(node: ElementNode, horizontal: Bool = false) {
        let p = PropReader(node)
        let limit = horizontal ? 9 : 8
        labels = (p.value("labels")?.arrayValue ?? []).map {
            ChartData.axisLabelText($0, limit: limit)
        }
        series = ChartData.usableSeries(StructuralProps.series(of: node))
        variant = p.string("variant")
        xLabel = p.text("xLabel")
        yLabel = p.text("yLabel")
    }

    /// `if (!labels.length || !series.length) return null` (L201, L375).
    public var hasData: Bool {
        ChartData.hasCartesianData(labels: labels, series: series)
    }

    /// Legend entries - one per series, in series order (L88-97).
    public var categories: [String] { series.map(\.category) }

    /// Every (series, label) cell with a missing value read as 0 - RN's
    /// `s.values[i] ?? 0` (L214, L253, L314).
    public var points: [Point] {
        var out: [Point] = []
        out.reserveCapacity(series.count * labels.count)
        var id = 0
        for (seriesIndex, entry) in series.enumerated() {
            for (labelIndex, label) in labels.enumerated() {
                let value =
                    entry.values.indices.contains(labelIndex) ? entry.values[labelIndex] : 0
                out.append(
                    Point(
                        id: id, seriesIndex: seriesIndex, category: entry.category,
                        label: label, value: value))
                id += 1
            }
        }
        return out
    }
}

// MARK: - Bridge geometry

extension ChartData {

    /// `GUTTER_T + labels.length * rowH + 24` (`shared/charts.tsx` L212).
    public static func horizontalChartHeight(labelCount: Int) -> Double {
        gutterTop + Double(max(0, labelCount)) * horizontalRowHeight + 24
    }

    /// Swift Charts groups marks by a `position(by:)` key. Grouped bars want
    /// one group per series; stacked bars must all share a key, which is what
    /// makes Swift Charts stack them.
    public static func barPositionKey(category: String, layout: BarLayout) -> String {
        layout == .grouped ? category : ""
    }

    /// `symbolSize` is an AREA, and RN draws a radius-2.4 dot (L400).
    public static var pointSymbolArea: Double { .pi * pointRadius * pointRadius }

    /// The pie/donut disc, in a box of `size`.
    ///
    /// `shared/charts.tsx` L471-476: a semi-circular chart takes its radius
    /// from the WIDTH and is anchored 6pt above the bottom edge; a full disc
    /// takes it from the HEIGHT and is centered. Both cap at a fixed maximum.
    public struct PieDisc: Sendable, Equatable {
        public let centerX: Double
        public let centerY: Double
        public let radius: Double
        public let innerRadius: Double

        public init(centerX: Double, centerY: Double, radius: Double, innerRadius: Double) {
            self.centerX = centerX
            self.centerY = centerY
            self.radius = radius
            self.innerRadius = innerRadius
        }

        /// Nothing can be drawn in a box too small for a positive radius.
        public var isDrawable: Bool { radius > 0 }
    }

    /// `r = semi ? min(width/2 - 8, 92) : min(height/2 - 8, 78)`,
    /// `cx = width/2`, `cy = semi ? height - 6 : height/2`,
    /// `inner = variant === "donut" ? r * 0.6 : 0`.
    public static func pieDisc(
        width: Double,
        height: Double,
        semiCircular: Bool,
        innerRadiusFactor: Double
    ) -> PieDisc {
        let radius =
            semiCircular
            ? Swift.min(width / 2 - 8, 92)
            : Swift.min(height / 2 - 8, 78)
        return PieDisc(
            centerX: width / 2,
            centerY: semiCircular ? height - 6 : height / 2,
            radius: radius,
            innerRadius: radius * innerRadiusFactor)
    }

    /// The box a `PieChart` reserves: 110pt semi-circular, `CHART_HEIGHT`
    /// otherwise (L466).
    public static func pieChartHeight(semiCircular: Bool) -> Double {
        semiCircular ? semiCircularHeight : height
    }

    /// `labels.slice(0, values.length)` (L507) - the pie legend never shows
    /// more entries than there are slices, INCLUDING zero-valued ones, which
    /// keep their palette color.
    public static func pieLegendEntries(labels: [String], valueCount: Int) -> [String] {
        Array(labels.prefix(Swift.max(0, valueCount)))
    }

    /// Legend entries per line. RN uses `flexWrap`; the port chunks, which is
    /// identical for the six-color palette at phone widths.
    public static let legendEntriesPerRow = 3

    /// `if (!xLabel) return null` / `if (!yLabel) return null` (L104, L114) -
    /// a JS truthiness test, so an EMPTY axis title reserves no space either.
    public static func showsAxisTitle(_ text: String?) -> Bool {
        !(text ?? "").isEmpty
    }

    /// `pts.length <= 16` - point markers are dropped once the series is long
    /// enough for them to read as noise (L400).
    public static func showsPointMarkers(labelCount: Int) -> Bool {
        labelCount <= maxPointsWithMarkers
    }

    /// `if (!total) return null` (L464) - a pie with nothing positive in it
    /// renders no chart at all, not an empty disc with a legend.
    public static func rendersPie(values: [Double]) -> Bool {
        !pieSlices(values: values, semiCircular: false).isEmpty
    }
}

extension ChartData.PieDisc {
    /// `arcPath`'s two branches: `inner <= 0` draws a filled wedge from the
    /// centre, otherwise the wedge is an annulus (L429-437).
    public var isDonut: Bool { innerRadius > 0 }
}
