package dev.appless.openuilang

/**
 * THE JS plain-object model — one shared abstraction for every lookup the
 * reference implementation performs with `[]`, `in` or `.`.
 *
 * Why this file exists at all: lang-core is written in idiomatic JavaScript, so
 * a "plain object" there is never just a map. It carries a `[[Prototype]]`, and
 * three separate families of port bugs all reduced to modelling it as one:
 *
 *  1. `BUILTINS[node.name]` (evaluator.js:48) is a property GET on an object
 *     literal, so it also answers for the twelve `Object.prototype` own names.
 *     `@toString(1)` therefore finds `Object.prototype.toString`, reads `.fn`
 *     off it (undefined) and calls it — `TypeError: builtin.fn is not a
 *     function`, which `evaluate-tree.js` catches into `runtimeErrors`.
 *  2. `o["__proto__"] = v` (materialize.js's `Obj` case, evaluate-prop.js's
 *     object rebuild) is not a dropped key: it invokes `Object.prototype`'s
 *     `__proto__` SETTER and re-points the receiver's `[[Prototype]]`, which
 *     lang-core's duck-typing (`isASTNode`, `isElementNode`,
 *     `containsDynamicValue`, and the serializer's `isAstNode`) then reads
 *     THROUGH.
 *  3. `obj.toString` / `obj.constructor` are ordinary member accesses that
 *     inherit real function values from the prototype chain.
 *
 * Everything the port needs to answer those questions lives here:
 * [PROTOTYPE_OWN_NAMES] (and its siblings) describe the intrinsics,
 * [prototypeOf] gives every runtime value its `[[Prototype]]`, and [getMember]
 * / [hasProperty] are the single implementations of `.`/`[]` and `in`.
 *
 * Mirrors `JSObject.swift`.
 */

/** One own property of an intrinsic prototype object. */
internal sealed interface JsMember {
    /** A native function, rendered `function <name>() { [native code] }`. */
    data class Fn(val name: String, val arity: Int) : JsMember

    /** A plain data property (`Array.prototype.length`, `Function.prototype.name`). */
    data class Data(val value: RtValue) : JsMember

    /**
     * `Object.prototype.__proto__` — an ACCESSOR pair. The getter answers the
     * RECEIVER's `[[Prototype]]`; the setter re-points it (see [RtObject.assign]).
     */
    data object ProtoAccessor : JsMember

    /**
     * `Function.prototype.arguments` / `.caller` — accessors that always throw
     * in strict mode (all module code is strict).
     */
    data object PoisonPill : JsMember
}

/** The intrinsic prototype objects this value model can reach. */
internal enum class JsProtoKind { OBJECT, ARRAY, NUMBER, STRING, BOOLEAN, FUNCTION }

internal object JsObjects {

    /** V8's message when `Function.prototype.arguments`/`.caller` is read. */
    const val POISON_PILL_MESSAGE: String =
        "'caller', 'callee', and 'arguments' properties may not be accessed on " +
            "strict mode functions or the arguments objects for calls to them"

    /** V8's message for `BUILTINS[name].fn(...)` when `.fn` is undefined. */
    const val BUILTIN_FN_MESSAGE: String = "builtin.fn is not a function"

    /** The `__proto__` key — the one key plain-object ASSIGNMENT never creates. */
    const val PROTO_KEY: String = "__proto__"

    // ── Intrinsic own-property tables ──────────────────────────────────────
    //
    // Generated verbatim from V8 (`Object.getOwnPropertyNames(X.prototype)`
    // plus each descriptor's kind, function name and arity), in V8's own
    // enumeration order.

    private val OBJECT_OWN: Map<String, JsMember> = linkedMapOf(
        "constructor" to JsMember.Fn("Object", 1),
        "__defineGetter__" to JsMember.Fn("__defineGetter__", 2),
        "__defineSetter__" to JsMember.Fn("__defineSetter__", 2),
        "hasOwnProperty" to JsMember.Fn("hasOwnProperty", 1),
        "__lookupGetter__" to JsMember.Fn("__lookupGetter__", 1),
        "__lookupSetter__" to JsMember.Fn("__lookupSetter__", 1),
        "isPrototypeOf" to JsMember.Fn("isPrototypeOf", 1),
        "propertyIsEnumerable" to JsMember.Fn("propertyIsEnumerable", 1),
        "toString" to JsMember.Fn("toString", 0),
        "valueOf" to JsMember.Fn("valueOf", 0),
        "__proto__" to JsMember.ProtoAccessor,
        "toLocaleString" to JsMember.Fn("toLocaleString", 0),
    )

