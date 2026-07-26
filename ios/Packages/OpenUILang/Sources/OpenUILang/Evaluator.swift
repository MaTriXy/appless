import Foundation

/// Runtime evaluation context — mirrors the EvaluationContext react-lang
/// builds: `getState` reads the initialized store (unwrapping
/// `{value, componentType}` wrappers), `resolveRef` yields undefined.
struct EvalContext {
    let getState: (String) -> RTValue
    let resolveRef: (String) -> RTValue
}

/// Presence marker for lang-core's THIRD `evaluate(node, context, schemaCtx)`
/// argument (`{ library }` in JS).
///
/// `evaluator.js` branches on schemaCtx's PRESENCE at four sites — 61 (catalog
/// def lookup for the reactive-prop test), 75 (`props[key] = schemaCtx ?
/// context.getState(val.n) : val`), 89 (recursive inline evaluation of nested
/// ElementNode props) and 421 (the `@Each` element-recursion gate) — and the
/// ACTION-PLAN path deliberately calls the TWO-argument form
/// (`evaluate(args[0], context)`, evaluator.js:264). So inside an `Action([…])`
/// the third argument is absent and raw `StateRef` ASTs are PRESERVED for
/// click-time evaluation instead of being read from the store.
///
/// Only the marker's presence is observable here: site 61 exists solely to find
/// a `reactive()`-marked prop schema, and the GenOS contract marks none (there
/// is no `$binding<>`/reactive annotation anywhere in
/// `spec/contract/genos.schema.json`), so the reactive branch at
/// evaluator.js:65 is dead in BOTH states. Hence a marker rather than a library
/// handle.
///
/// Deliberately NOT defaulted: JS makes the drop visible at each call site, and
/// so does this port. Fixtures `076-action-staterefs-preserved`,
/// `077-action-each-staterefs`.
struct SchemaCtx {
    static let present = SchemaCtx()
}

/// Port of `runtime/evaluator.js` + `runtime/evaluate-prop.js` +
/// `runtime/evaluate-tree.js` for the AppLess (non-reactive) contract
/// (spec/openui-lang.md §9 runtime evaluation; §9.1 operators, §9.2 builtins,
/// §9.3 actions).
final class Evaluator {
    private let ctx: EvalContext

    init(store: [String: RTValue]) {
        func unwrap(_ v: RTValue) -> RTValue {
            if case .object(let o) = v, let inner = o["value"] {
                return inner
            }
            return v
        }
        let storeCopy = store
        self.ctx = EvalContext(
            getState: { name in
                guard let v = storeCopy[name] else { return .undefined }
                return unwrap(v)
            },
            resolveRef: { _ in .undefined }
        )
    }

    /// Runtime prop-evaluation errors, in emission order — the JS
    /// `evalCtx.errors` array. Read by `Pipeline` after the root is evaluated.
    private(set) var runtimeErrors: [RuntimeError] = []

    // MARK: - Element/prop evaluation (evaluate-tree / evaluate-prop)

    /// `evaluate-tree.js` `evaluateElementProps` — the entry point, and the
    /// ONLY one that catches. Each prop is evaluated inside a do/catch; on a
    /// throw the RAW prop value is kept and a `runtimeErrors` entry recorded.
    func evaluateElementProps(_ root: RTValue) -> RTValue {
        guard let ref = JSObjects.runtimeElementRef(root) else { return root }
        // `inline: false` never rethrows — every prop is caught individually.
        return (try? recurseElement(ref, inline: false)) ?? root
    }

