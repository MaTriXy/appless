import Foundation

/// An INSERTION-ORDERED JSON object - the Swift stand-in for a JS object
/// literal (and for Kotlin's `LinkedHashMap`). A Swift `Dictionary` has no
/// order at all, so serializing one can only sort, which is NOT what
/// `JSON.stringify` does at any depth.
///
/// Key order semantics are `OrdinaryOwnPropertyKeys` (ES 10.1.11.1), applied
/// by `JSONValue.stringified()`: canonical array-index keys first in ascending
/// NUMERIC order, then every remaining key in insertion order.
///
/// Re-assigning an existing key keeps its ORIGINAL position and replaces the
/// value (JS `o.a = 1; o.b = 2; o.a = 3` still emits `a` first), matching both
/// JS and `LinkedHashMap.put`.
///
/// `==` is deliberately ORDER-INSENSITIVE: two objects with the same keys and
/// values are equal however they were built, which is the structural
/// comparison every `JSONValue` assertion in this package wants. Ordering is a
/// serialization concern, pinned by the byte-level tests.
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private var order: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    /// Build from an ordered key/value list; later duplicates keep the FIRST
    /// position and the LAST value (JS assignment semantics).
    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    /// Swift dictionary literals hand `init(dictionaryLiteral:)` their
    /// elements in SOURCE order, so `.object(["role": …, "content": …])`
    /// reads exactly like the RN object literal it ports.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            guard let newValue else {
                if storage.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
                return
            }
            if storage.updateValue(newValue, forKey: key) == nil {
                order.append(key)
            }
        }
    }

    /// Keys in INSERTION order (not `OrdinaryOwnPropertyKeys` order - that is
    /// applied at serialization time).
    public var insertionOrderedKeys: [String] { order }

    /// Key/value pairs in insertion order.
    public var pairs: [(String, JSONValue)] { order.map { ($0, storage[$0]!) } }

    /// Unordered dictionary view (lookups, structural assertions).
    public var dictionary: [String: JSONValue] { storage }

    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.storage == rhs.storage
    }
}

