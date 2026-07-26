package dev.appless.openuilang

/**
 * AST nodes mirroring lang-core `parser/ast.js`
 * (spec/openui-lang.md §5 expression grammar).
 *
 * Object/mappedProps entries are kept as ordered `List<Pair<String, AstNode>>`
 * (not a `Map`) because JS builds them with plain-object assignment: insertion
 * order is observable in `$ast` serialization, and duplicate keys are
 * last-wins **at the point of the first insertion** only for `Obj` literals —
 * which the reference implements by `o[k] = v` on a plain object. See
 * [Materialize] / [Evaluator] where the list is folded into an [RtObject].
 */
internal sealed interface AstNode {
    data class Str(val v: String) : AstNode
    data class Num(val v: Double) : AstNode
    data class Bool(val v: Boolean) : AstNode
    data object Null : AstNode
    data class Arr(val els: List<AstNode>) : AstNode
    data class Obj(val entries: List<Pair<String, AstNode>>) : AstNode
    data class Comp(
        val name: String,
        val args: List<AstNode>,
        val mappedProps: List<Pair<String, AstNode>>? = null,
    ) : AstNode

    data class Ref(val n: String) : AstNode
    data class StateRef(val n: String) : AstNode
    data class RuntimeRef(val n: String, val refType: String) : AstNode
    data class BinOp(val op: String, val left: AstNode, val right: AstNode) : AstNode
    data class UnaryOp(val op: String, val operand: AstNode) : AstNode
    data class Ternary(val cond: AstNode, val then: AstNode, val orElse: AstNode) : AstNode
    data class Member(val obj: AstNode, val field: String) : AstNode
    data class Index(val obj: AstNode, val index: AstNode) : AstNode
    data class Assign(val target: String, val value: AstNode) : AstNode
    data class Ph(val n: String) : AstNode
}

/**
 * The node's `k` discriminant — the own property lang-core's duck-typing reads
 * (`isASTNode`, `evaluate`'s switch, the serializer's `isAstNode`).
 */
internal val AstNode.kindTag: String
    get() = when (this) {
        is AstNode.Str -> "Str"
        is AstNode.Num -> "Num"
        is AstNode.Bool -> "Bool"
        is AstNode.Null -> "Null"
        is AstNode.Arr -> "Arr"
        is AstNode.Obj -> "Obj"
        is AstNode.Comp -> "Comp"
        is AstNode.Ref -> "Ref"
        is AstNode.StateRef -> "StateRef"
        is AstNode.RuntimeRef -> "RuntimeRef"
        is AstNode.BinOp -> "BinOp"
        is AstNode.UnaryOp -> "UnaryOp"
        is AstNode.Ternary -> "Ternary"
        is AstNode.Member -> "Member"
        is AstNode.Index -> "Index"
        is AstNode.Assign -> "Assign"
        is AstNode.Ph -> "Ph"
    }

/** Runtime expression nodes that survive parser lowering (`isRuntimeExpr`). */
internal val AstNode.isRuntimeExpr: Boolean
    get() = when (this) {
        is AstNode.StateRef, is AstNode.RuntimeRef, is AstNode.BinOp, is AstNode.UnaryOp,
        is AstNode.Ternary, is AstNode.Member, is AstNode.Index, is AstNode.Assign,
        -> true

        else -> false
    }

/** Walk an AST tree, visiting every node (port of `walkAST`). */
internal fun walkAst(node: AstNode, visit: (AstNode) -> Unit) {
    visit(node)
    when (node) {
        is AstNode.Comp -> {
            for (a in node.args) walkAst(a, visit)
            node.mappedProps?.forEach { walkAst(it.second, visit) }
        }

        is AstNode.Arr -> node.els.forEach { walkAst(it, visit) }
        is AstNode.Obj -> node.entries.forEach { walkAst(it.second, visit) }
        is AstNode.BinOp -> {
            walkAst(node.left, visit)
            walkAst(node.right, visit)
        }

        is AstNode.UnaryOp -> walkAst(node.operand, visit)
        is AstNode.Ternary -> {
            walkAst(node.cond, visit)
            walkAst(node.then, visit)
            walkAst(node.orElse, visit)
        }

        is AstNode.Member -> walkAst(node.obj, visit)
        is AstNode.Index -> {
            walkAst(node.obj, visit)
            walkAst(node.index, visit)
        }

        is AstNode.Assign -> walkAst(node.value, visit)
        else -> Unit
    }
}

/**
 * Collect all `StateRef` (`$variable`) names referenced within a node,
 * deduplicated preserving first-seen order (port of `collectQueryDeps`).
 *
 * A `LinkedHashSet<String>` is exactly a JS `Set` of strings here: JVM
 * `String.equals`/`hashCode` are UTF-16 code-unit based, so no `JSKey`
 * wrapper (as in the Swift port) is needed.
 */
internal fun collectStateRefs(node: AstNode): List<String> {
    val out = LinkedHashSet<String>()
    walkAst(node) { if (it is AstNode.StateRef) out.add(it.n) }
    return out.toList()
}
