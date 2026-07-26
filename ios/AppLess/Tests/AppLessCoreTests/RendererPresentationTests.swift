import Foundation
import OpenUILang
import Testing

@testable import AppLessCore

/// The decisions that used to be made inside a SwiftUI `body`.
///
/// Every test here also exercises the branch the implementation does NOT
/// take - the out-of-range index, the empty list, the label that is present
/// but empty, the degenerate range - because those are the cases the SwiftUI
/// versions got wrong.
@Suite struct RendererPresentationTests {

    private func element(
        _ component: String,
        _ props: [String: PropValue] = [:],
        children: PropValue? = nil
    ) -> ElementNode {
        ElementNode(component: component, props: props, children: children)
    }

    // MARK: - FlexWrap

    /// `flex-wrap` fills a line before starting the next one, and the LAST row
    /// is short - the tiles in it then stretch (`flexGrow: 1`).
    @Test func flexWrapFillsRowsAndLeavesTheLastShort() {
        #expect(FlexWrap.rows(count: 5, perRow: 2).map(Array.init) == [[0, 1], [2, 3], [4]])
        #expect(FlexWrap.rows(count: 4, perRow: 2).map(Array.init) == [[0, 1], [2, 3]])
        #expect(FlexWrap.rows(count: 1, perRow: 3).map(Array.init) == [[0]])
        // Empty input produces no rows at all, not one empty row - an empty
        // `StatTiles` must not reserve a row's height.
        #expect(FlexWrap.rows(count: 0, perRow: 2).isEmpty)
        // A nonsense row size cannot divide by zero or loop forever.
        #expect(FlexWrap.rows(count: 3, perRow: 0).map(Array.init) == [[0, 1, 2]])
        #expect(FlexWrap.rows(count: 0, perRow: 0).isEmpty)
        #expect(FlexWrap.rows(count: 3, perRow: -1).map(Array.init) == [[0, 1, 2]])
    }

    // MARK: - Tabs

    /// `items[Math.min(active, Math.max(items.length - 1, 0))]` - a list that
    /// shrank must not strand the selection past its end.
    @Test func tabsClampTheContentIndexButNotTheHighlight() {
        #expect(TabsPresentation.contentIndex(active: 0, count: 3) == 0)
        #expect(TabsPresentation.contentIndex(active: 2, count: 3) == 2)
        #expect(TabsPresentation.contentIndex(active: 4, count: 3) == 2)
        #expect(TabsPresentation.contentIndex(active: -1, count: 3) == 0)
        // Empty list: nothing to show, so no content at all.
        #expect(TabsPresentation.contentIndex(active: 0, count: 0) == nil)

        // …but the SEGMENT highlight tests the raw `active` (components.tsx
        // L650), so while a shrunken list shows tab 2's content, NO segment is
        // highlighted. Highlighting the clamped index would be a divergence.
        #expect(TabsPresentation.isHighlighted(index: 2, active: 4) == false)
        #expect(TabsPresentation.isHighlighted(index: 2, active: 2) == true)
        #expect(TabsPresentation.isHighlighted(index: 0, active: 2) == false)
    }

    /// `it.props?.label ?? \`Tab ${i + 1}\`` - `??` is nullish, so an EMPTY
    /// label renders an empty segment rather than falling back.
    @Test func tabTitleFallsBackOnlyForAMissingLabel() {
        #expect(TabsPresentation.title(label: "Today", index: 0) == "Today")
        #expect(TabsPresentation.title(label: nil, index: 0) == "Tab 1")
        #expect(TabsPresentation.title(label: nil, index: 4) == "Tab 5")
        // The branch the old `label.isEmpty ? "Tab n" : label` took by mistake.
        #expect(TabsPresentation.title(label: "", index: 0) == "")
        #expect(TabsPresentation.title(label: " ", index: 0) == " ")
    }

