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
        val evaluatedRoot = internalResult.root?.let { evaluator.evaluateElementProps(it) }

        val state = LinkedHashMap<String, PropValue>()
        for (key in internalResult.stateDeclarations.keys) {
            state[key] = convertValue(internalResult.stateDeclarations[key]!!)
        }

        return ParseResult(
            root = evaluatedRoot?.let { convertElement(it) },
            meta = ParseMeta(
                incomplete = internalResult.incomplete,
                unresolved = internalResult.unresolved,
                errors = internalResult.errors,
            ),
            state = state,
            // KNOWN-DEVIATION (mirrors the Swift port's #4): always empty. The
            // JS `evaluateElementProps` errors array is only appended to from
            // paths AppLess never reaches (QueryManager / tool providers), and
            // the oracle emits [] across the whole corpus.
            runtimeErrors = emptyList(),
        )
    }

    // ── RtValue → PropValue conversion (mirrors generator/lib/serialize.mjs) ──

    fun convertElement(el: RtElement): ElementNode {
        val props = LinkedHashMap<String, PropValue>()
        var children: PropValue? = null
        for ((key, value) in el.props.entries) {
            if (value is RtValue.Undefined) continue
            if (key == "children") children = convertValue(value) else props[key] = convertValue(value)
        }
        return ElementNode(
            component = el.typeName,
            statementId = el.statementId,
            props = props,
            children = children,
        )
    }

    fun convertValue(v: RtValue): PropValue = when (v) {
        is RtValue.Undefined, is RtValue.Null -> PropValue.Null
        is RtValue.Bool -> PropValue.Bool(v.value)
        is RtValue.Num -> PropValue.Num(v.value)
        is RtValue.Str -> PropValue.Str(v.value)
        is RtValue.Arr -> PropValue.Arr(v.items.map { convertValue(it) })
        is RtValue.Element -> PropValue.Element(convertElement(v.element))
        is RtValue.Ast -> PropValue.Ast(convertAst(v.node))
        is RtValue.Obj -> {
            val o = v.obj
            val steps = o["steps"]
            when {
                // ActionPlan: { steps: [...] }
                steps is RtValue.Arr ->
                    PropValue.Action(ActionPlan(steps.items.map { convertStep(it) }))
                // Bare ActionStep with a deferred AST: { type, valueAST }
                o.has("type") && o.has("valueAST") ->
                    PropValue.Action(ActionPlan(listOf(convertStep(v))))
                // serialize.mjs `isAstNode` duck-types ANY plain object whose
                // `k` entry is a string as an AST node and wraps it in
                // {"$ast": ...} — including data objects an author happened to
                // shape that way, e.g. a KVList row {k: "a", v: 1} (fixture
                // 070). The quirk is deliberate parity, not an accident.
                o["k"] is RtValue.Str -> PropValue.Ast(convertAstPlain(v))
                else -> PropValue.Obj(convertPlainObject(o))
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
        is RtValue.Undefined, is RtValue.Null -> PropValue.Null
        is RtValue.Bool -> PropValue.Bool(v.value)
        is RtValue.Num -> PropValue.Num(v.value)
        is RtValue.Str -> PropValue.Str(v.value)
        is RtValue.Arr -> PropValue.Arr(v.items.map { convertAstPlain(it) })
        is RtValue.Obj -> {
            val out = PropObject()
            for ((key, value) in v.obj.entries) {
                if (value is RtValue.Undefined) continue
                out[key] = convertAstPlain(value)
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
            if (value is RtValue.Undefined) continue
            out[key] = convertValue(value)
        }
        return out
    }

    /**
     * serialize.mjs `serializeStep`: sorted keys (handled by the serializer),
     * `undefined` entries omitted, `valueAST` wrapped as `$ast` (which the
     * [RtValue.Ast] branch of [convertValue] already does).
     */
    private fun convertStep(step: RtValue): PropValue = when (step) {
        is RtValue.Obj -> PropValue.Obj(convertPlainObject(step.obj))
        is RtValue.Element -> {
            val el = step.element
            val out = PropObject()
            out["type"] = PropValue.Str("element")
            out["typeName"] = PropValue.Str(el.typeName)
            out["props"] = PropValue.Obj(convertPlainObject(el.props))
            out["partial"] = PropValue.Bool(el.partial)
            out["hasDynamicProps"] = PropValue.Bool(el.hasDynamicProps)
            el.statementId?.let { out["statementId"] = PropValue.Str(it) }
            PropValue.Obj(out)
        }

        else -> convertValue(step)
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
