package dev.appless.openuilang

/**
 * A resolved (post-runtime-evaluation) prop value, as it appears in the
 * canonical expected-tree JSON (spec/fixtures/README.md;
 * spec/openui-lang.md Appendix A).
 *
 * Mirrors `PropValue` in `ios/Packages/OpenUILang/Sources/OpenUILang/ParseResult.swift`.
 */
public sealed interface PropValue {
    /** JSON `null`. `undefined` at a value position is normalized to this. */
    public data object Null : PropValue

    public data class Bool(val value: Boolean) : PropValue

    /**
     * Finite or non-finite. Non-finite values serialize as
     * `{"$number": "NaN" | "Infinity" | "-Infinity"}`.
     */
    public data class Num(val value: Double) : PropValue

    public data class Str(val value: String) : PropValue

    /** Element order preserved; the parser has already applied array-drop rules. */
    public data class Arr(val items: List<PropValue>) : PropValue

    /** Plain object; keys are sorted (UTF-16 code units) at serialization time. */
    public data class Obj(val entries: PropObject) : PropValue

    public data class Element(val node: ElementNode) : PropValue

    /** Deferred click-time value: serializes as `{"$action": {"steps": [...]}}`. */
    public data class Action(val plan: ActionPlan) : PropValue

    /**
     * Leftover AST node in a deferred slot: serializes as `{"$ast": <node>}`
     * with keys sorted deep.
     */
    public data class Ast(val node: PropValue) : PropValue
}

/**
 * A plain JS-like object: insertion-ordered, with UTF-16 code-unit key
 * identity and last-write-wins assignment that keeps the original key
 * position (JS object assignment semantics).
 *
 * Unlike Swift, Kotlin/JVM gets the key identity for free — `String.equals`
 * and `String.hashCode` are code-unit based, so a `LinkedHashMap` already
 * keeps precomposed and decomposed keys distinct (fixture 072). The wrapper
 * exists so the two ports have the same shape and so ordering stays explicit.
 *
 * Deliberately NO structural `equals`/`hashCode`: nothing in the port or its
 * tests compares prop objects by value — trees are compared as canonical JSON
 * bytes via [TreeSerializer] — and a value-equality override here would have
 * to answer whether key ORDER counts, which is a question only the serializer
 * gets to answer (see [TreeSerializer]'s `JS_OWN_KEY_ORDER`).
 */
public class PropObject() {
    private val map = LinkedHashMap<String, PropValue>()

    public constructor(pairs: List<Pair<String, PropValue>>) : this() {
        for ((k, v) in pairs) put(k, v)
    }

    /**
     * The object's own keys in JS `Object.keys(o)` order: canonical array
     * indices (`"0"`–`"4294967294"`) FIRST in ascending numeric order, then
     * every remaining key in insertion order (`OrdinaryOwnPropertyKeys`,
     * ES 10.1.11.1). So `{b, "2", a, "10"}` iterates `"2", "10", b, a`.
     *
     * This is deliberately NOT the serializer's order: `TreeSerializer`
     * additionally sorts the string group, because the reference serializer
     * does `Object.keys(v).sort()` and re-inserts into a fresh object (see
     * `StringJs.JS_OWN_KEY_ORDER`, fixture `075-object-key-index-order`).
     * A consumer iterating props directly gets what JS would give it; a
     * consumer wanting the canonical byte order must serialize.
     */
    public val keys: List<String> get() = jsOwnPropertyKeys(map.keys.toList())

    /** [keys] paired with their values, in the same JS own-key order. */
    public val entries: List<Pair<String, PropValue>>
        get() = keys.map { it to map.getValue(it) }
    public val size: Int get() = map.size
    public fun isEmpty(): Boolean = map.isEmpty()
    public fun has(key: String): Boolean = map.containsKey(key)

    public operator fun get(key: String): PropValue? = map[key]

