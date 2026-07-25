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
        nil // STUB
    }

    public static func parse(_ data: Data) -> JSONValue? {
        nil // STUB
    }

    /// Serialize like `JSON.stringify` (no pretty printing, `/` unescaped).
    /// Object key order follows the `keyOrder` hint when provided, else sorted.
    public func stringified(keyOrder: [String]? = nil) -> String {
        "" // STUB
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
