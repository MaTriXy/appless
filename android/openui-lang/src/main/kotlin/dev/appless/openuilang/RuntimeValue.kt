package dev.appless.openuilang

/**
 * A plain JS-like object: insertion-ordered keys, last write keeps the
 * original key position (JS object assignment semantics).
 *
 * Unlike the Swift port, no `JSKey` wrapper is needed: JVM `String.equals` /
 * `hashCode` are UTF-16 code-unit based, so a `LinkedHashMap` already keeps
 * canonically-equivalent-but-distinct keys apart (precomposed vs decomposed
 * "café" — fixture 072).
 */
internal class RtObject() {
    private val map = LinkedHashMap<String, RtValue>()

    constructor(pairs: List<Pair<String, RtValue>>) : this() {
        for ((k, v) in pairs) put(k, v)
    }

    /**
     * The object's `[[Prototype]]`. A plain object literal starts at
     * `Object.prototype`; [assign]ing `"__proto__"` re-points it, and
     * [RtValue.Null] means a genuinely prototype-less object.
     *
     * This slot is what makes lang-core's duck-typing (`isASTNode`,
     * `isElementNode`, `containsDynamicValue`, the serializer's `isAstNode`)
     * see through a `{"__proto__": …}` entry — see [JsObjects].
     */
    var prototype: RtValue = JsObjects.OBJECT_PROTOTYPE

    /**
     * Own keys in `Object.keys(o)` / `OrdinaryOwnPropertyKeys` order — every
     * canonical array index FIRST in ascending numeric order, then the rest in
     * insertion order.
     *
     * This is the runtime object, and its key order IS tree-observable: an
     * `@Each` template that captures a row object runs it through
     * `toLiteralAST` → `Obj.entries` → the `$ast` entries ARRAY, which the
     * serializer emits verbatim (arrays are never sorted). Fixture
     * `083-runtime-object-key-order`.
     */
    val keys: List<String> get() = jsOwnPropertyKeys(map.keys.toList())
    val entries: List<Pair<String, RtValue>> get() = keys.map { it to map.getValue(it) }
    val values: List<RtValue> get() = keys.map { map.getValue(it) }
    val isEmpty: Boolean get() = map.isEmpty()

    operator fun get(key: String): RtValue? = map[key]

    fun put(key: String, value: RtValue) {
        map[key] = value
    }

    operator fun set(key: String, value: RtValue): Unit = put(key, value)

    fun has(key: String): Boolean = map.containsKey(key)

    /**
     * JS plain-object ASSIGNMENT (`o[key] = value`), which is NOT the same as
     * defining an own property.
     *
     * A fresh `{}` inherits `Object.prototype`'s `__proto__` ACCESSOR, so
     * `o["__proto__"] = v` invokes that setter, and the setter does NOT merely
     * drop the key: for an object (or `null`) `v` it RE-POINTS the receiver's
     * `[[Prototype]]`, which the whole duck-typing layer then reads through
     * (fixtures `080-proto-object-key`, `085`–`087`). For a primitive `v` it
     * does nothing at all. Either way `"__proto__"` never becomes an own
     * property, so it never shows up in `Object.keys` / `JSON.stringify`.
     *
     * When the receiver no longer inherits that accessor (its chain was cut
     * with `"__proto__": null`), assignment falls back to creating an ordinary
     * own property — so the second write in
     * `{"__proto__": null, "__proto__": {…}}` really does produce a
     * `"__proto__"` key.
     *
     * Use this at every site whose JS original is an assignment. Sites whose
     * original is `Object.fromEntries` / `CreateDataPropertyOrThrow` must keep
     * using [put] — those DO create an own `__proto__` (evaluator.js:40).
     */
    fun assign(key: String, value: RtValue) {
        if (key == PROTO_KEY && JsObjects.inheritsProtoAccessor(RtValue.Obj(this))) {
            // ES 20.1.2.11 set Object.prototype.__proto__: object or null
            // re-points the prototype, anything else is a silent no-op.
            if (value.isObjectOrFunction) prototype = value
            else if (value is RtValue.Null) prototype = RtValue.Null
            return
        }
        put(key, value)
    }

    companion object {
        /** The one key JS object ASSIGNMENT never turns into an own property. */
        const val PROTO_KEY: String = JsObjects.PROTO_KEY

        fun of(vararg pairs: Pair<String, RtValue>): RtObject = RtObject(pairs.toList())
    }
}