    /// `evaluate-tree.js` `evaluateElementProps` (`inline: false`) and
    /// `evaluator.js` `evaluateElementInline` (`inline: true`) — the SAME prop
    /// loop, differing only in the catch. The inline one deliberately does NOT
    /// catch: a throw in there propagates out of `evaluate()` and is caught by
    /// the OUTER tree-level call, so the recorded error names the outer element
    /// and the outer prop key (fixture `082-runtime-error-outer-prop`).
    ///
    /// Everything the loop touches is an ordinary property GET on the receiver,
    /// so a duck-typed element works exactly like a typed one — with ONE
    /// consequence the typed path hides: the reference returns
    /// `{ ...el, props: evaluated }`, a FRESH object literal whose own
    /// enumerable keys are copied by DEFINE. An element identity that was only
    /// INHERITED (`{"__proto__": <element>}`) is therefore lost right here,
    /// because `type`/`typeName` were never own keys (fixture
    /// `096-duck-element-proto-spread`).
    private func recurseElement(_ ref: JSElementRef, inline: Bool) throws -> RTValue {
        // `if (el.hasDynamicProps === false) return el;` — a strict `=== false`,
        // so a MISSING `hasDynamicProps` (undefined) does not short-circuit.
        if case .bool(false) = ref.hasDynamicProps { return ref.receiver }
        var props = RTObject()
        // `Object.entries(el.props)` — own enumerable entries of whatever
        // `el.props` resolved to through the chain.
        for key in JSObjects.objectKeys(ref.props) ?? [] {
            let value = (try? JSObjects.getMember(ref.props, key)) ?? .undefined
            var evaluated: RTValue
            if inline {
                evaluated = try evaluatePropValue(value, inline: true)
            } else {
                do {
                    evaluated = try evaluatePropValue(value, inline: false)
                } catch let error as JSTypeError {
                    runtimeErrors.append(
                        RuntimeError(
                            message:
                                "Evaluating prop \"\(key)\" on \(ref.typeName) failed: "
                                + error.message,
                            component: ref.typeName,
                            statementId: Pipeline.rawJSON(ref.statementId)
                        )
                    )
                    evaluated = value
                } catch {
                    evaluated = value
                }
            }
            // `evaluated[key] = …` — ASSIGNMENT, so a `__proto__` key re-points
            // the rebuilt props object rather than becoming an own key.
            props.assign(key, evaluated)
        }
        if var el = ref.element {
            el.props = props
            return .element(el)
        }
        var out = RTObject()
        for key in JSObjects.objectKeys(ref.receiver) ?? [] {
            // Object spread is CreateDataProperty, not assignment: an own
            // `__proto__` key survives as ordinary data.
            out[key] = (try? JSObjects.getMember(ref.receiver, key)) ?? .undefined
        }
        out["props"] = .object(props)
        return .object(out)
    }

    /// `isElementNode(v) ? callbacks.recurseElement(v) : v`, chain-aware.
    private func recurseIfElement(_ v: RTValue, inline: Bool) throws -> RTValue {
        guard let ref = JSObjects.runtimeElementRef(v) else { return v }
        return try recurseElement(ref, inline: inline)
    }

    /// `evaluate-prop.js` `evaluatePropCore`. `inline` selects the recursion
    /// callback: the inline (non-catching) element path or the tree path.
    private func evaluatePropValue(_ value: RTValue, inline: Bool) throws -> RTValue {
        switch value {
        case .undefined, .null, .bool, .number, .string:
            return value
        // `typeof fn === "function"`, so evaluate-prop.js's
        // `typeof value !== "object"` guard returns it untouched.
        case .function:
            return value
        case .ast(let node):
            // The schema context IS present on every evaluate-prop entry
            // (evaluate-tree.js builds `{ library: evalCtx.library }`).
            let result = try evaluate(node, ctx, SchemaCtx.present)
            // `isElementNode(result)` / `result.map(item => isElementNode(item) ? …)`
            // — both chain-aware duck-type tests, not type checks.
            if JSObjects.runtimeElementRef(result) != nil {
                return try recurseIfElement(result, inline: inline)
            }
            if case .array(let items) = result {
                return .array(try items.map { try recurseIfElement($0, inline: inline) })
            }
            // Strip ReactiveAssign in a non-reactive context.
            if isReactiveAssign(result),
                case .string(let target) = try JSObjects.getMember(result, "target")
            {
                let v = ctx.getState(target)
                return v.isNullish ? .null : v
            }
            return result
        case .array(let items):
            return .array(try items.map { try evaluatePropValue($0, inline: inline) })
        case .element:
            return try recurseIfElement(value, inline: inline)
        case .object, .proto:
            // evaluate-prop.js runs its duck-typing in this exact order, and
            // EVERY test is a prototype-chain-aware read, so an object that
            // INHERITED `k` (via `{"__proto__": <ast node>}`) is evaluated as
            // an AST node and one that inherited `type`/`typeName` is recursed
            // into as an element (fixtures `085`–`086`).
            if let astView = JSObjects.astNodeView(value) {
                return try evaluatePropValue(.ast(astView), inline: inline)
            }
            if let elementRef = JSObjects.runtimeElementRef(value) {
                return try recurseElement(elementRef, inline: inline)
            }
            // ActionPlan / ActionStep — preserve as-is (deferred evaluation)
            if case .array = try JSObjects.getMember(value, "steps") { return value }
            if JSObjects.hasProperty(value, "type"),
                JSObjects.hasProperty(value, "valueAST")
            {
                return value
            }
            // KNOWN-DEVIATION (README.md #6): a LITERAL object whose OWN `k` is
            // a real AST kind string ({k: "Str", v: "x"}) is indistinguishable
            // from an AST node in JS and would be evaluated here; the typed
            // port keeps it as plain data.
            let entries: [(key: String, value: RTValue)]
            if case .object(let o) = value { entries = o.entries } else { entries = [] }
            if entries.contains(where: { $0.value.isObjectLike }) {
                // `result[k] = …` in evaluate-prop.js — ASSIGNMENT, so a
                // `__proto__` key re-points the rebuilt object's prototype
                // instead of becoming an own key. The rebuild starts from a
                // fresh `{}`, so it does NOT inherit the source's prototype.
                var out = RTObject()
                for (k, v) in entries {
                    out.assign(k, try evaluatePropValue(v, inline: inline))
                }
                return .object(out)
            }
            return value
        }
    }

