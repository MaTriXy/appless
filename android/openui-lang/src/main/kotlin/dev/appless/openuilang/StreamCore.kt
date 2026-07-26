package dev.appless.openuilang

/**
 * Insertion-ordered map used for statement caches and state declarations.
 * `set` on an existing key overwrites the value but keeps the original key
 * position — JS `Map.set` semantics, which `LinkedHashMap` already provides
 * (and its `String` keys are UTF-16 code-unit identified, like JS `Map`).
 */
internal class OrderedMap<V> {
    private val map = LinkedHashMap<String, V>()

    constructor()

    constructor(other: OrderedMap<V>) {
        map.putAll(other.map)
    }

    val keys: List<String> get() = map.keys.toList()
    val values: List<V> get() = map.values.toList()
    val size: Int get() = map.size

    operator fun get(key: String): V? = map[key]

    operator fun set(key: String, value: V) {
        map[key] = value
    }

    fun has(key: String): Boolean = map.containsKey(key)
}

/**
 * The pre-runtime-evaluation parse result (lang-core `ParseResult` minus the
 * query/mutation statement lists, which are always empty for AppLess).
 */
internal class InternalResult(
    /**
     * `parser.js`: `const root = isElementNode(materialized) ? materialized :
     * null` — a duck-type test, not a type check, so the entry statement may
     * be any object that ANSWERS the test. Kept as a raw [RtValue] for that
     * reason; [JsObjects.runtimeElementRef] reads its fields.
     */
    val root: RtValue? = null,
    val incomplete: Boolean = true,
    val unresolved: List<String> = emptyList(),
    val errors: List<ParseError> = emptyList(),
    val stateDeclarations: OrderedMap<RtValue> = OrderedMap(),
) {
    companion object {
        fun empty(incomplete: Boolean = true): InternalResult =
            InternalResult(incomplete = incomplete)
    }
}

private const val DEFAULT_ROOT_STATEMENT_ID = "root"

/** "Component statement" excludes builtins and Query/Mutation (spec §8.1). */
internal fun isComponentStatement(stmt: TypedStatement): Boolean {
    if (stmt.kind != StatementKind.VALUE) return false
    val expr = stmt.expr
    return expr is AstNode.Comp &&
        !Builtins.isBuiltin(expr.name) &&
        !Builtins.isReservedCall(expr.name)
}

/** Entry selection, spec §8.1 (five tiers). Port of `pickEntryId`. */
internal fun pickEntryId(
    stmtMap: OrderedMap<TypedStatement>,
    typedStmts: List<TypedStatement>,
    firstId: String,
    rootName: String?,
): String {
    if (stmtMap.has(DEFAULT_ROOT_STATEMENT_ID)) return DEFAULT_ROOT_STATEMENT_ID
    if (rootName != null && stmtMap.has(rootName)) return rootName
    if (rootName != null) {
        val preferred = typedStmts.firstOrNull { stmt ->
            isComponentStatement(stmt) && (stmt.expr as AstNode.Comp).name == rootName
        }
        if (preferred != null) return preferred.id
    }
    val firstComponent = typedStmts.firstOrNull { isComponentStatement(it) }
    return firstComponent?.id ?: firstId
}

/**
 * Port of `extractStatements`: materialize state defaults, then auto-declare
 * every referenced-but-undeclared `$var` with `null` (spec §9.5).
 */
private fun extractStatements(
    stmts: List<TypedStatement>,
    ctx: MaterializeContext,
): OrderedMap<RtValue> {
    val stateDeclarations = OrderedMap<RtValue>()
    for (stmt in stmts) {
        if (stmt.kind == StatementKind.STATE) {
            stateDeclarations[stmt.id] = materializeValue(stmt.expr, ctx)
        }
    }
    for (stmt in stmts) {
        val nodes: List<AstNode> = when (stmt.kind) {
            StatementKind.STATE, StatementKind.VALUE -> listOf(stmt.expr)
            StatementKind.QUERY, StatementKind.MUTATION ->
                (stmt.expr as? AstNode.Comp)?.args ?: emptyList()
        }
        for (node in nodes) {
            for (dep in collectStateRefs(node)) {
                if (!stateDeclarations.has(dep)) stateDeclarations[dep] = RtValue.Null
            }
        }
    }
    return stateDeclarations
}

