import Foundation

/// A resolved (post-runtime-evaluation) prop value, as it appears in the
/// canonical expected-tree JSON (spec/fixtures/README.md;
/// spec/openui-lang.md Appendix A).
public indirect enum PropValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Finite or non-finite. Non-finite values serialize as
    /// `{"$number": "NaN" | "Infinity" | "-Infinity"}`.
    case number(Double)
    case string(String)
    /// Element order preserved; the parser has already applied array-drop rules.
    case array([PropValue])
    /// Plain object; keys are sorted (by UTF-16 code units, like
    /// `Object.keys(...).sort()`) at serialization time.
    case object(PropObject)
    case element(ElementNode)
    /// Deferred click-time value: serializes as `{"$action": {"steps": [...]}}`.
    case action(ActionPlan)
    /// Leftover AST node in a deferred slot: serializes as `{"$ast": <node>}`
    /// with keys sorted deep.
    case ast(PropValue)
}

/// A plain JS-like object with UTF-16 code-unit key identity and insertion
/// order. A Swift `[String: PropValue]` cannot represent JS objects
/// faithfully: `String` dictionary keys use Unicode canonical equivalence,
/// so program-derived keys that differ only in normalization (precomposed
/// "café" vs decomposed "cafe\u{301}") would collide even though JS keeps
/// them as two distinct properties.
public struct PropObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    /// Raw insertion order. Public iteration goes through `keys`, which applies
    /// JS own-key order on top.
    private var insertionKeys: [String]
    private var storedValues: [PropValue]

    /// The object's own keys in JS `Object.keys(o)` order: canonical array
    /// indices (`"0"`–`"4294967294"`) FIRST in ascending numeric order, then
    /// every remaining key in insertion order (`OrdinaryOwnPropertyKeys`,
    /// ES 10.1.11.1). So `{b, "2", a, "10"}` iterates `"2", "10", b, a`.
    ///
    /// This is deliberately NOT the serializer's order: `TreeSerializer`
    /// additionally sorts the string group, because the reference serializer
    /// does `Object.keys(v).sort()` and re-inserts into a fresh object (see
    /// `jsOwnKeyLess`, fixture `075-object-key-index-order`). A consumer
    /// iterating props directly gets what JS would give it; a consumer wanting
    /// the canonical byte order must serialize.
    public var keys: [String] { jsOwnPropertyKeys(insertionKeys) }

    public init() {
        insertionKeys = []
        storedValues = []
    }

    public init(dictionaryLiteral elements: (String, PropValue)...) {
        self.init()
        for (key, value) in elements { self[key] = value }
    }

    public init(_ pairs: [(String, PropValue)]) {
        self.init()
        for (key, value) in pairs { self[key] = value }
    }

    private func indexOf(_ key: String) -> Int? {
        insertionKeys.firstIndex { jsStringEquals($0, key) }
    }

    /// Code-unit-exact lookup / last-write-wins insertion that keeps the
    /// original key position (JS object assignment semantics).
    public subscript(key: String) -> PropValue? {
        get { indexOf(key).map { storedValues[$0] } }
        set {
            if let i = indexOf(key) {
                if let newValue {
                    storedValues[i] = newValue
                } else {
                    insertionKeys.remove(at: i)
                    storedValues.remove(at: i)
                }
            } else if let newValue {
                insertionKeys.append(key)
                storedValues.append(newValue)
            }
        }
    }

    /// `keys` paired with their values, in the same JS own-key order.
    public var entries: [(key: String, value: PropValue)] {
        keys.map { ($0, storedValues[indexOf($0)!]) }
    }
    public var isEmpty: Bool { insertionKeys.isEmpty }
    public var count: Int { insertionKeys.count }

    /// Structural equality over the RAW insertion order (which `storedValues`
    /// is parallel to) — the JS own-key reordering `keys` applies is a
    /// presentation concern, not an identity one.
    public static func == (l: PropObject, r: PropObject) -> Bool {
        l.insertionKeys.count == r.insertionKeys.count
            && zip(l.insertionKeys, r.insertionKeys).allSatisfy { jsStringEquals($0, $1) }
            && l.storedValues == r.storedValues
    }
}

