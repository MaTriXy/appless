package dev.appless.openuilang

/** A raw statement produced by the token splitter. */
internal class RawStatement(
    val id: String,
    val idTokenType: TokType,
    val tokens: List<Token>,
)

/** Result of [autoClose]. */
internal class AutoCloseResult(val text: String, val wasIncomplete: Boolean)

/**
 * Auto-close unclosed strings and brackets so partial/streaming input parses
 * without syntax errors. Port of `statements.js` `autoClose`
 * (spec/openui-lang.md §7 auto-closing).
 *
 * Stray closers that do not match the top of the stack are ignored (not
 * popped). A trailing lone `\` inside an open string gets a second `\` first
 * so the escape stays valid.
 */
internal fun autoClose(input: String): AutoCloseResult {
    val stack = ArrayList<Char>()
    var inStr: Char? = null
    var esc = false
    for (c in input) {
        if (esc) { esc = false; continue }
        if (c == '\\' && inStr != null) { esc = true; continue }
        if (inStr != null) {
            if (c == inStr) inStr = null
            continue
        }
        if (c == '"' || c == '\'') { inStr = c; continue }
        when {
            c == '(' || c == '[' || c == '{' -> stack.add(c)
            c == ')' && stack.lastOrNull() == '(' -> stack.removeAt(stack.size - 1)
            c == ']' && stack.lastOrNull() == '[' -> stack.removeAt(stack.size - 1)
            c == '}' && stack.lastOrNull() == '{' -> stack.removeAt(stack.size - 1)
        }
    }
    val wasIncomplete = inStr != null || stack.isNotEmpty()
    if (!wasIncomplete) return AutoCloseResult(input, false)

    val out = StringBuilder(input)
    if (inStr != null) {
        if (esc) out.append('\\')
        out.append(inStr)
    }
    for (j in stack.indices.reversed()) {
        out.append(if (stack[j] == '(') ')' else if (stack[j] == '[') ']' else '}')
    }
    return AutoCloseResult(out.toString(), true)
}

/**
 * Split the flat token stream into individual statements. Port of
 * `statements.js` `split` (spec/openui-lang.md §6 statement splitting,
 * §2 program structure, §5.2 multi-line ternaries).
 */
internal fun splitStatements(tokens: List<Token>): List<RawStatement> {
    val stmts = ArrayList<RawStatement>()
    var pos = 0
    val count = tokens.size

    fun skipLine() {
        while (pos < count && tokens[pos].t != TokType.NEWLINE && tokens[pos].t != TokType.EOF) pos++
    }

    while (pos < count) {
        while (pos < count && tokens[pos].t == TokType.NEWLINE) pos++
        if (pos >= count || tokens[pos].t == TokType.EOF) break

        val tok = tokens[pos]
        if (tok.t != TokType.IDENT && tok.t != TokType.TYPE && tok.t != TokType.STATE_VAR) {
            skipLine()
            continue
        }
        val id = tok.s
        val idTokenType = tok.t
        pos++

        if (pos >= count || tokens[pos].t != TokType.EQUALS) {
            skipLine()
            continue
        }
        pos++

        val expr = ArrayList<Token>()
        var depth = 0
        var ternaryDepth = 0
        while (pos < count && tokens[pos].t != TokType.EOF) {
            val tt = tokens[pos].t
            if (tt == TokType.NEWLINE && depth <= 0 && ternaryDepth <= 0) {
                var peek = pos + 1
                while (peek < count && tokens[peek].t == TokType.NEWLINE) peek++
                val nextT = if (peek < count) tokens[peek].t else TokType.EOF
                if (nextT == TokType.QUESTION || (nextT == TokType.COLON && ternaryDepth > 0)) {
                    pos++
                    continue // ternary continuation — don't split
                }
                break // statement boundary
            }
            if (tt == TokType.NEWLINE) { pos++; continue }
            if (tt == TokType.LPAREN || tt == TokType.LBRACK || tt == TokType.LBRACE) {
                depth++
            } else if (
                (tt == TokType.RPAREN || tt == TokType.RBRACK || tt == TokType.RBRACE) && depth > 0
            ) {
                depth--
            } else if (tt == TokType.QUESTION && depth == 0) {
                ternaryDepth++
            } else if (tt == TokType.COLON && depth == 0 && ternaryDepth > 0) {
                ternaryDepth--
            }
            expr.add(tokens[pos])
            pos++
        }
        if (expr.isNotEmpty()) stmts.add(RawStatement(id, idTokenType, expr))
    }
    return stmts
}