    /// `value.__reactive === "assign"` — a chain-aware property read.
    private func isReactiveAssign(_ v: RTValue) -> Bool {
        guard v.isObjectLike else { return false }
        if case .string(let s)? = try? JSObjects.getMember(v, "__reactive") {
            return jsStringEquals(s, "assign")
        }
        return false
    }

    // MARK: - Core AST evaluation

    /// `evaluator.js` `evaluate(node, context, schemaCtx)`.
    ///
    /// `schemaCtx` is threaded EXACTLY where JS threads it: on to
    /// `evaluateLazyBuiltin` and to the recursive `mappedProps` evaluation.
    /// Every other recursion in JS calls the two-argument form, so those pass
    /// `nil` here — collection elements, object entries, operator operands,
    /// ternary branches, member/index receivers and eager-builtin arguments all
    /// drop it.
    func evaluate(_ node: ASTNode, _ context: EvalContext, _ schemaCtx: SchemaCtx?) throws
        -> RTValue
    {
        switch node {
        case .str(let v): return .string(v)
        case .num(let v): return .number(v)
        case .bool(let v): return .bool(v)
        case .null: return .null
        case .ph: return .null
        case .stateRef(let n):
            return context.getState(n)
        case .ref(let n), .runtimeRef(let n, _):
            return context.resolveRef(n)
        case .arr(let els):
            return .array(try els.map { try evaluate($0, context, nil) })
        case .obj(let entries):
            // Object.fromEntries → CreateDataProperty, NOT assignment: unlike
            // materialize.js's Obj case a `"__proto__"` entry DOES become an
            // own property here (the serializer's own `out[key] = …` drops it
            // again).
            var o = RTObject()
            for (k, v) in entries { o[k] = try evaluate(v, context, nil) }
            return .object(o)
        case .comp(let name, let args, let mappedProps):
            if Builtins.lazyBuiltins.contains(name) {
                return try evaluateLazyBuiltin(
                    name: name, args: args, context: context, schemaCtx: schemaCtx)
            }
            // evaluator.js:48 `const builtin = BUILTINS[node.name]` — a
            // property GET on a plain object literal, so it also answers for
            // the twelve `Object.prototype` names. Either way the args are
            // evaluated FIRST (evaluator.js:50), then `builtin.fn(...)` is
            // called — and for an inherited member `.fn` is `undefined`.
            let lookup = Builtins.lookupBuiltin(name)
            if lookup != .miss {
                // evaluator.js:50 — eager builtin args drop the schema context.
                let evaluated = try args.map { try evaluate($0, context, nil) }
                if lookup == .inherited {
                    throw JSTypeError(message: JSObjects.builtinFnMessage)
                }
                return try callDataBuiltin(name: name, args: evaluated)
            }
            if Builtins.actionNames.contains(name) {
                // evaluator.js:55 — evaluateActionCall takes no schemaCtx.
                return try evaluateActionCall(name: name, args: args, context: context)
            }
            if let mapped = mappedProps {
                var props = RTObject()
                for (key, val) in mapped {
                    if case .stateRef(let n) = val {
                        // evaluator.js:75 —
                        //   props[key] = schemaCtx ? context.getState(val.n) : val
                        // Site 61 (`schemaCtx?.library.components[node.name]`)
                        // picks the prop schema for the reactive test one line
                        // above; the GenOS contract marks no prop reactive, so
                        // that branch is dead in both states and only this
                        // ternary is observable.
                        props[key] = schemaCtx != nil ? context.getState(n) : .ast(val)
                    } else {
                        props[key] = try evaluate(val, context, schemaCtx)
                    }
                }
                var el = RTElement(
                    typeName: name, props: props, partial: false,
                    hasDynamicProps: true, statementId: nil)
                // evaluator.js:89 — nested ElementNodes in props are
                // re-evaluated inline ONLY when the schema context is present.
                if schemaCtx != nil {
                    for (key, v) in el.props.entries {
                        // `isElementNode(val)` / per-item — chain-aware tests.
                        if JSObjects.runtimeElementRef(v) != nil {
                            el.props[key] = try recurseIfElement(v, inline: true)
                        } else if case .array(let items) = v {
                            el.props[key] = .array(
                                try items.map { try recurseIfElement($0, inline: true) })
                        }
                    }
                }
                return .element(el)
            }
            return .null // unmapped Comp (unknown component in expression)
        case .binOp(let op, let leftNode, let rightNode):
            if op == "&&" {
                let left = try evaluate(leftNode, context, nil)
                return jsTruthy(left) ? try evaluate(rightNode, context, nil) : left
            }
            if op == "||" {
                let left = try evaluate(leftNode, context, nil)
                return jsTruthy(left) ? left : try evaluate(rightNode, context, nil)
            }
            let left = try evaluate(leftNode, context, nil)
            let right = try evaluate(rightNode, context, nil)
            switch op {
            case "+":
                if case .string = left {
                    return .string(try concatOperand(left) + (try concatOperand(right)))
                }
                if case .string = right {
                    return .string(try concatOperand(left) + (try concatOperand(right)))
                }
                return .number(dslToNumber(left) + dslToNumber(right))
            case "-":
                return .number(dslToNumber(left) - dslToNumber(right))
            case "*":
                return .number(dslToNumber(left) * dslToNumber(right))
            case "/":
                let r = dslToNumber(right)
                return .number(r == 0 ? 0 : dslToNumber(left) / r)
            case "%":
                let r = dslToNumber(right)
                return .number(r == 0 ? 0 : dslToNumber(left).truncatingRemainder(dividingBy: r))
            case "==":
                return .bool(try jsLooseEquals(left, right))
            case "!=":
                return .bool(!(try jsLooseEquals(left, right)))
            case ">":
                return .bool(dslToNumber(left) > dslToNumber(right))
            case "<":
                return .bool(dslToNumber(left) < dslToNumber(right))
            case ">=":
                return .bool(dslToNumber(left) >= dslToNumber(right))
            case "<=":
                return .bool(dslToNumber(left) <= dslToNumber(right))
            default:
                return .null
            }
        case .unaryOp(let op, let operandNode):
            if op == "!" {
                return .bool(!jsTruthy(try evaluate(operandNode, context, nil)))
            }
            if op == "-" {
                return .number(-dslToNumber(try evaluate(operandNode, context, nil)))
            }
            return .null
        case .ternary(let condNode, let thenNode, let elseNode):
            let cond = try evaluate(condNode, context, nil)
            return jsTruthy(cond)
                ? try evaluate(thenNode, context, nil)
                : try evaluate(elseNode, context, nil)
        case .member(let objNode, let field):
            let obj = try evaluate(objNode, context, nil)
            if obj.isNullish { return .null }
            if case .array(let items) = obj {
                if field == "length" { return .number(Double(items.count)) }
                // Array pluck: extract field from every element
                return .array(
                    try items.map { item in
                        if item.isNullish { return .null }
                        let v = try propertyGet(item, field)
                        return v.isNullish ? .null : v
                    })
            }
            return try propertyGet(obj, field)
        case .index(let objNode, let indexNode):
            let obj = try evaluate(objNode, context, nil)
            let idx = try evaluate(indexNode, context, nil)
            if obj.isNullish || idx.isNullish { return .null }
            if case .array(let items) = obj {
                let n = dslToNumber(idx)
                guard n.isFinite, n == n.rounded(.towardZero), n >= 0,
                    n < Double(items.count)
                else { return .undefined }
                return items[Int(n)]
            }
            return try propertyGet(obj, try jsToString(idx))
        case .assign(let target, let value):
            var o = RTObject()
            o["__reactive"] = .string("assign")
            o["target"] = .string(target)
            o["expr"] = .ast(value)
            return .object(o)
        }
    }