/// Sendable JSON model used for tool-call arguments, form state, and request
/// body assertions in tests.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object(JSONObject)

    /// Parse a JSON document. Returns nil on malformed input.
    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(text)
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        guard parser.isAtEnd else { return nil }
        return value
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Serialize like `JSON.stringify` (no pretty printing, `/` unescaped).
    ///
    /// Object keys follow `OrdinaryOwnPropertyKeys` (ES 10.1.11.1) at EVERY
    /// depth: canonical array-index keys first in ascending NUMERIC order,
    /// then the remaining keys in insertion order. So `{"b":1,"10":2,"2":3}`
    /// emits `{"2":3,"10":2,"b":1}`, exactly like node.
    ///
    /// There is no `keyOrder` hint any more. A single flat hint could only
    /// order keys it named and fell back to `.sorted()` everywhere else, so a
    /// nested object (form state is three levels deep) was alphabetized, and
    /// adding one unhinted key anywhere silently reordered the wire bytes.
    /// `JSONObject` carries per-object order instead.
    public func stringified() -> String {
        switch self {
        case .string(let s):
            return JSONValue.encodeJSONString(s)
        case .number(let n):
            return JSONValue.numberString(n)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let a):
            return "[" + a.map { $0.stringified() }.joined(separator: ",") + "]"
        case .object(let o):
            let parts = JSONValue.jsOwnKeyOrder(o.insertionOrderedKeys).map { key -> String in
                JSONValue.encodeJSONString(key) + ":" + (o[key] ?? .null).stringified()
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    /// Largest canonical array index: 2^32 - 2.
    private static let maxArrayIndex: UInt64 = 4_294_967_294

    /// The numeric value of `key` when it is a canonical array index (the
    /// canonical decimal spelling of an integer in 0...2^32-2, so no "+1", no
    /// "01", no "1.0"), else nil. Mirrors Kotlin's `canonicalArrayIndex`.
    static func canonicalArrayIndex(_ key: String) -> UInt64? {
        let n = key.utf8.count
        if n == 0 || n > 10 { return nil }
        if key.utf8.first == UInt8(ascii: "0") && n > 1 { return nil }
        var value: UInt64 = 0
        for byte in key.utf8 {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + UInt64(byte - UInt8(ascii: "0"))
        }
        return value > maxArrayIndex ? nil : value
    }

    /// `OrdinaryOwnPropertyKeys`: canonical array indices ascending
    /// numerically, then the rest in insertion order.
    static func jsOwnKeyOrder(_ keys: [String]) -> [String] {
        var indices: [(UInt64, String)] = []
        var rest: [String] = []
        for key in keys {
            if let index = canonicalArrayIndex(key) {
                indices.append((index, key))
            } else {
                rest.append(key)
            }
        }
        if indices.isEmpty { return rest }
        // Sort by numeric value only; canonical spellings are unique, so the
        // comparison is a total order and sort stability is irrelevant.
        return indices.sorted { $0.0 < $1.0 }.map(\.1) + rest
    }

    /// ECMAScript `Number::toString` (what `JSON.stringify` emits for numbers),
    /// ported from OpenUILang's TreeSerializer.formatNumber - the same algorithm
    /// verified there against a 267-entry table of node `String(x)` outputs
    /// spanning powers of two, Int64 boundaries, the 1e21/1e-7 thresholds,
    /// subnormals and -0.0.
    ///
    /// Swift's `"\(d)"` is shortest-round-trip like JS, but its positional vs
    /// exponential thresholds and exponent spelling differ (`1e+16` where JS
    /// writes `10000000000000000`; `1e-05` where JS writes `0.00001`;
    /// `1e-07` where JS writes `1e-7`), so the shortest digits are re-rendered
    /// under the spec's rules here.
    static func numberString(_ n: Double) -> String {
        // JSON.stringify serializes non-finite numbers as null.
        if n.isNaN || n.isInfinite { return "null" }
        if n == 0 { return "0" } // JSON.stringify(-0) === "0"

        // Integer fast path, valid only below 2^53: there every integer is
        // exactly representable, so the exact decimal expansion IS the shortest
        // round-trip form. At or above 2^53 ECMAScript renders SHORTEST digits
        // (String(2 ** 56) is "72057594037927940", not "...936"), so those fall
        // through to the re-rendering below even when they fit Int64.
        if abs(n) < 9_007_199_254_740_992, let i = Int64(exactly: n) { // 2^53
            return String(i)
        }

        let repr = "\(n)" // Swift's shortest round-trip representation
        guard let eIndex = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            // Positional shortest form already matches JS in the positional
            // range, except Swift's ".0" suffix on integer-valued doubles
            // (reachable now that |n| >= 2^53 integers land here).
            if repr.hasSuffix(".0") { return String(repr.dropLast(2)) }
            return repr
        }

        // Re-render Swift's exponential form under the Number::toString rules.
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
        while digits.count > 1 && digits.hasSuffix("0") {
            digits.removeLast()
        }
        let k = digits.count
        // pos: value == 0.digits * 10^pos
        let pos = exponent + pointOffset
        if k <= pos && pos <= 21 {
            return sign + digits + String(repeating: "0", count: pos - k)
        }
        if 0 < pos && pos <= 21 {
            return sign + String(digits.prefix(pos)) + "." + String(digits.dropFirst(pos))
        }
        if -6 < pos && pos <= 0 {
            return sign + "0." + String(repeating: "0", count: -pos) + digits
        }
        let first = String(digits.prefix(1))
        let rest = String(digits.dropFirst())
        let e = pos - 1
        let expPart = (e >= 0 ? "e+" : "e-") + String(abs(e))
        return sign + first + (rest.isEmpty ? "" : "." + rest) + expPart
    }

    static func encodeJSONString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// `JSON.stringify` of an object built from an ORDERED key/value list -
    /// RN's `JSON.stringify(formState)` emits keys in insertion order, and the
    /// shell passes form values in UI insertion order. Nested `.object`
    /// values keep their own insertion order too (form state is three levels
    /// deep: `{formName: {fieldName: {value, componentType}}}`).
    public static func stringifyOrdered(_ pairs: [(String, JSONValue)]) -> String {
        JSONValue.object(JSONObject(pairs)).stringified()
    }

    /// JS truthiness (`if (value)`): "" / 0 / NaN / false / null are falsy;
    /// any object or array (even empty) is truthy.
    public var isJSTruthy: Bool {
        switch self {
        case .string(let s): return !s.isEmpty
        case .number(let n): return n != 0 && !n.isNaN
        case .bool(let b): return b
        case .null: return false
        case .array, .object: return true
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Unordered dictionary view of an object (lookups / structural asserts).
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o.dictionary }
        return nil
    }

    /// The ordered object itself, when this value is one.
    public var orderedObjectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

/// Minimal recursive-descent JSON parser (JS `JSON.parse` semantics for the
/// payloads this package handles). Hand-rolled so the bool/number distinction
/// is exact on Linux Foundation.
private struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool { index >= scalars.count }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        let j = index + offset
        return j < scalars.count ? scalars[j] : nil
    }

    /// U+FFFD, what a lone surrogate becomes the moment JS UTF-8-encodes it.
    fileprivate static let replacement = Unicode.Scalar(0xFFFD)!

    mutating func skipWhitespace() {
        while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" {
            index += 1
        }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let c = current else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .string($0) }
        case "t": return consumeLiteral("true") ? .bool(true) : nil
        case "f": return consumeLiteral("false") ? .bool(false) : nil
        case "n": return consumeLiteral("null") ? JSONValue.null : nil
        default: return parseNumber()
        }
    }

    private mutating func consumeLiteral(_ literal: String) -> Bool {
        let ls = Array(literal.unicodeScalars)
        guard index + ls.count <= scalars.count else { return false }
        for (offset, s) in ls.enumerated() where scalars[index + offset] != s {
            return false
        }
        index += ls.count
        return true
    }

    private mutating func parseObject() -> JSONValue? {
        index += 1 // {
        // Ordered: keys parsed out of a document keep DOCUMENT order, like
        // JS's own `JSON.parse` (and Kotlin's LinkedHashMap-backed parser).
        var object = JSONObject()
        skipWhitespace()
        if current == "}" {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard current == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard current == ":" else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipWhitespace()
            if current == "," {
                index += 1
                continue
            }
            if current == "}" {
                index += 1
                return .object(object)
            }
            return nil
        }
    }

    private mutating func parseArray() -> JSONValue? {
        index += 1 // [
        var array: [JSONValue] = []
        skipWhitespace()
        if current == "]" {
            index += 1
            return .array(array)
        }
        while true {
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipWhitespace()
            if current == "," {
                index += 1
                continue
            }
            if current == "]" {
                index += 1
                return .array(array)
            }
            return nil
        }
    }

    private mutating func parseString() -> String? {
        index += 1 // opening quote
        var out = String.UnicodeScalarView()
        while let c = current {
            index += 1
            if c == "\"" {
                return String(out)
            }
            // JSON.parse throws on raw (unescaped) control characters
            // U+0000-U+001F inside strings - reject so the SSE layer skips
            // the chunk exactly where RN's try/catch around JSON.parse does.
            if c.value < 0x20 {
                return nil
            }
            if c == "\\" {
                guard let esc = current else { return nil }
                index += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    // `JSON.parse` ACCEPTS a lone-surrogate \u escape: the JS
                    // string keeps the unpaired UTF-16 unit and it degrades to
                    // U+FFFD only when the string is later UTF-8-encoded (HTTP
                    // body, JSON re-stringify) or rendered. Swift String cannot
                    // hold a lone surrogate, so the parser substitutes U+FFFD
                    // HERE - the same net observable result as RN, one step
                    // earlier. Rejecting the document instead (the previous
                    // behavior) made the SSE layer drop the WHOLE chunk, losing
                    // a delta RN delivers. See README KNOWN-DEVIATIONS #2.
                    guard let first = parseHex4() else { return nil }
                    if (0xD800...0xDBFF).contains(first) {
                        // High surrogate: take a following \uDC00-\uDFFF as the
                        // pair's low half, otherwise it is unpaired.
                        let save = index
                        if current == "\\", peek(1) == "u" {
                            index += 2
                            if let second = parseHex4(), (0xDC00...0xDFFF).contains(second) {
                                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                                // Always a valid scalar for the input ranges.
                                out.append(Unicode.Scalar(UInt32(combined)) ?? Self.replacement)
                                continue
                            }
                            // Not a low surrogate: rewind so the escape is
                            // re-read as its own (possibly lone) unit.
                            index = save
                        }
                        out.append(Self.replacement)
                    } else if (0xDC00...0xDFFF).contains(first) {
                        // Lone LOW surrogate.
                        out.append(Self.replacement)
                    } else if let scalar = Unicode.Scalar(UInt32(first)) {
                        out.append(scalar)
                    } else {
                        return nil
                    }
                default:
                    return nil
                }
            } else {
                out.append(c)
            }
        }
        return nil
    }

    private mutating func parseHex4() -> Int? {
        var value = 0
        for _ in 0..<4 {
            guard let c = current, let digit = c.jsonHexDigitValue else { return nil }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = index
        if current == "-" { index += 1 }
        // JSON.parse rejects leading zeros: the integer part is exactly "0"
        // or [1-9][0-9]*. "01" must fail so the SSE layer skips the chunk
        // the same way RN's try/catch around JSON.parse does.
        var sawDigit = false
        if current == "0" {
            sawDigit = true
            index += 1
            if let c = current, ("0"..."9").contains(c) { return nil }
        } else {
            while let c = current, ("0"..."9").contains(c) {
                sawDigit = true
                index += 1
            }
        }
        guard sawDigit else { return nil }
        if current == "." {
            index += 1
            var sawFrac = false
            while let c = current, ("0"..."9").contains(c) {
                sawFrac = true
                index += 1
            }
            guard sawFrac else { return nil }
        }
        if current == "e" || current == "E" {
            index += 1
            if current == "+" || current == "-" { index += 1 }
            var sawExp = false
            while let c = current, ("0"..."9").contains(c) {
                sawExp = true
                index += 1
            }
            guard sawExp else { return nil }
        }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        return Double(text).map { .number($0) }
    }
}

private extension Unicode.Scalar {
    var jsonHexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61 + 10)
        case "A"..."F": return Int(value - 0x41 + 10)
        default: return nil
        }
    }
}
