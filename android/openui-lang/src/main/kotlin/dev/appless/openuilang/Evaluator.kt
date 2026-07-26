package dev.appless.openuilang

import java.text.Collator
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.pow

/**
 * Runtime evaluation context — mirrors the `EvaluationContext` react-lang
 * builds: `getState` reads the initialized store (unwrapping
 * `{value, componentType}` wrappers), `resolveRef` yields `undefined`
 * (AppLess never uses Query/Mutation).
 */
internal class EvalContext(
    val getState: (String) -> RtValue,
    val resolveRef: (String) -> RtValue,
)

/**
 * Port of `runtime/evaluator.js` + `runtime/evaluate-prop.js` +
 * `runtime/evaluate-tree.js` for the AppLess (non-reactive) contract
 * (spec/openui-lang.md §9 runtime evaluation).
 */
internal class Evaluator(store: Map<String, RtValue>) {

    private val ctx: EvalContext = run {
        val storeCopy = LinkedHashMap(store)
        EvalContext(
            getState = { name ->
                val v = storeCopy[name] ?: return@EvalContext RtValue.Undefined
                if (v is RtValue.Obj) v.obj["value"] ?: v else v
            },
            resolveRef = { RtValue.Undefined },
        )
    }

    // ── Element / prop evaluation (evaluate-tree, evaluate-prop) ────────────

    fun evaluateElementProps(el: RtElement): RtElement {
        if (!el.hasDynamicProps) return el
        val props = RtObject()
        for ((key, value) in el.props.entries) {
            props[key] = evaluatePropValue(value)
        }
        return el.withProps(props)
    }

    private fun evaluatePropValue(value: RtValue): RtValue = when (value) {
        is RtValue.Undefined, is RtValue.Null, is RtValue.Bool,
        is RtValue.Num, is RtValue.Str,
        -> value

        is RtValue.Ast -> {
            val result = evaluate(value.node, ctx)
            when {
                result is RtValue.Element -> RtValue.Element(evaluateElementProps(result.element))
                result is RtValue.Arr -> RtValue.Arr(
                    result.items.map {
                        if (it is RtValue.Element) {
                            RtValue.Element(evaluateElementProps(it.element))
                        } else {
                            it
                        }
                    }
                )
                // Strip a ReactiveAssign marker in a non-reactive context.
                isReactiveAssign(result) -> {
                    val target = ((result as RtValue.Obj).obj["target"] as? RtValue.Str)?.value
                    val v = if (target == null) RtValue.Undefined else ctx.getState(target)
                    if (v.isNullish) RtValue.Null else v
                }

                else -> result
            }
        }

        is RtValue.Arr -> RtValue.Arr(value.items.map { evaluatePropValue(it) })
        is RtValue.Element -> RtValue.Element(evaluateElementProps(value.element))
        is RtValue.Obj -> {
            val o = value.obj
            // ActionPlan / ActionStep — preserve as-is (deferred click-time eval).
            // KNOWN-DEVIATION (mirrors Swift #6): a LITERAL object whose `k` is
            // a real AST kind ({k: "Str", v: "x"}) is indistinguishable from an
            // AST node in JS and would be evaluated here; the typed port keeps
            // it as plain data. (The SERIALIZER-level duck-typing IS
            // replicated — see Pipeline.convertValue / fixture 070.)
            when {
                o["steps"] is RtValue.Arr -> value
                o.has("type") && o.has("valueAST") -> value
                o.values.any { it.isObjectLike } -> {
                    val out = RtObject()
                    for ((k, v) in o.entries) out[k] = evaluatePropValue(v)
                    RtValue.Obj(out)
                }

                else -> value
            }
        }
    }

    private fun isReactiveAssign(v: RtValue): Boolean =
        v is RtValue.Obj && (v.obj["__reactive"] as? RtValue.Str)?.value == "assign"

    // ── Core AST evaluation ────────────────────────────────────────────────