    private val ARRAY_OWN: Map<String, JsMember> = linkedMapOf(
        "length" to JsMember.Data(RtValue.Num(0.0)),
        "constructor" to JsMember.Fn("Array", 1),
        "at" to JsMember.Fn("at", 1),
        "concat" to JsMember.Fn("concat", 1),
        "copyWithin" to JsMember.Fn("copyWithin", 2),
        "fill" to JsMember.Fn("fill", 1),
        "find" to JsMember.Fn("find", 1),
        "findIndex" to JsMember.Fn("findIndex", 1),
        "findLast" to JsMember.Fn("findLast", 1),
        "findLastIndex" to JsMember.Fn("findLastIndex", 1),
        "lastIndexOf" to JsMember.Fn("lastIndexOf", 1),
        "pop" to JsMember.Fn("pop", 0),
        "push" to JsMember.Fn("push", 1),
        "reverse" to JsMember.Fn("reverse", 0),
        "shift" to JsMember.Fn("shift", 0),
        "unshift" to JsMember.Fn("unshift", 1),
        "slice" to JsMember.Fn("slice", 2),
        "sort" to JsMember.Fn("sort", 1),
        "splice" to JsMember.Fn("splice", 2),
        "includes" to JsMember.Fn("includes", 1),
        "indexOf" to JsMember.Fn("indexOf", 1),
        "join" to JsMember.Fn("join", 1),
        "keys" to JsMember.Fn("keys", 0),
        "entries" to JsMember.Fn("entries", 0),
        "values" to JsMember.Fn("values", 0),
        "forEach" to JsMember.Fn("forEach", 1),
        "filter" to JsMember.Fn("filter", 1),
        "flat" to JsMember.Fn("flat", 0),
        "flatMap" to JsMember.Fn("flatMap", 1),
        "map" to JsMember.Fn("map", 1),
        "every" to JsMember.Fn("every", 1),
        "some" to JsMember.Fn("some", 1),
        "reduce" to JsMember.Fn("reduce", 1),
        "reduceRight" to JsMember.Fn("reduceRight", 1),
        "toReversed" to JsMember.Fn("toReversed", 0),
        "toSorted" to JsMember.Fn("toSorted", 1),
        "toSpliced" to JsMember.Fn("toSpliced", 2),
        "with" to JsMember.Fn("with", 2),
        "toLocaleString" to JsMember.Fn("toLocaleString", 0),
        "toString" to JsMember.Fn("toString", 0),
    )

    private val NUMBER_OWN: Map<String, JsMember> = linkedMapOf(
        "constructor" to JsMember.Fn("Number", 1),
        "toExponential" to JsMember.Fn("toExponential", 1),
        "toFixed" to JsMember.Fn("toFixed", 1),
        "toPrecision" to JsMember.Fn("toPrecision", 1),
        "toString" to JsMember.Fn("toString", 1),
        "valueOf" to JsMember.Fn("valueOf", 0),
        "toLocaleString" to JsMember.Fn("toLocaleString", 0),
    )