    /// `String(x ?? "")` used by string concatenation and action strings.
    private func concatOperand(_ v: RTValue) throws -> String {
        v.isNullish ? "" : try jsToString(v)
    }

    /// JS `obj[key]` property access — own properties first, then the whole
    /// PROTOTYPE CHAIN, via the shared `JSObjects` model. So `$obj.toString`
    /// yields `Object.prototype.toString` (a native function value),
    /// `$obj.constructor` yields `Object`, `$num.constructor` yields `Number`,
    /// and `$obj.__proto__` yields `Object.prototype` itself.
    ///
    /// Element receivers read their own fields (`typeName`, `props`,
    /// `partial`, `hasDynamicProps`, `type`, `statementId`) here too — in JS an
    /// ElementNode is just a plain object.
    private func propertyGet(_ obj: RTValue, _ key: String) throws -> RTValue {
        try JSObjects.getMember(obj, key)
    }

    // MARK: - Data builtins

    private func callDataBuiltin(name: String, args: [RTValue]) throws -> RTValue {
        func arg(_ i: Int) -> RTValue { i < args.count ? args[i] : .undefined }

        switch name {
        case "Count":
            if case .array(let items) = arg(0) { return .number(Double(items.count)) }
            return .number(0)
        case "First":
            if case .array(let items) = arg(0) {
                let v = items.first ?? .null
                return v.isNullish ? .null : v
            }
            return .null
        case "Last":
            if case .array(let items) = arg(0) {
                let v = items.last ?? .null
                return v.isNullish ? .null : v
            }
            return .null
        case "Sum":
            if case .array(let items) = arg(0) {
                return .number(items.reduce(0.0) { $0 + dslToNumber($1) })
            }
            return .number(0)
        case "Avg":
            if case .array(let items) = arg(0), !items.isEmpty {
                let sum = items.reduce(0.0) { $0 + dslToNumber($1) }
                return .number(sum / Double(items.count))
            }
            return .number(0)
        case "Min":
            if case .array(let items) = arg(0), !items.isEmpty {
                let start = dslToNumber(items[0])
                return .number(items.reduce(start) { jsMathMin($0, dslToNumber($1)) })
            }
            return .number(0)
        case "Max":
            if case .array(let items) = arg(0), !items.isEmpty {
                let start = dslToNumber(items[0])
                return .number(items.reduce(start) { jsMathMax($0, dslToNumber($1)) })
            }
            return .number(0)
        case "Sort":
            guard case .array(let items) = arg(0) else { return arg(0) }
            let f = arg(1).isNullish ? "" : try jsToString(arg(1))
            let desc = (arg(2).isNullish ? "asc" : try jsToString(arg(2))) == "desc"
            // ES 23.1.3.30.1 SortIndexedProperties: `undefined` elements are
            // PARTITIONED OFF before sorting, appended after every defined
            // element, and the comparator is NEVER invoked on them. So
            // `@Sort([3, undefined, 1])` is `[1, 3, undefined]` (not
            // `[undefined, 1, 3]` — an undefined coerced to "" would sort
            // first), and a comparator that would throw on an undefined
            // operand never runs (fixture `089-sort-undefined-partition`).
            //
            // `sorted(by:)` is `rethrows`, so a comparator that hits a
            // `toString`-shadowing member propagates the TypeError just like
            // `Array.prototype.sort` does in JS.
            var defined: [RTValue] = []
            var holes = 0
            for item in items {
                if case .undefined = item { holes += 1 } else { defined.append(item) }
            }
            let sorted = try defined.sorted { a, b in
                let av = f.isEmpty ? a : try resolveField(a, f)
                let bv = f.isEmpty ? b : try resolveField(b, f)
                let cmp = try sortCompare(av, bv)
                return desc ? cmp > 0 : cmp < 0
            }
            return .array(sorted + Array(repeating: .undefined, count: holes))
        case "Filter":
            guard case .array(let items) = arg(0) else { return .array([]) }
            let f = arg(1).isNullish ? "" : try jsToString(arg(1))
            let o = arg(2).isNullish ? "==" : try jsToString(arg(2))
            let value = arg(3)
            let filtered = try items.filter { item in
                let v = f.isEmpty ? item : try resolveField(item, f)
                switch o {
                case "==": return try jsLooseEquals(v, value)
                case "!=": return !(try jsLooseEquals(v, value))
                case ">": return dslToNumber(v) > dslToNumber(value)
                case "<": return dslToNumber(v) < dslToNumber(value)
                case ">=": return dslToNumber(v) >= dslToNumber(value)
                case "<=": return dslToNumber(v) <= dslToNumber(value)
                case "contains":
                    // JS `String.prototype.includes` — UTF-16 code-unit
                    // subsequence, NOT Swift's canonical `contains`.
                    let hay = v.isNullish ? "" : try jsToString(v)
                    let needle = value.isNullish ? "" : try jsToString(value)
                    return jsStringContains(hay, needle)
                default:
                    return false
                }
            }
            return .array(filtered)
        case "Round":
            let num = dslToNumber(arg(0))
            let d = arg(1).isNullish ? 0 : dslToNumber(arg(1))
            let factor = pow(10, d)
            return .number(jsMathRound(num * factor) / factor)
        case "Abs":
            return .number(abs(dslToNumber(arg(0))))
        case "Floor":
            return .number(dslToNumber(arg(0)).rounded(.down))
        case "Ceil":
            return .number(dslToNumber(arg(0)).rounded(.up))
        default:
            return .null
        }
    }