    fun evaluate(node: AstNode, context: EvalContext): RtValue = when (node) {
        is AstNode.Str -> RtValue.Str(node.v)
        is AstNode.Num -> RtValue.Num(node.v)
        is AstNode.Bool -> RtValue.Bool(node.v)
        is AstNode.Null -> RtValue.Null
        is AstNode.Ph -> RtValue.Null
        is AstNode.StateRef -> context.getState(node.n)
        is AstNode.Ref -> context.resolveRef(node.n)
        is AstNode.RuntimeRef -> context.resolveRef(node.n)
        is AstNode.Arr -> RtValue.Arr(node.els.map { evaluate(it, context) })
        is AstNode.Obj -> {
            val o = RtObject()
            for ((k, v) in node.entries) o[k] = evaluate(v, context)
            RtValue.Obj(o)
        }

        is AstNode.Comp -> evaluateComp(node, context)

        is AstNode.BinOp -> evaluateBinOp(node, context)

        is AstNode.UnaryOp -> when (node.op) {
            "!" -> RtValue.Bool(!jsTruthy(evaluate(node.operand, context)))
            "-" -> RtValue.Num(-dslToNumber(evaluate(node.operand, context)))
            else -> RtValue.Null
        }

        is AstNode.Ternary ->
            if (jsTruthy(evaluate(node.cond, context))) {
                evaluate(node.then, context)
            } else {
                evaluate(node.orElse, context)
            }

        is AstNode.Member -> {
            val obj = evaluate(node.obj, context)
            when {
                obj.isNullish -> RtValue.Null
                obj is RtValue.Arr ->
                    if (node.field == "length") {
                        RtValue.Num(obj.items.size.toDouble())
                    } else {
                        // Array pluck: map each element to `el.field ?? null`.
                        RtValue.Arr(
                            obj.items.map { item ->
                                if (item.isNullish) {
                                    RtValue.Null
                                } else {
                                    val v = propertyGet(item, node.field)
                                    if (v.isNullish) RtValue.Null else v
                                }
                            }
                        )
                    }

                else -> propertyGet(obj, node.field)
            }
        }

        is AstNode.Index -> {
            val obj = evaluate(node.obj, context)
            val idx = evaluate(node.index, context)
            when {
                obj.isNullish || idx.isNullish -> RtValue.Null
                obj is RtValue.Arr -> {
                    val n = dslToNumber(idx)
                    if (n.isFinite() && n == floor(n) && n >= 0 && n < obj.items.size) {
                        obj.items[n.toInt()]
                    } else {
                        RtValue.Undefined
                    }
                }

                else -> propertyGet(obj, jsToString(idx))
            }
        }

        is AstNode.Assign -> RtValue.Obj(
            RtObject.of(
                "__reactive" to RtValue.Str("assign"),
                "target" to RtValue.Str(node.target),
                "expr" to RtValue.Ast(node.value),
            )
        )
    }

    private fun evaluateComp(node: AstNode.Comp, context: EvalContext): RtValue {
        if (Builtins.lazyBuiltins.contains(node.name)) {
            return evaluateLazyBuiltin(node.name, node.args, context)
        }
        if (Builtins.dataBuiltins.contains(node.name)) {
            return callDataBuiltin(node.name, node.args.map { evaluate(it, context) })
        }
        if (Builtins.actionNames.contains(node.name)) {
            return evaluateActionCall(node.name, node.args, context)
        }
        val mapped = node.mappedProps ?: return RtValue.Null // unmapped Comp
        val props = RtObject()
        for ((key, value) in mapped) {
            props[key] = if (value is AstNode.StateRef) {
                context.getState(value.n)
            } else {
                evaluate(value, context)
            }
        }
        // Recursively evaluate nested ElementNodes in props.
        val finalProps = RtObject()
        for ((key, v) in props.entries) {
            finalProps[key] = when (v) {
                is RtValue.Element -> RtValue.Element(evaluateElementProps(v.element))
                is RtValue.Arr -> RtValue.Arr(
                    v.items.map {
                        if (it is RtValue.Element) {
                            RtValue.Element(evaluateElementProps(it.element))
                        } else {
                            it
                        }
                    }
                )

                else -> v
            }
        }
        return RtValue.Element(
            RtElement(
                typeName = node.name,
                props = finalProps,
                partial = false,
                hasDynamicProps = true,
            )
        )
    }

