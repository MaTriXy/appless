import Foundation
import OpenUILang
import Testing

@testable import AppLessCore

/// The chart work that moved out of `Renderers+Charts.swift`.
///
/// Graded against `src/genos/ui/shared/charts.tsx`; the line references in the
/// comments are that file.
@Suite struct ChartLayoutTests {

    private func series(_ category: String, _ values: [Double]) -> PropValue {
        .element(
            ElementNode(
                component: "Series",
                props: [
                    "category": .string(category),
                    "values": .array(values.map { PropValue.number($0) }),
                ]))
    }

    private func chart(
        labels: PropValue,
        series seriesProp: [PropValue],
        variant: String? = nil,
        xLabel: PropValue? = nil,
        yLabel: PropValue? = nil
    ) -> ElementNode {
        var props: [String: PropValue] = ["labels": labels, "series": .array(seriesProp)]
        if let variant { props["variant"] = .string(variant) }
        if let xLabel { props["xLabel"] = xLabel }
        if let yLabel { props["yLabel"] = yLabel }
        return ElementNode(component: "BarChart", props: props)
    }

    // MARK: - Axis labels

    /// `props.labels ?? []` is NOT filtered (L194): every entry keeps its slot
    /// and React paints numbers. Dropping non-strings shortened the array, so
    /// bar `i` lined up under label `i+1` - and an all-numeric `labels` prop
    /// emptied it entirely, which took `hasCartesianData` false and made the
    /// whole chart vanish.
    @Test func axisLabelsKeepEverySlot() {
        let raw = PropValue.array([
            .string("Mon"), .number(2), .null, .bool(true), .string(""),
        ])
        #expect(ChartData.axisLabels(raw) == ["Mon", "2", "", "", ""])
        #expect(ChartData.axisLabels(nil).isEmpty)
        #expect(ChartData.axisLabels(.string("Mon")).isEmpty)  // not an array
    }

    /// Elision is guarded by `l.length > 8` (L181) / `> 9` (L254), and
    /// `.length` is `undefined` on a number - so a long NUMBER is printed in
    /// full while a long string is cut.
    @Test func onlyStringLabelsAreElided() {
        #expect(ChartData.axisLabelText(.string("Wednesday"), limit: 8) == "Wednesd\u{2026}")
        #expect(ChartData.axisLabelText(.string("Wednesda"), limit: 8) == "Wednesda")  // exactly 8
        #expect(ChartData.axisLabelText(.string("Wednesday"), limit: 9) == "Wednesday")
        #expect(ChartData.axisLabelText(.number(1_234_567_890), limit: 8) == "1234567890")
        #expect(ChartData.axisLabelText(.null, limit: 8) == "")
        #expect(ChartData.isElidable(.string("x")))
        #expect(!ChartData.isElidable(.number(1)))
    }

    // MARK: - CartesianChartInput

    @Test func cartesianInputDecodesAndFlattens() {
        let node = chart(
            labels: .array([.string("Mon"), .string("Tue"), .string("Wed")]),
            series: [series("Spend", [4, 5]), series("Save", [1, 2, 3])],
            xLabel: .string("Day"),
            yLabel: .number(2024))
        let input = CartesianChartInput(node: node)

        #expect(input.hasData)
        #expect(input.labels == ["Mon", "Tue", "Wed"])
        #expect(input.categories == ["Spend", "Save"])
        #expect(input.xLabel == "Day")
        #expect(input.yLabel == "2024")  // a numeric axis title still paints

        let points = input.points
        #expect(points.count == 6)  // 2 series x 3 labels
        #expect(points.map(\.id) == [0, 1, 2, 3, 4, 5])
        // `s.values[i] ?? 0` - Spend has no third value.
        #expect(points.map(\.value) == [4, 5, 0, 1, 2, 3])
        #expect(points[2].label == "Wed")
        #expect(points[3].category == "Save")
    }

    /// `if (!labels.length || !series.length) return null` (L201) - each of
    /// the two guards, separately, plus the case that reaches neither.
    @Test func cartesianInputRefusesToRenderWithoutBothHalves() {
        let noLabels = chart(labels: .array([]), series: [series("Spend", [1])])
        #expect(!CartesianChartInput(node: noLabels).hasData)

        let noSeries = chart(labels: .array([.string("Mon")]), series: [])
        #expect(!CartesianChartInput(node: noSeries).hasData)

        // `readSeries` drops a series with no values at all (L49), so this
        // has a `Series` element and still no usable series.
        let emptyValues = chart(labels: .array([.string("Mon")]), series: [series("Spend", [])])
        #expect(!CartesianChartInput(node: emptyValues).hasData)

        // The one that must render: an all-numeric labels array, which the old
        // `p.strings("labels")` decode emptied.
        let numeric = chart(
            labels: .array([.number(1), .number(2)]), series: [series("Spend", [3, 4])])
        let input = CartesianChartInput(node: numeric)
        #expect(input.hasData)
        #expect(input.labels == ["1", "2"])
    }