/** An element node in the materialized/evaluated tree (lang-core `ElementNode`). */
internal class RtElement(
    val typeName: String,
    val props: RtObject,
    val partial: Boolean,
    val hasDynamicProps: Boolean,
    val statementId: String? = null,
) {
    fun withStatementId(id: String?): RtElement =
        RtElement(typeName, props, partial, hasDynamicProps, id)

    fun withProps(newProps: RtObject): RtElement =
        RtElement(typeName, newProps, partial, hasDynamicProps, statementId)
}

/**
 * A dynamically-typed runtime value mirroring the JS value space that flows
 * through materialization and evaluation (spec/openui-lang.md §8–§9).
 * `Undefined` and `Null` are distinct: `undefined` entries are omitted from
 * serialized objects while `null` entries are kept.
 */
internal sealed interface RtValue {
    data object Undefined : RtValue
    data object Null : RtValue
    data class Bool(val value: Boolean) : RtValue
    data class Num(val value: Double) : RtValue
    data class Str(val value: String) : RtValue
    data class Arr(val items: List<RtValue>) : RtValue
    data class Obj(val obj: RtObject) : RtValue
    data class Element(val element: RtElement) : RtValue

    /** A leftover AST node (builtin call, runtime expression, deferred slot). */
    data class Ast(val node: AstNode) : RtValue

    /**
     * A native function value, reachable by inheriting one from a prototype
     * (`$obj.toString`, `$obj.constructor`). `typeof` is `"function"`, not
     * `"object"`, and `JSON.stringify` drops it exactly like `undefined`.
     */
    data class Func(val name: String, val arity: Int) : RtValue

    /**
     * One of the intrinsic prototype objects, reachable through the
     * `Object.prototype.__proto__` GETTER (`$obj.__proto__`).
     */
    data class Proto(val kind: JsProtoKind) : RtValue
}

internal val RtValue.isNullish: Boolean
    get() = this is RtValue.Undefined || this is RtValue.Null

/**
 * `typeof v === "object" && v !== null` in JS terms.
 *
 * A [RtValue.Func] is deliberately EXCLUDED: `typeof fn` is `"function"`, which
 * is what gates `containsDynamicValue`, `evaluatePropCore`'s early return and
 * its plain-object `needsEval` scan.
 */
internal val RtValue.isObjectLike: Boolean
    get() = this is RtValue.Arr || this is RtValue.Obj || this is RtValue.Element ||
        this is RtValue.Ast || this is RtValue.Proto

/** `Type(v) is Object` — [isObjectLike] plus functions (ES "is an Object"). */
internal val RtValue.isObjectOrFunction: Boolean
    get() = isObjectLike || this is RtValue.Func

/**
 * `JSON.stringify` omits an object property whose value is `undefined` OR a
 * FUNCTION (ES 25.5.2 SerializeJSONProperty returns undefined for both, and
 * SerializeJSONObject skips those). Inside an ARRAY both become `null`
 * instead — which is what [Pipeline.convertValue] maps them to.
 */
internal val RtValue.isDroppedByJsonStringify: Boolean
    get() = this is RtValue.Undefined || this is RtValue.Func

/**
 * Convert a plain JSON value (e.g. a schema `default`) into the runtime value
 * space. Object keys are inserted sorted — JSON key order is not observable
 * downstream (the serializer sorts), this just keeps the result deterministic.
 */
internal fun jsonToRtValue(v: JsonValue): RtValue = when (v) {
    is JsonValue.Null -> RtValue.Null
    is JsonValue.Bool -> RtValue.Bool(v.value)
    is JsonValue.Num -> RtValue.Num(v.value)
    is JsonValue.Str -> RtValue.Str(v.value)
    is JsonValue.Arr -> RtValue.Arr(v.value.map { jsonToRtValue(it) })
    is JsonValue.Obj -> {
        val out = RtObject()
        for (key in v.value.keys.sortedWith(JS_STRING_ORDER)) {
            out[key] = jsonToRtValue(v.value.getValue(key))
        }
        RtValue.Obj(out)
    }
}

// ── JS coercion helpers ─────────────────────────────────────────────────────

/** ECMAScript `Number::toString` (shortest round-trip), incl. non-finite. */
internal fun jsNumberToString(d: Double): String = when {
    d.isNaN() -> "NaN"
    d.isInfinite() -> if (d > 0) "Infinity" else "-Infinity"
    else -> TreeSerializer.formatNumber(d)
}

