import Foundation

/// Runtime evaluation context — mirrors the EvaluationContext react-lang
/// builds: `getState` reads the initialized store (unwrapping
/// `{value, componentType}` wrappers), `resolveRef` yields undefined.
struct EvalContext {
    let getState: (String) -> RTValue
    let resolveRef: (String) -> RTValue
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

    // MARK: - Element/prop evaluation (evaluate-tree / evaluate-prop)

    func evaluateElementProps(_ el: RTElement) -> RTElement {
        if el.hasDynamicProps == false { return el }
        var out = el
        var props = RTObject()
        for (key, value) in el.props.entries {
            props[key] = evaluatePropValue(value)
        }
        out.props = props
        return out
    }

    private func evaluatePropValue(_ value: RTValue) -> RTValue {
        switch value {
        case .undefined, .null, .bool, .number, .string:
            return value
        case .ast(let node):
            let result = evaluate(node, ctx)
            if case .element(let el) = result {
                return .element(evaluateElementProps(el))
            }
            if case .array(let items) = result {
                return .array(items.map { item in
                    if case .element(let el) = item {
                        return .element(evaluateElementProps(el))
                    }
                    return item
                })
            }
            // Strip ReactiveAssign in a non-reactive context.
            if isReactiveAssign(result), case .object(let o) = result,
                case .string(let target)? = o["target"]
            {
                let v = ctx.getState(target)
                return v.isNullish ? .null : v
            }
            return result
        case .array(let items):
            return .array(items.map { evaluatePropValue($0) })
        case .element(let el):
            return .element(evaluateElementProps(el))
        case .object(let o):
            // KNOWN-DEVIATION (README.md #6): a LITERAL object whose `k` is a
            // real AST kind string ({k: "Str", v: "x"}) is indistinguishable
            // from an AST node in JS and would be evaluated here; the typed
            // port keeps it as plain data.
            // ActionPlan / ActionStep — preserve as-is (deferred evaluation)
            if case .array? = o["steps"] { return value }
            if o.has("type") && o.has("valueAST") { return value }
            let needsEval = o.values.contains { $0.isObjectLike }
            if needsEval {
                var out = RTObject()
                for (k, v) in o.entries {
                    out[k] = evaluatePropValue(v)
                }
                return .object(out)
            }
            return value
        }
    }

    private func isReactiveAssign(_ v: RTValue) -> Bool {
        if case .object(let o) = v, case .string("assign")? = o["__reactive"] {
            return true
        }
        return false
    }

    // MARK: - Core AST evaluation