    private val STRING_OWN: Map<String, JsMember> = linkedMapOf(
        "length" to JsMember.Data(RtValue.Num(0.0)),
        "constructor" to JsMember.Fn("String", 1),
        "anchor" to JsMember.Fn("anchor", 1),
        "at" to JsMember.Fn("at", 1),
        "big" to JsMember.Fn("big", 0),
        "blink" to JsMember.Fn("blink", 0),
        "bold" to JsMember.Fn("bold", 0),
        "charAt" to JsMember.Fn("charAt", 1),
        "charCodeAt" to JsMember.Fn("charCodeAt", 1),
        "codePointAt" to JsMember.Fn("codePointAt", 1),
        "concat" to JsMember.Fn("concat", 1),
        "endsWith" to JsMember.Fn("endsWith", 1),
        "fontcolor" to JsMember.Fn("fontcolor", 1),
        "fontsize" to JsMember.Fn("fontsize", 1),
        "fixed" to JsMember.Fn("fixed", 0),
        "includes" to JsMember.Fn("includes", 1),
        "indexOf" to JsMember.Fn("indexOf", 1),
        "isWellFormed" to JsMember.Fn("isWellFormed", 0),
        "italics" to JsMember.Fn("italics", 0),
        "lastIndexOf" to JsMember.Fn("lastIndexOf", 1),
        "link" to JsMember.Fn("link", 1),
        "localeCompare" to JsMember.Fn("localeCompare", 1),
        "match" to JsMember.Fn("match", 1),
        "matchAll" to JsMember.Fn("matchAll", 1),
        "normalize" to JsMember.Fn("normalize", 0),
        "padEnd" to JsMember.Fn("padEnd", 1),
        "padStart" to JsMember.Fn("padStart", 1),
        "repeat" to JsMember.Fn("repeat", 1),
        "replace" to JsMember.Fn("replace", 2),
        "replaceAll" to JsMember.Fn("replaceAll", 2),
        "search" to JsMember.Fn("search", 1),
        "slice" to JsMember.Fn("slice", 2),
        "small" to JsMember.Fn("small", 0),
        "split" to JsMember.Fn("split", 2),
        "strike" to JsMember.Fn("strike", 0),
        "sub" to JsMember.Fn("sub", 0),
        "substr" to JsMember.Fn("substr", 2),
        "substring" to JsMember.Fn("substring", 2),
        "sup" to JsMember.Fn("sup", 0),
        "startsWith" to JsMember.Fn("startsWith", 1),
        "toString" to JsMember.Fn("toString", 0),
        "toWellFormed" to JsMember.Fn("toWellFormed", 0),
        "trim" to JsMember.Fn("trim", 0),
        "trimStart" to JsMember.Fn("trimStart", 0),
        "trimLeft" to JsMember.Fn("trimStart", 0),
        "trimEnd" to JsMember.Fn("trimEnd", 0),
        "trimRight" to JsMember.Fn("trimEnd", 0),
        "toLocaleLowerCase" to JsMember.Fn("toLocaleLowerCase", 0),
        "toLocaleUpperCase" to JsMember.Fn("toLocaleUpperCase", 0),
        "toLowerCase" to JsMember.Fn("toLowerCase", 0),
        "toUpperCase" to JsMember.Fn("toUpperCase", 0),
        "valueOf" to JsMember.Fn("valueOf", 0),
    )

    private val BOOLEAN_OWN: Map<String, JsMember> = linkedMapOf(
        "constructor" to JsMember.Fn("Boolean", 1),
        "toString" to JsMember.Fn("toString", 0),
        "valueOf" to JsMember.Fn("valueOf", 0),
    )

    private val FUNCTION_OWN: Map<String, JsMember> = linkedMapOf(
        "length" to JsMember.Data(RtValue.Num(0.0)),
        "name" to JsMember.Data(RtValue.Str("")),
        "arguments" to JsMember.PoisonPill,
        "caller" to JsMember.PoisonPill,
        "constructor" to JsMember.Fn("Function", 1),
        "apply" to JsMember.Fn("apply", 2),
        "bind" to JsMember.Fn("bind", 1),
        "call" to JsMember.Fn("call", 1),
        "toString" to JsMember.Fn("toString", 0),
    )

    /**
     * `Object.prototype`'s own property names — THE table the whole file exists
     * for. Every lookup lang-core performs on a plain object literal
     * (`BUILTINS[name]`, `name in RESERVED_CALLS`, `obj.field`) falls through to
     * exactly these twelve names when the own lookup misses.
     */
    val PROTOTYPE_OWN_NAMES: Map<String, JsMember> get() = OBJECT_OWN

    fun intrinsicOwn(kind: JsProtoKind): Map<String, JsMember> = when (kind) {
        JsProtoKind.OBJECT -> OBJECT_OWN
        JsProtoKind.ARRAY -> ARRAY_OWN
        JsProtoKind.NUMBER -> NUMBER_OWN
        JsProtoKind.STRING -> STRING_OWN
        JsProtoKind.BOOLEAN -> BOOLEAN_OWN
        JsProtoKind.FUNCTION -> FUNCTION_OWN
    }

