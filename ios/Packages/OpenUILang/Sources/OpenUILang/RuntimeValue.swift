import Foundation

/// A plain object with JS-like insertion-ordered keys (last-write keeps the
/// original key position, like JS object assignment).
struct RTObject {
    /// Own keys in INSERTION order — the raw slot list, before
    /// `OrdinaryOwnPropertyKeys` hoists the canonical array indices.
    private(set) var insertionKeys: [String] = []
    /// Keyed on `JSKey` (UTF-16 code-unit identity): JS object properties are
    /// code-unit exact, and program text can produce canonically-equal but
    /// code-unit-different keys (string-literal object keys, e.g. NFC vs NFD
    /// "café") that must stay distinct.
    private var storage: [JSKey: RTValue] = [:]

    /// The object's `[[Prototype]]`. A plain object literal starts at
    /// `Object.prototype`; `assign`ing `"__proto__"` re-points it, and `.null`
    /// means a genuinely prototype-less object.
    ///
    /// This slot is what makes lang-core's duck-typing (`isASTNode`,
    /// `isElementNode`, `containsDynamicValue`, the serializer's `isAstNode`)
    /// see through a `{"__proto__": …}` entry — see `JSObjects`.
    var prototype: RTValue = .proto(.object)

    init() {}
    init(_ pairs: [(String, RTValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    subscript(key: String) -> RTValue? {
        get { storage[JSKey(key)] }
        set {
            let k = JSKey(key)
            guard let newValue else {
                if storage.removeValue(forKey: k) != nil {
                    insertionKeys.removeAll { jsStringEquals($0, key) }
                }
                return
            }
            if storage[k] == nil { insertionKeys.append(key) }
            storage[k] = newValue
        }
    }

    /// Own keys in `Object.keys(o)` / `OrdinaryOwnPropertyKeys` order — every
    /// canonical array index FIRST in ascending numeric order, then the rest in
    /// insertion order.
    ///
    /// This is the runtime object, and its key order IS tree-observable: an
    /// `@Each` template that captures a row object runs it through
    /// `toLiteralAST` → `Obj.entries` → the `$ast` entries ARRAY, which the
    /// serializer emits verbatim (arrays are never sorted). Fixture
    /// `083-runtime-object-key-order`.
    var keys: [String] { jsOwnPropertyKeys(insertionKeys) }

    var entries: [(key: String, value: RTValue)] {
        keys.map { ($0, storage[JSKey($0)]!) }
    }
    var values: [RTValue] { keys.map { storage[JSKey($0)]! } }
    func has(_ key: String) -> Bool { storage[JSKey(key)] != nil }
    var isEmpty: Bool { insertionKeys.isEmpty }

    /// The one key JS object ASSIGNMENT never turns into an own property.
    static let protoKey = JSObjects.protoKey

    /// JS plain-object ASSIGNMENT (`o[key] = value`), which is NOT the same as
    /// defining an own property.
    ///
    /// A fresh `{}` inherits `Object.prototype`'s `__proto__` ACCESSOR, so
    /// `o["__proto__"] = v` invokes that setter, and the setter does NOT merely
    /// drop the key: for an object (or `null`) `v` it RE-POINTS the receiver's
    /// `[[Prototype]]`, which the whole duck-typing layer then reads through
    /// (fixtures `080-proto-object-key`, `085`–`087`). For a primitive `v` it
    /// does nothing at all. Either way `"__proto__"` never becomes an own
    /// property, so it never shows up in `Object.keys` / `JSON.stringify`.
    ///
    /// When the receiver no longer inherits that accessor (its chain was cut
    /// with `"__proto__": null`), assignment falls back to creating an ordinary
    /// own property.
    ///
    /// Use this at every site whose JS original is an assignment. Sites whose
    /// original is `Object.fromEntries` / `CreateDataPropertyOrThrow` keep
    /// using the subscript — those DO create an own `__proto__`
    /// (evaluator.js:40).
    mutating func assign(_ key: String, _ value: RTValue) {
        if key == RTObject.protoKey, JSObjects.inheritsProtoAccessor(.object(self)) {
            // ES 20.1.2.11 set Object.prototype.__proto__: object or null
            // re-points the prototype, anything else is a silent no-op.
            if value.isObjectOrFunction {
                prototype = value
            } else if case .null = value {
                prototype = .null
            }
            return
        }
        self[key] = value
    }
}

/// An element node in the materialized/evaluated tree
/// (lang-core `ElementNode`).
struct RTElement {
    var typeName: String
    var props: RTObject
    var partial: Bool
    var hasDynamicProps: Bool
    var statementId: String? = nil
}

/// A dynamically-typed runtime value mirroring the JS value space that flows
/// through materialization and evaluation (spec/openui-lang.md §8–§9).
/// `undefined` and `null` are distinct: `undefined` entries are omitted from
/// serialized objects while `null` entries are kept.
indirect enum RTValue {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RTValue])
    case object(RTObject)
    case element(RTElement)
    /// A leftover AST node (builtin call, runtime expression, deferred slot).
    case ast(ASTNode)
    /// A native function value, reachable by inheriting one from a prototype
    /// (`$obj.toString`, `$obj.constructor`). `typeof` is `"function"`, not
    /// `"object"`, and `JSON.stringify` drops it exactly like `undefined`.
    case function(name: String, arity: Int)
    /// One of the intrinsic prototype objects, reachable through the
    /// `Object.prototype.__proto__` GETTER (`$obj.__proto__`).
    case proto(JSProtoKind)

    var isNullish: Bool {
        switch self {
        case .undefined, .null: return true
        default: return false
        }
    }

    /// `typeof v === "object" && v !== null` in JS terms (AST nodes, arrays,
    /// elements, intrinsic prototypes and plain objects are all objects there).
    ///
    /// `.function` is deliberately EXCLUDED: `typeof fn` is `"function"`, which
    /// is what gates `containsDynamicValue`, `evaluatePropCore`'s early return
    /// and its plain-object `needsEval` scan.
    var isObjectLike: Bool {
        switch self {
        case .array, .object, .element, .ast, .proto: return true
        default: return false
        }
    }

    /// `Type(v) is Object` — `isObjectLike` plus functions.
    var isObjectOrFunction: Bool {
        if case .function = self { return true }
        return isObjectLike
    }

    /// `JSON.stringify` omits an object property whose value is `undefined` OR
    /// a FUNCTION (ES 25.5.2 SerializeJSONProperty returns undefined for both).
    /// Inside an ARRAY both become `null` instead.
    var isDroppedByJSONStringify: Bool {
        switch self {
        case .undefined, .function: return true
        default: return false
        }
    }
}

/// Convert a plain JSON value (e.g. a schema `default`) into the runtime
/// value space. Object keys are inserted in sorted order — JSON object key
/// order is not observable downstream (the serializer sorts keys), sorting
/// just keeps the RTObject deterministic.
func jsonToRTValue(_ v: JSONValue) -> RTValue {
    switch v {
    case .null:
        return .null
    case .bool(let b):
        return .bool(b)
    case .number(let n):
        return .number(n)
    case .string(let s):
        return .string(s)
    case .array(let items):
        return .array(items.map { jsonToRTValue($0) })
    case .object(let o):
        var out = RTObject()
        for key in o.keys.sorted() {
            out[key] = jsonToRTValue(o[key]!)
        }
        return .object(out)
    }
}

// MARK: - JS coercion helpers

/// A JS `TypeError` escaping a prop evaluation.
///
/// `String(obj)` is `ToPrimitive(obj, string)`: call `obj.toString()` if
/// callable, else `obj.valueOf()` if callable, else throw
/// `TypeError: Cannot convert object to primitive value`. This value model has
/// no function values, so an own `toString` key (whatever it holds — a number,
/// a string, null) is never callable and the lookup falls through to
/// `Object.prototype.valueOf`, which returns the object itself and is rejected
/// as non-primitive. So a plain object with an own `"toString"` key ALWAYS
/// throws; without one, `Object.prototype.toString` answers `"[object Object]"`.
/// `"valueOf"` alone never matters at the string hint — `toString` is tried
/// first and succeeds.
///
/// `Evaluator.evaluateElementProps` catches this per prop, keeps the RAW prop
/// value and records a `runtimeErrors` entry, exactly like `evaluate-tree.js`'s
/// try/catch. Fixture `081-tostring-shadow-throws`.
struct JSTypeError: Error {
    /// The V8 message text, reproduced verbatim in the `runtimeErrors` entry.
    let message: String

