package dev.appless.openuilang

/** Statement classification (lang-core `classifyStatement`; spec §2.1). */
internal enum class StatementKind { VALUE, STATE, QUERY, MUTATION }

internal class TypedStatement(
    val kind: StatementKind,
    val id: String,
    /**
     * For state statements the initializer, for query/mutation the full `Comp`
     * call, otherwise the value expression.
     */
    val expr: AstNode,
)

internal fun classifyStatement(raw: RawStatement, expr: AstNode): TypedStatement {
    // Query/Mutation are checked BEFORE `$var`, so `$foo = Query(...)` is a query.
    if (expr is AstNode.Comp) {
        if (expr.name == "Query") return TypedStatement(StatementKind.QUERY, raw.id, expr)
        if (expr.name == "Mutation") return TypedStatement(StatementKind.MUTATION, raw.id, expr)
    }
    if (raw.idTokenType == TokType.STATE_VAR) {
        return TypedStatement(StatementKind.STATE, raw.id, expr)
    }
    return TypedStatement(StatementKind.VALUE, raw.id, expr)
}

/** Mutable context threaded through materialization (lang-core `Ctx`). */
internal class MaterializeContext(
    val syms: Map<String, AstNode>,
    val cat: Map<String, List<LibrarySchema.Param>>,
    val partial: Boolean,
    var currentStatementId: String,
) {
    val errors = ArrayList<ParseError>()
    val unres = ArrayList<String>()
    val visited = HashSet<String>()
}

private fun reservedRefType(name: String): String = if (name == "Mutation") "mutation" else "query"

private fun unknownComponentError(name: String, ctx: MaterializeContext) = ParseError(
    code = ParseError.Code.UNKNOWN_COMPONENT,
    component = name,
    path = "",
    message = "Unknown component \"$name\" — not found in catalog or builtins",
    statementId = ctx.currentStatementId,
)

/** Resolve a `Ref` in value mode (port of `resolveRef` mode "value"; spec §8). */
private fun resolveRefValue(name: String, ctx: MaterializeContext): RtValue {
    if (ctx.visited.contains(name)) {
        ctx.unres.add(name)
        return RtValue.Null
    }
    val target = ctx.syms[name]
    if (target == null) {
        ctx.unres.add(name)
        return RtValue.Null
    }
    if (target is AstNode.Comp && Builtins.isReservedCall(target.name)) {
        return RtValue.Ast(AstNode.RuntimeRef(name, reservedRefType(target.name)))
    }
    ctx.visited.add(name)
    val prev = ctx.currentStatementId
    ctx.currentStatementId = name
    try {
        val result = materializeValue(target, ctx)
        return if (result is RtValue.Element) {
            RtValue.Element(result.element.withStatementId(name))
        } else {
            result
        }
    } finally {
        ctx.currentStatementId = prev
        ctx.visited.remove(name)
    }
}

/** Resolve a `Ref` in expression mode. */
private fun resolveRefExpr(name: String, ctx: MaterializeContext): AstNode {
    if (ctx.visited.contains(name)) {
        ctx.unres.add(name)
        return AstNode.Ph(name)
    }
    val target = ctx.syms[name]
    if (target == null) {
        ctx.unres.add(name)
        return AstNode.Ph(name)
    }
    if (target is AstNode.Comp && Builtins.isReservedCall(target.name)) {
        return AstNode.RuntimeRef(name, reservedRefType(target.name))
    }
    ctx.visited.add(name)
    val prev = ctx.currentStatementId
    ctx.currentStatementId = name
    try {
        return materializeExpr(target, ctx)
    } finally {
        ctx.currentStatementId = prev
        ctx.visited.remove(name)
    }
}

/**
 * If the node is a lazy builtin like `Each(arr, varName, template)`, scope the
 * iterator variable during materialization. Returns `null` when not applicable.
 */
private fun materializeLazyBuiltin(
    node: AstNode.Comp,
    ctx: MaterializeContext,
    scopedRefs: Set<String>,
): AstNode? {
    if (!Builtins.lazyBuiltins.contains(node.name) || node.args.size < 3) return null
    val varArg = node.args[1]
    val varName = when (varArg) {
        is AstNode.Ref -> varArg.n
        is AstNode.Str -> varArg.v
        else -> null
    }
    // materialize.js guards with `if (!varName)` — FALSY, not null. An empty
    // string iterator name (`@Each(items, "", …)`) therefore aborts the lazy
    // path here too, so the template's refs resolve as ordinary refs and land
    // in `unresolved` (fixture `079-each-empty-iterator-name`).
    if (varName.isNullOrEmpty()) return null
    val nextScoped = HashSet(scopedRefs).also { it.add(varName) }
    // args[1] (the iterator declaration) is skipped; scoped refs apply elsewhere.
    val recursed = node.args.mapIndexed { i, a ->
        if (i == 1) a else materializeExprInternal(a, ctx, nextScoped)
    }
    return AstNode.Comp(node.name, recursed, node.mappedProps)
}

