import Foundation

/// Names and classification from lang-core `parser/builtins.js`
/// (spec/openui-lang.md §9.2 builtins, §9.3 actions).
enum Builtins {
    static let dataBuiltins: Set<String> = [
        "Count", "First", "Last", "Sum", "Avg", "Min", "Max",
        "Sort", "Filter", "Round", "Abs", "Floor", "Ceil",
    ]
    static let lazyBuiltins: Set<String> = ["Each"]
    /// parser-level action step names → runtime step type strings
    static let actionSteps: [String: String] = [
        "Run": "run",
        "ToAssistant": "continue_conversation",
        "OpenUrl": "open_url",
        "Set": "set",
        "Reset": "reset",
    ]
    static let actionNames: Set<String> = {
        var s = Set(actionSteps.keys)
        s.insert("Action")
        return s
    }()
    static let allNames: Set<String> = dataBuiltins.union(lazyBuiltins).union(actionNames)

    static func isBuiltin(_ name: String) -> Bool { allNames.contains(name) }

    /// `Object.prototype`'s own property names, in V8's
    /// `Object.getOwnPropertyNames(Object.prototype)` order.
    ///
    /// lang-core writes `RESERVED_CALLS = { Query: "Query", Mutation: "Mutation" }`
    /// and tests membership with `name in RESERVED_CALLS` — the `in` operator,
    /// which walks the PROTOTYPE CHAIN. On a plain object literal that chain
    /// is `Object.prototype`, so all twelve of these names answer `true` too.
    /// They are reachable from source: `@ident` lexes to a BUILTIN token with
    /// ANY name (fixture `078-reserved-call-prototype-names`).
    static let objectPrototypeNames: Set<String> = [
        "constructor",
        "__defineGetter__",
        "__defineSetter__",
        "hasOwnProperty",
        "__lookupGetter__",
        "__lookupSetter__",
        "isPrototypeOf",
        "propertyIsEnumerable",
        "toString",
        "valueOf",
        "__proto__",
        "toLocaleString",
    ]

    /// Reserved statement-level call names — not builtins, not components.
    ///
    /// Port of `isReservedCall(name) { return name in RESERVED_CALLS; }`. The
    /// `in` operator is prototype-chain aware, so this is `{Query, Mutation}`
    /// UNION `objectPrototypeNames` — NOT just the two declared keys.
    ///
    /// `classifyStatement` and `reservedRefType` still compare with `===`
    /// against the literal `"Query"` / `"Mutation"` (parser.js:45,
    /// materialize.js:40), so a prototype name is a reserved call for
    /// classification but always yields `refType: "query"`.
    static func isReservedCall(_ name: String) -> Bool {
        name == "Query" || name == "Mutation" || objectPrototypeNames.contains(name)
    }
}
