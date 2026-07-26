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

    /// `Object.prototype`'s own property names — a view onto the ONE table in
    /// `JSObjects`, so the two can never drift apart.
    ///
    /// Every classification below is a JS property lookup on a plain object
    /// literal, and a plain object literal inherits these twelve names.
    static var objectPrototypeNames: Set<String> { Set(JSObjects.prototypeOwnNames.keys) }

    /// `RESERVED_CALLS = { Query: "Query", Mutation: "Mutation" }` — modelled
    /// as a real JS object so that `in` and `[]` both behave.
    private nonisolated(unsafe) static let reservedCalls: RTValue = .object(
        RTObject([("Query", .string("Query")), ("Mutation", .string("Mutation"))]))

    /// `BUILTINS` — the shared builtin registry, again modelled as a real JS
    /// object. Only membership and own-ness matter here; the port dispatches
    /// the actual implementations in `Evaluator.callDataBuiltin`.
    private nonisolated(unsafe) static let builtinsRegistry: RTObject = {
        var o = RTObject()
        for name in [
            "Count", "First", "Last", "Sum", "Avg", "Min", "Max",
            "Sort", "Filter", "Round", "Abs", "Floor", "Ceil",
        ] {
            o[name] = .string(name)
        }
        return o
    }()

    /// Reserved statement-level call names — not builtins, not components.
    ///
    /// Port of `isReservedCall(name) { return name in RESERVED_CALLS; }`. The
    /// `in` operator is prototype-chain aware, so this routes through
    /// `JSObjects.hasProperty` and answers `true` for `{Query, Mutation}` UNION
    /// the twelve `Object.prototype` names — NOT just the two declared keys.
    /// They are reachable from source: `@ident` lexes to a BUILTIN token with
    /// ANY name (fixture `078-reserved-call-prototype-names`).
    ///
    /// `classifyStatement` and `reservedRefType` still compare with `===`
    /// against the literal `"Query"` / `"Mutation"` (parser.js:45,
    /// materialize.js:40), so a prototype name is a reserved call for
    /// classification but always yields `refType: "query"`.
    static func isReservedCall(_ name: String) -> Bool {
        JSObjects.hasProperty(reservedCalls, name)
    }

    /// What `BUILTINS[name]` (evaluator.js:48) resolves to.
    enum BuiltinLookup {
        /// Miss — the registry has no such name, own or inherited.
        case miss
        /// One of the thirteen real data builtins: `builtin.fn` is callable.
        case own
        /// An `Object.prototype` member reached through the registry's
        /// prototype chain. It is TRUTHY, so `evaluate` proceeds to
        /// `builtin.fn(...args)` — and `.fn` is `undefined`, so the call throws
        /// `TypeError: builtin.fn is not a function`, which `evaluate-tree.js`
        /// turns into a `runtimeErrors` entry (fixture
        /// `084-reserved-call-expression-throws`).
        case inherited
    }

    static func lookupBuiltin(_ name: String) -> BuiltinLookup {
        if builtinsRegistry.has(name) { return .own }
        if JSObjects.hasProperty(.object(builtinsRegistry), name) { return .inherited }
        return .miss
    }
}
