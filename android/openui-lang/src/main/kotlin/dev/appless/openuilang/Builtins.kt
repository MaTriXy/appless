package dev.appless.openuilang

/**
 * Names and classification from lang-core `parser/builtins.js`
 * (spec/openui-lang.md §9.2 builtins, §9.3 actions).
 */
internal object Builtins {
    val dataBuiltins: Set<String> = hashSetOf(
        "Count", "First", "Last", "Sum", "Avg", "Min", "Max",
        "Sort", "Filter", "Round", "Abs", "Floor", "Ceil",
    )

    val lazyBuiltins: Set<String> = hashSetOf("Each")

    /** Parser-level action step names → runtime step type strings. */
    val actionSteps: Map<String, String> = mapOf(
        "Run" to "run",
        "ToAssistant" to "continue_conversation",
        "OpenUrl" to "open_url",
        "Set" to "set",
        "Reset" to "reset",
    )

    val actionNames: Set<String> = HashSet(actionSteps.keys).also { it.add("Action") }

    val allNames: Set<String> = HashSet<String>().apply {
        addAll(dataBuiltins)
        addAll(lazyBuiltins)
        addAll(actionNames)
    }

    /**
     * The collision rule of spec §5: a builtin name written bare (without `@`)
     * does NOT parse as a call — `Action` is the single exception.
     */
    fun isBuiltin(name: String): Boolean = allNames.contains(name)

    /**
     * `Object.prototype`'s own property names, in V8's
     * `Object.getOwnPropertyNames(Object.prototype)` order.
     *
     * lang-core writes `RESERVED_CALLS = { Query: "Query", Mutation: "Mutation" }`
     * and tests membership with `name in RESERVED_CALLS` — the `in` operator,
     * which walks the PROTOTYPE CHAIN. On a plain object literal that chain is
     * `Object.prototype`, so all twelve of these names answer `true` as well.
     * They are reachable from source: `@ident` lexes to a BUILTIN token with
     * ANY name (fixture `078-reserved-call-prototype-names`).
     */
    val objectPrototypeNames: Set<String> = hashSetOf(
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
    )

    /**
     * Reserved statement-level call names — not builtins, not components.
     *
     * Port of `isReservedCall(name) { return name in RESERVED_CALLS; }`. The
     * `in` operator is prototype-chain aware, so this is `{Query, Mutation}`
     * UNION [objectPrototypeNames] — NOT just the two declared keys.
     *
     * Note `classifyStatement` and `reservedRefType` still compare the name
     * with `===` against the literal `"Query"` / `"Mutation"` (parser.js:45,
     * materialize.js:40), so a prototype name is a reserved call for
     * classification purposes but always yields `refType: "query"`.
     */
    fun isReservedCall(name: String): Boolean =
        name == "Query" || name == "Mutation" || objectPrototypeNames.contains(name)
}
