package dev.appless.openuilang

/**
 * Replays the app's steady-state Renderer pipeline on a parse result
 * (spec/openui-lang.md §1 processing pipeline, Appendix A result shapes;
 * spec/fixtures/README.md "How expected trees are produced"): initialize the
 * state store from declarations, evaluate the root element's props, and
 * convert everything into the public (serializable) shapes.
 */
internal object Pipeline {

    fun run(internalResult: InternalResult): ParseResult {
        // Store initialization: declared defaults only (no persisted values).
        val store = LinkedHashMap<String, RtValue>()
        for (key in internalResult.stateDeclarations.keys) {
            store[key] = internalResult.stateDeclarations[key]!!
        }
        val evaluator = Evaluator(store)
        val evaluatedRoot: RtValue? = internalResult.root?.let { evaluator.evaluateElementProps(it) }

        val state = LinkedHashMap<String, PropValue>()
        for (key in internalResult.stateDeclarations.keys) {
            state[key] = convertValue(internalResult.stateDeclarations[key]!!)
        }

        // `serializeExpected`: `evaluatedRoot ? serializeElement(evaluatedRoot) : null`.
        // The evaluated root can have LOST its element identity (the
        // `{ ...el, props }` spread drops inherited fields), in which case the
        // reference calls `serializeElement` on a non-element anyway and
        // `el.typeName` comes out `undefined` — see [convertRootLike].
        return ParseResult(
            root = evaluatedRoot?.let { convertRootLike(it) },
            meta = ParseMeta(
                incomplete = internalResult.incomplete,
                unresolved = internalResult.unresolved,
                errors = internalResult.errors,
            ),
            state = state,
            // Populated by `Evaluator.evaluateElementProps`'s per-prop catch —
            // the JS `evalCtx.errors` array (fixture
            // `081-tostring-shadow-throws`).
            runtimeErrors = evaluator.runtimeErrors.toList(),
        )
    }

    // ── RtValue → PropValue conversion (mirrors generator/lib/serialize.mjs) ──

    fun convertElement(el: RtElement): ElementNode = convertElementFields(
        typeName = RtValue.Str(el.typeName),
        statementId = el.statementId?.let { RtValue.Str(it) } ?: RtValue.Undefined,
        props = RtValue.Obj(el.props),
    )

    private fun convertElementRef(ref: JsElementRef): ElementNode =
        convertElementFields(RtValue.Str(ref.typeName), ref.statementId, ref.props)

    /**
     * serialize.mjs `serializeElement`. Every field is read off the receiver
     * through the prototype chain by the caller; `props` is then enumerated by
     * `Object.keys(el.props)` — an OWN-key enumeration of whatever that GET
     * produced, so a non-object `props` is not an error (`Object.keys(7)` is
     * `[]`, `Object.keys("ab")` is `["0","1"]`).
     *
     * `statementId` is copied VERBATIM (`out.statementId = el.statementId`) —
     * no `serializeValue`, hence no `$ast`/`$action`/`$number` treatment; see
     * [rawJson].
     */
    private fun convertElementFields(
        typeName: RtValue,
        statementId: RtValue,
        props: RtValue,
    ): ElementNode {
        val out = LinkedHashMap<String, PropValue>()
        var children: PropValue? = null
        for (key in JsObjects.objectKeys(props) ?: emptyList()) {
            // `props[key] = …` / `children = …` — plain assignment again.
            if (key == RtObject.PROTO_KEY) continue
            val value = JsObjects.getMember(props, key)
            if (value.isDroppedByJsonStringify) continue
            if (key == "children") children = convertValue(value) else out[key] = convertValue(value)
        }
        // `out.component = el.typeName`. Only the root slot can reach this with
        // a non-string `typeName`, and there it is always `undefined`: every
        // other caller went through a duck-type test that already required a
        // STRING `typeName`, and the one that did not (`serializeExpected`'s
        // root) sees a `{...el}` spread, which either kept the own — hence
        // string-checked — `typeName` or dropped it entirely.
        return ElementNode(
            component = (typeName as? RtValue.Str)?.value ?: "",
            statementId = rawJson(statementId),
            props = out,
            children = children,
            componentPresent = typeName is RtValue.Str,
        )
    }

