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
     * `Object.prototype`'s own property names — a view onto the ONE table in
     * [JsObjects], so the two can never drift apart.
     *
     * Every classification below is a JS property lookup on a plain object
     * literal, and a plain object literal inherits these twelve names.
     */
    val objectPrototypeNames: Set<String> get() = JsObjects.PROTOTYPE_OWN_NAMES.keys

    /**
     * `RESERVED_CALLS = { Query: "Query", Mutation: "Mutation" }` — modelled as
     * a real JS object so that `in` and `[]` both behave.
     */
    private val reservedCalls: RtObject = RtObject.of(
        "Query" to RtValue.Str("Query"),
        "Mutation" to RtValue.Str("Mutation"),
    )

    /**
     * `BUILTINS` — the shared builtin registry, again modelled as a real JS
     * object. Only membership and own-ness matter here; the port dispatches the
     * actual implementations in `Evaluator.callDataBuiltin`.
     */
    private val builtinsRegistry: RtObject = RtObject().also { o ->
        for (name in listOf(
            "Count", "First", "Last", "Sum", "Avg", "Min", "Max",
            "Sort", "Filter", "Round", "Abs", "Floor", "Ceil",
        )) {
            o[name] = RtValue.Str(name)
        }
    }

    /**
     * Reserved statement-level call names — not builtins, not components.
     *
     * Port of `isReservedCall(name) { return name in RESERVED_CALLS; }`. The
     * `in` operator is prototype-chain aware, so this routes through
     * [JsObjects.hasProperty] and answers `true` for `{Query, Mutation}` UNION
     * the twelve `Object.prototype` names — NOT just the two declared keys.
     * They are reachable from source: `@ident` lexes to a BUILTIN token with
     * ANY name (fixture `078-reserved-call-prototype-names`).
     *
     * Note `classifyStatement` and `reservedRefType` still compare the name
     * with `===` against the literal `"Query"` / `"Mutation"` (parser.js:45,
     * materialize.js:40), so a prototype name is a reserved call for
     * classification purposes but always yields `refType: "query"`.
     */
    fun isReservedCall(name: String): Boolean =
        JsObjects.hasProperty(RtValue.Obj(reservedCalls), name)

    /** What `BUILTINS[name]` (evaluator.js:48) resolves to. */
    enum class BuiltinLookup {
        /** Miss — the registry has no such name, own or inherited. */
        MISS,

        /** One of the thirteen real data builtins: `builtin.fn` is callable. */
        OWN,

        /**
         * An `Object.prototype` member reached through the registry's prototype
         * chain. It is TRUTHY, so `evaluate` proceeds to `builtin.fn(...args)`
         * — and `.fn` is `undefined`, so the call throws
         * `TypeError: builtin.fn is not a function`, which `evaluate-tree.js`
         * turns into a `runtimeErrors` entry (fixture
         * `084-reserved-call-expression-throws`).
         */
        INHERITED,
    }

    fun lookupBuiltin(name: String): BuiltinLookup = when {
        builtinsRegistry.has(name) -> BuiltinLookup.OWN
        JsObjects.hasProperty(RtValue.Obj(builtinsRegistry), name) -> BuiltinLookup.INHERITED
        else -> BuiltinLookup.MISS
    }
}