    func evaluate(_ node: ASTNode, _ context: EvalContext) -> RTValue {
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
            return .array(els.map { evaluate($0, context) })
        case .obj(let entries):
            var o = RTObject()
            for (k, v) in entries { o[k] = evaluate(v, context) }
            return .object(o)
        case .comp(let name, let args, let mappedProps):
            if Builtins.lazyBuiltins.contains(name) {
                return evaluateLazyBuiltin(name: name, args: args, context: context)
            }
            if Builtins.dataBuiltins.contains(name) {
                let evaluated = args.map { evaluate($0, context) }
                return callDataBuiltin(name: name, args: evaluated)
            }
            if Builtins.actionNames.contains(name) {
                return evaluateActionCall(name: name, args: args, context: context)
            }
            if let mapped = mappedProps {
                var props = RTObject()
                for (key, val) in mapped {
                    if case .stateRef(let n) = val {
                        props[key] = context.getState(n)
                    } else {
                        props[key] = evaluate(val, context)
                    }
                }
                var el = RTElement(
                    typeName: name, props: props, partial: false,
                    hasDynamicProps: true, statementId: nil)
                // Recursively evaluate nested ElementNodes in props.
                for (key, v) in el.props.entries {
                    if case .element(let sub) = v {
                        el.props[key] = .element(evaluateElementProps(sub))
                    } else if case .array(let items) = v {
                        el.props[key] = .array(items.map { item in
                            if case .element(let sub) = item {
                                return .element(evaluateElementProps(sub))
                            }
                            return item
                        })
                    }
                }
                return .element(el)
            }
            return .null // unmapped Comp (unknown component in expression)
        case .binOp(let op, let leftNode, let rightNode):
            if op == "&&" {
                let left = evaluate(leftNode, context)
                return jsTruthy(left) ? evaluate(rightNode, context) : left
            }
            if op == "||" {
                let left = evaluate(leftNode, context)
                return jsTruthy(left) ? left : evaluate(rightNode, context)
            }
            let left = evaluate(leftNode, context)
            let right = evaluate(rightNode, context)
            switch op {
            case "+":
                if case .string = left {
                    return .string(concatOperand(left) + concatOperand(right))
                }
                if case .string = right {
                    return .string(concatOperand(left) + concatOperand(right))
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
                return .bool(jsLooseEquals(left, right))
            case "!=":
                return .bool(!jsLooseEquals(left, right))
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
                return .bool(!jsTruthy(evaluate(operandNode, context)))
            }
            if op == "-" {
                return .number(-dslToNumber(evaluate(operandNode, context)))
            }
            return .null
        case .ternary(let condNode, let thenNode, let elseNode):
            let cond = evaluate(condNode, context)
            return jsTruthy(cond) ? evaluate(thenNode, context) : evaluate(elseNode, context)
        case .member(let objNode, let field):
            let obj = evaluate(objNode, context)
            if obj.isNullish { return .null }
            if case .array(let items) = obj {
                if field == "length" { return .number(Double(items.count)) }
                // Array pluck: extract field from every element
                return .array(items.map { item in
                    if item.isNullish { return .null }
                    let v = propertyGet(item, field)
                    return v.isNullish ? .null : v
                })
            }
            return propertyGet(obj, field)
        case .index(let objNode, let indexNode):
            let obj = evaluate(objNode, context)
            let idx = evaluate(indexNode, context)
            if obj.isNullish || idx.isNullish { return .null }
            if case .array(let items) = obj {
                let n = dslToNumber(idx)
                guard n.isFinite, n == n.rounded(.towardZero), n >= 0,
                    n < Double(items.count)
                else { return .undefined }
                return items[Int(n)]
            }
            return propertyGet(obj, jsToString(idx))
        case .assign(let target, let value):
            var o = RTObject()
            o["__reactive"] = .string("assign")
            o["target"] = .string(target)
            o["expr"] = .ast(value)
            return .object(o)
        }
    }

    /// `String(x ?? "")` used by string concatenation and action strings.
    private func concatOperand(_ v: RTValue) -> String {
        v.isNullish ? "" : jsToString(v)
    }

    /// JS `obj[key]` property access for non-array receivers.
    ///
    /// KNOWN-DEVIATION (README.md #5): `.element` receivers fall into the
    /// `default` branch and yield `undefined`, whereas in JS an ElementNode is
    /// a plain object whose fields (`typeName`, `props`, `partial`,
    /// `hasDynamicProps`, `type`, `statementId`) are readable from
    /// expressions. Observable only for programs that member-access an
    /// element value.
    private func propertyGet(_ obj: RTValue, _ key: String) -> RTValue {
        switch obj {
        case .object(let o):
            return o[key] ?? .undefined
        case .array(let items):
            if key == "length" { return .number(Double(items.count)) }
            if let i = Int(key), i >= 0, i < items.count, String(i) == key {
                return items[i]
            }
            return .undefined
        case .string(let s):
            let units = Array(s.utf16)
            if key == "length" { return .number(Double(units.count)) }
            if let i = Int(key), i >= 0, i < units.count, String(i) == key {
                return .string(String(utf16CodeUnits: [units[i]], count: 1))
            }
            return .undefined
        default:
            return .undefined
        }
    }

    // MARK: - Data builtins

