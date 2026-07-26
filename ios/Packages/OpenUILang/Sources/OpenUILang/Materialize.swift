import Foundation

/// Statement classification (lang-core `classifyStatement`;
/// spec/openui-lang.md §2.1 statement classification).
enum StatementKind {
    case value
    case state
    case query
    case mutation
}

struct TypedStatement {
    let kind: StatementKind
    let id: String
    /// For state statements this is the initializer; for query/mutation the
    /// full `Comp` call; otherwise the value expression.
    let expr: ASTNode
}

func classifyStatement(_ raw: RawStatement, _ expr: ASTNode) -> TypedStatement {
    if case .comp(let name, _, _) = expr {
        if name == "Query" { return TypedStatement(kind: .query, id: raw.id, expr: expr) }
        if name == "Mutation" { return TypedStatement(kind: .mutation, id: raw.id, expr: expr) }
    }
    if raw.idTokenType == .stateVar {
        return TypedStatement(kind: .state, id: raw.id, expr: expr)
    }
    return TypedStatement(kind: .value, id: raw.id, expr: expr)
}

/// Mutable context threaded through materialization (lang-core `Ctx`).
final class MaterializeContext {
    let syms: [String: ASTNode]
    let cat: [String: [LibrarySchema.Param]]
    var errors: [ParseError] = []
    var unres: [String] = []
    var visited: Set<String> = []
    let partial: Bool
    var currentStatementId: String

    init(
        syms: [String: ASTNode],
        cat: [String: [LibrarySchema.Param]],
        partial: Bool,
        currentStatementId: String
    ) {
        self.syms = syms
        self.cat = cat
        self.partial = partial
        self.currentStatementId = currentStatementId
    }
}

private func reservedRefType(_ name: String) -> String {
    name == "Mutation" ? "mutation" : "query"
}

/// Resolve a Ref in value mode. Port of `resolveRef` (mode "value";
/// spec/openui-lang.md §8 reference resolution).
private func resolveRefValue(_ name: String, _ ctx: MaterializeContext) -> RTValue {
    if ctx.visited.contains(name) {
        ctx.unres.append(name)
        return .null
    }
    guard let target = ctx.syms[name] else {
        ctx.unres.append(name)
        return .null
    }
    if case .comp(let compName, _, _) = target, Builtins.isReservedCall(compName) {
        return .ast(.runtimeRef(name: name, refType: reservedRefType(compName)))
    }
    ctx.visited.insert(name)
    let prev = ctx.currentStatementId
    ctx.currentStatementId = name
    defer {
        ctx.currentStatementId = prev
        ctx.visited.remove(name)
    }
    var result = materializeValue(target, ctx)
    if case .element(var el) = result {
        el.statementId = name
        result = .element(el)
    }
    return result
}

/// Resolve a Ref in expression mode.
private func resolveRefExpr(_ name: String, _ ctx: MaterializeContext) -> ASTNode {
    if ctx.visited.contains(name) {
        ctx.unres.append(name)
        return .ph(name)
    }
    guard let target = ctx.syms[name] else {
        ctx.unres.append(name)
        return .ph(name)
    }
    if case .comp(let compName, _, _) = target, Builtins.isReservedCall(compName) {
        return .runtimeRef(name: name, refType: reservedRefType(compName))
    }
    ctx.visited.insert(name)
    let prev = ctx.currentStatementId
    ctx.currentStatementId = name
    defer {
        ctx.currentStatementId = prev
        ctx.visited.remove(name)
    }
    return materializeExpr(target, ctx)
}