/** Port of `buildResult` (spec §8 resolution & materialization). */
internal fun buildResult(
    stmtMap: OrderedMap<TypedStatement>,
    typedStmts: List<TypedStatement>,
    firstId: String,
    wasIncomplete: Boolean,
    cat: Map<String, List<LibrarySchema.Param>>,
    rootName: String?,
): InternalResult {
    val entryId = pickEntryId(stmtMap, typedStmts, firstId, rootName)
    if (!stmtMap.has(entryId)) return InternalResult.empty(wasIncomplete)

    val syms = LinkedHashMap<String, AstNode>()
    for (id in stmtMap.keys) syms[id] = stmtMap[id]!!.expr

    val ctx = MaterializeContext(
        syms = syms,
        cat = cat,
        partial = wasIncomplete,
        currentStatementId = entryId,
    )
    val materialized = materializeValue(syms.getValue(entryId), ctx)
    // `const root = isElementNode(materialized) ? materialized : null;`
    // `if (root) root.statementId = entryId;` — a chain-aware duck-type test
    // followed by an ordinary ASSIGNMENT, so an object that only INHERITS its
    // element identity is a valid root and gets an OWN `statementId` key
    // (fixture `094-duck-element-root`). A non-element entry gives `null`
    // (spec §8.1, fixture `015-root-non-element`).
    val root: RtValue? = JsObjects.runtimeElementRef(materialized)?.let { ref ->
        if (ref.element != null) {
            RtValue.Element(ref.element.withStatementId(entryId))
        } else {
            (materialized as RtValue.Obj).obj.assign("statementId", RtValue.Str(entryId))
            materialized
        }
    }
    val stateDeclarations = extractStatements(typedStmts, ctx)
    return InternalResult(
        root = root,
        incomplete = wasIncomplete,
        unresolved = ctx.unres,
        errors = ctx.errors,
        stateDeclarations = stateDeclarations,
    )
}

/**
 * Port of lang-core `createStreamParser` — the incremental statement scanner
 * with prefix-extension caching (spec/openui-lang.md §10). This is the single
 * parsing entry point; the batch parser is `set(fullText)` on a fresh
 * instance, matching how the fixture generator drives the reference
 * implementation.
 *
 * Scans the accumulated buffer by `Char` (= UTF-16 code unit), exactly like
 * the JS reference indexes `buf[i]`: the `\n` of a CRLF pair is its own unit
 * (fixture 073) and a combining mark after `"`/`)` cannot hide the delimiter
 * (fixture 074).
 */
internal class StreamCore(schema: LibrarySchema) {
    private val cat = schema.paramOrder
    private val rootName: String? = schema.root

    private var buf = StringBuilder()
    private var completedEnd = 0
    private var completedStmtMap = OrderedMap<TypedStatement>()
    private var completedCount = 0
    private var firstId = ""

    /**
     * `set(fullText)`: when the text is shorter than the buffer or is not a
     * prefix-extension of it, the parser resets completely and reparses from
     * scratch (spec §10.2).
     */
    fun set(fullText: String): InternalResult {
        if (!bufferIsPrefixOf(fullText)) reset()
        if (fullText.length > buf.length) {
            buf.append(fullText, buf.length, fullText.length)
        }
        return currentResult()
    }

    /**
     * `fullText.startsWith(buf)` — the §10.2 prefix-extension test — WITHOUT
     * materializing the buffer.
     *
     * `buf.toString()` copies the entire accumulated program on every flush,
     * and the Renderer calls [set] once per streamed token, so that is a
     * quadratic amount of copying over a response purely to answer a question
     * that a code-unit walk answers in place (and usually bails out of on the
     * first mismatch). Semantics are unchanged: `String.startsWith` on the JVM
     * is a UTF-16 code-unit prefix test, which is exactly this loop, and a
     * shorter text still fails the length guard as before.
     */
    private fun bufferIsPrefixOf(fullText: String): Boolean {
        val n = buf.length
        if (fullText.length < n) return false
        for (i in 0 until n) {
            if (fullText[i] != buf[i]) return false
        }
        return true
    }

