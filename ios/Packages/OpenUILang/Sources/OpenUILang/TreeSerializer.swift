import Foundation

/// Hand-written deterministic serializer emitting the canonical expected-tree
/// JSON documented in `spec/fixtures/README.md` (result shapes:
/// spec/openui-lang.md Appendix A):
///
/// - 2-space indent, exactly like `JSON.stringify(value, null, 2)`;
/// - trailing newline;
/// - the document, element nodes, `meta.errors[]` entries and
///   `runtimeErrors[]` entries use the reference implementation's fixed key
///   order; all other objects (props, state, plain objects, action steps,
///   `$ast` nodes) have their keys sorted;
/// - JS number formatting (`125` not `125.0`, shortest round-trip for
///   doubles); non-finite numbers become `{"$number": ...}`;
/// - `undefined` at a value position becomes `null` (modeled as `.null`).
///
/// Ordering is never delegated to `JSONSerialization`.
public enum TreeSerializer {
    public static func serialize(_ result: ParseResult) -> String {
        var out = "{\n"

        // Document key order: root, meta, state, runtimeErrors.
        out += "  \"root\": "
        if let root = result.root {
            out += serializeElement(root, indent: 1)
        } else {
            out += "null"
        }
        out += ",\n"

        out += "  \"meta\": " + serializeMeta(result.meta, indent: 1) + ",\n"

        out += "  \"state\": " + serializeObjectBody(result.state, indent: 1) + ",\n"

        out += "  \"runtimeErrors\": "
        if result.runtimeErrors.isEmpty {
            out += "[]"
        } else {
            out += "[\n"
            out += result.runtimeErrors
                .map { pad(2) + serializeRuntimeError($0, indent: 2) }
                .joined(separator: ",\n")
            out += "\n" + pad(1) + "]"
        }
        out += "\n}\n"
        return out
    }

    // MARK: - Sections

    private static func serializeMeta(_ meta: ParseMeta, indent: Int) -> String {
        var out = "{\n"
        let inner = indent + 1
        out += pad(inner) + "\"incomplete\": " + (meta.incomplete ? "true" : "false") + ",\n"

        out += pad(inner) + "\"unresolved\": "
        if meta.unresolved.isEmpty {
            out += "[]"
        } else {
            out += "[\n"
            out += meta.unresolved
                .map { pad(inner + 1) + quote($0) }
                .joined(separator: ",\n")
            out += "\n" + pad(inner) + "]"
        }
        out += ",\n"

        out += pad(inner) + "\"errors\": "
        if meta.errors.isEmpty {
            out += "[]"
        } else {
            out += "[\n"
            out += meta.errors
                .map { pad(inner + 1) + serializeParseError($0, indent: inner + 1) }
                .joined(separator: ",\n")
            out += "\n" + pad(inner) + "]"
        }
        out += "\n" + pad(indent) + "}"
        return out
    }

