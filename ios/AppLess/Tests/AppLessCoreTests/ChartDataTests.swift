import Foundation
import OpenUILang
import Testing

@testable import AppLessCore

/// Chart shaping, pinned against `src/genos/ui/shared/charts.tsx`.
@Suite struct ChartDataTests {

    private func series(_ pairs: (String, [Double])...) -> [StructuralProps.Series] {
        pairs.map { StructuralProps.Series(category: $0.0, values: $0.1) }
    }

    // MARK: - niceMax

    @Test func niceMaxRoundsToTheRNTickLadder() {
        #expect(ChartData.niceMax(0) == 1)
        #expect(ChartData.niceMax(-5) == 1)
        #expect(ChartData.niceMax(0.7) == 1)
        #expect(ChartData.niceMax(1) == 1)
        #expect(ChartData.niceMax(1.5) == 2)
        #expect(ChartData.niceMax(2.4) == 2.5)
        #expect(ChartData.niceMax(3) == 5)
        #expect(ChartData.niceMax(7) == 10)
        #expect(ChartData.niceMax(12) == 20)
        #expect(ChartData.niceMax(230) == 250)
        #expect(ChartData.niceMax(4300) == 5000)
        #expect(ChartData.niceMax(.infinity) == 1)
    }

    // MARK: - Domain

    @Test func groupedDomainUsesEveryValue() {
        let data = series(("a", [3, 9]), ("b", [4, 1, 40]))
        // 40 is past labels.count and STILL counts, like RN's flatMap.
        #expect(ChartData.domainMax(series: data, labelCount: 2, stacked: false) == 50)
    }

    @Test func stackedDomainUsesColumnTotals() {
        let data = series(("a", [3, 9]), ("b", [4, 1]))
        // columns: 7 and 10 → niceMax(10) == 10
        #expect(ChartData.domainMax(series: data, labelCount: 2, stacked: true) == 10)
    }

    @Test func stackedDomainToleratesRaggedSeries() {
        let data = series(("a", [3]), ("b", [4, 100]))
        #expect(ChartData.domainMax(series: data, labelCount: 2, stacked: true) == 100)
        #expect(ChartData.domainMax(series: [], labelCount: 2, stacked: true) == 1)
        #expect(ChartData.domainMax(series: [], labelCount: 0, stacked: false) == 1)
    }

    @Test func negativeValuesAreAlreadyClampedByTheDecoder() {
        // The contract's documented rule, implemented in PropDecoding.
        #expect(StructuralProps.clampChartValue(-7) == 0)
        let data = series(("a", [-7, 3].map(StructuralProps.clampChartValue)))
        #expect(data[0].values == [0, 3])
        #expect(ChartData.domainMax(series: data, labelCount: 2, stacked: false) == 5)
    }

    // MARK: - Ticks and labels

    @Test func formatTickMatchesTheRNFormatter() {
        #expect(ChartData.formatTick(0) == "0")
        #expect(ChartData.formatTick(12.5) == "12.5")
        #expect(ChartData.formatTick(12.04) == "12")
        #expect(ChartData.formatTick(999) == "999")
        #expect(ChartData.formatTick(1000) == "1k")
        #expect(ChartData.formatTick(1500) == "1.5k")
        #expect(ChartData.formatTick(2_400_000) == "2.4M")
        #expect(ChartData.formatTick(1_000_000) == "1M")
    }

    @Test func labelStrideThinsDenseAxes() {
        // ~44pt per label.
        #expect(ChartData.labelStride(labelCount: 4, width: 320) == 1)
        #expect(ChartData.labelStride(labelCount: 20, width: 320) == 3)
        #expect(ChartData.labelStride(labelCount: 20, width: 0) == 20)
        #expect(ChartData.labelStride(labelCount: 0, width: 320) == 1)
    }

    @Test func longLabelsAreElided() {
        #expect(ChartData.truncateAxisLabel("January") == "January")
        #expect(ChartData.truncateAxisLabel("Wednesday") == "Wednesd\u{2026}")
        #expect(ChartData.truncateRowLabel("Wednesday") == "Wednesday")
        #expect(ChartData.truncateRowLabel("Wednesdays") == "Wednesda\u{2026}")
    }

    // MARK: - Variants