    private fun reset() {
        buf = StringBuilder()
        completedEnd = 0
        completedStmtMap = OrderedMap()
        completedCount = 0
        firstId = ""
    }

    private fun addStmt(text: String) {
        val cleaned = stripComments(text).jsTrim()
        if (cleaned.isEmpty() || cleaned.startsWith("```")) return
        for (s in splitStatements(tokenize(cleaned))) {
            val expr = parseExpression(s.tokens)
            completedStmtMap[s.id] = classifyStatement(s, expr)
            completedCount++
            if (firstId.isEmpty()) firstId = s.id
        }
    }

    /**
     * Scan `buf` from the watermark for newly completed statements; returns
     * the start index of the current pending (incomplete) statement.
     *
     * Quote-aware but deliberately NOT comment-aware — the §10.3 apostrophe
     * glue hazard is a must-reproduce quirk (comment stripping happens per
     * statement, AFTER this scan).
     */
    private fun scanNewCompleted(): Int {
        var depth = 0
        var ternaryDepth = 0
        var inStr: Char? = null
        var esc = false
        var stmtStart = completedEnd
        var i = completedEnd
        val n = buf.length
        while (i < n) {
            val c = buf[i]
            if (esc) { esc = false; i++; continue }
            if (c == '\\' && inStr != null) { esc = true; i++; continue }
            if (inStr != null) {
                if (c == inStr) inStr = null
                i++
                continue
            }
            if (c == '"' || c == '\'') { inStr = c; i++; continue }
            if (c == '(' || c == '[' || c == '{') {
                depth++
            } else if (c == ')' || c == ']' || c == '}') {
                depth = maxOf(0, depth - 1)
            } else if (c == '?' && depth == 0) {
                ternaryDepth++
            } else if (c == ':' && depth == 0 && ternaryDepth > 0) {
                ternaryDepth--
            } else if (c == '\n' && depth <= 0 && ternaryDepth <= 0) {
                var peek = i + 1
                while (peek < n &&
                    (buf[peek] == ' ' || buf[peek] == '\t' || buf[peek] == '\r' || buf[peek] == '\n')
                ) {
                    peek++
                }
                if (peek < n && (buf[peek] == '?' || (buf[peek] == ':' && ternaryDepth > 0))) {
                    i++
                    continue // ternary continuation — don't split
                }
                val t = buf.substring(stmtStart, i).jsTrim()
                if (t.isNotEmpty()) addStmt(t)
                stmtStart = i + 1
                completedEnd = i + 1
            }
            i++
        }
        return stmtStart
    }

    fun currentResult(): InternalResult {
        val pendingStart = scanNewCompleted()
        val pendingText = buf.substring(minOf(pendingStart, buf.length)).jsTrim()

        fun completedOnly(incomplete: Boolean): InternalResult {
            if (completedCount == 0) return InternalResult.empty()
            return buildResult(
                completedStmtMap, completedStmtMap.values, firstId, incomplete, cat, rootName
            )
        }

        if (pendingText.isEmpty()) return completedOnly(false)

        val cleaned = stripComments(stripFences(pendingText)).jsTrim()
        if (cleaned.isEmpty()) return completedOnly(false)

        val closed = autoClose(cleaned)
        val stmts = splitStatements(tokenize(closed.text))
        if (stmts.isEmpty()) {
            if (completedCount == 0) return InternalResult.empty(closed.wasIncomplete)
            return buildResult(
                completedStmtMap, completedStmtMap.values, firstId, closed.wasIncomplete,
                cat, rootName,
            )
        }

        // Merge: completed cache + re-parsed pending statements. A pending
        // statement whose id already exists in the completed cache is IGNORED
        // (spec §10.1 step 3 / §10.6).
        val allStmtMap = OrderedMap(completedStmtMap)
        for (s in stmts) {
            if (completedStmtMap.has(s.id)) continue
            allStmtMap[s.id] = classifyStatement(s, parseExpression(s.tokens))
        }
        val fid = firstId.ifEmpty { stmts[0].id }
        return buildResult(
            allStmtMap, allStmtMap.values, fid, closed.wasIncomplete, cat, rootName
        )
    }
}