    /// Numeric-aware comparator matching Sort's JS implementation; returns
    /// negative/zero/positive like `localeCompare`.
    private func sortCompare(_ av: RTValue, _ bv: RTValue) throws -> Int {
        func isNumeric(_ v: RTValue) -> Bool {
            if case .number = v { return true }
            if case .string(let s) = v {
                return !jsStringToNumber(s).isNaN && !s.isEmpty
            }
            return false
        }
        if isNumeric(av) && isNumeric(bv) {
            let diff = dslToNumber(av) - dslToNumber(bv)
            if diff < 0 { return -1 }
            if diff > 0 { return 1 }
            return 0
        }
        let a = av.isNullish ? "" : try jsToString(av)
        let b = bv.isNullish ? "" : try jsToString(bv)
        // ASCII — the whole range `@Sort` can reach from a `.oui` corpus
        // without non-Latin text — goes through the shared CLDR-root
        // (`alternate = non-ignorable`) weight table, verified against V8 over
        // 235,233 pairs with zero mismatches and byte-identical to the Kotlin
        // port's twin table. That removes the dependency on whichever ICU
        // version Foundation happens to be linked against (which differs
        // between Linux CI and iOS devices) for the range that matters.
        if let ascii = jsASCIILocaleCompare(a, b) { return ascii }
        // Outside ASCII: Foundation's en_US comparison (KNOWN-DEVIATION #1).
        // Canonical equivalence is NOT a hazard here: `localeCompare` itself
        // normalizes, so NFC/NFD variants compare equal (return 0) in BOTH
        // implementations — unlike `==`, which is code-unit exact in JS.
        let result = a.compare(b, options: [], range: nil, locale: Locale(identifier: "en_US"))
        switch result {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    /// Dot-path field resolution (port of `resolveField`). Splitting happens
    /// over UTF-16 code units like JS `path.split(".")` — Character-based
    /// splitting would let a combining mark glue onto the "." and hide it.
    private func resolveField(_ obj: RTValue, _ path: String) throws -> RTValue {
        if path.isEmpty || obj.isNullish { return .undefined }
        let parts = jsStringSplit(path, separator: ".")
        if parts.count == 1 {
            return try propertyGet(obj, path)
        }
        var cur = obj
        for p in parts {
            if cur.isNullish { return .undefined }
            cur = try propertyGet(cur, p)
        }
        return cur
    }

    private func jsMathMin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        return Swift.min(a, b)
    }
    private func jsMathMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        return Swift.max(a, b)
    }
    /// ECMAScript `Math.round` (ES2025 21.3.2.28) — "the integral Number
    /// closest to x, preferring the Number closer to +∞ in case of a tie".
    ///
    /// NOT `x.rounded()` (half-away-from-zero: disagrees on -0.5, -1.5, …) and
    /// NOT the popular `floor(x + 0.5)` shorthand either. The shorthand is
    /// wrong twice:
    ///
    /// - `x + 0.5` can round UP to the next double before the floor sees it.
    ///   `Math.round(0.49999999999999994)` is `0` in JS, but
    ///   `0.49999999999999994 + 0.5` is exactly `1.0` in binary64, so the
    ///   shorthand answers `1`. `@Round(x, digits)` scales first
    ///   (`round(x * 10^d) / 10^d`), so the same input reappears as
    ///   `@Round(0.049999999999999994, 1)` → JS `0`, shorthand `0.1`.
    /// - it loses the negative zero: JS `Math.round(-0.5)` is `-0`, the
    ///   shorthand gives `+0`.
    ///
    /// The comparison below is exact. A non-integral double always has
    /// |x| < 2^52, so `floor(x) + 0.5` is representable without rounding and
    /// `x >= floor(x) + 0.5` decides the tie by the spec's rule directly —
    /// unlike `x - floor(x) >= 0.5`, where the subtraction itself can round.
    private func jsMathRound(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite { return x }
        let r = x.rounded(.down)
        if r == x { return x } // integral Number (incl. -0.0) returned as-is
        // ES step 4: -0.5 <= x < 0 rounds to -0, not +0.
        if x < 0, x >= -0.5 { return -0.0 }
        return x >= r + 0.5 ? r + 1 : r
    }

