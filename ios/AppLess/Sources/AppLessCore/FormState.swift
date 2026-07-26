//
//  FormState.swift
//  AppLessCore
//
//  The form-state model the Cupertino form renderers bind into, ported from
//  react-lang's state store as `src/genos/ui/shared/forms.ts` uses it
//  (`useFieldState`) and as `spec/openui-lang.md` §9.4 specifies the payload.
//
//  Field values are stored per FORM NAME, in UI insertion order, and are
//  wrapped `{ value, componentType }` on the way out - that wrapper is what the
//  model actually receives in "Submitted form values: {...}".
//
//  NO SwiftUI in this file: `AppLessUI` wraps this in an `ObservableObject`.
//

import Foundation
import GenOSCore
import OpenUILang

/// `GenOSCore`'s JSON model.
///
/// Both of AppLess's dependencies export a type called `JSONValue`
/// (`OpenUILang.JSONValue` for fixture trees, `GenOSCore.JSONValue` for request
/// bodies and form state), and this target imports both - so the bare name is
/// ambiguous. Form state and action params are request-shaped, hence GenOSCore's.
public typealias GenosJSONValue = GenOSCore.JSONValue

// MARK: - Field values

/// A value a GenOS input can hold. `Slider` writes `[Double]` (react-lang's
/// range-slider convention, `forms.tsx` L195-196); every other input writes a
/// string.
public enum FormValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case numbers([Double])
    case bool(Bool)
    case null

    /// The value as it is serialized into the request JSON.
    public var jsonValue: GenosJSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .numbers(let ns): return .array(ns.map { GenosJSONValue.number($0) })
        case .bool(let b): return .bool(b)
        case .null: return .null
        }
    }

    /// `typeof field.value === "string" ? field.value : ""` - the guard every
    /// text input in `forms.tsx` applies before handing the value to `TextInput`.
    public var textValue: String {
        if case .string(let s) = self { return s }
        return ""
    }

    /// `Array.isArray(field.value) ? ... : undefined` for the Slider.
    public var numbersValue: [Double]? {
        switch self {
        case .numbers(let ns): return ns
        case .number(let n): return [n]
        default: return nil
        }
    }

    /// Seed a field from the model-supplied `value` / `defaultValue` prop.
    /// Returns `nil` for `undefined`-like props (absent or explicit `null`), so
    /// an unseeded field stays absent from form state instead of submitting
    /// `null`.
    public init?(seed: PropValue?) {
        switch seed {
        case .none, .some(.null):
            return nil
        case .some(.string(let s)):
            self = .string(s)
        case .some(.number(let n)):
            self = .number(n)
        case .some(.bool(let b)):
            self = .bool(b)
        case .some(.array(let items)):
            let numbers = items.compactMap(\.finiteNumberValue)
            guard numbers.count == items.count, !numbers.isEmpty else { return nil }
            self = .numbers(numbers)
        default:
            return nil
        }
    }
}

// MARK: - The store

/// Every named input's value, grouped by the enclosing `Form`'s `name`.
///
/// Insertion order is preserved per form because the request JSON must list
/// fields in UI order (`Controller.resolveAction` takes an ORDERED pair list
/// for exactly this reason).
public struct FormStateModel: Sendable, Equatable {

    /// One bound input.
    public struct Field: Sendable, Equatable {
        public let name: String
        /// The contract component that owns the field - `"Input"`, `"Select"`,
        /// `"Slider"`, … It ships to the model inside the value wrapper.
        public let componentType: String
        public var value: FormValue

        public init(name: String, componentType: String, value: FormValue) {
            self.name = name
            self.componentType = componentType
            self.value = value
        }

        /// `{ value, componentType }` - `spec/openui-lang.md` §9.4 step 1.
        public var wrapped: GenosJSONValue {
            .object(["value": value.jsonValue, "componentType": .string(componentType)])
        }
    }

    /// Fields written outside any `Form` land here (react-lang's `useFormName()`
    /// is undefined there); kept as its own bucket so a bare `Button` still
    /// submits them in the whole-store snapshot.
    public static let unscopedFormName = ""

    private var formOrder: [String] = []
    private var fieldsByForm: [String: [Field]] = [:]

    public init() {}

    // MARK: Reads

    /// Form names in the order their first field was written.
    public var formNames: [String] { formOrder }

    /// Fields of one form, in insertion order.
    public func fields(in form: String) -> [Field] { fieldsByForm[form] ?? [] }