private fun materializeExprInternal(
    node: AstNode,
    ctx: MaterializeContext,
    scopedRefs: Set<String>,
): AstNode = when (node) {
    is AstNode.Ref -> if (scopedRefs.contains(node.n)) node else resolveRefExpr(node.n, ctx)
    is AstNode.Ph -> node
    is AstNode.Comp -> {
        val lazy = materializeLazyBuiltin(node, ctx, scopedRefs)
        if (lazy != null) {
            lazy
        } else {
            val recursedArgs = node.args.map { materializeExprInternal(it, ctx, scopedRefs) }
            if (Builtins.isBuiltin(node.name) || Builtins.isReservedCall(node.name)) {
                AstNode.Comp(node.name, recursedArgs, node.mappedProps)
            } else {
                val def = ctx.cat[node.name]
                if (def != null) {
                    val mapped = ArrayList<Pair<String, AstNode>>()
                    var i = 0
                    while (i < def.size && i < recursedArgs.size) {
                        mapped.add(def[i].name to recursedArgs[i])
                        i++
                    }
                    AstNode.Comp(node.name, recursedArgs, mapped)
                } else {
                    ctx.errors.add(unknownComponentError(node.name, ctx))
                    AstNode.Comp(node.name, recursedArgs, node.mappedProps)
                }
            }
        }
    }

    is AstNode.Arr -> AstNode.Arr(node.els.map { materializeExprInternal(it, ctx, scopedRefs) })
    is AstNode.Obj -> AstNode.Obj(
        node.entries.map { it.first to materializeExprInternal(it.second, ctx, scopedRefs) }
    )

    is AstNode.BinOp -> AstNode.BinOp(
        node.op,
        materializeExprInternal(node.left, ctx, scopedRefs),
        materializeExprInternal(node.right, ctx, scopedRefs),
    )

    is AstNode.UnaryOp ->
        AstNode.UnaryOp(node.op, materializeExprInternal(node.operand, ctx, scopedRefs))

    is AstNode.Ternary -> AstNode.Ternary(
        materializeExprInternal(node.cond, ctx, scopedRefs),
        materializeExprInternal(node.then, ctx, scopedRefs),
        materializeExprInternal(node.orElse, ctx, scopedRefs),
    )

    is AstNode.Member ->
        AstNode.Member(materializeExprInternal(node.obj, ctx, scopedRefs), node.field)

    is AstNode.Index -> AstNode.Index(
        materializeExprInternal(node.obj, ctx, scopedRefs),
        materializeExprInternal(node.index, ctx, scopedRefs),
    )

    is AstNode.Assign ->
        AstNode.Assign(node.target, materializeExprInternal(node.value, ctx, scopedRefs))

    // Literals, StateRef, RuntimeRef — pass through unchanged.
    else -> node
}

internal fun materializeExpr(node: AstNode, ctx: MaterializeContext): AstNode =
    materializeExprInternal(node, ctx, emptySet())

/**
 * Port of `containsDynamicValue`.
 *
 * Its three type tests (`isASTNode`, `Array.isArray`, `isElementNode`) all read
 * through the PROTOTYPE CHAIN, so an object that inherited `k` or
 * `type`/`typeName` from a `{"__proto__": …}` entry is classified as an AST
 * node / element here — which is what decides `hasDynamicProps`, and therefore
 * whether the element is evaluated at all. `typeof fn === "function"` fails the
 * leading `typeof v !== "object"` guard, so functions are never dynamic.
 */
internal fun containsDynamicValue(v: RtValue): Boolean = when (v) {
    is RtValue.Ast -> true
    is RtValue.Arr -> v.items.any { containsDynamicValue(it) }
    is RtValue.Element -> v.element.props.values.any { containsDynamicValue(it) }
    is RtValue.Obj -> when {
        JsObjects.astNodeView(v) != null -> true
        else -> {
            val el = JsObjects.elementView(v)
            if (el != null) {
                el.props.values.any { containsDynamicValue(it) }
            } else {
                v.obj.values.any { containsDynamicValue(it) }
            }
        }
    }
    // The intrinsic prototypes have no ENUMERABLE own properties.
    is RtValue.Proto -> false
    else -> false
}