/**
 * JS `Number(string)` semantics — returns NaN for non-numeric strings.
 *
 * Hand-rolled rather than delegated to `String.toDoubleOrNull()`, which is
 * `Double.parseDouble` and accepts a pile of things JS rejects: trailing
 * `d`/`D`/`f`/`F` suffixes (`"1f"` → 1.0, JS → NaN), hex-float literals
 * (`"0x1p3"`), and `Character.isWhitespace` padding. It also REJECTS things
 * JS accepts (`"0x10"` → 16, `"0b101"` → 5, `"Infinity"`).
 *
 * ES *StrWhiteSpace* is exactly the [jsTrim] set.
 */
internal fun jsStringToNumber(s: String): Double {
    val t = s.jsTrim()
    if (t.isEmpty()) return 0.0
    if (t == "Infinity" || t == "+Infinity") return Double.POSITIVE_INFINITY
    if (t == "-Infinity") return Double.NEGATIVE_INFINITY
    // Radix literals (no sign allowed).
    if (t.length > 2 && t[0] == '0') {
        when (t[1]) {
            'x', 'X' -> return parseRadix(t.substring(2), 16)
            'o', 'O' -> return parseRadix(t.substring(2), 8)
            'b', 'B' -> return parseRadix(t.substring(2), 2)
        }
    }
    if (!isStrictDecimalLiteral(t)) return Double.NaN
    return t.toDoubleOrNull() ?: Double.NaN
}

private fun parseRadix(digits: String, radix: Int): Double {
    if (digits.isEmpty()) return Double.NaN
    var value = 0.0
    for (c in digits) {
        val d = when (c) {
            in '0'..'9' -> c - '0'
            in 'a'..'f' -> c - 'a' + 10
            in 'A'..'F' -> c - 'A' + 10
            else -> return Double.NaN
        }
        if (d >= radix) return Double.NaN
        value = value * radix + d
    }
    return value
}

private fun isStrictDecimalLiteral(s: String): Boolean {
    var i = 0
    if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
    var intDigits = 0
    while (i < s.length && s[i] in '0'..'9') { intDigits++; i++ }
    var fracDigits = 0
    if (i < s.length && s[i] == '.') {
        i++
        while (i < s.length && s[i] in '0'..'9') { fracDigits++; i++ }
    }
    if (intDigits == 0 && fracDigits == 0) return false
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        i++
        if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
        var expDigits = 0
        while (i < s.length && s[i] in '0'..'9') { expDigits++; i++ }
        if (expDigits == 0) return false
    }
    return i == s.length
}

/**
 * lang-core `toNumber` (spec §9.1): number → itself (NaN passes through);
 * numeric string → number, non-numeric string → 0; boolean → 1/0; anything
 * else → 0.
 */
internal fun dslToNumber(v: RtValue): Double = when (v) {
    is RtValue.Num -> v.value
    is RtValue.Str -> {
        val n = jsStringToNumber(v.value)
        if (n.isNaN()) 0.0 else n
    }

    is RtValue.Bool -> if (v.value) 1.0 else 0.0
    else -> 0.0
}

/**
 * A JS `TypeError` escaping a prop evaluation. `evaluateElementProps` catches
 * it per prop, keeps the RAW prop value, and records a `runtimeErrors` entry —
 * exactly like `evaluate-tree.js`'s try/catch.
 */
internal class JsTypeError(message: String) : RuntimeException(message)

/**
 * JS `String(value)` semantics — including the case where it THROWS.
 *
 * `String(obj)` is `ToPrimitive(obj, string)`: call `obj.toString()` if
 * callable, else `obj.valueOf()` if callable, else throw
 * `TypeError: Cannot convert object to primitive value`. BOTH lookups go
 * through the prototype chain ([JsObjects.getMember]), so the answer depends on
 * the receiver's `[[Prototype]]`, not just on its own keys:
 *
 * - a plain object inherits `Object.prototype.toString` → `"[object Object]"`;
 * - an own `toString` key shadows it with a non-callable value (this model has
 *   no user function values), so the lookup falls through to
 *   `Object.prototype.valueOf`, which returns the object itself and is
 *   rejected as non-primitive → THROWS (fixture `081-tostring-shadow-throws`);
 * - a prototype-LESS object (`{"__proto__": null, …}`) has neither method, so
 *   it throws as well (fixture `087-proto-null-toprimitive-throws`) — the case
 *   an own-key check alone can never see.
 */