    static let cannotConvertObjectToPrimitive =
        JSTypeError(message: "Cannot convert object to primitive value")
}

/// ECMAScript Number-to-String (shortest round-trip); reuses the serializer's
/// formatter for finite values.
func jsNumberToString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    return TreeSerializer.formatNumber(d)
}

/// JS `Number(string)` semantics. Returns NaN for non-numeric strings.
/// ES *StrWhiteSpace* is exactly the `trim()` set (*WhiteSpace* ∪
/// *LineTerminator*; U+0085 NEL is NOT in it — former KNOWN-DEVIATION #7,
/// now fixed), so this reuses `jsTrim()` (Preprocess.swift), verified
/// empirically against node v22 `Number()` for every candidate scalar.
func jsStringToNumber(_ s: String) -> Double {
    let t = s.jsTrim()
    if t.isEmpty { return 0 }
    if t == "Infinity" || t == "+Infinity" { return .infinity }
    if t == "-Infinity" { return -.infinity }
    // Radix literals (no sign allowed).
    if t.hasPrefix("0x") || t.hasPrefix("0X") {
        return parseRadix(String(t.dropFirst(2)), radix: 16)
    }
    if t.hasPrefix("0o") || t.hasPrefix("0O") {
        return parseRadix(String(t.dropFirst(2)), radix: 8)
    }
    if t.hasPrefix("0b") || t.hasPrefix("0B") {
        return parseRadix(String(t.dropFirst(2)), radix: 2)
    }
    // Strict decimal literal: [+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?
    guard isStrictDecimalLiteral(t) else { return .nan }
    return Double(t) ?? .nan
}