    // MARK: - Actions

    private func evaluateActionCall(name: String, args: [ASTNode], context: EvalContext) throws
        -> RTValue
    {
        switch name {
        case "Action":
            let stepsArg: RTValue = args.isEmpty ? .array([]) : try evaluate(args[0], context, nil)
            var rawSteps: [RTValue] = []
            if case .array(let items) = stepsArg { rawSteps = items }
            // `s != null && typeof s === "object" && "type" in s` — the `in`
            // walks the prototype chain. (JS ElementNodes carry `type`.)
            let steps = rawSteps.filter { $0.isObjectLike && JSObjects.hasProperty($0, "type") }
            var plan = RTObject()
            plan["steps"] = .array(steps)
            return .object(plan)
        case "Run":
            guard let first = args.first else { return .null }
            if case .runtimeRef(let n, let refType) = first {
                var o = RTObject()
                o["type"] = .string("run")
                o["statementId"] = .string(n)
                o["refType"] = .string(refType)
                return .object(o)
            }
            return .null
        case "ToAssistant":
            let message = args.isEmpty ? "" : try concatOperand(try evaluate(args[0], context, nil))
            var o = RTObject()
            o["type"] = .string("continue_conversation")
            o["message"] = .string(message)
            if args.count > 1 {
                o["context"] = .string(try concatOperand(try evaluate(args[1], context, nil)))
            }
            return .object(o)
        case "OpenUrl":
            let url = args.isEmpty ? "" : try concatOperand(try evaluate(args[0], context, nil))
            var o = RTObject()
            o["type"] = .string("open_url")
            o["url"] = .string(url)
            return .object(o)
        case "Set":
            guard args.count >= 2 else { return .null }
            guard case .stateRef(let target) = args[0] else { return .null }
            var o = RTObject()
            o["type"] = .string("set")
            o["target"] = .string(target)
            o["valueAST"] = .ast(args[1])
            return .object(o)
        case "Reset":
            var targets: [RTValue] = []
            for a in args {
                if case .stateRef(let n) = a { targets.append(.string(n)) }
            }
            if targets.isEmpty { return .null }
            var o = RTObject()
            o["type"] = .string("reset")
            o["targets"] = .array(targets)
            return .object(o)
        default:
            return .null
        }
    }

