import Foundation

/// A plain object with JS-like insertion-ordered keys (last-write keeps the
/// original key position, like JS object assignment).
struct RTObject {
    private(set) var keys: [String] = []
    /// Keyed on `JSKey` (UTF-16 code-unit identity): JS object properties are
    /// code-unit exact, and program text can produce canonically-equal but
    /// code-unit-different keys (string-literal object keys, e.g. NFC vs NFD
    /// "café") that must stay distinct.
    private var storage: [JSKey: RTValue] = [:]

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
                    keys.removeAll { jsStringEquals($0, key) }
                }
                return
            }
            if storage[k] == nil { keys.append(key) }
            storage[k] = newValue
        }
    }

    var entries: [(key: String, value: RTValue)] {
        keys.map { ($0, storage[JSKey($0)]!) }
    }
    var values: [RTValue] { keys.map { storage[JSKey($0)]! } }
    func has(_ key: String) -> Bool { storage[JSKey(key)] != nil }
    var isEmpty: Bool { keys.isEmpty }

    /// The one key JS object ASSIGNMENT silently swallows.
    static let protoKey = "__proto__"
    /// Own key that shadows `Object.prototype.toString` (see `jsToString`).
    static let toStringKey = "toString"

    /// JS plain-object ASSIGNMENT (`o[key] = value`), which is NOT the same as
    /// defining an own property.
    ///
    /// A fresh `{}` inherits `Object.prototype`'s `__proto__` ACCESSOR, so
    /// `o["__proto__"] = v` invokes that setter: it either re-points `o`'s
    /// prototype (object/null `v`) or does nothing at all (primitive `v`).
    /// Either way `"__proto__"` never becomes an own property and never shows
    /// up in `Object.keys` / `JSON.stringify` (fixture `080-proto-object-key`).
    ///
    /// Use this at every site whose JS original is an assignment. Sites whose
    /// original is `Object.fromEntries` / `CreateDataPropertyOrThrow` keep
    /// using the subscript — those DO create an own `__proto__`
    /// (evaluator.js:40).
    mutating func assign(_ key: String, _ value: RTValue) {
        if key == RTObject.protoKey { return }
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

    var isNullish: Bool {
        switch self {
        case .undefined, .null: return true
        default: return false
        }
    }

    /// `typeof v === "object" && v !== null` in JS terms (AST nodes, arrays,
    /// elements and plain objects are all objects there).
    var isObjectLike: Bool {
        switch self {
        case .array, .object, .element, .ast: return true
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
enum JSTypeError: Error {
    case cannotConvertObjectToPrimitive

    /// The V8 message text, reproduced verbatim in the `runtimeErrors` entry.
    var message: String {
        switch self {
        case .cannotConvertObjectToPrimitive:
            return "Cannot convert object to primitive value"
        }
    }
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

/// JS `String(value)` semantics.
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
    case .object(let o):
        if o.has(RTObject.toStringKey) {
            throw JSTypeError.cannotConvertObjectToPrimitive
        }
        return "[object Object]"
    // ElementNodes and AST nodes are plain objects whose own keys are fixed
    // (`type`/`typeName`/`props`/… and `k`/…), never `toString`.
    case .element, .ast:
        return "[object Object]"
    }
}

/// JS truthiness.
func jsTruthy(_ v: RTValue) -> Bool {
    switch v {
    case .undefined, .null: return false
    case .bool(let b): return b
    case .number(let n): return !(n == 0 || n.isNaN)
    case .string(let s): return !s.isEmpty
    case .array, .object, .element, .ast: return true
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
    case .array, .object, .element, .ast:
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