    /**
     * `serializeExpected`'s root slot: `evaluatedRoot ?
     * serializeElement(evaluatedRoot) : null`. The call is UNCONDITIONAL, so a
     * root that lost its element identity during evaluation (the
     * `{ ...el, props }` spread drops fields that were only INHERITED) is still
     * run through `serializeElement` — `el.typeName` then reads `undefined` and
     * `JSON.stringify` omits the `component` key entirely (fixture
     * `096-duck-element-proto-spread`).
     */
    private fun convertRootLike(v: RtValue): ElementNode {
        JsObjects.serializerElementRef(v)?.let { return convertElementRef(it) }
        return convertElementFields(
            typeName = JsObjects.getMember(v, "typeName"),
            statementId = JsObjects.getMember(v, "statementId"),
            props = JsObjects.getMember(v, "props"),
        )
    }

    /**
     * Plain `JSON.stringify` semantics for a value the reference serializer
     * copies VERBATIM instead of routing through `serializeValue`: no
     * element/action/AST duck-typing and, notably, no `{"$number": …}` — raw
     * `JSON.stringify` writes `null` for NaN and ±Infinity.
     *
     * `null` (Kotlin) means the value is dropped entirely: `undefined` and
     * functions are omitted from the emitted object.
     */
    internal fun rawJson(v: RtValue): PropValue? = when (v) {
        is RtValue.Undefined, is RtValue.Func -> null
        is RtValue.Null -> PropValue.Null
        is RtValue.Bool -> PropValue.Bool(v.value)
        is RtValue.Num -> if (v.value.isFinite()) PropValue.Num(v.value) else PropValue.Null
        is RtValue.Str -> PropValue.Str(v.value)
        is RtValue.Arr -> PropValue.Arr(v.items.map { rawJson(it) ?: PropValue.Null })
        is RtValue.Proto ->
            if (v.kind == JsProtoKind.ARRAY) PropValue.Arr(emptyList()) else PropValue.Obj(PropObject())

        is RtValue.Obj, is RtValue.Element, is RtValue.Ast -> {
            // `JSON.stringify` reads the SOURCE object's own keys; unlike the
            // serializer's rebuild there is no `out[key] = …` assignment here,
            // so an own `"__proto__"` key IS emitted
            // (`JSON.stringify(Object.fromEntries([["__proto__",1]]))` is
            // `{"__proto__":1}`).
            val out = PropObject()
            for (key in JsObjects.objectKeys(v) ?: emptyList()) {
                rawJson(JsObjects.getMember(v, key))?.let { out[key] = it }
            }
            PropValue.Obj(out)
        }
    }

    fun convertValue(v: RtValue): PropValue = when (v) {
        // `JSON.stringify` drops a function-valued property exactly like an
        // `undefined` one (and writes `null` for one inside an array), so a
        // native function inherited from a prototype serializes as nothing.
        is RtValue.Undefined, is RtValue.Null, is RtValue.Func -> PropValue.Null
        is RtValue.Bool -> PropValue.Bool(v.value)
        is RtValue.Num -> PropValue.Num(v.value)
        is RtValue.Str -> PropValue.Str(v.value)
        is RtValue.Arr -> PropValue.Arr(v.items.map { convertValue(it) })
        is RtValue.Element -> PropValue.Element(convertElement(v.element))
        is RtValue.Ast -> PropValue.Ast(convertAst(v.node))
        // Array.prototype is an empty array; every other intrinsic prototype
        // is an object with no enumerable own keys.
        is RtValue.Proto ->
            if (v.kind == JsProtoKind.ARRAY) {
                PropValue.Arr(emptyList())
            } else {
                PropValue.Obj(PropObject())
            }

        is RtValue.Obj -> {
            // serialize.mjs tests in this order, and every test reads through
            // the PROTOTYPE CHAIN (`v.type`, `v.steps`, `"type" in v`, `v.k`)
            // while the plain-object fallback enumerates OWN keys only. So a
            // `{"__proto__": TextContent(…), …}` row serializes as the
            // inherited ELEMENT (fixture `086-proto-component-valued`), and a row whose prototype is
            // an AST node serializes as `{"$ast": <own keys>}` (fixture `085-proto-object-valued`).
            // NOTE the serializer's `isElementNode` is LOOSER than the runtime
            // one: only `type === "element"` and a string `typeName`, no
            // `props`/`partial` check (serialize.mjs:9-11).
            val element = JsObjects.serializerElementRef(v)
            val steps = JsObjects.getMember(v, "steps")
            when {
                element != null -> PropValue.Element(convertElementRef(element))
                // ActionPlan: { steps: [...] }
                steps is RtValue.Arr ->
                    PropValue.Action(ActionPlan(steps.items.map { convertStep(it) }))
                // Bare ActionStep with a deferred AST: { type, valueAST }
                JsObjects.hasProperty(v, "type") && JsObjects.hasProperty(v, "valueAST") ->
                    PropValue.Action(ActionPlan(listOf(convertStep(v))))
                // serialize.mjs `isAstNode` duck-types ANY object whose `k` is
                // a string as an AST node and wraps it in {"$ast": ...} —
                // including data objects an author happened to shape that way,
                // e.g. a KVList row {k: "a", v: 1} (fixture 070). The quirk is
                // deliberate parity, not an accident.
                JsObjects.serializerIsAstNode(v) -> PropValue.Ast(convertAstPlain(v))
                else -> PropValue.Obj(convertPlainObject(v.obj))
            }
        }
    }

