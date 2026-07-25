import Foundation

/// Sendable JSON model used for tool-call arguments, form state, and request
/// body assertions in tests.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

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
    /// Object key order follows the `keyOrder` hint when provided, else sorted.
    public func stringified(keyOrder: [String]? = nil) -> String {
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
            return "[" + a.map { $0.stringified(keyOrder: keyOrder) }.joined(separator: ",") + "]"
        case .object(let o):
            var keys: [String]
            if let keyOrder {
                let hinted = keyOrder.filter { o[$0] != nil }
                let rest = o.keys.filter { !keyOrder.contains($0) }.sorted()
                keys = hinted + rest
            } else {
                keys = o.keys.sorted()
            }
            let parts = keys.map { key -> String in
                JSONValue.encodeJSONString(key) + ":" + (o[key] ?? .null).stringified(keyOrder: keyOrder)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    static func numberString(_ n: Double) -> String {
        if n.isNaN || n.isInfinite { return "null" }
        if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
            return String(Int64(n))
        }
        return "\(n)"
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

    public var objectValue: [String: JSONValue]? {
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
        var object: [String: JSONValue] = [:]
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
                    guard let first = parseHex4() else { return nil }
                    if (0xD800...0xDBFF).contains(first) {
                        // Surrogate pair.
                        guard current == "\\" else { return nil }
                        index += 1
                        guard current == "u" else { return nil }
                        index += 1
                        guard let second = parseHex4(), (0xDC00...0xDFFF).contains(second) else { return nil }
                        let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        guard let scalar = Unicode.Scalar(combined) else { return nil }
                        out.append(scalar)
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
        var sawDigit = false
        while let c = current, ("0"..."9").contains(c) {
            sawDigit = true
            index += 1
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