    private static func serializeParseError(_ error: ParseError, indent: Int) -> String {
        // Fixed key order: code, component, path, message, statementId?.
        let inner = indent + 1
        var lines: [String] = []
        lines.append(pad(inner) + "\"code\": " + quote(error.code.rawValue))
        lines.append(pad(inner) + "\"component\": " + quote(error.component))
        lines.append(pad(inner) + "\"path\": " + quote(error.path))
        lines.append(pad(inner) + "\"message\": " + quote(error.message))
        if let statementId = error.statementId {
            lines.append(pad(inner) + "\"statementId\": " + quote(statementId))
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + pad(indent) + "}"
    }

    private static func serializeRuntimeError(_ error: RuntimeError, indent: Int) -> String {
        // Fixed key order: source, code, message, component?, statementId?.
        let inner = indent + 1
        var lines: [String] = []
        lines.append(pad(inner) + "\"source\": " + quote(error.source))
        lines.append(pad(inner) + "\"code\": " + quote(error.code))
        lines.append(pad(inner) + "\"message\": " + quote(error.message))
        if let component = error.component {
            lines.append(pad(inner) + "\"component\": " + quote(component))
        }
        if let statementId = error.statementId {
            lines.append(
                pad(inner) + "\"statementId\": " + serializeValue(statementId, indent: inner))
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + pad(indent) + "}"
    }

    private static func serializeElement(_ element: ElementNode, indent: Int) -> String {
        // Fixed key order: component, statementId?, props, children?.
        let inner = indent + 1
        var lines: [String] = []
        // `{ component: el.typeName }` with an UNDEFINED typeName is an object
        // with an undefined-valued key, which JSON.stringify omits.
        if element.componentPresent {
            lines.append(pad(inner) + "\"component\": " + quote(element.component))
        }
        if let statementId = element.statementId {
            lines.append(
                pad(inner) + "\"statementId\": " + serializeValue(statementId, indent: inner))
        }
        lines.append(pad(inner) + "\"props\": " + serializeObjectBody(element.props, indent: inner))
        if let children = element.children {
            lines.append(pad(inner) + "\"children\": " + serializeValue(children, indent: inner))
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + pad(indent) + "}"
    }

    // MARK: - Values

    private static func serializeValue(_ value: PropValue, indent: Int) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .number(let n):
            if n.isNaN || n.isInfinite {
                let name = n.isNaN ? "NaN" : (n > 0 ? "Infinity" : "-Infinity")
                return "{\n" + pad(indent + 1) + "\"$number\": " + quote(name)
                    + "\n" + pad(indent) + "}"
            }
            return formatNumber(n)
        case .string(let s):
            return quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            var out = "[\n"
            out += items
                .map { pad(indent + 1) + serializeValue($0, indent: indent + 1) }
                .joined(separator: ",\n")
            out += "\n" + pad(indent) + "]"
            return out
        case .object(let entries):
            return serializePropObject(entries, indent: indent)
        case .element(let element):
            return serializeElement(element, indent: indent)
        case .action(let plan):
            let inner = indent + 1
            var out = "{\n" + pad(inner) + "\"$action\": {\n"
            out += pad(inner + 1) + "\"steps\": "
            out += serializeValue(.array(plan.steps), indent: inner + 1)
            out += "\n" + pad(inner) + "}"
            out += "\n" + pad(indent) + "}"
            return out
        case .ast(let node):
            return "{\n" + pad(indent + 1) + "\"$ast\": "
                + serializeValue(node, indent: indent + 1)
                + "\n" + pad(indent) + "}"
        }
    }

    /// Serializes a dictionary (props, `state`) as an object in `jsOwnKeyLess`
    /// order — canonical array indices first in ascending numeric order, then
    /// the remaining keys in UTF-16 code-unit order.
    ///
    /// The reference serializer sorts with `Object.keys(v).sort()` and
    /// re-inserts into a fresh object, but the bytes come out of
    /// `JSON.stringify`, which re-derives the order from
    /// `OrdinaryOwnPropertyKeys` and hoists the integer-index keys. A flat
    /// code-unit sort matches only for objects with no index-shaped keys
    /// (fixture `075-object-key-index-order`). The code-unit half must stay
    /// explicit because Swift's `String` ordering is canonical and would place
    /// NFC/NFD keys differently.
    private static func serializeObjectBody(
        _ entries: [String: PropValue], indent: Int
    ) -> String {
        if entries.isEmpty { return "{}" }
        var out = "{\n"
        out += entries.keys.sorted(by: jsOwnKeyLess)
            .map { key in
                pad(indent + 1) + quote(key) + ": "
                    + serializeValue(entries[key]!, indent: indent + 1)
            }
            .joined(separator: ",\n")
        out += "\n" + pad(indent) + "}"
        return out
    }

    /// Serializes a `PropObject` (code-unit-exact keys) — plain data objects,
    /// `$ast` nodes and action steps — in the same `jsOwnKeyLess` order as
    /// `serializeObjectBody`.
    private static func serializePropObject(
        _ object: PropObject, indent: Int
    ) -> String {
        if object.isEmpty { return "{}" }
        var out = "{\n"
        out += object.entries
            .sorted { jsOwnKeyLess($0.key, $1.key) }
            .map { entry in
                pad(indent + 1) + quote(entry.key) + ": "
                    + serializeValue(entry.value, indent: indent + 1)
            }
            .joined(separator: ",\n")
        out += "\n" + pad(indent) + "}"
        return out
    }

    // MARK: - Scalars

    private static func pad(_ indent: Int) -> String {
        String(repeating: "  ", count: indent)
    }

    /// JSON string escaping matching `JSON.stringify`: only `"`, `\` and
    /// control characters below U+0020 are escaped; everything else (including
    /// non-ASCII) is emitted raw.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
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

    /// JS number-to-string for finite doubles (ECMAScript Number::toString,
    /// shortest round-trip): integers without a decimal point, positional
    /// notation for decimal exponents in (-7, 21), exponential (`1e-7`,
    /// `1.5e+21`) outside.
    static func formatNumber(_ d: Double) -> String {
        precondition(d.isFinite)
        if d == 0 { return "0" } // JSON.stringify(-0) === "0"
        // Integer fast path, valid only below 2^53: there every integer is
        // exactly representable, so the exact decimal expansion IS the
        // shortest round-trip form. At |d| >= 2^53 that no longer holds —
        // ECMAScript renders SHORTEST round-trip digits, not the exact
        // expansion (`String(2 ** 56)` is `"72057594037927940"`, not
        // `"72057594037927936"`), so those magnitudes fall through to the
        // shortest-repr re-rendering below even when they fit Int64.
        if abs(d) < 9007199254740992, let i = Int64(exactly: d) { // 2^53
            return String(i)
        }
        // Everything else — including integer-valued doubles at or beyond
        // 2^53 but below 1e21, which ECMAScript renders positionally from the
        // SHORTEST round-trip digits (`String(12345678901234567168)` is
        // `"12345678901234567000"`, not the exact expansion
        // `"12345678901234567168"`) — is derived from Swift's own shortest
        // round-trip representation and re-rendered under the Number::toString
        // positional/exponential rules below.
        let repr = "\(d)" // Swift's shortest round-trip representation
        guard let eIndex = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            // Positional shortest form matches JS in the positional range,
            // except that Swift prints integer-valued doubles with a ".0"
            // suffix (reachable now that |d| >= 2^53 integers land here).
            if repr.hasSuffix(".0") {
                return String(repr.dropLast(2))
            }
            return repr
        }
        // Re-render Swift's exponential form under JS rules.
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
        // n: value == 0.digits * 10^n
        let n = exponent + pointOffset
        if k <= n && n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let head = String(digits.prefix(n))
            let tail = String(digits.dropFirst(n))
            return sign + head + "." + tail
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let first = String(digits.prefix(1))
        let rest = String(digits.dropFirst())
        let e = n - 1
        let expPart = (e >= 0 ? "e+" : "e-") + String(abs(e))
        return sign + first + (rest.isEmpty ? "" : "." + rest) + expPart
    }
}
