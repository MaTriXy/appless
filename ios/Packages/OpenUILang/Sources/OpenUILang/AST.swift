import Foundation

/// AST nodes mirroring lang-core `parser/ast.js`
/// (spec/openui-lang.md §5 expression grammar).
/// No `Equatable` conformance on purpose: the runtime never compares AST
/// nodes, and a synthesized/handwritten `==` would only invite accidental
/// (and previously misleading) use.
indirect enum ASTNode {
    case str(String)
    case num(Double)
    case bool(Bool)
    case null
    case arr([ASTNode])
    case obj([(key: String, value: ASTNode)])
    case comp(name: String, args: [ASTNode], mappedProps: [(key: String, value: ASTNode)]?)
    case ref(String)
    case stateRef(String)
    case runtimeRef(name: String, refType: String)
    case binOp(op: String, left: ASTNode, right: ASTNode)
    case unaryOp(op: String, operand: ASTNode)
    case ternary(cond: ASTNode, then: ASTNode, elseNode: ASTNode)
    case member(obj: ASTNode, field: String)
    case index(obj: ASTNode, index: ASTNode)
    case assign(target: String, value: ASTNode)
    case ph(String)

    /// Runtime expression nodes that survive parser lowering.
    var isRuntimeExpr: Bool {
        switch self {
        case .stateRef, .runtimeRef, .binOp, .unaryOp, .ternary, .member, .index, .assign:
            return true
        default:
            return false
        }
    }
}

/// Walk an AST tree, visiting every node (port of `walkAST`).
func walkAST(_ node: ASTNode, _ visit: (ASTNode) -> Void) {
    visit(node)
    switch node {
    case .comp(_, let args, let mappedProps):
        for a in args { walkAST(a, visit) }
        if let mapped = mappedProps {
            for (_, v) in mapped { walkAST(v, visit) }
        }
    case .arr(let els):
        for e in els { walkAST(e, visit) }
    case .obj(let entries):
        for (_, v) in entries { walkAST(v, visit) }
    case .binOp(_, let l, let r):
        walkAST(l, visit)
        walkAST(r, visit)
    case .unaryOp(_, let operand):
        walkAST(operand, visit)
    case .ternary(let c, let t, let e):
        walkAST(c, visit)
        walkAST(t, visit)
        walkAST(e, visit)
    case .member(let obj, _):
        walkAST(obj, visit)
    case .index(let obj, let idx):
        walkAST(obj, visit)
        walkAST(idx, visit)
    case .assign(_, let value):
        walkAST(value, visit)
    default:
        break
    }
}

/// Collect all StateRef ($variable) names referenced within a node,
/// deduplicated preserving first-seen order (port of `collectQueryDeps`).
func collectStateRefs(_ node: ASTNode) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    walkAST(node) { current in
        if case .stateRef(let n) = current, !seen.contains(n) {
            seen.insert(n)
            out.append(n)
        }
    }
    return out
}