    /// A `TabItem` with an explicit null label is nullish and so DOES fall
    /// back, while one with `label: ""` does not - the two only differ once
    /// the decoded label is optional.
    @Test func tabItemsPreserveTheDifferenceBetweenEmptyAndAbsent() {
        let tabs = element(
            "Tabs",
            [
                "items": .array([
                    .element(element("TabItem", ["label": .string("Today")])),
                    .element(element("TabItem", ["label": .string("")])),
                    .element(element("TabItem", [:])),
                    .element(element("TabItem", ["label": .null])),
                    .element(element("TabItem", ["label": .number(7)])),
                ])
            ])
        let items = StructuralProps.tabItems(of: tabs)
        #expect(items.map(\.label) == ["Today", "", nil, nil, "7"])
        #expect(
            items.indices.map { TabsPresentation.title(label: items[$0].label, index: $0) }
                == ["Today", "", "Tab 3", "Tab 4", "7"])
    }

    // MARK: - Select

    @Test func selectTriggerLabelUsesThePlaceholderNotTheValue() {
        let labelled = StructuralProps.SelectItem(value: "in", label: "India")
        let bare = StructuralProps.SelectItem(value: "us", label: nil)

        #expect(
            SelectPresentation.triggerLabel(selected: labelled, placeholder: "Country")
                == "India")
        // The divergence this replaced: the port printed "us" here.
        #expect(
            SelectPresentation.triggerLabel(selected: bare, placeholder: "Country")
                == "Country")
        #expect(SelectPresentation.triggerLabel(selected: bare, placeholder: nil) == "Select\u{2026}")
        #expect(
            SelectPresentation.triggerLabel(selected: nil, placeholder: "Country") == "Country")
        #expect(SelectPresentation.triggerLabel(selected: nil, placeholder: nil) == "Select\u{2026}")

        // …while the OPEN list still shows the value for the same item.
        #expect(bare.optionLabel == "us")
        #expect(labelled.optionLabel == "India")

        // Ink follows the selected ITEM, not the label: a label-less but
        // selected item still reads as a choice.
        #expect(SelectPresentation.triggerShowsSelection(bare))
        #expect(!SelectPresentation.triggerShowsSelection(nil))
    }

    @Test func selectFindsTheSelectedItemByValue() {
        let items = [
            StructuralProps.SelectItem(value: "in", label: "India"),
            StructuralProps.SelectItem(value: "us", label: "USA"),
        ]
        #expect(SelectPresentation.selected(in: items, value: "us")?.label == "USA")
        #expect(SelectPresentation.selected(in: items, value: "xx") == nil)
        // No stored value matches nothing - NOT the first item.
        #expect(SelectPresentation.selected(in: items, value: nil) == nil)
        #expect(SelectPresentation.selected(in: [], value: "us") == nil)
    }

    // MARK: - Chips

    @Test func chipsIgnoreATapOnTheActiveChip() {
        #expect(ChipsPresentation.shouldDispatch(tapped: 1, active: 0))
        #expect(!ChipsPresentation.shouldDispatch(tapped: 0, active: 0))
        #expect(ChipsPresentation.dispatchesWithFormName == nil)
    }

    /// The chip request is a literal in `components.tsx` L594; the shared
    /// builder must not paraphrase it.
    @Test func chipsMessageIsTheRNLiteral() {
        #expect(
            GenosActions.chipsMessage("Unread")
                == #"Apply the "Unread" filter and re-render this screen with only matching content"#
        )
    }

    // MARK: - ListItem

    /// `useTap` returns `undefined` when there is no action, and RN derives
    /// BOTH `disabled` and the chevron from that one value - so an inert row
    /// can never show a chevron.
    @Test func listItemInteractivityAndChevronAgree() {
        #expect(!ListItemPresentation.isInteractive(action: nil))
        #expect(ListItemPresentation.isInteractive(action: ActionPlan(steps: [])))
        #expect(ListItemPresentation.dispatchesWithFormName == nil)
    }

    // MARK: - Bubbles

    @Test func bubbleCornersClipTheTailOnTheSendersSide() {
        let mine = BubblePresentation.corners(isMine: true)
        #expect(mine.topLeft == 18 && mine.topRight == 18)
        #expect(mine.bottomRight == 6 && mine.bottomLeft == 18)

        let theirs = BubblePresentation.corners(isMine: false)
        #expect(theirs.bottomRight == 18 && theirs.bottomLeft == 6)
    }

    /// 78% of the thread - but only once the thread has been measured. Before
    /// that the cap must be ABSENT, not zero, or the first frame paints an
    /// invisible bubble.
    @Test func bubbleWidthCapWaitsForAMeasuredThread() {
        #expect(BubblePresentation.maxWidth(threadWidth: 100) == 78)
        #expect(BubblePresentation.maxWidth(threadWidth: 0) == nil)
        #expect(BubblePresentation.maxWidth(threadWidth: -5) == nil)
    }

    // MARK: - Slider

    /// The contract declares min/max required; a model can still omit them,
    /// and RN then falls through to the RN slider's own 0…1.
    @Test func sliderBoundsDefaultAndNeverDegenerate() {
        #expect(SliderPresentation.bounds(min: 10, max: 20) == (10, 20))
        #expect(SliderPresentation.bounds(min: nil, max: nil) == (0, 1))
        #expect(SliderPresentation.bounds(min: 5, max: nil) == (5, 6))
        #expect(SliderPresentation.bounds(min: nil, max: 20) == (0, 20))
        // max == min and max < min both have to produce a usable range.
        #expect(SliderPresentation.bounds(min: 7, max: 7) == (7, 8))
        #expect(SliderPresentation.bounds(min: 7, max: 3) == (7, 8))
    }

    /// `{Math.round(current * 100) / 100}` interpolated into a `<Text>`. The
    /// magnitudes below are the ones `%g` used to destroy.
    @Test func sliderReadoutPrintsTheJSNumber() {
        #expect(SliderPresentation.readoutText(3.14159) == "3.14")
        #expect(SliderPresentation.readoutText(2) == "2")
        #expect(SliderPresentation.readoutText(2.0) == "2")
        // Negative halves are where Swift's `rounded()` disagrees with JS.
        // Node: Math.round(-0.005*100)/100 === -0, String(-0) === "0".
        #expect(SliderPresentation.readoutText(-0.005) == "0")
        // Node: Math.round(-2.505*100)/100 === -2.5  (Swift's would be -2.51)
        #expect(SliderPresentation.readoutText(-2.505) == "-2.5")
        #expect(SliderPresentation.readoutText(-2.515) == "-2.51")
        #expect(SliderPresentation.readoutText(0.1 + 0.2) == "0.3")
        // Six significant digits is where `%g` gave up.
        #expect(SliderPresentation.readoutText(123_456.7) == "123456.7")
        #expect(SliderPresentation.readoutText(1_234_567.89) == "1234567.89")
        #expect(SliderPresentation.readoutText(12_345_678) == "12345678")
    }

    /// `props.value ?? props.defaultValue ?? [props.min]` - nullish, so an
    /// explicit null falls through but an EMPTY ARRAY does not.
    @Test func sliderSeedFollowsTheNullishChain() {
        let value = PropValue.array([.number(9)])
        let fallback = PropValue.array([.number(4)])
        #expect(FieldSeeding.sliderSeed(value: value, defaultValue: fallback, min: 1) == value)
        #expect(FieldSeeding.sliderSeed(value: nil, defaultValue: fallback, min: 1) == fallback)
        #expect(FieldSeeding.sliderSeed(value: .null, defaultValue: fallback, min: 1) == fallback)
        #expect(
            FieldSeeding.sliderSeed(value: nil, defaultValue: nil, min: 1) == .array([.number(1)]))
        #expect(
            FieldSeeding.sliderSeed(value: nil, defaultValue: .null, min: 1)
                == .array([.number(1)]))
        // An empty array is not nullish: it wins over the min.
        #expect(FieldSeeding.sliderSeed(value: .array([]), defaultValue: nil, min: 1) == .array([]))
    }

    // MARK: - Buttons

    @Test func buttonsAreARowUnlessTheDirectionSaysColumn() {
        #expect(ButtonsPresentation.isColumn(direction: "column"))
        #expect(!ButtonsPresentation.isColumn(direction: "row"))
        #expect(!ButtonsPresentation.isColumn(direction: nil))
        #expect(!ButtonsPresentation.isColumn(direction: "Column"))  // case-sensitive
    }

    // MARK: - Text styles

    /// SwiftUI's `lineSpacing` is the GAP; RN's `lineHeight` is the BOX.
    @Test func extraLineSpacingIsTheGapNotTheBox() {
        #expect(CdsMetrics.Typography.calloutTitle.extraLineSpacing == 19 - 14)
        // No declared lineHeight: add nothing, keep the system leading.
        #expect(CdsMetrics.Typography.headerSubtitle.extraLineSpacing == 0)
        // A lineHeight tighter than the font must clamp to 0, not go negative.
        #expect(
            CdsMetrics.TextStyle(fontSize: 20, lineHeight: 12).extraLineSpacing == 0)
        #expect(CdsMetrics.TextStyle(fontSize: 20, lineHeight: 20).extraLineSpacing == 0)
    }
}