    private fun evaluateBinOp(node: AstNode.BinOp, context: EvalContext): RtValue {
        if (node.op == "&&") {
            val left = evaluate(node.left, context)
            return if (jsTruthy(left)) evaluate(node.right, context) else left
        }
        if (node.op == "||") {
            val left = evaluate(node.left, context)
            return if (jsTruthy(left)) left else evaluate(node.right, context)
        }
        val left = evaluate(node.left, context)
        val right = evaluate(node.right, context)
        return when (node.op) {
            "+" ->
                if (left is RtValue.Str || right is RtValue.Str) {
                    RtValue.Str(concatOperand(left) + concatOperand(right))
                } else {
                    RtValue.Num(dslToNumber(left) + dslToNumber(right))
                }

            "-" -> RtValue.Num(dslToNumber(left) - dslToNumber(right))
            "*" -> RtValue.Num(dslToNumber(left) * dslToNumber(right))
            // DSL design choice: division/modulo by zero yields 0.
            "/" -> {
                val r = dslToNumber(right)
                RtValue.Num(if (r == 0.0) 0.0 else dslToNumber(left) / r)
            }

            "%" -> {
                val r = dslToNumber(right)
                RtValue.Num(if (r == 0.0) 0.0 else dslToNumber(left) % r)
            }

            "==" -> RtValue.Bool(jsLooseEquals(left, right))
            "!=" -> RtValue.Bool(!jsLooseEquals(left, right))
            ">" -> RtValue.Bool(dslToNumber(left) > dslToNumber(right))
            "<" -> RtValue.Bool(dslToNumber(left) < dslToNumber(right))
            ">=" -> RtValue.Bool(dslToNumber(left) >= dslToNumber(right))
            "<=" -> RtValue.Bool(dslToNumber(left) <= dslToNumber(right))
            else -> RtValue.Null
        }
    }

    /** `String(x ?? "")`, used by string concatenation and action strings. */
    private fun concatOperand(v: RtValue): String = if (v.isNullish) "" else jsToString(v)

    /**
     * JS `obj[key]` property access for non-array receivers.
     *
     * KNOWN-DEVIATION (mirrors Swift #5): an element receiver yields
     * `undefined`, whereas in JS an ElementNode is a plain object whose
     * `typeName`/`props`/`partial`/`hasDynamicProps`/`type` fields are
     * readable. Observable only for programs that member-access an element.
     */
    private fun propertyGet(obj: RtValue, key: String): RtValue = when (obj) {
        is RtValue.Obj -> obj.obj[key] ?: RtValue.Undefined
        is RtValue.Arr -> when {
            key == "length" -> RtValue.Num(obj.items.size.toDouble())
            else -> {
                val i = key.toIntOrNull()
                if (i != null && i >= 0 && i < obj.items.size && i.toString() == key) {
                    obj.items[i]
                } else {
                    RtValue.Undefined
                }
            }
        }

        is RtValue.Str -> when {
            key == "length" -> RtValue.Num(obj.value.length.toDouble())
            else -> {
                val i = key.toIntOrNull()
                if (i != null && i >= 0 && i < obj.value.length && i.toString() == key) {
                    RtValue.Str(obj.value[i].toString())
                } else {
                    RtValue.Undefined
                }
            }
        }

        else -> RtValue.Undefined
    }

    // ── Data builtins ──────────────────────────────────────────────────────