    /**
     * serialize.mjs `serializeAst`: a deep plain-JSON conversion applied to
     * values inside an `$ast` wrapper. Unlike [convertValue] it never
     * re-detects ActionPlans / ActionSteps / elements — nested objects stay
     * plain objects, nested elements are spread as plain objects of their own
     * fields, and non-finite numbers still become `{"$number": ...}`.
     */
    private fun convertAstPlain(v: RtValue): PropValue = when (v) {
        is RtValue.Undefined, is RtValue.Null, is RtValue.Func -> PropValue.Null
        is RtValue.Proto ->
            if (v.kind == JsProtoKind.ARRAY) {
                PropValue.Arr(emptyList())
            } else {
                PropValue.Obj(PropObject())
            }

        is RtValue.Bool -> PropValue.Bool(v.value)
        is RtValue.Num -> PropValue.Num(v.value)
        is RtValue.Str -> PropValue.Str(v.value)
        is RtValue.Arr -> PropValue.Arr(v.items.map { convertAstPlain(it) })
        is RtValue.Obj -> {
            val out = PropObject()
            for ((key, value) in v.obj.entries) {
                if (value.isDroppedByJsonStringify) continue
                jsAssign(out, key, convertAstPlain(value))
            }
            PropValue.Obj(out)
        }

        is RtValue.Element -> {
            val el = v.element
            val out = PropObject()
            out["type"] = PropValue.Str("element")
            out["typeName"] = PropValue.Str(el.typeName)
            out["props"] = convertAstPlain(RtValue.Obj(el.props))
            out["partial"] = PropValue.Bool(el.partial)
            out["hasDynamicProps"] = PropValue.Bool(el.hasDynamicProps)
            el.statementId?.let { out["statementId"] = PropValue.Str(it) }
            PropValue.Obj(out)
        }

        is RtValue.Ast -> convertAst(v.node)
    }

    private fun convertPlainObject(o: RtObject): PropObject {
        val out = PropObject()
        for ((key, value) in o.entries) {
            if (value.isDroppedByJsonStringify) continue
            jsAssign(out, key, convertValue(value))
        }
        return out
    }

    /**
     * serialize.mjs writes its output objects with `out[key] = …` — plain JS
     * ASSIGNMENT, which routes `"__proto__"` through `Object.prototype`'s
     * setter and never creates an own key. So even where a `__proto__` entry
     * survived materialization/evaluation (`Object.fromEntries` in
     * `evaluator.js`'s Obj case does keep it), it disappears from the emitted
     * JSON. Fixture `080-proto-object-key`.
     */
    private fun jsAssign(out: PropObject, key: String, value: PropValue) {
        if (key == RtObject.PROTO_KEY) return
        out[key] = value
    }

    /**
     * serialize.mjs `serializeStep` — verbatim:
     *
     * ```js
     * function serializeStep(step) {
     *   const out = {};
     *   for (const key of Object.keys(step).sort()) {
     *     const v = step[key];
     *     if (v === undefined) continue;
     *     out[key] = key === "valueAST" ? { $ast: serializeAst(v) } : serializeValue(v);
     *   }
     *   return out;
     * }
     * ```
     *
     * Two rules that are easy to get wrong, and this port did:
     *
     * 1. It is `Object.keys(step)`, NOT a type switch. A step that is not a
     *    plain object is BOXED, so it always serializes as an OBJECT:
     *    `{steps: [1, 2]}` gives `[{}, {}]`, `{steps: ["ab"]}` gives
     *    `[{"0":"a","1":"b"}]`, `{steps: [[1, 2]]}` gives `[{"0":1,"1":2}]`
     *    and `{steps: [true]}` gives `[{}]` (fixture
     *    `091-action-steps-nonobject`).
     * 2. `valueAST` is wrapped by KEY NAME, not by value type. `{type: "set",
     *    valueAST: 1}` gives `"valueAST": {"$ast": 1}`, and any other key
     *    holding an AST value is wrapped by `serializeValue`'s own AST branch
     *    instead (fixture `092-action-valueast-by-key`).
     *
     * A step of `null`/`undefined` makes the REFERENCE THROW
     * (`Object.keys(null)`), taking the fixture generator with it, so no
     * expected tree exists for it; the port emits `{}` — see the READMEs'
     * KNOWN-DEVIATIONS.
     */
    private fun convertStep(step: RtValue): PropValue {
        val out = PropObject()
        for (key in JsObjects.objectKeys(step) ?: emptyList()) {
            val value = JsObjects.getMember(step, key)
            if (value is RtValue.Undefined) continue
            if (key == "valueAST") {
                // `{ $ast: serializeAst(v) }`; a function `v` survives
                // `serializeAst` untouched and `JSON.stringify` then drops the
                // `$ast` key, leaving `{}`.
                out[key] = if (value is RtValue.Func) {
                    PropValue.Obj(PropObject())
                } else {
                    PropValue.Ast(convertAstPlain(value))
                }
            } else {
                if (value.isDroppedByJsonStringify) continue
                jsAssign(out, key, convertValue(value))
            }
        }
        return PropValue.Obj(out)
    }