    private func callDataBuiltin(name: String, args: [RTValue]) -> RTValue {
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
            let f = arg(1).isNullish ? "" : jsToString(arg(1))
            let desc = (arg(2).isNullish ? "asc" : jsToString(arg(2))) == "desc"
            let sorted = items.sorted { a, b in
                let av = f.isEmpty ? a : resolveField(a, f)
                let bv = f.isEmpty ? b : resolveField(b, f)
                let cmp = sortCompare(av, bv)
                return desc ? cmp > 0 : cmp < 0
            }
            return .array(sorted)
        case "Filter":
            guard case .array(let items) = arg(0) else { return .array([]) }
            let f = arg(1).isNullish ? "" : jsToString(arg(1))
            let o = arg(2).isNullish ? "==" : jsToString(arg(2))
            let value = arg(3)
            let filtered = items.filter { item in
                let v = f.isEmpty ? item : resolveField(item, f)
                switch o {
                case "==": return jsLooseEquals(v, value)
                case "!=": return !jsLooseEquals(v, value)
                case ">": return dslToNumber(v) > dslToNumber(value)
                case "<": return dslToNumber(v) < dslToNumber(value)
                case ">=": return dslToNumber(v) >= dslToNumber(value)
                case "<=": return dslToNumber(v) <= dslToNumber(value)
                case "contains":
                    let hay = v.isNullish ? "" : jsToString(v)
                    let needle = value.isNullish ? "" : jsToString(value)
                    return needle.isEmpty || hay.contains(needle)
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
    private func sortCompare(_ av: RTValue, _ bv: RTValue) -> Int {
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
        let a = av.isNullish ? "" : jsToString(av)
        let b = bv.isNullish ? "" : jsToString(bv)
        // KNOWN-DEVIATION (README.md #1): approximates JS `localeCompare`
        // (V8 ICU collation) with Foundation's en_US comparison; agrees for
        // ASCII, may differ for locale-sensitive orderings.
        let result = a.compare(b, options: [], range: nil, locale: Locale(identifier: "en_US"))
        switch result {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    /// Dot-path field resolution (port of `resolveField`).
    private func resolveField(_ obj: RTValue, _ path: String) -> RTValue {
        if path.isEmpty || obj.isNullish { return .undefined }
        if !path.contains(".") {
            return propertyGet(obj, path)
        }
        var cur = obj
        for p in path.split(separator: ".", omittingEmptySubsequences: false) {
            if cur.isNullish { return .undefined }
            cur = propertyGet(cur, String(p))
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
    private func jsMathRound(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite { return x }
        return (x + 0.5).rounded(.down)
    }

    // MARK: - Actions

    private func evaluateActionCall(name: String, args: [ASTNode], context: EvalContext) -> RTValue {
        switch name {
        case "Action":
            let stepsArg: RTValue = args.isEmpty ? .array([]) : evaluate(args[0], context)
            var rawSteps: [RTValue] = []
            if case .array(let items) = stepsArg { rawSteps = items }
            let steps = rawSteps.filter { s in
                switch s {
                case .object(let o): return o.has("type")
                case .element: return true // JS elements carry a `type` field
                default: return false
                }
            }
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
            let message = args.isEmpty ? "" : concatOperand(evaluate(args[0], context))
            var o = RTObject()
            o["type"] = .string("continue_conversation")
            o["message"] = .string(message)
            if args.count > 1 {
                o["context"] = .string(concatOperand(evaluate(args[1], context)))
            }
            return .object(o)
        case "OpenUrl":
            let url = args.isEmpty ? "" : concatOperand(evaluate(args[0], context))
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

    private func evaluateLazyBuiltin(name: String, args: [ASTNode], context: EvalContext) -> RTValue {
        guard name == "Each" else { return .null }
        guard args.count >= 3 else { return .array([]) }
        guard case .array(let arr) = evaluate(args[0], context) else { return .array([]) }
        let varName: String?
        switch args[1] {
        case .ref(let n): varName = n
        case .str(let v): varName = v
        default: varName = nil
        }
        guard let varName else { return .array([]) }
        let template = args[2]
        let results = arr.map { item -> RTValue in
            let substituted = substituteRef(template, varName: varName, value: toLiteralAST(item))
            let childCtx = EvalContext(
                getState: context.getState,
                resolveRef: { refName in
                    refName == varName ? item : context.resolveRef(refName)
                }
            )
            let result = evaluate(substituted, childCtx)
            if case .element(let el) = result {
                return .element(evaluateElementProps(el))
            }
            return result
        }
        return .array(results)
    }

    /// Convert a resolved runtime value back to a literal AST node
    /// (port of `toLiteralAST`).
    private func toLiteralAST(_ value: RTValue) -> ASTNode {
        switch value {
        case .undefined, .null:
            return .null
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
            return n == varName ? value : node
        case .member(let obj, let field):
            let subObj = substituteRef(obj, varName: varName, value: value)
            if case .obj(let entries) = subObj {
                if let entry = entries.first(where: { $0.key == field }) {
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