    private fun callDataBuiltin(name: String, args: List<RtValue>): RtValue {
        fun arg(i: Int): RtValue = if (i < args.size) args[i] else RtValue.Undefined
        val a0 = arg(0)
        val items = (a0 as? RtValue.Arr)?.items

        return when (name) {
            "Count" -> RtValue.Num((items?.size ?: 0).toDouble())
            "First" -> {
                val v = items?.firstOrNull() ?: RtValue.Null
                if (v.isNullish) RtValue.Null else v
            }

            "Last" -> {
                val v = items?.lastOrNull() ?: RtValue.Null
                if (v.isNullish) RtValue.Null else v
            }

            "Sum" -> RtValue.Num(items?.fold(0.0) { acc, v -> acc + dslToNumber(v) } ?: 0.0)
            "Avg" ->
                if (items != null && items.isNotEmpty()) {
                    RtValue.Num(items.fold(0.0) { acc, v -> acc + dslToNumber(v) } / items.size)
                } else {
                    RtValue.Num(0.0)
                }

            "Min" ->
                if (items != null && items.isNotEmpty()) {
                    RtValue.Num(
                        items.fold(dslToNumber(items[0])) { acc, v -> jsMathMin(acc, dslToNumber(v)) }
                    )
                } else {
                    RtValue.Num(0.0)
                }

            "Max" ->
                if (items != null && items.isNotEmpty()) {
                    RtValue.Num(
                        items.fold(dslToNumber(items[0])) { acc, v -> jsMathMax(acc, dslToNumber(v)) }
                    )
                } else {
                    RtValue.Num(0.0)
                }

            "Sort" -> {
                if (items == null) {
                    a0 // non-array input returned unchanged
                } else {
                    val f = if (arg(1).isNullish) "" else jsToString(arg(1))
                    val desc = (if (arg(2).isNullish) "asc" else jsToString(arg(2))) == "desc"
                    // JS Array.prototype.sort is stable (V8 TimSort); so is
                    // Kotlin's sortedWith.
                    RtValue.Arr(
                        items.sortedWith { a, b ->
                            val av = if (f.isEmpty()) a else resolveField(a, f)
                            val bv = if (f.isEmpty()) b else resolveField(b, f)
                            val cmp = sortCompare(av, bv)
                            if (desc) -cmp else cmp
                        }
                    )
                }
            }

            "Filter" -> {
                if (items == null) {
                    RtValue.Arr(emptyList())
                } else {
                    val f = if (arg(1).isNullish) "" else jsToString(arg(1))
                    val o = if (arg(2).isNullish) "==" else jsToString(arg(2))
                    val value = arg(3)
                    RtValue.Arr(
                        items.filter { item ->
                            val v = if (f.isEmpty()) item else resolveField(item, f)
                            when (o) {
                                "==" -> jsLooseEquals(v, value)
                                "!=" -> !jsLooseEquals(v, value)
                                ">" -> dslToNumber(v) > dslToNumber(value)
                                "<" -> dslToNumber(v) < dslToNumber(value)
                                ">=" -> dslToNumber(v) >= dslToNumber(value)
                                "<=" -> dslToNumber(v) <= dslToNumber(value)
                                // JS String.prototype.includes — a UTF-16
                                // code-unit search, which `String.contains` IS
                                // on the JVM.
                                "contains" -> {
                                    val hay = if (v.isNullish) "" else jsToString(v)
                                    val needle = if (value.isNullish) "" else jsToString(value)
                                    hay.contains(needle)
                                }

                                else -> false
                            }
                        }
                    )
                }
            }

            "Round" -> {
                val num = dslToNumber(a0)
                val d = if (arg(1).isNullish) 0.0 else dslToNumber(arg(1))
                val factor = 10.0.pow(d)
                RtValue.Num(jsMathRound(num * factor) / factor)
            }

            "Abs" -> RtValue.Num(abs(dslToNumber(a0)))
            "Floor" -> RtValue.Num(floor(dslToNumber(a0)))
            "Ceil" -> RtValue.Num(ceil(dslToNumber(a0)))
            else -> RtValue.Null
        }
    }