    /** The default `[[Prototype]]` of a plain object literal. */
    val OBJECT_PROTOTYPE: RtValue = RtValue.Proto(JsProtoKind.OBJECT)

    // ── The chain ──────────────────────────────────────────────────────────

    /**
     * `Object.getPrototypeOf(v)` — `null` (Kotlin) means the value has no
     * `[[Prototype]]` concept at all (`undefined` / `null`, where JS throws on
     * member access); [RtValue.Null] means a genuinely prototype-less object.
     */
    fun prototypeOf(v: RtValue): RtValue? = when (v) {
        is RtValue.Undefined, is RtValue.Null -> null
        is RtValue.Obj -> v.obj.prototype
        is RtValue.Arr -> RtValue.Proto(JsProtoKind.ARRAY)
        is RtValue.Num -> RtValue.Proto(JsProtoKind.NUMBER)
        is RtValue.Str -> RtValue.Proto(JsProtoKind.STRING)
        is RtValue.Bool -> RtValue.Proto(JsProtoKind.BOOLEAN)
        is RtValue.Func -> RtValue.Proto(JsProtoKind.FUNCTION)
        // ElementNodes and AST nodes are plain object literals in JS.
        is RtValue.Element, is RtValue.Ast -> OBJECT_PROTOTYPE
        is RtValue.Proto ->
            if (v.kind == JsProtoKind.OBJECT) RtValue.Null else OBJECT_PROTOTYPE
    }

    /**
     * `Object.getOwnPropertyDescriptor(v, key)` reduced to what this value model
     * needs: the own property's value, or `null` when the key is not own.
     */
    private fun ownMember(v: RtValue, key: String): JsMember? = when (v) {
        is RtValue.Obj -> v.obj[key]?.let { JsMember.Data(it) }
        is RtValue.Proto -> intrinsicOwn(v.kind)[key]
        is RtValue.Func -> when (key) {
            "length" -> JsMember.Data(RtValue.Num(v.arity.toDouble()))
            "name" -> JsMember.Data(RtValue.Str(v.name))
            else -> null
        }

        is RtValue.Arr -> when {
            key == "length" -> JsMember.Data(RtValue.Num(v.items.size.toDouble()))
            else -> {
                val i = jsCanonicalArrayIndex(key)
                if (i >= 0 && i < v.items.size) JsMember.Data(v.items[i.toInt()]) else null
            }
        }

        is RtValue.Str -> when {
            key == "length" -> JsMember.Data(RtValue.Num(v.value.length.toDouble()))
            else -> {
                val i = jsCanonicalArrayIndex(key)
                if (i >= 0 && i < v.value.length) {
                    JsMember.Data(RtValue.Str(v.value[i.toInt()].toString()))
                } else {
                    null
                }
            }
        }

        // An ElementNode is a plain object of its own fields; so is an AST node.
        is RtValue.Element -> elementOwn(v.element, key)?.let { JsMember.Data(it) }
        is RtValue.Ast -> astOwn(v.node, key)?.let { JsMember.Data(it) }

        is RtValue.Num, is RtValue.Bool, is RtValue.Undefined, is RtValue.Null -> null
    }

    /**
     * `receiver[key]` — own lookup, then the whole prototype chain.
     *
     * Throws [JsTypeError] for the `Function.prototype.arguments`/`.caller`
     * poison pills, exactly like V8.
     */
    fun getMember(receiver: RtValue, key: String): RtValue =
        getMemberWithOwner(receiver, key)?.first ?: RtValue.Undefined