    public func field(form: String, name: String) -> Field? {
        fieldsByForm[form]?.first { $0.name == name }
    }

    public func value(form: String, name: String) -> FormValue? {
        field(form: form, name: name)?.value
    }

    public var isEmpty: Bool { formOrder.isEmpty }

    // MARK: Writes

    /// Write a field, creating it (and its form bucket) if needed. An existing
    /// field keeps its position - this is `setFieldValue`.
    public mutating func set(
        form: String,
        name: String,
        componentType: String,
        value: FormValue
    ) {
        var fields = fieldsByForm[form] ?? []
        if fields.isEmpty, !formOrder.contains(form) { formOrder.append(form) }
        if let index = fields.firstIndex(where: { $0.name == name }) {
            fields[index].value = value
        } else {
            fields.append(Field(name: name, componentType: componentType, value: value))
        }
        fieldsByForm[form] = fields
    }

    /// Seed a model-supplied default, but only when the field has no value yet
    /// - `useSetDefaultValue` (`shared/forms.ts` L24-30).
    ///
    /// - Returns: `true` when the seed was applied.
    @discardableResult
    public mutating func seedDefault(
        form: String,
        name: String,
        componentType: String,
        value: FormValue
    ) -> Bool {
        guard field(form: form, name: name) == nil else { return false }
        set(form: form, name: name, componentType: componentType, value: value)
        return true
    }

    /// `@Reset($a, $b, …)` - drop the named fields back to "not set".
    /// Passing no names clears the whole form.
    public mutating func reset(form: String, names: [String] = []) {
        guard var fields = fieldsByForm[form] else { return }
        if names.isEmpty {
            fields = []
        } else {
            fields.removeAll { names.contains($0.name) }
        }
        if fields.isEmpty {
            fieldsByForm[form] = nil
            formOrder.removeAll { $0 == form }
        } else {
            fieldsByForm[form] = fields
        }
    }

    // MARK: Payload

    /// One form as `{ field: { value, componentType }, … }`, fields in UI
    /// insertion order.
    ///
    /// react-lang writes the field level as `{ ...formData, [name]: wrapped }`
    /// (`hooks/useOpenUIState.js` `setFieldValue`), so a new field is appended
    /// and an overwritten one keeps its original position. A Swift
    /// `Dictionary` here would serialize SORTED and silently reorder the
    /// "Submitted form values: {…}" bytes, so this builds `GenOSCore`'s
    /// insertion-ordered `JSONObject` instead.
    public func payloadObject(form: String) -> GenosJSONValue {
        var object = GenOSCore.JSONObject()
        for field in fields(in: form) { object[field.name] = field.wrapped }
        return .object(object)
    }

    /// The `formState` an ActionEvent carries (`spec/openui-lang.md` §9.4 step 1):
    /// with a `formName` that HAS data, just that form; otherwise the whole
    /// store snapshot.
    ///
    /// Returned as an ordered pair list because `GenOSCore.Controller`
    /// `resolveAction(parentId:message:formState:)` serializes it with
    /// `GenosJSONValue.stringifyOrdered`, preserving insertion order like
    /// `JSON.stringify` does.
    public func payload(formName: String?) -> OrderedJSON {
        if let formName, !fields(in: formName).isEmpty {
            return OrderedJSON([(formName, payloadObject(form: formName))])
        }
        return OrderedJSON(formOrder.map { ($0, payloadObject(form: $0)) })
    }
}

// MARK: - Ordered JSON

/// A JSON object whose key order is meaningful - the shape
/// `Controller.resolveAction` consumes.
///
/// A Swift `Dictionary` cannot express it and a `[(String, GenosJSONValue)]` is not
/// `Equatable`, so the pairs are stored as two parallel arrays.
public struct OrderedJSON: Sendable, Equatable {
    public private(set) var keys: [String]
    public private(set) var values: [GenosJSONValue]

    public init() {
        keys = []
        values = []
    }

    public init(_ pairs: [(String, GenosJSONValue)]) {
        keys = pairs.map { $0.0 }
        values = pairs.map { $0.1 }
    }

    /// The pair list `Controller.resolveAction(parentId:message:formState:)` takes.
    public var pairs: [(String, GenosJSONValue)] { Array(zip(keys, values)) }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public subscript(key: String) -> GenosJSONValue? {
        keys.firstIndex(of: key).map { values[$0] }
    }

    /// `JSON.stringify(formState)` with insertion order preserved at the top level.
    public var stringified: String { GenosJSONValue.stringifyOrdered(pairs) }
}
