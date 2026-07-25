import Foundation
import OpenUILang
import Testing

@testable import AppLessCore

@Suite struct PropDecodingTests {

    private func element(
        _ component: String,
        _ props: [String: PropValue] = [:],
        children: PropValue? = nil
    ) -> ElementNode {
        ElementNode(component: component, props: props, children: children)
    }

    @Test func scalarReadsAreTypeSafe() {
        let node = element(
            "CardHeader",
            ["title": .string("Today"), "subtitle": .number(3), "extra": .null])
        let p = PropReader(node)
        #expect(p.string("title") == "Today")
        #expect(p.string("subtitle") == nil)  // wrong type -> nil, not a crash
        #expect(p.number("subtitle") == 3)
        #expect(p.int("subtitle") == 3)
        #expect(p.string("missing") == nil)
        #expect(p.value("extra") == .null)
        #expect(p.renderable == .CardHeader)
        #expect(p.component == "CardHeader")
    }

    @Test func truthinessMatchesJS() {
        #expect(PropValue.string("").isJSTruthy == false)
        #expect(PropValue.string("x").isJSTruthy == true)
        #expect(PropValue.number(0).isJSTruthy == false)
        #expect(PropValue.number(.nan).isJSTruthy == false)
        #expect(PropValue.number(1).isJSTruthy == true)
        #expect(PropValue.bool(false).isJSTruthy == false)
        #expect(PropValue.null.isJSTruthy == false)
        #expect(PropValue.array([]).isJSTruthy == true)  // JS: [] is truthy

        let node = element("ListBlock", ["header": .string("")])
        #expect(PropReader(node).isTruthy("header") == false)
        #expect(PropReader(node).isTruthy("absent") == false)
    }

    @Test func nonFiniteNumbersAreRejectedWhereItMatters() {
        #expect(PropValue.number(.infinity).numberValue == .infinity)
        #expect(PropValue.number(.infinity).finiteNumberValue == nil)
        #expect(PropValue.number(.nan).intValue == nil)
        let node = element("Slider", ["values": .array([.number(1), .number(.nan), .number(2)])])
        #expect(PropReader(node).numbers("values") == [1, 2])
    }

    @Test func enumPropsFallBackWhenUnknown() {
        let node = element("BarChart", ["variant": .string("sideways")])
        let p = PropReader(node)
        #expect(p.enumString("variant", allowed: ["grouped", "stacked"]) == nil)
        let ok = PropReader(element("BarChart", ["variant": .string("stacked")]))
        #expect(ok.enumString("variant", allowed: ["grouped", "stacked"]) == "stacked")
    }

    @Test func seriesDecodesAndClampsNegatives() {
        let chart = element(
            "BarChart",
            [
                "labels": .array([.string("Mon"), .string("Tue")]),
                "series": .array([
                    .element(element("Series", [
                        "category": .string("Spend"),
                        "values": .array([.number(4), .number(-2)]),
                    ])),
                    .string("junk"),  // dropped
                ]),
            ])
        let series = StructuralProps.series(of: chart)
        #expect(series.count == 1)
        #expect(series[0].category == "Spend")
        #expect(series[0].values == [4, 0])  // negatives clamp to 0
        #expect(PropReader(chart).strings("labels") == ["Mon", "Tue"])
    }

    @Test func selectItemsFallBackToValueForLabel() {
        let select = element(
            "Select",
            ["items": .array([
                .element(element("SelectItem", ["value": .string("in"), "label": .string("India")])),
                .element(element("SelectItem", ["value": .string("us")])),
            ])])
        let items = StructuralProps.selectItems(of: select)
        #expect(items == [
            .init(value: "in", label: "India"),
            .init(value: "us", label: "us"),
        ])
    }

    @Test func tabItemsCarryTheirChildren() {
        let tabs = element(
            "Tabs",
            ["items": .array([
                .element(element(
                    "TabItem",
                    ["label": .string("Today")],
                    children: .array([.element(element("CardHeader"))])
                ))
            ])])
        let items = StructuralProps.tabItems(of: tabs)
        #expect(items.count == 1)
        #expect(items[0].label == "Today")
        #expect(items[0].children.map(\.component) == ["CardHeader"])
    }

    @Test func placeholdersAreNotRenderableComponents() {
        for name in ContractSchema.structuralPlaceholders {
            #expect(RenderableComponent(rawValue: name) == nil, "\(name)")
        }
        #expect(RenderableComponent(rawValue: "Nonsense") == nil)
        #expect(RenderableComponent(rawValue: "Card") == .Card)
    }
}
