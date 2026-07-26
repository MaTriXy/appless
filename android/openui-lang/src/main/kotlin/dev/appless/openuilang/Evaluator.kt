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
 * Presence marker for lang-core's THIRD `evaluate(node, context, schemaCtx)`
 * argument (`{ library }` in JS).
 *
 * `evaluator.js` branches on schemaCtx's PRESENCE at four sites — 61 (catalog
 * def lookup for the reactive-prop test), 75 (`props[key] = schemaCtx ?
 * context.getState(val.n) : val`), 89 (recursive inline evaluation of nested
 * ElementNode props) and 421 (the `@Each` element-recursion gate) — and the
 * ACTION-PLAN path deliberately calls the TWO-argument form
 * (`evaluate(args[0], context)`, evaluator.js:264). So inside an `Action([…])`
 * the third argument is absent and raw `StateRef` ASTs are PRESERVED for
 * click-time evaluation instead of being read from the store.
 *
 * Only the marker's presence is observable here: site 61 exists solely to find
 * a `reactive()`-marked prop schema, and the GenOS contract marks none (there
 * is no `$binding<>`/reactive annotation anywhere in
 * `spec/contract/genos.schema.json`), so the reactive branch at evaluator.js:65
 * is dead in BOTH states. Hence a marker object rather than a library handle.
 *
 * Deliberately NOT defaulted: JS makes the drop visible at each call site, and
 * so does this port. Fixtures `076-action-staterefs-preserved`,
 * `077-action-each-staterefs`.
 */