    /**
     * [getMember] plus the chain link the property was found on — needed by
     * `ToPrimitive`, which behaves differently depending on WHICH intrinsic
     * `toString` it ended up resolving.
     */
    fun getMemberWithOwner(receiver: RtValue, key: String): Pair<RtValue, RtValue>? {
        var cur: RtValue = receiver
        while (true) {
            val own = ownMember(cur, key)
            if (own != null) {
                val value = when (own) {
                    is JsMember.Data -> own.value
                    is JsMember.Fn -> RtValue.Func(own.name, own.arity)
                    // The getter answers the RECEIVER's prototype, not the
                    // prototype of the link the accessor was found on.
                    is JsMember.ProtoAccessor -> prototypeOf(receiver) ?: RtValue.Undefined
                    is JsMember.PoisonPill -> throw JsTypeError(POISON_PILL_MESSAGE)
                }
                return value to cur
            }
            val proto = prototypeOf(cur) ?: return null
            if (proto is RtValue.Null) return null
            cur = proto
        }
    }

    /** The `in` operator: own lookup plus the whole prototype chain. */
    fun hasProperty(receiver: RtValue, key: String): Boolean {
        var cur: RtValue = receiver
        while (true) {
            if (ownMember(cur, key) != null) return true
            val proto = prototypeOf(cur) ?: return false
            if (proto is RtValue.Null) return false
            cur = proto
        }
    }

    /**
     * `Object.keys(v)` — the own ENUMERABLE string keys of `ToObject(v)`, in
     * `OrdinaryOwnPropertyKeys` order.
     *
     * The BOXING is the whole point: `Object.keys` accepts every value except
     * `undefined`/`null`, and each primitive wrapper has different own keys.
     * Measured on node v22:
     *
     * ```
     * Object.keys(1) -> []          Object.keys(true) -> []
     * Object.keys("ab") -> ["0","1"]  Object.keys([1,2]) -> ["0","1"]
     * Object.keys(Array.prototype) -> []   Object.keys(function f(){}) -> []
     * ```
     *
     * `length` is NON-enumerable on arrays and String wrappers, `name`/`length`
     * are non-enumerable on functions, and every own property of every
     * intrinsic prototype is non-enumerable too — so all four answer `[]`/
     * index-only.
     *
     * Returns `null` for `undefined`/`null`, where JS throws
     * `TypeError: Cannot convert undefined or null to object`.
     */
    fun objectKeys(v: RtValue): List<String>? = when (v) {
        is RtValue.Undefined, is RtValue.Null -> null
        is RtValue.Num, is RtValue.Bool, is RtValue.Func, is RtValue.Proto -> emptyList()
        is RtValue.Str -> (0 until v.value.length).map { it.toString() }
        is RtValue.Arr -> v.items.indices.map { it.toString() }
        is RtValue.Obj -> v.obj.keys
        is RtValue.Element -> ELEMENT_FIELD_NAMES.filter { elementOwn(v.element, it) != null }
        is RtValue.Ast -> AST_FIELD_NAMES.filter { astOwn(v.node, it) != null }
    }

    /** `Object.values(v)`; `[]` where [objectKeys] would throw. */
    fun objectValues(v: RtValue): List<RtValue> =
        objectKeys(v)?.map { getMember(v, it) } ?: emptyList()

    /**
     * Every field name an ElementNode object literal can carry, in the order
     * `materialize.js` creates them (`{ type, typeName, props, partial,
     * hasDynamicProps }`, with `statementId` assigned afterwards). Key ORDER is
     * never observable in the emitted tree — every serializer object is sorted
     * — but the set is.
     */
    private val ELEMENT_FIELD_NAMES: List<String> =
        listOf("type", "typeName", "props", "partial", "hasDynamicProps", "statementId")

    /** Every field name any AST node object literal can carry. */
    private val AST_FIELD_NAMES: List<String> = listOf(
        "k", "v", "n", "refType", "els", "entries", "name", "args", "mappedProps",
        "op", "left", "right", "operand", "cond", "then", "else", "obj", "field",
        "index", "target", "value",
    )

    /**
     * True when the receiver still inherits `Object.prototype`'s `__proto__`
     * SETTER — the precondition for `o["__proto__"] = v` re-pointing the
     * prototype instead of creating an own key (`Object.create(null)`-style
     * objects have no setter, so there assignment DOES create an own key).
     */
    fun inheritsProtoAccessor(start: RtValue): Boolean {
        var cur: RtValue? = prototypeOf(start)
        while (cur != null && cur !is RtValue.Null) {
            if (ownMember(cur, PROTO_KEY) is JsMember.ProtoAccessor) return true
            cur = prototypeOf(cur)
        }
        return false
    }

