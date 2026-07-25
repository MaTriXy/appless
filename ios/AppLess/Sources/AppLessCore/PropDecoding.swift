//
//  PropDecoding.swift
//  AppLessCore
//
//  Prop-reading helpers over `OpenUILang.PropValue` / `ElementNode`.
//
//  The renderers live in `AppLessUI`, but decoding a prop bag is pure data
//  work, so it lives here where Linux can test it. Everything follows the RN
//  renderers' defensive style: a wrong-typed or missing prop yields `nil` or
//  the caller's default, never a crash - the model can emit anything.
//

import Foundation
import OpenUILang

// MARK: - PropValue accessors

extension PropValue {
    /// The string payload, or `nil` for any other case.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The number payload, or `nil`. Non-finite values (`NaN`, `±Infinity`)
    /// are returned as-is; use ``finiteNumberValue`` to reject them.
    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The number payload if it is finite.
    public var finiteNumberValue: Double? {
        numberValue.flatMap { $0.isFinite ? $0 : nil }
    }

    /// The number payload truncated to `Int`, if finite and representable.
    public var intValue: Int? {
        guard let n = finiteNumberValue,
              n >= Double(Int.min), n <= Double(Int.max)
        else { return nil }
        return Int(n)
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The array payload, or `[]` for any other case - matches the RN guard
    /// `Array.isArray(props.items) ? props.items : []`.
    public var arrayValue: [PropValue] {
        if case .array(let items) = self { return items }
        return []
    }

    public var objectValue: PropObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var elementValue: ElementNode? {
        if case .element(let e) = self { return e }
        return nil
    }

    public var actionValue: ActionPlan? {
        if case .action(let a) = self { return a }
        return nil
    }

    /// JS truthiness, as the RN renderers use it (`!!props.header`,
    /// `props.on ? ... : ...`): `null`, `false`, `0`, `NaN` and `""` are falsy;
    /// everything else - including empty arrays and objects - is truthy.
    public var isJSTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object, .element, .action, .ast: return true
        }
    }

    /// Elements directly inside this value, flattening a single level of
    /// array - the shape `children` and list props arrive in. Non-element
    /// entries are dropped, mirroring the RN `.filter(Boolean)` guards.
    public var childElements: [ElementNode] {
        switch self {
        case .element(let e): return [e]
        case .array(let items): return items.compactMap { $0.elementValue }
        default: return []
        }
    }
}

// MARK: - Element prop reader

/// Typed reads over one element's props.
///
/// ```swift
/// let p = PropReader(node)
/// let title = p.string("title") ?? ""
/// let zoom = p.int("zoom") ?? 15          // MapView default
/// let variant = p.enumString("variant", allowed: ["grouped", "stacked"]) ?? "grouped"
/// ```
public struct PropReader {
    public let node: ElementNode

    public init(_ node: ElementNode) { self.node = node }

    /// The component name, e.g. `"CardHeader"`.
    public var component: String { node.component }

    /// The component as a ``RenderableComponent``, or `nil` for the three
    /// structural placeholders and for anything outside the contract.
    public var renderable: RenderableComponent? { RenderableComponent(rawValue: node.component) }

    /// Raw prop, `nil` if absent. `undefined` props are already dropped by the
    /// parser; an explicit `null` comes back as `.null`.
    public func value(_ key: String) -> PropValue? { node.props[key] }

    public func string(_ key: String) -> String? { value(key)?.stringValue }
    public func number(_ key: String) -> Double? { value(key)?.finiteNumberValue }
    public func int(_ key: String) -> Int? { value(key)?.intValue }
    public func bool(_ key: String) -> Bool? { value(key)?.boolValue }
    public func array(_ key: String) -> [PropValue] { value(key)?.arrayValue ?? [] }
    public func object(_ key: String) -> PropObject? { value(key)?.objectValue }
    public func action(_ key: String) -> ActionPlan? { value(key)?.actionValue }

    /// `true` when the prop is present AND JS-truthy - the `!!props.subtitle`
    /// test the RN renderers use before showing optional text.
    public func isTruthy(_ key: String) -> Bool { value(key)?.isJSTruthy ?? false }

    /// A string prop constrained to a set of contract enum values; anything
    /// else (wrong type, unknown case) reads as `nil` so callers fall back to
    /// the documented default.
    public func enumString(_ key: String, allowed: Set<String>) -> String? {
        guard let s = string(key), allowed.contains(s) else { return nil }
        return s
    }

    /// Strings from an array-of-strings prop (`Chips.labels`, chart `labels`),
    /// dropping non-strings.
    public func strings(_ key: String) -> [String] {
        array(key).compactMap(\.stringValue)
    }

    /// Finite numbers from an array-of-numbers prop, dropping the rest.
    public func numbers(_ key: String) -> [Double] {
        array(key).compactMap(\.finiteNumberValue)
    }

    /// Child elements of an array-of-elements prop, optionally filtered to one
    /// component type (`items` for Tabs/Select, `series` for the charts).
    public func elements(_ key: String, component: String? = nil) -> [ElementNode] {
        let all = (value(key)?.childElements ?? [])
        guard let component else { return all }
        return all.filter { $0.component == component }
    }

    /// The `children` slot (Card, TabItem), flattened to elements.
    public var children: [ElementNode] { node.children?.childElements ?? [] }
}

// MARK: - Structural placeholders

/// Decoders for the three components that never render themselves - their
/// parent consumes them (`src/genos/ui/contract.tsx`: `component: () => null`).
public enum StructuralProps {

    /// `Series(category, values)` - consumed by the five chart components.
    public struct Series: Sendable, Equatable {
        public let category: String
        /// Chart values must be non-negative; negatives are clamped to 0
        /// (contract note, "Stats & Charts" group).
        public let values: [Double]

        public init(category: String, values: [Double]) {
            self.category = category
            self.values = values
        }
    }

    /// `SelectItem(value, label)` - consumed by `Select`.
    public struct SelectItem: Sendable, Equatable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// `TabItem(label, children)` - consumed by `Tabs`.
    public struct TabItem: Sendable, Equatable {
        public let label: String
        public let children: [ElementNode]

        public init(label: String, children: [ElementNode]) {
            self.label = label
            self.children = children
        }
    }

    /// Decode the `series` prop of any cartesian/pie chart.
    public static func series(of node: ElementNode) -> [Series] {
        PropReader(node).elements("series", component: "Series").map { element in
            let p = PropReader(element)
            return Series(
                category: p.string("category") ?? "",
                values: p.numbers("values").map(clampChartValue)
            )
        }
    }

    /// Decode the `items` prop of `Select`. `label` falls back to `value`,
    /// matching `forms.tsx` L157 (`it.label ?? it.value`).
    public static func selectItems(of node: ElementNode) -> [SelectItem] {
        PropReader(node).elements("items", component: "SelectItem").map { element in
            let p = PropReader(element)
            let value = p.string("value") ?? ""
            return SelectItem(value: value, label: p.string("label") ?? value)
        }
    }

    /// Decode the `items` prop of `Tabs`.
    public static func tabItems(of node: ElementNode) -> [TabItem] {
        PropReader(node).elements("items", component: "TabItem").map { element in
            let p = PropReader(element)
            return TabItem(label: p.string("label") ?? "", children: p.children)
        }
    }

    /// "Chart values must be non-negative - negative numbers are clamped to 0."
    /// (`src/genos/ui/contract.tsx`, Stats & Charts group notes.)
    public static func clampChartValue(_ value: Double) -> Double { max(0, value) }
}
