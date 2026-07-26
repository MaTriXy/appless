//
//  JSValue.swift
//  AppLessCore
//
//  The two JavaScript semantics the renderers depend on and Swift does not
//  have: `String(number)` and "what does React actually paint for this child".
//
//  Both used to be implicit in the SwiftUI layer - `String(format: "%g", …)`
//  for the slider read-out, `p.string("title") ?? ""` everywhere else - and
//  both got the answer wrong for inputs the model can really emit. They are
//  values, so they live here where a Linux test can pin them against node.
//
//  NO SwiftUI in this file.
//

import Foundation
import OpenUILang

// MARK: - Number → String

/// ECMAScript `Number::toString` (§6.1.6.1.20) for the cases a renderer can
/// hit.
///
/// Swift's own `"\(d)"` is shortest-round-trip like JS, but its
/// positional/exponential thresholds and exponent spelling differ (`1e+16`
/// where JS writes `10000000000000000`, `1e-05` where JS writes `0.00001`,
/// `1e-07` where JS writes `1e-7`), so the shortest digits are re-rendered
/// here under the spec's rules.
///
/// This is a deliberate re-implementation of the algorithm already verified in
/// `OpenUILang.TreeSerializer.formatNumber` / `GenOSCore.JSONValue.numberString`;
/// both are `internal` to their packages, so `AppLessCore` cannot call either.
/// ``JSValueTests`` pins this copy against a node-generated table, including
/// the 1e21 / 1e-7 thresholds and the 2^53 shortest-digits boundary where a
/// naive exact-expansion port diverges.
public enum JSNumber {

    /// `String(n)`. `NaN` / `±Infinity` stringify as themselves (unlike
    /// `JSON.stringify`, which emits `null`), because that is what React would
    /// paint into a `<Text>`.
    public static func string(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
        if n == 0 { return "0" }  // String(-0) === "0"

        // Integer fast path, valid only below 2^53: there every integer is
        // exactly representable, so the exact decimal expansion IS the
        // shortest round-trip form. At or above 2^53 ECMAScript renders the
        // SHORTEST digits (`String(2 ** 56)` is `"72057594037927940"`, not
        // `"…936"`), so those fall through to the re-rendering below.
        if abs(n) < 9_007_199_254_740_992, let i = Int64(exactly: n) {
            return String(i)
        }

        let repr = "\(n)"  // Swift's shortest round-trip representation
        guard let eIndex = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            // Already positional and shortest; Swift only differs by the ".0"
            // it appends to integer-valued doubles (reachable at |n| >= 2^53).
            if repr.hasSuffix(".0") { return String(repr.dropLast(2)) }
            return repr
        }

        var mantissa = String(repr[repr.startIndex..<eIndex])
        let exponent = Int(repr[repr.index(after: eIndex)...]) ?? 0
        var sign = ""
        if mantissa.hasPrefix("-") {
            sign = "-"
            mantissa.removeFirst()
        }
        var digits = mantissa
        var pointOffset = mantissa.count
        if let dot = mantissa.firstIndex(of: ".") {
            pointOffset = mantissa.distance(from: mantissa.startIndex, to: dot)
            digits.remove(at: dot)
        }
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }

        let k = digits.count
        // n in the spec's terms: value == 0.<digits> * 10^n
        let power = exponent + pointOffset
        if k <= power && power <= 21 {
            return sign + digits + String(repeating: "0", count: power - k)
        }
        if 0 < power && power <= 21 {
            return sign + String(digits.prefix(power)) + "." + String(digits.dropFirst(power))
        }
        if -6 < power && power <= 0 {
            return sign + "0." + String(repeating: "0", count: -power) + digits
        }
        let first = String(digits.prefix(1))
        let rest = String(digits.dropFirst())
        let e = power - 1
        let exponentPart = (e >= 0 ? "e+" : "e-") + String(abs(e))
        return sign + first + (rest.isEmpty ? "" : "." + rest) + exponentPart
    }
}

// MARK: - React text children

extension PropValue {

    /// What React paints for `<Text>{prop}</Text>`, or `nil` when it paints
    /// nothing.
    ///
    /// React renders only string and number children. `null`, `undefined` and
    /// **booleans** are skipped entirely (`<Text>{false}</Text>` is empty, and
    /// so is `<Text>{true}</Text>`), while `0` renders as `"0"`. Objects throw
    /// ("Objects are not valid as a React child"), which in a rendered screen
    /// is indistinguishable from an unrenderable prop, so they read as `nil`
    /// rather than crashing the port.
    ///
    /// This is NOT the same as ``isJSTruthy``: `0` and `""` are falsy but
    /// still render, which is why the RN renderers spell the two tests
    /// separately (`!!props.subtitle && <Text>{props.subtitle}</Text>`).
    public var jsText: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JSNumber.string(n)
        case .null, .bool: return nil
        case .array, .object, .element, .action, .ast: return nil
        }
    }
}

extension PropValue {

    /// `value == null` in JS - the test the `??` operator makes. An absent prop
    /// is dropped by the parser, so `.null` is the only nullish `PropValue`.
    public var isJSNullish: Bool {
        if case .null = self { return true }
        return false
    }

    /// `String(value)` - the EXPLICIT coercion, which is a different function
    /// from ``jsText``.
    ///
    /// `readSeries` writes `String(p.category ?? "")` (`shared/charts.tsx`
    /// L47), so a boolean category becomes the text `"true"` there, while the
    /// same boolean handed straight to a `<Text>` as a child renders nothing.
    /// Objects stringify as `"[object Object]"`; arrays join their elements.
    public var jsStringCoerced: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSNumber.string(n)
        case .string(let s): return s
        case .array(let items):
            // Array.prototype.join(","): null/undefined elements become "".
            return items.map { item in
                if case .null = item { return "" }
                return item.jsStringCoerced
            }.joined(separator: ",")
        case .object, .element, .action, .ast: return "[object Object]"
        }
    }
}

extension PropReader {

    /// The prop as React would paint it - the read every renderer that
    /// interpolates a prop into a `Text` should use.
    ///
    /// `p.string("value")` was the old spelling and silently dropped a number:
    /// `HeroStat(1234)` painted an empty hero. `p.text("value")` paints
    /// `"1234"`, which is what `<Text>{props.value}</Text>` does.
    public func text(_ key: String) -> String? { value(key)?.jsText }

    /// `String(props[key] ?? fallback)` - the explicit coercion, with `??`'s
    /// nullish test applied first.
    public func coerced(_ key: String, or fallback: String = "") -> String {
        guard let value = value(key), !value.isJSNullish else { return fallback }
        return value.jsStringCoerced
    }
}