    // ── Own fields of the port's structured objects ────────────────────────

    private fun elementOwn(el: RtElement, key: String): RtValue? = when (key) {
        "type" -> RtValue.Str("element")
        "typeName" -> RtValue.Str(el.typeName)
        "props" -> RtValue.Obj(el.props)
        "partial" -> RtValue.Bool(el.partial)
        "hasDynamicProps" -> RtValue.Bool(el.hasDynamicProps)
        "statementId" -> el.statementId?.let { RtValue.Str(it) }
        else -> null
    }

    /** The own fields of an AST node, which is a plain object literal in JS. */
    private fun astOwn(node: AstNode, key: String): RtValue? {
        if (key == "k") return RtValue.Str(node.kindTag)
        return when (node) {
            is AstNode.Str -> if (key == "v") RtValue.Str(node.v) else null
            is AstNode.Num -> if (key == "v") RtValue.Num(node.v) else null
            is AstNode.Bool -> if (key == "v") RtValue.Bool(node.v) else null
            is AstNode.Null -> null
            is AstNode.Ph -> if (key == "n") RtValue.Str(node.n) else null
            is AstNode.Ref -> if (key == "n") RtValue.Str(node.n) else null
            is AstNode.StateRef -> if (key == "n") RtValue.Str(node.n) else null
            is AstNode.RuntimeRef -> when (key) {
                "n" -> RtValue.Str(node.n)
                "refType" -> RtValue.Str(node.refType)
                else -> null
            }

            is AstNode.Arr ->
                if (key == "els") RtValue.Arr(node.els.map { RtValue.Ast(it) }) else null

            is AstNode.Obj -> if (key == "entries") {
                RtValue.Arr(
                    node.entries.map {
                        RtValue.Arr(listOf(RtValue.Str(it.first), RtValue.Ast(it.second)))
                    }
                )
            } else {
                null
            }

            is AstNode.Comp -> when (key) {
                "name" -> RtValue.Str(node.name)
                "args" -> RtValue.Arr(node.args.map { RtValue.Ast(it) })
                "mappedProps" -> node.mappedProps?.let { mapped ->
                    val o = RtObject()
                    for ((k, v) in mapped) o[k] = RtValue.Ast(v)
                    RtValue.Obj(o)
                }

                else -> null
            }

            is AstNode.BinOp -> when (key) {
                "op" -> RtValue.Str(node.op)
                "left" -> RtValue.Ast(node.left)
                "right" -> RtValue.Ast(node.right)
                else -> null
            }

            is AstNode.UnaryOp -> when (key) {
                "op" -> RtValue.Str(node.op)
                "operand" -> RtValue.Ast(node.operand)
                else -> null
            }

            is AstNode.Ternary -> when (key) {
                "cond" -> RtValue.Ast(node.cond)
                "then" -> RtValue.Ast(node.then)
                "else" -> RtValue.Ast(node.orElse)
                else -> null
            }

            is AstNode.Member -> when (key) {
                "obj" -> RtValue.Ast(node.obj)
                "field" -> RtValue.Str(node.field)
                else -> null
            }

            is AstNode.Index -> when (key) {
                "obj" -> RtValue.Ast(node.obj)
                "index" -> RtValue.Ast(node.index)
                else -> null
            }

            is AstNode.Assign -> when (key) {
                "target" -> RtValue.Str(node.target)
                "value" -> RtValue.Ast(node.value)
                else -> null
            }
        }
    }

    // ── Duck-typing, prototype-chain aware ─────────────────────────────────