    @Test func variantTablesMatchTheContractEnums() {
        #expect(ChartData.barLayout("stacked") == .stacked)
        #expect(ChartData.barLayout("grouped") == .grouped)
        #expect(ChartData.barLayout(nil) == .grouped)
        #expect(ChartData.barLayout("nonsense") == .grouped)

        #expect(ChartData.lineInterpolation("natural") == .natural)
        #expect(ChartData.lineInterpolation("step") == .step)
        #expect(ChartData.lineInterpolation("linear") == .linear)
        #expect(ChartData.lineInterpolation(nil) == .linear)

        #expect(ChartData.innerRadiusFactor(variant: "donut") == 0.6)
        #expect(ChartData.innerRadiusFactor(variant: "pie") == 0)
        #expect(ChartData.innerRadiusFactor(variant: nil) == 0)

        #expect(ChartData.isSemiCircular(appearance: "semiCircular"))
        #expect(!ChartData.isSemiCircular(appearance: "circular"))
        #expect(!ChartData.isSemiCircular(appearance: nil))
    }

    // MARK: - Pie geometry

    @Test func pieSlicesSpanTheFullCircle() {
        let slices = ChartData.pieSlices(values: [1, 1, 2], semiCircular: false)
        #expect(slices.count == 3)
        #expect(abs(slices[0].startAngle - (-Double.pi / 2)) < 1e-12)
        #expect(abs(slices[2].endAngle - (-Double.pi / 2 + 2 * Double.pi)) < 1e-12)
        // Quarter, quarter, half.
        #expect(abs((slices[0].endAngle - slices[0].startAngle) - Double.pi / 2) < 1e-12)
        #expect(abs((slices[2].endAngle - slices[2].startAngle) - Double.pi) < 1e-12)
        #expect(slices[0].drawnEndAngle < slices[0].endAngle)
    }

    @Test func semiCircularPieStartsAtPiAndSpansPi() {
        let slices = ChartData.pieSlices(values: [1, 1], semiCircular: true)
        #expect(abs(slices[0].startAngle - Double.pi) < 1e-12)
        #expect(abs(slices[1].endAngle - 2 * Double.pi) < 1e-12)
    }

    @Test func zeroAndNegativeSlicesKeepTheirPaletteIndex() {
        let slices = ChartData.pieSlices(values: [1, -4, 1], semiCircular: false)
        #expect(slices.map(\.index) == [0, 2])
        // The dropped entry contributes nothing to the total, so the two
        // survivors are half the circle each.
        #expect(abs((slices[0].endAngle - slices[0].startAngle) - Double.pi) < 1e-12)
        // ...and slice 2 starts exactly where slice 0 ended (no gap in the geometry).
        #expect(abs(slices[1].startAngle - slices[0].endAngle) < 1e-12)
    }

    @Test func aZeroTotalRendersNothing() {
        #expect(ChartData.pieSlices(values: [], semiCircular: false).isEmpty)
        #expect(ChartData.pieSlices(values: [0, -1], semiCircular: false).isEmpty)
    }

    @Test func pieValuesDecodePositionally() {
        // A non-number entry becomes 0 and KEEPS its slot, so later slices stay
        // aligned with their labels.
        let raw = PropValue.array([.number(2), .string("x"), .number(4), .number(-1)])
        #expect(ChartData.pieValues(from: raw) == [2, 0, 4, 0])
        #expect(ChartData.pieValues(from: nil).isEmpty)
    }

    // MARK: - Guards

    @Test func chartsWithoutDataRenderNothing() {
        #expect(!ChartData.hasCartesianData(labels: [], series: series(("a", [1]))))
        #expect(!ChartData.hasCartesianData(labels: ["a"], series: []))
        #expect(ChartData.hasCartesianData(labels: ["a"], series: series(("a", [1]))))
    }

    @Test func emptySeriesAreDropped() {
        let data = series(("a", [1]), ("b", []))
        #expect(ChartData.usableSeries(data).map(\.category) == ["a"])
    }

    @Test func legendOnlyShowsForMultipleSeries() {
        #expect(!ChartData.showsLegend(seriesCount: 1))
        #expect(!ChartData.showsLegend(seriesCount: 0))
        #expect(ChartData.showsLegend(seriesCount: 2))
    }

    @Test func paletteWrapsAroundTheThemeColors() {
        let theme = CdsTheme.light
        #expect(ChartData.paletteColor(0, theme: theme) == theme.chartPalette[0])
        #expect(ChartData.paletteColor(6, theme: theme) == theme.chartPalette[0])
        #expect(ChartData.paletteColor(7, theme: theme) == theme.chartPalette[1])
    }
}
