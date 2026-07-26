import Foundation
import OpenUILang
import Testing

@testable import AppLessCore

/// `JSNumber.string` and the two coercions built on it.
///
/// The expectations below are node output, not a restatement of the Swift
/// implementation: every pair was produced by running
///
///     node -e 'for (const x of [...]) console.log(JSON.stringify(String(x)))'
///
/// on node v22.22.2 and pasted in. That matters because the naive ports of
/// this algorithm all pass the easy cases and fail exactly at the thresholds
/// pinned here.
@Suite struct JSValueTests {

    /// The three regions of `Number::toString`: positional, positional with a
    /// decimal point, and exponential, plus the two thresholds (1e21 and
    /// 1e-7) where the region changes.
    @Test func numberStringMatchesNode() {
        let cases: [(Double, String)] = [
            // Integers below 2^53 - the exact-expansion fast path.
            (0, "0"),
            (1, "1"),
            (-1, "-1"),
            (100, "100"),
            (1_000_000, "1000000"),
            (12_345_678, "12345678"),
            // Fractions.
            (2.5, "2.5"),
            (0.1, "0.1"),
            (0.5, "0.5"),
            (-0.5, "-0.5"),
            (3.14, "3.14"),
            (255.05, "255.05"),
            (12.345, "12.345"),
            (1.0 / 3.0, "0.3333333333333333"),
            (0.1 + 0.2, "0.30000000000000004"),
            // The magnitudes `%g` used to destroy.
            (123_456.7, "123456.7"),
            (1_234_567.89, "1234567.89"),
            (-1_234_567.89, "-1234567.89"),
            // Positional up to and including 1e20; exponential from 1e21.
            (1e16, "10000000000000000"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (1.5e21, "1.5e+21"),
            (1e23, "1e+23"),
            // Positional down to 1e-6; exponential from 1e-7.
            (1e-5, "0.00001"),
            (1e-6, "0.000001"),
            (1e-7, "1e-7"),
            (1e-21, "1e-21"),
            (.leastNonzeroMagnitude, "5e-324"),  // 5e-324, the smallest subnormal
            // At/above 2^53 ECMAScript prints the SHORTEST round-trip digits,
            // not the exact expansion - an Int64 fast path that ran here would
            // print 72057594037927936 for 2^56.
            (9_007_199_254_740_992, "9007199254740992"),
            // 2^53 + 1 is not representable; the nearest Double is 2^53, and
            // node prints that. Built from an Int64 so the literal itself is
            // exact and the conversion is the thing under test.
            (Double(9_007_199_254_740_993 as Int64), "9007199254740992"),
            (72_057_594_037_927_936, "72057594037927940"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
        ]
        for (input, expected) in cases {
            #expect(JSNumber.string(input) == expected, "String(\(input))")
        }
    }

    /// `String(-0) === "0"`, and the non-finites stringify as themselves
    /// (which is where this differs from `JSON.stringify`, whose answer for
    /// all three is `null`).
    @Test func numberStringHandlesTheSpecialValues() {
        #expect(JSNumber.string(-0.0) == "0")
        #expect(JSNumber.string(.nan) == "NaN")
        #expect(JSNumber.string(.infinity) == "Infinity")
        #expect(JSNumber.string(-.infinity) == "-Infinity")
    }

    /// The one that mattered: `%g` truncates to six significant digits and
    /// switches to exponent notation, so this is the regression guard for the
    /// slider read-out.
    @Test func numberStringIsNotPrintfG() {
        #expect(String(format: "%g", 123_456.7) == "123457")  // what it used to print
        #expect(JSNumber.string(123_456.7) == "123456.7")  // what RN prints
        #expect(String(format: "%g", 1_234_567.89) == "1.23457e+06")
        #expect(JSNumber.string(1_234_567.89) == "1234567.89")
    }

    // MARK: - React text children

    /// React renders strings and numbers; it skips `null`, `undefined` and
    /// BOTH booleans. `0` is falsy but still renders - which is exactly why
    /// `jsText` and `isJSTruthy` have to be different functions.
    @Test func jsTextRendersOnlyWhatReactRenders() {
        #expect(PropValue.string("hi").jsText == "hi")
        #expect(PropValue.string("").jsText == "")
        #expect(PropValue.number(0).jsText == "0")
        #expect(PropValue.number(1_234_567.89).jsText == "1234567.89")
        #expect(PropValue.number(.nan).jsText == "NaN")
        #expect(PropValue.null.jsText == nil)
        #expect(PropValue.bool(true).jsText == nil)
        #expect(PropValue.bool(false).jsText == nil)
        #expect(PropValue.array([.string("a")]).jsText == nil)
        #expect(PropValue.object(["a": .string("b")]).jsText == nil)

        // Falsy-but-rendering vs truthy-but-not-rendering, the two cases a
        // single predicate would get wrong.
        #expect(PropValue.number(0).isJSTruthy == false)
        #expect(PropValue.number(0).jsText == "0")
        #expect(PropValue.bool(true).isJSTruthy == true)
        #expect(PropValue.bool(true).jsText == nil)
    }

    /// `String(v)` is a DIFFERENT function from "what React paints": it
    /// stringifies booleans and null, which React drops. `readSeries` uses it
    /// (`String(p.category ?? "")`), the renderers do not.
    ///
    /// Node:
    ///   String(true) "true" | String(null) "null" | String([1,null,2]) "1,,2"
    ///   String({}) "[object Object]"
    @Test func jsStringCoercedIsTheExplicitConversion() {
        #expect(PropValue.bool(true).jsStringCoerced == "true")
        #expect(PropValue.bool(false).jsStringCoerced == "false")
        #expect(PropValue.null.jsStringCoerced == "null")
        #expect(PropValue.number(1_234_567.89).jsStringCoerced == "1234567.89")
        #expect(PropValue.string("x").jsStringCoerced == "x")
        #expect(
            PropValue.array([.number(1), .null, .number(2)]).jsStringCoerced == "1,,2")
        #expect(PropValue.object(["a": .number(1)]).jsStringCoerced == "[object Object]")
    }

    /// `??` tests nullish, not falsy: an explicit `null` category falls back
    /// to `""` while `0` and `false` do not.
    @Test func coercedAppliesTheNullishTestBeforeStringifying() {
        let node = ElementNode(
            component: "Series",
            props: [
                "nulled": .null,
                "zero": .number(0),
                "no": .bool(false),
                "text": .string("Spend"),
            ])
        let p = PropReader(node)
        #expect(p.coerced("nulled") == "")
        #expect(p.coerced("absent") == "")
        #expect(p.coerced("zero") == "0")
        #expect(p.coerced("no") == "false")
        #expect(p.coerced("text") == "Spend")
        #expect(p.coerced("absent", or: "fallback") == "fallback")
    }

    /// The whole point of the `text(_:)` reader: a numeric prop used to read
    /// as `nil` and paint an empty view.
    @Test func propReaderTextKeepsNumbersThatStringWouldDrop() {
        let hero = ElementNode(component: "HeroStat", props: ["value": .number(1234)])
        let p = PropReader(hero)
        #expect(p.string("value") == nil)  // the old read - an empty hero
        #expect(p.text("value") == "1234")
        #expect(p.text("missing") == nil)
    }

    /// A `Series` category coerces (RN calls `String(...)`), so a number keeps
    /// its digits and an explicit null becomes the empty legend entry.
    @Test func seriesCategoryUsesTheExplicitCoercion() {
        func chart(_ category: PropValue?) -> ElementNode {
            var props: [String: PropValue] = ["values": .array([.number(1)])]
            if let category { props["category"] = category }
            return ElementNode(
                component: "BarChart",
                props: ["series": .array([.element(ElementNode(component: "Series", props: props))])]
            )
        }
        #expect(StructuralProps.series(of: chart(.string("Spend")))[0].category == "Spend")
        #expect(StructuralProps.series(of: chart(.number(2024)))[0].category == "2024")
        #expect(StructuralProps.series(of: chart(.bool(true)))[0].category == "true")
        #expect(StructuralProps.series(of: chart(.null))[0].category == "")
        #expect(StructuralProps.series(of: chart(nil))[0].category == "")
    }
}