    // MARK: - Each

    private func evaluateLazyBuiltin(
        name: String, args: [ASTNode], context: EvalContext, schemaCtx: SchemaCtx?
    ) throws -> RTValue {
        guard name == "Each" else { return .null }
        guard args.count >= 3 else { return .array([]) }
        guard case .array(let arr) = try evaluate(args[0], context, nil) else { return .array([]) }
        let varName: String?
        switch args[1] {
        case .ref(let n): varName = n
        case .str(let v): varName = v
        default: varName = nil
        }
        // evaluator.js:405 guards with `if (!varName)` — FALSY, so an EMPTY
        // iterator name aborts the loop and yields `[]`, it does not iterate
        // (fixture `079-each-empty-iterator-name`).
        guard let varName, !varName.isEmpty else { return .array([]) }
        let template = args[2]
        let results = try arr.map { item -> RTValue in
            let substituted = substituteRef(template, varName: varName, value: toLiteralAST(item))
            let childCtx = EvalContext(
                getState: context.getState,
                resolveRef: { refName in
                    // JS `refName === varName` — code-unit exact (varName can
                    // come from a string literal and be non-ASCII).
                    jsStringEquals(refName, varName) ? item : context.resolveRef(refName)
                }
            )
            let result = try evaluate(substituted, childCtx, schemaCtx)
            // evaluator.js:421 — the element re-evaluation is gated on the
            // schema context, so inside an Action the per-item element keeps
            // whatever raw ASTs site 75 preserved.
            if schemaCtx != nil { return try recurseIfElement(result, inline: true) }
            return result
        }
        return .array(results)
    }