    public fun put(key: String, value: PropValue?) {
        if (value == null) map.remove(key) else map[key] = value
    }

    public operator fun set(key: String, value: PropValue?): Unit = put(key, value)

    override fun toString(): String = map.toString()
}

/** An element in the resolved tree. */
public data class ElementNode(
    /** Component type name, e.g. `"CardHeader"`. */
    val component: String,
    /**
     * Present iff the element carries a `statementId` field — normally the
     * name of the statement it came from, hence normally a [PropValue.Str]
     * (use [statementIdText]).
     *
     * It is a [PropValue] and not a `String?` because lang-core's ElementNode
     * is a plain JS object and the reference serializer copies the field
     * VERBATIM (`out.statementId = el.statementId`). An object that merely
     * duck-types as an element can therefore carry any value there — see
     * `spec/fixtures/095-duck-element-fields.oui`, where a row with an own
     * `statementId: 42` serializes as `"statementId": 42`.
     */
    val statementId: PropValue? = null,
    /**
     * Named props (positional args already mapped via the contract's property
     * order), EXCLUDING `children`. Props that evaluated to `undefined` are
     * omitted; `null` is kept as [PropValue.Null]. Keys are sorted at
     * serialization time.
     */
    val props: Map<String, PropValue> = emptyMap(),
    /** Present iff the element has a `children` prop (Card, TabItem). */
    val children: PropValue? = null,
) {
    /** [statementId] when it is a string, which is every ordinary element. */
    public val statementIdText: String? get() = (statementId as? PropValue.Str)?.value
}

/**
 * A deferred action: `{steps: [...]}`. Each step is a plain-object value
 * (sorted keys at serialization); a `@Set` step's deferred `valueAST` is a
 * nested [PropValue.Ast].
 */
public data class ActionPlan(val steps: List<PropValue> = emptyList())

/** A parser validation error, in emission order. */
public data class ParseError(
    val code: Code,
    /** Component type name, e.g. `"Toggle"`. */
    val component: String,
    /** JSON pointer into props, e.g. `"/on"`; `""` for component-level errors. */
    val path: String,
    /** Reference implementation's text — informational for comparisons. */
    val message: String,
    /** Omitted from serialization when null. */
    val statementId: String? = null,
) {
    public enum class Code(public val wire: String) {
        MISSING_REQUIRED("missing-required"),
        NULL_REQUIRED("null-required"),
        UNKNOWN_COMPONENT("unknown-component"),
        INLINE_RESERVED("inline-reserved"),
    }
}

/** A per-prop evaluation error (rare). */
public data class RuntimeError(
    val message: String,
    val component: String? = null,
    /**
     * `evaluate-tree.js` copies the failing element's `statementId` field into
     * the error VERBATIM, so this has the same shape as
     * [ElementNode.statementId] and for the same reason.
     */
    val statementId: PropValue? = null,
    val source: String = "runtime",
    val code: String = "runtime-error",
)

/** Parse metadata for one pass. */
public data class ParseMeta(
    /** Pending tail needed auto-closing this pass. */
    val incomplete: Boolean = false,
    /** Refs that failed to resolve, in resolution order, duplicates preserved. */
    val unresolved: List<String> = emptyList(),
    /** Parser validation errors, in emission order. */
    val errors: List<ParseError> = emptyList(),
)

/**
 * The full result of one parse pass: the resolved tree, metadata, materialized
 * state declarations, and runtime evaluation errors.
 */
public data class ParseResult(
    /** `null` means no renderable root (host shows a skeleton). */
    val root: ElementNode? = null,
    val meta: ParseMeta = ParseMeta(),
    /**
     * State declarations keyed by `$name`, with materialized defaults
     * (auto-declared refs map to [PropValue.Null]). Keys sorted at
     * serialization.
     */
    val state: Map<String, PropValue> = emptyMap(),
    val runtimeErrors: List<RuntimeError> = emptyList(),
)