    /**
     * `Sort`'s numeric-aware comparator. The numeric branch is exact; the
     * string branch approximates JS `String.prototype.localeCompare`.
     *
     * KNOWN-DEVIATION (mirrors Swift #1): JS `localeCompare` is V8's ICU
     * collation for the host default locale. `java.text.Collator` for
     * `Locale.US` agrees for ASCII data; locale tailorings and non-Latin
     * scripts may differ. Deliberately NOT `String.compareTo`, which is raw
     * code-unit order and would sort `"a" > "B"`.
     */
    private fun sortCompare(av: RtValue, bv: RtValue): Int {
        fun isNumeric(v: RtValue): Boolean = when (v) {
            is RtValue.Num -> true
            is RtValue.Str -> v.value.isNotEmpty() && !jsStringToNumber(v.value).isNaN()
            else -> false
        }
        if (isNumeric(av) && isNumeric(bv)) {
            val diff = dslToNumber(av) - dslToNumber(bv)
            return if (diff < 0) -1 else if (diff > 0) 1 else 0
        }
        val a = if (av.isNullish) "" else jsToString(av)
        val b = if (bv.isNullish) "" else jsToString(bv)
        val cmp = LOCALE_COLLATOR.compare(a, b)
        return if (cmp < 0) -1 else if (cmp > 0) 1 else 0
    }

    /**
     * Dot-path field resolution (port of `resolveField`). A path WITHOUT a dot
     * is a direct property access — the JS implementation short-circuits on
     * `!path.includes(".")` and never splits.
     */
    private fun resolveField(obj: RtValue, path: String): RtValue {
        if (path.isEmpty() || obj.isNullish) return RtValue.Undefined
        if (!path.contains('.')) return propertyGet(obj, path)
        var cur = obj
        // JS `path.split(".")` keeps empty segments; jsSplitOnChar does too.
        for (p in jsStringSplit(path, '.')) {
            if (cur.isNullish) return RtValue.Undefined
            cur = propertyGet(cur, p)
        }
        return cur
    }

    private fun jsMathMin(a: Double, b: Double): Double =
        if (a.isNaN() || b.isNaN()) Double.NaN else minOf(a, b)

    private fun jsMathMax(a: Double, b: Double): Double =
        if (a.isNaN() || b.isNaN()) Double.NaN else maxOf(a, b)

    /**
     * ECMAScript `Math.round` (ES2025 21.3.2.28) — "the integral Number
     * closest to x, preferring the Number closer to +∞ in case of a tie".
     *
     * NOT Kotlin's `Math.round`/`roundToInt` (half-AWAY-from-zero: disagrees on
     * -0.5, -1.5, -2.5, …) and NOT the popular `floor(x + 0.5)` shorthand
     * either. `floor(x + 0.5)` is wrong twice:
     *
     * - `x + 0.5` can round UP to the next double before the floor sees it.
     *   `Math.round(0.49999999999999994)` is `0` in JS, but
     *   `0.49999999999999994 + 0.5` is exactly `1.0` in binary64, so the
     *   shorthand answers `1`. `@Round(x, digits)` scales first
     *   (`round(x * 10^d) / 10^d`), so the same input reappears as
     *   `@Round(0.049999999999999994, 1)` → JS `0`, shorthand `0.1`.
     * - it loses the negative zero: JS `Math.round(-0.5)` is `-0`, the
     *   shorthand gives `+0`.
     *
     * The comparison below is exact. A non-integral double always has
     * |x| < 2^52, so `floor(x) + 0.5` is representable without rounding and
     * `x >= floor(x) + 0.5` decides the tie by the spec's rule directly —
     * unlike `x - floor(x) >= 0.5`, where the subtraction itself can round.
     */
    private fun jsMathRound(x: Double): Double {
        if (x.isNaN() || x.isInfinite()) return x
        val r = floor(x)
        if (r == x) return x // integral Number (incl. -0.0) is returned as-is
        // ES step 4: -0.5 <= x < 0 rounds to -0, not +0.
        if (x < 0.0 && x >= -0.5) return -0.0
        return if (x >= r + 0.5) r + 1.0 else r
    }