/// If node is a lazy builtin like Each(arr, varName, template), scope the
/// iterator variable during materialization. Returns nil if not applicable.
private func materializeLazyBuiltin(
    name: String, args: [ASTNode], ctx: MaterializeContext, scopedRefs: Set<JSKey>
) -> ASTNode? {
    guard Builtins.lazyBuiltins.contains(name), args.count >= 3 else { return nil }
    let varName: String?
    switch args[1] {
    case .ref(let n): varName = n
    case .str(let v): varName = v
    default: varName = nil
    }
    // materialize.js guards with `if (!varName)` — FALSY, not null. An empty
    // string iterator name (`@Each(items, "", …)`) therefore aborts the lazy
    // path here too, so the template's refs resolve as ordinary refs and land
    // in `unresolved` (fixture `079-each-empty-iterator-name`).
    guard let varName, !varName.isEmpty else { return nil }
    var nextScoped = scopedRefs
    // JSKey: the iterator name can come from a string literal (non-ASCII);
    // JS `Set` membership is code-unit exact.
    nextScoped.insert(JSKey(varName))
    let recursed = args.enumerated().map { (i, a) in
        i == 1 ? a : materializeExprInternal(a, ctx, nextScoped)
    }
    return .comp(name: name, args: recursed, mappedProps: nil)
}

private func materializeExprInternal(
    _ node: ASTNode, _ ctx: MaterializeContext, _ scopedRefs: Set<JSKey>
) -> ASTNode {
    switch node {
    case .ref(let n):
        return scopedRefs.contains(JSKey(n)) ? node : resolveRefExpr(n, ctx)
    case .ph:
        return node
    case .comp(let name, let args, _):
        if let lazy = materializeLazyBuiltin(name: name, args: args, ctx: ctx, scopedRefs: scopedRefs) {
            return lazy
        }
        let recursedArgs = args.map { materializeExprInternal($0, ctx, scopedRefs) }
        if Builtins.isBuiltin(name) || Builtins.isReservedCall(name) {
            return .comp(name: name, args: recursedArgs, mappedProps: nil)
        }
        if let def = ctx.cat[name] {
            var mapped: [(key: String, value: ASTNode)] = []
            var i = 0
            while i < def.count && i < recursedArgs.count {
                mapped.append((key: def[i].name, value: recursedArgs[i]))
                i += 1
            }
            return .comp(name: name, args: recursedArgs, mappedProps: mapped)
        }
        ctx.errors.append(
            ParseError(
                code: .unknownComponent,
                component: name,
                path: "",
                message: "Unknown component \"\(name)\" — not found in catalog or builtins",
                statementId: ctx.currentStatementId
            ))
        return .comp(name: name, args: recursedArgs, mappedProps: nil)
    case .arr(let els):
        return .arr(els.map { materializeExprInternal($0, ctx, scopedRefs) })
    case .obj(let entries):
        return .obj(entries.map { (key: $0.key, value: materializeExprInternal($0.value, ctx, scopedRefs)) })
    case .binOp(let op, let l, let r):
        return .binOp(
            op: op,
            left: materializeExprInternal(l, ctx, scopedRefs),
            right: materializeExprInternal(r, ctx, scopedRefs))
    case .unaryOp(let op, let operand):
        return .unaryOp(op: op, operand: materializeExprInternal(operand, ctx, scopedRefs))
    case .ternary(let c, let t, let e):
        return .ternary(
            cond: materializeExprInternal(c, ctx, scopedRefs),
            then: materializeExprInternal(t, ctx, scopedRefs),
            elseNode: materializeExprInternal(e, ctx, scopedRefs))
    case .member(let obj, let field):
        return .member(obj: materializeExprInternal(obj, ctx, scopedRefs), field: field)
    case .index(let obj, let idx):
        return .index(
            obj: materializeExprInternal(obj, ctx, scopedRefs),
            index: materializeExprInternal(idx, ctx, scopedRefs))
    case .assign(let target, let value):
        return .assign(target: target, value: materializeExprInternal(value, ctx, scopedRefs))
    default:
        // Literals, StateRef, RuntimeRef — pass through unchanged
        return node
    }
}

func materializeExpr(_ node: ASTNode, _ ctx: MaterializeContext) -> ASTNode {
    materializeExprInternal(node, ctx, [])
}

/// Recursively check if a value contains any AST nodes needing runtime
/// evaluation (port of `containsDynamicValue`).
func containsDynamicValue(_ v: RTValue) -> Bool {
    switch v {
    case .ast:
        return true
    case .array(let items):
        return items.contains(where: containsDynamicValue)
    case .element(let el):
        return el.props.values.contains(where: containsDynamicValue)
    case .object(let o):
        return o.values.contains(where: containsDynamicValue)
    default:
        return false
    }
}