private func parseRadix(_ digits: String, radix: Int) -> Double {
    if digits.isEmpty { return .nan }
    var value = 0.0
    for c in digits {
        guard let d = c.hexDigitValue, d < radix else { return .nan }
        value = value * Double(radix) + Double(d)
    }
    return value
}

private func isStrictDecimalLiteral(_ s: String) -> Bool {
    let chars = Array(s)
    var i = 0
    if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
    var intDigits = 0
    while i < chars.count, chars[i].isASCII, chars[i].isNumber { intDigits += 1; i += 1 }
    var fracDigits = 0
    if i < chars.count && chars[i] == "." {
        i += 1
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { fracDigits += 1; i += 1 }
    }
    if intDigits == 0 && fracDigits == 0 { return false }
    if i < chars.count && (chars[i] == "e" || chars[i] == "E") {
        i += 1
        if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
        var expDigits = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { expDigits += 1; i += 1 }
        if expDigits == 0 { return false }
    }
    return i == chars.count
}

/// lang-core `toNumber`: number → itself (NaN passes through); numeric string
/// → number, non-numeric string → 0; boolean → 1/0; anything else → 0.
func dslToNumber(_ v: RTValue) -> Double {
    switch v {
    case .number(let n):
        return n
    case .string(let s):
        let n = jsStringToNumber(s)
        return n.isNaN ? 0 : n
    case .bool(let b):
        return b ? 1 : 0
    default:
        return 0
    }
}

/// JS `String(value)` semantics — including the case where it THROWS.
///
/// `String(obj)` is `ToPrimitive(obj, string)`: `toString` then `valueOf`, and
/// BOTH lookups go through the prototype chain (`JSObjects.getMember`), so the
/// answer depends on the receiver's `[[Prototype]]`, not just on its own keys:
///
/// - a plain object inherits `Object.prototype.toString` → `"[object Object]"`;
/// - an own `toString` key shadows it with a non-callable value (this model has
///   no user function values), so the lookup falls through to
///   `Object.prototype.valueOf`, which returns the object itself and is
///   rejected as non-primitive → THROWS (fixture `081-tostring-shadow-throws`);
/// - a prototype-LESS object (`{"__proto__": null, …}`) has neither method, so
///   it throws as well (fixture `087-proto-null-toprimitive-throws`) — the case
///   an own-key check alone can never see.
func jsToString(_ v: RTValue) throws -> String {
    switch v {
    case .undefined: return "undefined"
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return jsNumberToString(n)
    case .string(let s): return s
    case .array(let items):
        // Array.prototype.toString → join(","); null/undefined → "". A member
        // that shadows `toString` makes the join itself throw.
        return try items.map { $0.isNullish ? "" : try jsToString($0) }.joined(separator: ",")
    case .function(let name, _):
        return "function \(name)() { [native code] }"
    case .proto(let kind):
        // The intrinsic prototypes are ordinary objects of their own type:
        // Number.prototype is a Number object wrapping 0, String.prototype
        // wraps "", Boolean.prototype wraps false, Array.prototype is an empty
        // array and Function.prototype is an anonymous native function.
        switch kind {
        case .object: return "[object Object]"
        case .array: return ""
        case .number: return "0"
        case .string: return ""
        case .boolean: return "false"
        case .function: return "function () { [native code] }"
        }
    case .object, .element, .ast:
        return try objectToPrimitiveString(v)
    }
}