    // ── Actions ────────────────────────────────────────────────────────────

    private fun evaluateActionCall(
        name: String,
        args: List<AstNode>,
        context: EvalContext,
    ): RtValue = when (name) {
        "Action" -> {
            val stepsArg = if (args.isEmpty()) {
                RtValue.Arr(emptyList())
            } else {
                evaluate(args[0], context)
            }
            val rawSteps = (stepsArg as? RtValue.Arr)?.items ?: emptyList()
            // Non-object / null entries and entries without a `type` field are
            // filtered out. (JS ElementNodes carry a `type` field, so they pass.)
            val steps = rawSteps.filter {
                when (it) {
                    is RtValue.Obj -> it.obj.has("type")
                    is RtValue.Element -> true
                    else -> false
                }
            }
            RtValue.Obj(RtObject.of("steps" to RtValue.Arr(steps)))
        }

        "Run" -> {
            val first = args.firstOrNull()
            if (first is AstNode.RuntimeRef) {
                RtValue.Obj(
                    RtObject.of(
                        "type" to RtValue.Str("run"),
                        "statementId" to RtValue.Str(first.n),
                        "refType" to RtValue.Str(first.refType),
                    )
                )
            } else {
                RtValue.Null
            }
        }

        "ToAssistant" -> {
            val o = RtObject()
            o["type"] = RtValue.Str("continue_conversation")
            o["message"] =
                RtValue.Str(if (args.isEmpty()) "" else concatOperand(evaluate(args[0], context)))
            if (args.size > 1) {
                o["context"] = RtValue.Str(concatOperand(evaluate(args[1], context)))
            }
            RtValue.Obj(o)
        }

        "OpenUrl" -> RtValue.Obj(
            RtObject.of(
                "type" to RtValue.Str("open_url"),
                "url" to RtValue.Str(
                    if (args.isEmpty()) "" else concatOperand(evaluate(args[0], context))
                ),
            )
        )

        "Set" -> {
            val target = args.getOrNull(0)
            if (args.size >= 2 && target is AstNode.StateRef) {
                RtValue.Obj(
                    RtObject.of(
                        "type" to RtValue.Str("set"),
                        "target" to RtValue.Str(target.n),
                        "valueAST" to RtValue.Ast(args[1]),
                    )
                )
            } else {
                RtValue.Null
            }
        }

        "Reset" -> {
            val targets = args.filterIsInstance<AstNode.StateRef>()
                .map { RtValue.Str(it.n) as RtValue }
            if (targets.isEmpty()) {
                RtValue.Null
            } else {
                RtValue.Obj(
                    RtObject.of(
                        "type" to RtValue.Str("reset"),
                        "targets" to RtValue.Arr(targets),
                    )
                )
            }
        }

        else -> RtValue.Null
    }

    // ── @Each ──────────────────────────────────────────────────────────────

    private fun evaluateLazyBuiltin(
        name: String,
        args: List<AstNode>,
        context: EvalContext,
    ): RtValue {
        if (name != "Each") return RtValue.Null
        if (args.size < 3) return RtValue.Arr(emptyList())
        val arr = (evaluate(args[0], context) as? RtValue.Arr)?.items
            ?: return RtValue.Arr(emptyList())
        val varName = when (val v = args[1]) {
            is AstNode.Ref -> v.n
            is AstNode.Str -> v.v
            else -> null
        } ?: return RtValue.Arr(emptyList())
        val template = args[2]

        return RtValue.Arr(
            arr.map { item ->
                val substituted = substituteRef(template, varName, toLiteralAst(item))
                val childCtx = EvalContext(
                    getState = context.getState,
                    resolveRef = { refName ->
                        if (refName == varName) item else context.resolveRef(refName)
                    },
                )
                val result = evaluate(substituted, childCtx)
                if (result is RtValue.Element) {
                    RtValue.Element(evaluateElementProps(result.element))
                } else {
                    result
                }
            }
        )
    }