    /**
     * `parser/ast.js` `isASTNode(value)`: an object (not an array) whose `k` —
     * read through the PROTOTYPE CHAIN — is one of the AST discriminants.
     *
     * Returns the underlying node when the port can name it. A value inherits
     * AST-ness from a real [RtValue.Ast] link in its chain; a plain object that
     * merely *looks* like an AST node without one is KNOWN-DEVIATION #6 (see
     * README) and answers `null` here, as before.
     */
    fun astNodeView(v: RtValue): AstNode? {
        when (v) {
            is RtValue.Ast -> return v.node
            is RtValue.Obj -> {
                var cur: RtValue? = prototypeOf(v)
                // An own `k` shadows the chain — deviation #6 territory.
                if (v.obj.has("k")) return null
                while (cur != null && cur !is RtValue.Null) {
                    if (cur is RtValue.Ast) return cur.node
                    if (cur is RtValue.Obj && cur.obj.has("k")) return null
                    cur = prototypeOf(cur)
                }
                return null
            }

            else -> return null
        }
    }

    /**
     * The serializer's looser `isAstNode(v)`: ANY object (not an array) whose
     * `k` is a string, AST discriminant or not (serialize.mjs:14).
     */
    fun serializerIsAstNode(v: RtValue): Boolean = when (v) {
        is RtValue.Ast -> true
        is RtValue.Obj, is RtValue.Element, is RtValue.Proto, is RtValue.Func ->
            getMember(v, "k") is RtValue.Str

        else -> false
    }

    /**
     * `parser/types.js` `isElementNode(value)` — read through the prototype
     * chain, exactly like the reference: `type === "element"`, string
     * `typeName`, non-null object `props`, boolean `partial`.
     *
     * `typeof props === "object"` is true for ARRAYS too (and for the intrinsic
     * prototypes), so `props` is deliberately kept as a raw [RtValue] rather
     * than an [RtObject].
     */
    fun runtimeElementRef(v: RtValue): JsElementRef? {
        val ref = elementRefCommon(v) ?: return null
        val props = ref.props
        // typeof props === "object" && props !== null
        if (!props.isObjectLike) return null
        // typeof partial === "boolean"
        if (getMember(v, "partial") !is RtValue.Bool) return null
        return ref
    }

    /**
     * The SERIALIZER's looser `isElementNode(v)` (serialize.mjs:9-11): only
     * `v.type === "element"` and `typeof v.typeName === "string"`, both
     * ordinary GETs and therefore chain-aware. It does NOT check `props` or
     * `partial`, so it accepts shapes [runtimeElementRef] rejects — e.g.
     * `{type: "element", typeName: "X", props: 7}` serializes as an element
     * with empty props (`Object.keys(7)` is `[]`).
     */
    fun serializerElementRef(v: RtValue): JsElementRef? = elementRefCommon(v)

    /** The two checks both duck-type tests share, all chain-aware GETs. */
    private fun elementRefCommon(v: RtValue): JsElementRef? {
        if (v is RtValue.Element) {
            return JsElementRef(
                receiver = v,
                typeName = v.element.typeName,
                props = RtValue.Obj(v.element.props),
                statementId = v.element.statementId?.let { RtValue.Str(it) } ?: RtValue.Undefined,
                hasDynamicProps = RtValue.Bool(v.element.hasDynamicProps),
                element = v.element,
            )
        }
        // `!!value && typeof value === "object" && !Array.isArray(value)`.
        // (`typeof fn` is `"function"`, so functions never get this far either.)
        if (!v.isObjectLike || v is RtValue.Arr) return null
        if ((getMember(v, "type") as? RtValue.Str)?.value != "element") return null
        val typeName = (getMember(v, "typeName") as? RtValue.Str)?.value ?: return null
        return JsElementRef(
            receiver = v,
            typeName = typeName,
            props = getMember(v, "props"),
            statementId = getMember(v, "statementId"),
            hasDynamicProps = getMember(v, "hasDynamicProps"),
            element = null,
        )
    }
}

/**
 * An element-like receiver plus the five fields lang-core then reads off it —
 * every one an ordinary property GET, so every one is prototype-chain aware.
 *
 * The reference has ONE representation for elements (a plain object literal),
 * so `isElementNode` answering true says nothing about the field TYPES beyond
 * what the guard itself checked. [element] is non-null only for the ordinary
 * case where the receiver is the port's typed [RtElement]; a duck-typed object
 * keeps its fields raw.
 */
internal class JsElementRef(
    val receiver: RtValue,
    val typeName: String,
    val props: RtValue,
    val statementId: RtValue,
    val hasDynamicProps: RtValue,
    val element: RtElement?,
)