internal fun jsToString(v: RtValue): String = when (v) {
    is RtValue.Undefined -> "undefined"
    is RtValue.Null -> "null"
    is RtValue.Bool -> if (v.value) "true" else "false"
    is RtValue.Num -> jsNumberToString(v.value)
    is RtValue.Str -> v.value
    // Array.prototype.toString → join(","); null/undefined → "". A member that
    // shadows `toString` makes the join itself throw.
    is RtValue.Arr -> v.items.joinToString(",") { if (it.isNullish) "" else jsToString(it) }
    is RtValue.Func -> "function ${v.name}() { [native code] }"
    is RtValue.Proto -> when (v.kind) {
        // The intrinsic prototypes are ordinary objects of their own type:
        // Number.prototype is a Number object wrapping 0, String.prototype
        // wraps "", Boolean.prototype wraps false, Array.prototype is an empty
        // array and Function.prototype is an anonymous native function.
        JsProtoKind.OBJECT -> "[object Object]"
        JsProtoKind.ARRAY -> ""
        JsProtoKind.NUMBER -> "0"
        JsProtoKind.STRING -> ""
        JsProtoKind.BOOLEAN -> "false"
        JsProtoKind.FUNCTION -> "function () { [native code] }"
    }

    is RtValue.Obj, is RtValue.Element, is RtValue.Ast -> objectToPrimitiveString(v)
}

/**
 * `ToPrimitive(v, string)` for the object-shaped runtime values: try
 * `toString`, then `valueOf`, each only if it resolves to a callable.
 */
private fun objectToPrimitiveString(v: RtValue): String {
    val resolved = JsObjects.getMemberWithOwner(v, "toString")
    if (resolved != null && resolved.first is RtValue.Func) {
        val owner = resolved.second
        // `Array.prototype.toString` on a NON-array receiver reads `this.join`,
        // whose `this.length` is undefined → joins zero elements → "". Every
        // other reachable chain ends at `Object.prototype.toString`.
        return if (owner is RtValue.Proto && owner.kind == JsProtoKind.ARRAY) "" else "[object Object]"
    }
    // `valueOf` either is missing (prototype-less object) or is
    // `Object.prototype.valueOf`, which answers the object itself — never a
    // primitive. Both end the same way.
    throw JsTypeError("Cannot convert object to primitive value")
}

/** JS truthiness. */
internal fun jsTruthy(v: RtValue): Boolean = when (v) {
    is RtValue.Undefined, is RtValue.Null -> false
    is RtValue.Bool -> v.value
    is RtValue.Num -> !(v.value == 0.0 || v.value.isNaN())
    is RtValue.Str -> v.value.isNotEmpty()
    else -> true
}

/**
 * JS loose equality (`==`), spec §9.1.
 *
 * KNOWN-DEVIATION (mirrors the Swift port's #3): object-vs-object comparison
 * is reference identity in JS; this port has value semantics and no stable
 * identities, so object == object is uniformly `false` — which is what the
 * oracle produces too, because the materializer always builds freshly
 * distinct objects.
 */
internal fun jsLooseEquals(a: RtValue, b: RtValue): Boolean {
    if (a.isNullish || b.isNullish) return a.isNullish && b.isNullish
    if (a is RtValue.Num && b is RtValue.Num) return a.value == b.value
    // JS compares strings by UTF-16 code units — String.equals on the JVM is
    // exactly that (canonically-equivalent NFC/NFD variants are NOT equal).
    if (a is RtValue.Str && b is RtValue.Str) return a.value == b.value
    if (a is RtValue.Bool && b is RtValue.Bool) return a.value == b.value
    if (a is RtValue.Bool) return jsLooseEquals(RtValue.Num(if (a.value) 1.0 else 0.0), b)
    if (b is RtValue.Bool) return jsLooseEquals(a, RtValue.Num(if (b.value) 1.0 else 0.0))
    if (a is RtValue.Num && b is RtValue.Str) return a.value == jsStringToNumber(b.value)
    if (a is RtValue.Str && b is RtValue.Num) return jsStringToNumber(a.value) == b.value
    // object-vs-primitive: ToPrimitive(object) → string, then compare.
    if (a.isObjectLike && !b.isObjectLike) return jsLooseEquals(RtValue.Str(jsToString(a)), b)
    if (!a.isObjectLike && b.isObjectLike) return jsLooseEquals(a, RtValue.Str(jsToString(b)))
    return false
}