/// `ToPrimitive(v, string)` for the object-shaped runtime values: try
/// `toString`, then `valueOf`, each only if it resolves to a callable.
private func objectToPrimitiveString(_ v: RTValue) throws -> String {
    if let resolved = try JSObjects.getMemberWithOwner(v, "toString"),
        case .function = resolved.value
    {
        // `Array.prototype.toString` on a NON-array receiver reads `this.join`,
        // whose `this.length` is undefined → joins zero elements → "". Every
        // other reachable chain ends at `Object.prototype.toString`.
        if case .proto(.array) = resolved.owner { return "" }
        return "[object Object]"
    }
    // `valueOf` either is missing (prototype-less object) or is
    // `Object.prototype.valueOf`, which answers the object itself — never a
    // primitive. Both end the same way.
    throw JSTypeError.cannotConvertObjectToPrimitive
}

/// JS truthiness.
func jsTruthy(_ v: RTValue) -> Bool {
    switch v {
    case .undefined, .null: return false
    case .bool(let b): return b
    case .number(let n): return !(n == 0 || n.isNaN)
    case .string(let s): return !s.isEmpty
    case .array, .object, .element, .ast, .function, .proto: return true
    }
}

/// JS ToNumber for loose equality (differs from dslToNumber: non-numeric
/// strings yield NaN, null → 0, undefined → NaN).
private func jsToNumberStrict(_ v: RTValue) throws -> Double {
    switch v {
    case .undefined: return .nan
    case .null: return 0
    case .bool(let b): return b ? 1 : 0
    case .number(let n): return n
    case .string(let s): return jsStringToNumber(s)
    case .array, .object, .element, .ast, .function, .proto:
        return jsStringToNumber(try jsToString(v))
    }
}

/// JS loose equality (`==`).
func jsLooseEquals(_ a: RTValue, _ b: RTValue) throws -> Bool {
    switch (a, b) {
    case (.undefined, .undefined), (.undefined, .null), (.null, .undefined), (.null, .null):
        return true
    case (.undefined, _), (.null, _), (_, .undefined), (_, .null):
        return false
    case (.number(let x), .number(let y)):
        return x == y
    case (.string(let x), .string(let y)):
        // JS compares strings by UTF-16 code units — canonically equivalent
        // NFC/NFD variants are NOT equal (Swift's `==` would say they are).
        return jsStringEquals(x, y)
    case (.bool(let x), .bool(let y)):
        return x == y
    case (.bool(let x), _):
        return try jsLooseEquals(.number(x ? 1 : 0), b)
    case (_, .bool(let y)):
        return try jsLooseEquals(a, .number(y ? 1 : 0))
    case (.number(let x), .string(let y)):
        return x == jsStringToNumber(y)
    case (.string(let x), .number(let y)):
        return jsStringToNumber(x) == y
    default:
        // object-vs-primitive: ToPrimitive(object) → string, then compare.
        if a.isObjectLike && !b.isObjectLike {
            return try jsLooseEquals(.string(try jsToString(a)), b)
        }
        if !a.isObjectLike && b.isObjectLike {
            return try jsLooseEquals(a, .string(try jsToString(b)))
        }
        // KNOWN-DEVIATION (README.md #3): JS object == object is reference
        // identity; the port's value semantics have no identities, so this is
        // uniformly false — which matches the oracle, since materialized
        // values are always freshly built distinct objects.
        return false
    }
}