/// Schema-aware materialization (port of `materializeValue`;
/// spec/openui-lang.md §8 reference resolution & materialization, §8.2).
func materializeValue(_ node: ASTNode, _ ctx: MaterializeContext) -> RTValue {
    switch node {
    case .ref(let n):
        return resolveRefValue(n, ctx)
    case .str(let v):
        return .string(v)
    case .num(let v):
        return .number(v)
    case .bool(let v):
        return .bool(v)
    case .null:
        return .null
    case .ph:
        return .null
    case .arr(let els):
        var items: [RTValue] = []
        for e in els {
            if case .ph = e { continue } // drop unresolved placeholders
            let value = materializeValue(e, ctx)
            // Drop null entries from component/ref resolution
            if case .null = value {
                if case .comp = e { continue }
                if case .ref = e { continue }
            }
            items.append(value)
        }
        return .array(items)
    case .obj(let entries):
        // materialize.js builds this with `o[k] = …` — plain ASSIGNMENT, so a
        // `"__proto__"` key hits Object.prototype's setter and is swallowed.
        // (evaluator.js's Obj case uses Object.fromEntries and DOES keep it.)
        var o = RTObject()
        for (k, v) in entries {
            o.assign(k, materializeValue(v, ctx))
        }
        return .object(o)
    case .comp(let name, let args, _):
        // Builtins → preserve as AST for runtime
        if Builtins.isBuiltin(name) {
            if let lazy = materializeLazyBuiltin(name: name, args: args, ctx: ctx, scopedRefs: []) {
                return .ast(lazy)
            }
            return .ast(.comp(name: name, args: args.map { materializeExpr($0, ctx) }, mappedProps: nil))
        }
        // Inline Query/Mutation → validation error
        if Builtins.isReservedCall(name) {
            ctx.errors.append(
                ParseError(
                    code: .inlineReserved,
                    component: name,
                    path: "",
                    message: "\(name)() must be declared as a top-level statement, not used inline as a value",
                    statementId: ctx.currentStatementId
                ))
            return .null
        }
        guard let def = ctx.cat[name] else {
            ctx.errors.append(
                ParseError(
                    code: .unknownComponent,
                    component: name,
                    path: "",
                    message: "Unknown component \"\(name)\" — not found in catalog or builtins",
                    statementId: ctx.currentStatementId
                ))
            return .null
        }
        var props = RTObject()
        var i = 0
        while i < def.count && i < args.count {
            props[def[i].name] = materializeValue(args[i], ctx)
            i += 1
        }
        // Validate required props — apply a schema `default` first before
        // reporting (materialize.js: `props[p.name] = p.defaultValue`). The
        // current GenOS contract declares no defaults, but Phase 2+ schemas
        // may.
        let missingRequired = def.filter { p in
            guard p.required else { return false }
            guard let v = props[p.name] else { return true }
            if case .null = v { return true }
            return false
        }
        if !missingRequired.isEmpty {
            let stillInvalid = missingRequired.filter { p in
                if let defaultValue = p.defaultValue {
                    props[p.name] = jsonToRTValue(defaultValue)
                    return false
                }
                return true
            }
            if !stillInvalid.isEmpty {
                for p in stillInvalid {
                    let isNull = props.has(p.name)
                    ctx.errors.append(
                        ParseError(
                            code: isNull ? .nullRequired : .missingRequired,
                            component: name,
                            path: "/\(p.name)",
                            message: isNull
                                ? "required field \"\(p.name)\" cannot be null"
                                : "missing required field \"\(p.name)\"",
                            statementId: ctx.currentStatementId
                        ))
                }
                return .null
            }
        }
        let hasDynamic = props.values.contains(where: containsDynamicValue)
        return .element(
            RTElement(
                typeName: name,
                props: props,
                partial: ctx.partial,
                hasDynamicProps: hasDynamic,
                statementId: nil
            ))
    default:
        if node.isRuntimeExpr {
            return .ast(materializeExpr(node, ctx))
        }
        return .ast(node) // defensive — unreachable for well-formed AST
    }
}