    /// Convert a resolved runtime value back to a literal AST node
    /// (port of `toLiteralAST`).
    private func toLiteralAST(_ value: RTValue) -> ASTNode {
        switch value {
        // `typeof fn === "function"` matches none of toLiteralAST's branches,
        // so it falls through to the trailing `return { k: "Null" }`.
        case .undefined, .null, .function:
            return .null
        case .proto(let kind):
            // Array.prototype is an empty array; every other intrinsic
            // prototype has no ENUMERABLE own properties.
            return kind == .array ? .arr([]) : .obj([])
        case .string(let s):
            return .str(s)
        case .number(let n):
            return .num(n)
        case .bool(let b):
            return .bool(b)
        case .array(let items):
            return .arr(items.map { toLiteralAST($0) })
        case .object(let o):
            return .obj(o.entries.map { (key: $0.key, value: toLiteralAST($0.value)) })
        case .element(let el):
            // JS treats the element as a plain object of its fields.
            var entries: [(key: String, value: ASTNode)] = [
                (key: "type", value: .str("element")),
                (key: "typeName", value: .str(el.typeName)),
                (key: "props", value: .obj(el.props.entries.map { (key: $0.key, value: toLiteralAST($0.value)) })),
                (key: "partial", value: .bool(el.partial)),
                (key: "hasDynamicProps", value: .bool(el.hasDynamicProps)),
            ]
            if let sid = el.statementId {
                entries.append((key: "statementId", value: .str(sid)))
            }
            return .obj(entries)
        case .ast(let node):
            // An AST node is itself a plain object in JS.
            return node
        }
    }

    /// Substitute all Ref(varName) nodes with a literal value
    /// (port of `substituteRef`).
    private func substituteRef(_ node: ASTNode, varName: String, value: ASTNode) -> ASTNode {
        switch node {
        case .ref(let n):
            // JS `node.n === varName` — code-unit exact.
            return jsStringEquals(n, varName) ? value : node
        case .member(let obj, let field):
            let subObj = substituteRef(obj, varName: varName, value: value)
            if case .obj(let entries) = subObj {
                // JS `entries.find(([k]) => k === node.field)` — code-unit
                // exact (object keys and member fields can both be
                // string-literal-derived).
                if let entry = entries.first(where: { jsStringEquals($0.key, field) }) {
                    return entry.value
                }
            }
            return .member(obj: subObj, field: field)
        case .index(let obj, let idx):
            return .index(
                obj: substituteRef(obj, varName: varName, value: value),
                index: substituteRef(idx, varName: varName, value: value))
        case .binOp(let op, let l, let r):
            return .binOp(
                op: op,
                left: substituteRef(l, varName: varName, value: value),
                right: substituteRef(r, varName: varName, value: value))
        case .unaryOp(let op, let operand):
            return .unaryOp(op: op, operand: substituteRef(operand, varName: varName, value: value))
        case .ternary(let c, let t, let e):
            return .ternary(
                cond: substituteRef(c, varName: varName, value: value),
                then: substituteRef(t, varName: varName, value: value),
                elseNode: substituteRef(e, varName: varName, value: value))
        case .arr(let els):
            return .arr(els.map { substituteRef($0, varName: varName, value: value) })
        case .obj(let entries):
            return .obj(entries.map { (key: $0.key, value: substituteRef($0.value, varName: varName, value: value)) })
        case .comp(let name, let args, let mappedProps):
            let subArgs = args.map { substituteRef($0, varName: varName, value: value) }
            let subMapped = mappedProps.map { mapped in
                mapped.map { (key: $0.key, value: substituteRef($0.value, varName: varName, value: value)) }
            }
            return .comp(name: name, args: subArgs, mappedProps: subMapped)
        case .assign(let target, let v):
            return .assign(target: target, value: substituteRef(v, varName: varName, value: value))
        default:
            return node
        }
    }
}