/**
 * Schema-aware materialization (port of `materializeValue`;
 * spec/openui-lang.md §8 reference resolution & materialization, §8.2).
 */
internal fun materializeValue(node: AstNode, ctx: MaterializeContext): RtValue = when (node) {
    is AstNode.Ref -> resolveRefValue(node.n, ctx)
    is AstNode.Str -> RtValue.Str(node.v)
    is AstNode.Num -> RtValue.Num(node.v)
    is AstNode.Bool -> RtValue.Bool(node.v)
    is AstNode.Null -> RtValue.Null
    is AstNode.Ph -> RtValue.Null

    is AstNode.Arr -> {
        val items = ArrayList<RtValue>()
        for (e in node.els) {
            if (e is AstNode.Ph) continue // drop unresolved placeholders
            val value = materializeValue(e, ctx)
            // Drop nulls that came from component/ref resolution; a LITERAL
            // null element stays.
            if (value is RtValue.Null && (e is AstNode.Comp || e is AstNode.Ref)) continue
            items.add(value)
        }
        RtValue.Arr(items)
    }

    is AstNode.Obj -> {
        // materialize.js builds this with `o[k] = …` — plain ASSIGNMENT, so a
        // `"__proto__"` key hits Object.prototype's setter and is swallowed.
        // (evaluator.js's Obj case uses Object.fromEntries and DOES keep it.)
        val o = RtObject()
        for ((k, v) in node.entries) o.assign(k, materializeValue(v, ctx))
        RtValue.Obj(o)
    }

    is AstNode.Comp -> materializeComp(node, ctx)

    else -> if (node.isRuntimeExpr) {
        RtValue.Ast(materializeExpr(node, ctx))
    } else {
        RtValue.Ast(node) // defensive — unreachable for a well-formed AST
    }
}

private fun materializeComp(node: AstNode.Comp, ctx: MaterializeContext): RtValue {
    val name = node.name

    // Builtins (Sum, Count, Filter, Action, …) → preserve as AST for runtime.
    if (Builtins.isBuiltin(name)) {
        val lazy = materializeLazyBuiltin(node, ctx, emptySet())
        if (lazy != null) return RtValue.Ast(lazy)
        return RtValue.Ast(
            AstNode.Comp(name, node.args.map { materializeExpr(it, ctx) }, node.mappedProps)
        )
    }

    // Inline Query/Mutation used as a value → validation error.
    if (Builtins.isReservedCall(name)) {
        ctx.errors.add(
            ParseError(
                code = ParseError.Code.INLINE_RESERVED,
                component = name,
                path = "",
                message =
                    "$name() must be declared as a top-level statement, not used inline as a value",
                statementId = ctx.currentStatementId,
            )
        )
        return RtValue.Null
    }

    val def = ctx.cat[name]
    if (def == null) {
        ctx.errors.add(unknownComponentError(name, ctx))
        return RtValue.Null
    }

    // Positional args → named props via the contract's property order; extra
    // args beyond the parameter list are ignored silently.
    val props = RtObject()
    var i = 0
    while (i < def.size && i < node.args.size) {
        props[def[i].name] = materializeValue(node.args[i], ctx)
        i++
    }

    val missingRequired = def.filter { p ->
        p.required && (!props.has(p.name) || props[p.name] is RtValue.Null)
    }
    if (missingRequired.isNotEmpty()) {
        // A schema `default` is applied BEFORE missing-required/null-required
        // is reported (materialize.js). The shipped GenOS contract declares no
        // defaults; this is future-proofing for later contracts.
        val stillInvalid = missingRequired.filter { p ->
            val defaultValue = p.defaultValue
            if (defaultValue != null) {
                props[p.name] = jsonToRtValue(defaultValue)
                false
            } else {
                true
            }
        }
        if (stillInvalid.isNotEmpty()) {
            for (p in stillInvalid) {
                val isNull = props.has(p.name)
                ctx.errors.add(
                    ParseError(
                        code = if (isNull) {
                            ParseError.Code.NULL_REQUIRED
                        } else {
                            ParseError.Code.MISSING_REQUIRED
                        },
                        component = name,
                        path = "/${p.name}",
                        message = if (isNull) {
                            "required field \"${p.name}\" cannot be null"
                        } else {
                            "missing required field \"${p.name}\""
                        },
                        statementId = ctx.currentStatementId,
                    )
                )
            }
            return RtValue.Null // whole component dropped
        }
    }

    return RtValue.Element(
        RtElement(
            typeName = name,
            props = props,
            partial = ctx.partial,
            hasDynamicProps = props.values.any { containsDynamicValue(it) },
        )
    )
}