/// An element in the resolved tree.
public struct ElementNode: Sendable, Equatable {
    /// Component type name, e.g. `"CardHeader"`.
    public var component: String
    /// Present iff the element came from a named statement.
    public var statementId: String?
    /// Named props (positional args already mapped via the contract's property
    /// order), EXCLUDING `children`. Props that evaluated to `undefined` are
    /// omitted; `null` is kept as `.null`.
    public var props: [String: PropValue]
    /// Present iff the element has a `children` prop (Card, TabItem).
    public var children: PropValue?

    public init(
        component: String,
        statementId: String? = nil,
        props: [String: PropValue] = [:],
        children: PropValue? = nil
    ) {
        self.component = component
        self.statementId = statementId
        self.props = props
        self.children = children
    }
}

/// A deferred action: `{steps: [...]}`. Each step is a plain-object value
/// (sorted keys at serialization); a `@Set` step's deferred `valueAST` is a
/// nested `.ast` value.
public struct ActionPlan: Sendable, Equatable {
    public var steps: [PropValue]

    public init(steps: [PropValue] = []) {
        self.steps = steps
    }
}

/// A parser validation error, in emission order.
public struct ParseError: Sendable, Equatable {
    public enum Code: String, Sendable {
        case missingRequired = "missing-required"
        case nullRequired = "null-required"
        case unknownComponent = "unknown-component"
        case inlineReserved = "inline-reserved"
    }

    public var code: Code
    /// Component type name, e.g. `"Toggle"`.
    public var component: String
    /// JSON pointer into props, e.g. `"/on"`; `""` for component-level errors.
    public var path: String
    /// Reference implementation's text — informational for comparisons.
    public var message: String
    /// Omitted from serialization when nil.
    public var statementId: String?

    public init(
        code: Code,
        component: String,
        path: String,
        message: String,
        statementId: String? = nil
    ) {
        self.code = code
        self.component = component
        self.path = path
        self.message = message
        self.statementId = statementId
    }
}

/// A per-prop evaluation error (rare).
public struct RuntimeError: Sendable, Equatable {
    public var source: String
    public var code: String
    public var message: String
    public var component: String?
    public var statementId: String?

    public init(
        source: String = "runtime",
        code: String = "runtime-error",
        message: String,
        component: String? = nil,
        statementId: String? = nil
    ) {
        self.source = source
        self.code = code
        self.message = message
        self.component = component
        self.statementId = statementId
    }
}

/// Parse metadata for one pass.
public struct ParseMeta: Sendable, Equatable {
    /// Pending tail needed auto-closing this pass.
    public var incomplete: Bool
    /// Refs that failed to resolve, in resolution order, duplicates preserved.
    public var unresolved: [String]
    /// Parser validation errors, in emission order.
    public var errors: [ParseError]

    public init(
        incomplete: Bool = false,
        unresolved: [String] = [],
        errors: [ParseError] = []
    ) {
        self.incomplete = incomplete
        self.unresolved = unresolved
        self.errors = errors
    }
}

/// The full result of one parse pass: the resolved tree, metadata, materialized
/// state declarations, and runtime evaluation errors.
public struct ParseResult: Sendable, Equatable {
    /// `nil` means no renderable root (host shows a skeleton).
    public var root: ElementNode?
    public var meta: ParseMeta
    /// State declarations, keyed by `$name`, with materialized defaults
    /// (auto-declared refs map to `.null`). Keys are sorted at serialization.
    public var state: [String: PropValue]
    public var runtimeErrors: [RuntimeError]

    public init(
        root: ElementNode? = nil,
        meta: ParseMeta = ParseMeta(),
        state: [String: PropValue] = [:],
        runtimeErrors: [RuntimeError] = []
    ) {
        self.root = root
        self.meta = meta
        self.state = state
        self.runtimeErrors = runtimeErrors
    }
}