    /// The horizontal variant only changes the elision limit.
    @Test func horizontalInputElidesAtNineNotEight() {
        let node = chart(
            labels: .array([.string("Wednesday")]), series: [series("Spend", [1])])
        #expect(CartesianChartInput(node: node, horizontal: false).labels == ["Wednesd\u{2026}"])
        #expect(CartesianChartInput(node: node, horizontal: true).labels == ["Wednesday"])
    }

    // MARK: - Bridge numbers

    /// `GUTTER_T + labels.length * rowH + 24` (L212).
    @Test func horizontalHeightGrowsWithTheRowCount() {
        #expect(ChartData.horizontalChartHeight(labelCount: 0) == 8 + 24)
        #expect(ChartData.horizontalChartHeight(labelCount: 1) == 8 + 26 + 24)
        #expect(ChartData.horizontalChartHeight(labelCount: 5) == 8 + 130 + 24)
        // A negative count cannot shrink the box below its gutters.
        #expect(ChartData.horizontalChartHeight(labelCount: -3) == 8 + 24)
    }

    /// Grouped bars need one position group per series; stacked bars must
    /// share one, or Swift Charts draws them side by side.
    @Test func barPositionKeySeparatesGroupedAndJoinsStacked() {
        #expect(ChartData.barPositionKey(category: "Spend", layout: .grouped) == "Spend")
        #expect(ChartData.barPositionKey(category: "Save", layout: .grouped) == "Save")
        #expect(ChartData.barPositionKey(category: "Spend", layout: .stacked) == "")
        #expect(ChartData.barPositionKey(category: "Save", layout: .stacked) == "")
    }

    /// `symbolSize` is an AREA, and RN draws a radius-2.4 dot.
    @Test func pointSymbolAreaIsTheDotsArea() {
        #expect(abs(ChartData.pointSymbolArea - Double.pi * 2.4 * 2.4) < 1e-12)
    }

    // MARK: - Pie geometry

    /// `r = semi ? min(width/2 - 8, 92) : min(height/2 - 8, 78)`,
    /// `cy = semi ? height - 6 : height/2` (L471-476).
    @Test func pieDiscMatchesTheRNArcGeometry() {
        // Full disc, tall enough to hit the cap.
        let full = ChartData.pieDisc(
            width: 300, height: 170, semiCircular: false, innerRadiusFactor: 0)
        #expect(full.centerX == 150)
        #expect(full.centerY == 85)
        #expect(full.radius == 77)  // 170/2 - 8, under the 78 cap
        #expect(full.innerRadius == 0)
        #expect(full.isDrawable)

        // The cap actually binds once the box is tall.
        let capped = ChartData.pieDisc(
            width: 300, height: 400, semiCircular: false, innerRadiusFactor: 0)
        #expect(capped.radius == 78)

        // Semi-circular: radius from the WIDTH, anchored 6pt above the bottom.
        let semi = ChartData.pieDisc(
            width: 160, height: 110, semiCircular: true, innerRadiusFactor: 0)
        #expect(semi.radius == 72)  // 160/2 - 8
        #expect(semi.centerY == 104)  // 110 - 6
        #expect(ChartData.pieDisc(
            width: 400, height: 110, semiCircular: true, innerRadiusFactor: 0).radius == 92)

        // Donut carves 60% out of whatever radius won.
        let donut = ChartData.pieDisc(
            width: 300, height: 170, semiCircular: false, innerRadiusFactor: 0.6)
        #expect(abs(donut.innerRadius - 77 * 0.6) < 1e-12)

        // A box too small for a positive radius draws nothing rather than an
        // inverted arc.
        let tiny = ChartData.pieDisc(
            width: 10, height: 10, semiCircular: false, innerRadiusFactor: 0)
        #expect(tiny.radius == -3)
        #expect(!tiny.isDrawable)
    }

    @Test func pieChartHeightSwitchesOnAppearance() {
        #expect(ChartData.pieChartHeight(semiCircular: true) == 110)
        #expect(ChartData.pieChartHeight(semiCircular: false) == 170)
    }

    /// `labels.slice(0, values.length)` (L507): extra labels are cut, missing
    /// ones are simply absent - the legend never invents an entry.
    @Test func pieLegendNeverOutrunsTheValues() {
        #expect(ChartData.pieLegendEntries(labels: ["a", "b", "c"], valueCount: 2) == ["a", "b"])
        #expect(ChartData.pieLegendEntries(labels: ["a"], valueCount: 3) == ["a"])
        #expect(ChartData.pieLegendEntries(labels: ["a", "b"], valueCount: 0).isEmpty)
        #expect(ChartData.pieLegendEntries(labels: [], valueCount: 2).isEmpty)
        #expect(ChartData.pieLegendEntries(labels: ["a"], valueCount: -1).isEmpty)
    }

    /// A zero-valued slice draws nothing but KEEPS its palette index, so the
    /// legend colors stay aligned with the labels.
    @Test func zeroSlicesKeepTheirPaletteIndex() {
        let slices = ChartData.pieSlices(values: [3, 0, 1], semiCircular: false)
        #expect(slices.map(\.index) == [0, 2])
        #expect(ChartData.pieLegendEntries(labels: ["a", "b", "c"], valueCount: 3).count == 3)
    }
}