internal object SchemaCtx

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

    /**
     * Runtime prop-evaluation errors, in emission order — the JS
     * `evalCtx.errors` array. Read by [Pipeline] after the root is evaluated.
     */
    val runtimeErrors: MutableList<RuntimeError> = ArrayList()

    // ── Element / prop evaluation (evaluate-tree, evaluate-prop) ────────────

    /**
     * `evaluate-tree.js` `evaluateElementProps` — the entry point, and the ONLY
     * one that catches. Each prop is evaluated inside a try/catch; on a throw
     * the RAW prop value is kept and a `runtimeErrors` entry is recorded.
     */
    fun evaluateElementProps(root: RtValue): RtValue {
        val ref = JsObjects.runtimeElementRef(root) ?: return root
        return recurseElement(ref, inline = false)
    }

    /**
     * `evaluate-tree.js` `evaluateElementProps` (`inline = false`) and
     * `evaluator.js` `evaluateElementInline` (`inline = true`) — the SAME prop
     * loop, differing only in the try/catch. The inline one deliberately does
     * NOT catch: a throw in there propagates out of `evaluate()` and is caught
     * by the OUTER tree-level call, so the recorded error names the outer
     * element and the outer prop key (fixture `082-runtime-error-outer-prop`).
     *
     * Everything the loop touches is an ordinary property GET on the receiver,
     * so a duck-typed element works exactly like a typed one — with ONE
     * consequence the typed path hides: the reference returns
     * `{ ...el, props: evaluated }`, a FRESH object literal whose own
     * enumerable keys are copied by DEFINE. An element identity that was only
     * INHERITED (`{"__proto__": <element>}`) is therefore lost right here,
     * because `type`/`typeName` were never own keys (fixture
     * `096-duck-element-proto-spread`).
     */
    private fun recurseElement(ref: JsElementRef, inline: Boolean): RtValue {
        // `if (el.hasDynamicProps === false) return el;` — a strict `=== false`,
        // so a MISSING `hasDynamicProps` (undefined) does not short-circuit.
        if (ref.hasDynamicProps == RtValue.Bool(false)) return ref.receiver
        val props = RtObject()
        // `Object.entries(el.props)` — own enumerable entries of whatever
        // `el.props` resolved to through the chain.
        for (key in JsObjects.objectKeys(ref.props) ?: emptyList()) {
            val value = JsObjects.getMember(ref.props, key)
            val evaluated = if (inline) {
                evaluatePropValue(value, inline = true)
            } else {
                try {
                    evaluatePropValue(value, inline = false)
                } catch (e: JsTypeError) {
                    runtimeErrors.add(
                        RuntimeError(
                            message =
                                "Evaluating prop \"$key\" on ${ref.typeName} failed: ${e.message}",
                            component = ref.typeName,
                            statementId = Pipeline.rawJson(ref.statementId),
                        )
                    )
                    value
                }
            }
            // `evaluated[key] = …` — ASSIGNMENT, so a `__proto__` key re-points
            // the rebuilt props object rather than becoming an own key.
            props.assign(key, evaluated)
        }
        if (ref.element != null) return RtValue.Element(ref.element.withProps(props))
        val out = RtObject()
        for (key in JsObjects.objectKeys(ref.receiver) ?: emptyList()) {
            // Object spread is CreateDataProperty, not assignment: an own
            // `__proto__` key survives as ordinary data.
            out.put(key, JsObjects.getMember(ref.receiver, key))
        }
        out.put("props", RtValue.Obj(props))
        return RtValue.Obj(out)
    }

    /** `isElementNode(v) ? callbacks.recurseElement(v) : v`, chain-aware. */
    private fun recurseIfElement(v: RtValue, inline: Boolean): RtValue =
        JsObjects.runtimeElementRef(v)?.let { recurseElement(it, inline) } ?: v

    /**
     * `evaluate-prop.js` `evaluatePropCore`. [inline] selects the recursion
     * callback: the inline (non-catching) element path or the tree path.
     */
    private fun evaluatePropValue(value: RtValue, inline: Boolean): RtValue = when (value) {
        is RtValue.Undefined, is RtValue.Null, is RtValue.Bool,
        is RtValue.Num, is RtValue.Str,
        -> value

        // `typeof fn === "function"`, so evaluate-prop.js's
        // `typeof value !== "object"` guard returns it untouched.
        is RtValue.Func -> value

        is RtValue.Ast -> {
            // The schema context IS present on every evaluate-prop entry
            // (evaluate-tree.js builds `{ library: evalCtx.library }`).
            val result = evaluate(value.node, ctx, SchemaCtx)
            when {
                // `isElementNode(result)` / `result.map(item => isElementNode(item) ? …)`
                // — both chain-aware duck-type tests, not type checks.
                JsObjects.runtimeElementRef(result) != null ->
                    recurseIfElement(result, inline)

                result is RtValue.Arr ->
                    RtValue.Arr(result.items.map { recurseIfElement(it, inline) })
                // Strip a ReactiveAssign marker in a non-reactive context.
                isReactiveAssign(result) -> {
                    val target = (JsObjects.getMember(result, "target") as? RtValue.Str)?.value
                    val v = if (target == null) RtValue.Undefined else ctx.getState(target)
                    if (v.isNullish) RtValue.Null else v
                }

                else -> result
            }
        }

        is RtValue.Arr -> RtValue.Arr(value.items.map { evaluatePropValue(it, inline) })
        is RtValue.Element -> recurseIfElement(value, inline)

        is RtValue.Obj, is RtValue.Proto -> {
            // evaluate-prop.js runs its duck-typing in this exact order, and
            // EVERY test is a prototype-chain-aware read, so an object that
            // INHERITED `k` (via `{"__proto__": <ast node>}`) is evaluated as
            // an AST node and one that inherited `type`/`typeName` is recursed
            // into as an element (fixtures `085`–`086`).
            val astView = JsObjects.astNodeView(value)
            val elementRef = JsObjects.runtimeElementRef(value)
            when {
                astView != null -> evaluatePropValue(RtValue.Ast(astView), inline)
                elementRef != null -> recurseElement(elementRef, inline)
                // ActionPlan / ActionStep — preserve as-is (deferred eval).
                JsObjects.getMember(value, "steps") is RtValue.Arr -> value
                JsObjects.hasProperty(value, "type") &&
                    JsObjects.hasProperty(value, "valueAST") -> value
                // KNOWN-DEVIATION #5 (both READMEs, same number): a LITERAL object whose
                // OWN `k` is a real AST kind ({k: "Str", v: "x"}) is
                // indistinguishable from an AST node in JS and would be
                // evaluated here; the typed port keeps it as plain data.
                // (The SERIALIZER-level duck-typing IS replicated — see
                // Pipeline.convertValue / fixture 070.)
                else -> {
                    val entries = if (value is RtValue.Obj) value.obj.entries else emptyList()
                    if (entries.any { it.second.isObjectLike }) {
                        // `result[k] = …` in evaluate-prop.js — ASSIGNMENT, so
                        // a `__proto__` key re-points the rebuilt object's
                        // prototype instead of becoming an own key.
                        val out = RtObject()
                        for ((k, v) in entries) out.assign(k, evaluatePropValue(v, inline))
                        // The rebuild starts from a fresh `{}`, so it does NOT
                        // inherit the source object's prototype.
                        RtValue.Obj(out)
                    } else {
                        value
                    }
                }
            }
        }
    }

    /** `value.__reactive === "assign"` — a chain-aware property read. */
    private fun isReactiveAssign(v: RtValue): Boolean =
        v.isObjectLike && (JsObjects.getMember(v, "__reactive") as? RtValue.Str)?.value == "assign"

    // ── Core AST evaluation ────────────────────────────────────────────────

    /**
     * `evaluator.js` `evaluate(node, context, schemaCtx)`.
     *
     * [schemaCtx] is threaded EXACTLY where JS threads it: on to
     * [evaluateLazyBuiltin] and to the recursive `mappedProps` evaluation. Every
     * other recursion in JS calls the two-argument form, so those pass `null`
     * here — collection elements, object entries, operator operands, ternary
     * branches, member/index receivers and eager-builtin arguments all drop it.
     */
    fun evaluate(node: AstNode, context: EvalContext, schemaCtx: SchemaCtx?): RtValue = when (node) {
        is AstNode.Str -> RtValue.Str(node.v)
        is AstNode.Num -> RtValue.Num(node.v)
        is AstNode.Bool -> RtValue.Bool(node.v)
        is AstNode.Null -> RtValue.Null
        is AstNode.Ph -> RtValue.Null
        is AstNode.StateRef -> context.getState(node.n)
        is AstNode.Ref -> context.resolveRef(node.n)
        is AstNode.RuntimeRef -> context.resolveRef(node.n)
        is AstNode.Arr -> RtValue.Arr(node.els.map { evaluate(it, context, null) })
        is AstNode.Obj -> {
            // Object.fromEntries → CreateDataProperty, NOT assignment: unlike
            // materialize.js's Obj case a `"__proto__"` entry DOES become an
            // own property here (it is dropped again by the serializer, whose
            // own `out[key] = …` is an assignment).
            val o = RtObject()
            for ((k, v) in node.entries) o[k] = evaluate(v, context, null)
            RtValue.Obj(o)
        }

        is AstNode.Comp -> evaluateComp(node, context, schemaCtx)

        is AstNode.BinOp -> evaluateBinOp(node, context)

        is AstNode.UnaryOp -> when (node.op) {
            "!" -> RtValue.Bool(!jsTruthy(evaluate(node.operand, context, null)))
            "-" -> RtValue.Num(-dslToNumber(evaluate(node.operand, context, null)))
            else -> RtValue.Null
        }

        is AstNode.Ternary ->
            if (jsTruthy(evaluate(node.cond, context, null))) {
                evaluate(node.then, context, null)
            } else {
                evaluate(node.orElse, context, null)
            }

        is AstNode.Member -> {
            val obj = evaluate(node.obj, context, null)
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
            val obj = evaluate(node.obj, context, null)
            val idx = evaluate(node.index, context, null)
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

    private fun evaluateComp(
        node: AstNode.Comp,
        context: EvalContext,
        schemaCtx: SchemaCtx?,
    ): RtValue {
        if (Builtins.lazyBuiltins.contains(node.name)) {
            return evaluateLazyBuiltin(node.name, node.args, context, schemaCtx)
        }
        // evaluator.js:48 `const builtin = BUILTINS[node.name]` — a property GET
        // on a plain object literal, so it also answers for the twelve
        // `Object.prototype` names. Either way the args are evaluated FIRST
        // (evaluator.js:50), then `builtin.fn(...)` is called — and for an
        // inherited member `.fn` is `undefined`.
        val lookup = Builtins.lookupBuiltin(node.name)
        if (lookup != Builtins.BuiltinLookup.MISS) {
            // evaluator.js:50 — eager builtin args drop the schema context.
            val args = node.args.map { evaluate(it, context, null) }
            if (lookup == Builtins.BuiltinLookup.INHERITED) {
                throw JsTypeError(JsObjects.BUILTIN_FN_MESSAGE)
            }
            return callDataBuiltin(node.name, args)
        }
        if (Builtins.actionNames.contains(node.name)) {
            // evaluator.js:55 — evaluateActionCall takes no schemaCtx at all.
            return evaluateActionCall(node.name, node.args, context)
        }
        val mapped = node.mappedProps ?: return RtValue.Null // unmapped Comp
        val props = RtObject()
        for ((key, value) in mapped) {
            props[key] = if (value is AstNode.StateRef) {
                // evaluator.js:75 —
                //   props[key] = schemaCtx ? context.getState(val.n) : val
                // Site 61 (`schemaCtx?.library.components[node.name]`) picks the
                // prop schema for the reactive test one line above; the GenOS
                // contract marks no prop reactive, so that branch is dead in
                // both states and only this ternary is observable.
                if (schemaCtx != null) context.getState(value.n) else RtValue.Ast(value)
            } else {
                evaluate(value, context, schemaCtx)
            }
        }
        // evaluator.js:89 — nested ElementNodes in props are re-evaluated
        // inline ONLY when the schema context is present.
        val finalProps = if (schemaCtx == null) {
            props
        } else {
            val out = RtObject()
            for ((key, v) in props.entries) {
                // `isElementNode(val)` / per-item — chain-aware duck-type tests.
                out[key] = when {
                    JsObjects.runtimeElementRef(v) != null -> recurseIfElement(v, inline = true)
                    v is RtValue.Arr ->
                        RtValue.Arr(v.items.map { recurseIfElement(it, inline = true) })

                    else -> v
                }
            }
            out
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
            val left = evaluate(node.left, context, null)
            return if (jsTruthy(left)) evaluate(node.right, context, null) else left
        }
        if (node.op == "||") {
            val left = evaluate(node.left, context, null)
            return if (jsTruthy(left)) left else evaluate(node.right, context, null)
        }
        val left = evaluate(node.left, context, null)
        val right = evaluate(node.right, context, null)
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
     * JS `obj[key]` property access — own properties first, then the whole
     * PROTOTYPE CHAIN, via the shared [JsObjects] model. So `$obj.toString`
     * yields `Object.prototype.toString` (a native function value), `$obj
     * .constructor` yields `Object`, `$num.constructor` yields `Number`, and
     * `$obj.__proto__` yields `Object.prototype` itself.
     *
     * Element receivers read their own fields (`typeName`, `props`, `partial`,
     * `hasDynamicProps`, `type`, `statementId`) here too — in JS an
     * ElementNode is just a plain object.
     */
    private fun propertyGet(obj: RtValue, key: String): RtValue = JsObjects.getMember(obj, key)

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
                    // ES 23.1.3.30.1 SortIndexedProperties: `undefined`
                    // elements are PARTITIONED OFF before sorting, appended
                    // after every defined element, and the comparator is NEVER
                    // invoked on them. So `@Sort([3, undefined, 1])` is
                    // `[1, 3, undefined]` (not `[undefined, 1, 3]` — an
                    // undefined coerced to "" would sort first), and a
                    // comparator that would throw on an undefined operand
                    // never runs (fixture `089-sort-undefined-partition`).
                    //
                    // JS Array.prototype.sort is stable (V8 TimSort); so is
                    // Kotlin's sortedWith.
                    val defined = items.filter { it !is RtValue.Undefined }
                    val holes = items.size - defined.size
                    val sorted = defined.sortedWith { a, b ->
                        val av = if (f.isEmpty()) a else resolveField(a, f)
                        val bv = if (f.isEmpty()) b else resolveField(b, f)
                        val cmp = sortCompare(av, bv)
                        if (desc) -cmp else cmp
                    }
                    RtValue.Arr(sorted + List(holes) { RtValue.Undefined })
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
     * string branch is JS `String.prototype.localeCompare`.
     *
     * ASCII — the whole range `@Sort` can reach from a `.oui` corpus without
     * non-Latin text — goes through [jsAsciiLocaleCompare], a direct CLDR-root
     * (`alternate = non-ignorable`) weight table verified against V8 over
     * 235,233 pairs with zero mismatches, and shared verbatim with the Swift
     * port.
     *
     * This deliberately REPLACES `java.text.Collator.getInstance(Locale.US)`,
     * whose legacy en_US rules treat hyphen and space as ignorable at primary
     * strength: it answered `"a-b" > "ab"` and `"co-op" > "coop"` where V8 and
     * the Swift port say `<`. That was never "not observable in the corpus" —
     * it is observable the moment a `@Sort` input contains a hyphen or a space
     * (fixture `090-sort-ascii-collation`).
     *
     * KNOWN-DEVIATION #1 (see README) now covers ONLY the non-ASCII fallback
     * below, where the two ports still lean on their platform collators.
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
        jsAsciiLocaleCompare(a, b)?.let { return it }
        // Outside ASCII: the platform collator (KNOWN-DEVIATION #1).
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
                evaluate(args[0], context, null)
            }
            val rawSteps = (stepsArg as? RtValue.Arr)?.items ?: emptyList()
            // Non-object / null entries and entries without a `type` field are
            // filtered out. (JS ElementNodes carry a `type` field, so they pass.)
            // `s != null && typeof s === "object" && "type" in s` — the `in`
            // walks the prototype chain. (JS ElementNodes carry `type`.)
            val steps = rawSteps.filter { it.isObjectLike && JsObjects.hasProperty(it, "type") }
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
                RtValue.Str(if (args.isEmpty()) "" else concatOperand(evaluate(args[0], context, null)))
            if (args.size > 1) {
                o["context"] = RtValue.Str(concatOperand(evaluate(args[1], context, null)))
            }
            RtValue.Obj(o)
        }

        "OpenUrl" -> RtValue.Obj(
            RtObject.of(
                "type" to RtValue.Str("open_url"),
                "url" to RtValue.Str(
                    if (args.isEmpty()) "" else concatOperand(evaluate(args[0], context, null))
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
        schemaCtx: SchemaCtx?,
    ): RtValue {
        if (name != "Each") return RtValue.Null
        if (args.size < 3) return RtValue.Arr(emptyList())
        val arr = (evaluate(args[0], context, null) as? RtValue.Arr)?.items
            ?: return RtValue.Arr(emptyList())
        val varName = when (val v = args[1]) {
            is AstNode.Ref -> v.n
            is AstNode.Str -> v.v
            else -> null
        }
        // evaluator.js:405 guards with `if (!varName)` — FALSY, so an EMPTY
        // iterator name aborts the loop and yields `[]`, it does not iterate
        // (fixture `079-each-empty-iterator-name`).
        if (varName.isNullOrEmpty()) return RtValue.Arr(emptyList())
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
                val result = evaluate(substituted, childCtx, schemaCtx)
                // evaluator.js:421 — the element re-evaluation is gated on the
                // schema context, so inside an Action the per-item element
                // keeps whatever raw ASTs site 75 preserved.
                if (schemaCtx != null) recurseIfElement(result, inline = true) else result
            }
        )
    }

    /** Convert a resolved runtime value back to a literal AST node (`toLiteralAST`). */
    private fun toLiteralAst(value: RtValue): AstNode = when (value) {
        // `typeof fn === "function"` matches none of toLiteralAST's branches,
        // so it falls through to the trailing `return { k: "Null" }`.
        is RtValue.Undefined, is RtValue.Null, is RtValue.Func -> AstNode.Null
        is RtValue.Proto ->
            if (value.kind == JsProtoKind.ARRAY) {
                AstNode.Arr(emptyList()) // Array.prototype is an empty array
            } else {
                AstNode.Obj(emptyList()) // no ENUMERABLE own properties
            }

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