    /**
     * Deep AST → plain JSON tree (kind tag + fields; keys sorted by the
     * serializer). Numbers keep NaN/Infinity — the serializer emits
     * `{"$number": ...}` for them.
     */
    fun convertAst(node: AstNode): PropValue = when (node) {
        is AstNode.Str -> obj("k" to PropValue.Str("Str"), "v" to PropValue.Str(node.v))
        is AstNode.Num -> obj("k" to PropValue.Str("Num"), "v" to PropValue.Num(node.v))
        is AstNode.Bool -> obj("k" to PropValue.Str("Bool"), "v" to PropValue.Bool(node.v))
        is AstNode.Null -> obj("k" to PropValue.Str("Null"))
        is AstNode.Arr -> obj(
            "k" to PropValue.Str("Arr"),
            "els" to PropValue.Arr(node.els.map { convertAst(it) }),
        )

        is AstNode.Obj -> obj(
            "k" to PropValue.Str("Obj"),
            "entries" to PropValue.Arr(
                node.entries.map {
                    PropValue.Arr(listOf(PropValue.Str(it.first), convertAst(it.second)))
                }
            ),
        )

        is AstNode.Comp -> {
            val out = PropObject()
            out["k"] = PropValue.Str("Comp")
            out["name"] = PropValue.Str(node.name)
            out["args"] = PropValue.Arr(node.args.map { convertAst(it) })
            node.mappedProps?.let { mapped ->
                val m = PropObject()
                for ((key, value) in mapped) m[key] = convertAst(value)
                out["mappedProps"] = PropValue.Obj(m)
            }
            PropValue.Obj(out)
        }

        is AstNode.Ref -> obj("k" to PropValue.Str("Ref"), "n" to PropValue.Str(node.n))
        is AstNode.StateRef -> obj("k" to PropValue.Str("StateRef"), "n" to PropValue.Str(node.n))
        is AstNode.RuntimeRef -> obj(
            "k" to PropValue.Str("RuntimeRef"),
            "n" to PropValue.Str(node.n),
            "refType" to PropValue.Str(node.refType),
        )

        is AstNode.BinOp -> obj(
            "k" to PropValue.Str("BinOp"),
            "op" to PropValue.Str(node.op),
            "left" to convertAst(node.left),
            "right" to convertAst(node.right),
        )

        is AstNode.UnaryOp -> obj(
            "k" to PropValue.Str("UnaryOp"),
            "op" to PropValue.Str(node.op),
            "operand" to convertAst(node.operand),
        )

        is AstNode.Ternary -> obj(
            "k" to PropValue.Str("Ternary"),
            "cond" to convertAst(node.cond),
            "then" to convertAst(node.then),
            "else" to convertAst(node.orElse),
        )

        is AstNode.Member -> obj(
            "k" to PropValue.Str("Member"),
            "obj" to convertAst(node.obj),
            "field" to PropValue.Str(node.field),
        )

        is AstNode.Index -> obj(
            "k" to PropValue.Str("Index"),
            "obj" to convertAst(node.obj),
            "index" to convertAst(node.index),
        )

        is AstNode.Assign -> obj(
            "k" to PropValue.Str("Assign"),
            "target" to PropValue.Str(node.target),
            "value" to convertAst(node.value),
        )

        is AstNode.Ph -> obj("k" to PropValue.Str("Ph"), "n" to PropValue.Str(node.n))
    }

    private fun obj(vararg pairs: Pair<String, PropValue>): PropValue =
        PropValue.Obj(PropObject(pairs.toList()))
}
