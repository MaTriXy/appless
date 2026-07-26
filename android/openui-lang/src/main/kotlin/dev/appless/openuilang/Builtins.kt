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

    /** Reserved statement-level call names — not builtins, not components. */
    fun isReservedCall(name: String): Boolean = name == "Query" || name == "Mutation"
}