    /** Convert a resolved runtime value back to a literal AST node (`toLiteralAST`). */
    private fun toLiteralAst(value: RtValue): AstNode = when (value) {
        is RtValue.Undefined, is RtValue.Null -> AstNode.Null
        is RtValue.Str -> AstNode.Str(value.value)
        is RtValue.Num -> AstNode.Num(value.value)
        is RtValue.Bool -> AstNode.Bool(value.value)
        is RtValue.Arr -> AstNode.Arr(value.items.map { toLiteralAst(it) })
        is RtValue.Obj -> AstNode.Obj(value.obj.entries.map { it.first to toLiteralAst(it.second) })
        is RtValue.Element -> {
            // In JS the element is a plain object of its own fields.
            val el = value.element
            val entries = ArrayList<Pair<String, AstNode>>()
            entries.add("type" to AstNode.Str("element"))
            entries.add("typeName" to AstNode.Str(el.typeName))
            entries.add(
                "props" to AstNode.Obj(el.props.entries.map { it.first to toLiteralAst(it.second) })
            )
            entries.add("partial" to AstNode.Bool(el.partial))
            entries.add("hasDynamicProps" to AstNode.Bool(el.hasDynamicProps))
            el.statementId?.let { entries.add("statementId" to AstNode.Str(it)) }
            AstNode.Obj(entries)
        }

        is RtValue.Ast -> value.node // an AST node is itself a plain object in JS
    }

    /** Substitute all `Ref(varName)` nodes with a literal value (`substituteRef`). */
    private fun substituteRef(node: AstNode, varName: String, value: AstNode): AstNode =
        when (node) {
            is AstNode.Ref -> if (node.n == varName) value else node
            is AstNode.Member -> {
                val subObj = substituteRef(node.obj, varName, value)
                if (subObj is AstNode.Obj) {
                    val entry = subObj.entries.firstOrNull { it.first == node.field }
                    entry?.second ?: AstNode.Member(subObj, node.field)
                } else {
                    AstNode.Member(subObj, node.field)
                }
            }

            is AstNode.Index -> AstNode.Index(
                substituteRef(node.obj, varName, value),
                substituteRef(node.index, varName, value),
            )

            is AstNode.BinOp -> AstNode.BinOp(
                node.op,
                substituteRef(node.left, varName, value),
                substituteRef(node.right, varName, value),
            )

            is AstNode.UnaryOp ->
                AstNode.UnaryOp(node.op, substituteRef(node.operand, varName, value))

            is AstNode.Ternary -> AstNode.Ternary(
                substituteRef(node.cond, varName, value),
                substituteRef(node.then, varName, value),
                substituteRef(node.orElse, varName, value),
            )

            is AstNode.Arr -> AstNode.Arr(node.els.map { substituteRef(it, varName, value) })
            is AstNode.Obj -> AstNode.Obj(
                node.entries.map { it.first to substituteRef(it.second, varName, value) }
            )

            is AstNode.Comp -> AstNode.Comp(
                node.name,
                node.args.map { substituteRef(it, varName, value) },
                node.mappedProps?.map { it.first to substituteRef(it.second, varName, value) },
            )

            is AstNode.Assign ->
                AstNode.Assign(node.target, substituteRef(node.value, varName, value))

            else -> node
        }

    private companion object {
        val LOCALE_COLLATOR: Collator = Collator.getInstance(Locale.US)
    }
}
