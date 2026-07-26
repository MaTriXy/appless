package dev.appless.openuilang

/** Token kinds mirroring lang-core `parser/tokens` (spec/openui-lang.md §3.1). */
internal enum class TokType {
    NEWLINE,
    LPAREN, RPAREN, LBRACK, RBRACK, LBRACE, RBRACE,
    COMMA, COLON,
    EQUALS, EQEQ, NOTEQ,
    NOT,
    GREATER, GREATER_EQ, LESS, LESS_EQ,
    AND, OR,
    DOT, QUESTION,
    PLUS, MINUS, STAR, SLASH, PERCENT,
    STR, NUM,
    IDENT, TYPE,
    STATE_VAR, // value INCLUDES the leading `$`
    BUILTIN, // value EXCLUDES the leading `@`
    TRUE, FALSE, NULL,
    EOF,
}

/**
 * A lexed token. `s` carries the text value for STR/IDENT/TYPE/STATE_VAR/
 * BUILTIN, `n` the numeric value for NUM.
 */
internal class Token(val t: TokType, val s: String = "", val n: Double = 0.0) {
    /** Token kinds that count as "values" for the minus disambiguation (§3.4). */
    val isValueToken: Boolean
        get() = when (t) {
            TokType.NUM, TokType.STR, TokType.IDENT, TokType.TYPE, TokType.RPAREN,
            TokType.RBRACK, TokType.TRUE, TokType.FALSE, TokType.NULL,
            TokType.STATE_VAR, TokType.BUILTIN,
            -> true

            else -> false
        }

    override fun toString(): String = "$t(${if (t == TokType.NUM) n.toString() else s})"
}

private fun isDigit(c: Char): Boolean = c in '0'..'9'

private fun isAlpha(c: Char): Boolean = (c in 'a'..'z') || (c in 'A'..'Z') || c == '_'

private fun isWordChar(c: Char): Boolean = isAlpha(c) || isDigit(c)

/**
 * Direct port of lang-core `parser/lexer.js` `tokenize`
 * (spec/openui-lang.md §3 lexical grammar; strings §3.2–3.3, numbers §3.4).
 *
 * Scans the Kotlin `String` by `Char`, which IS a UTF-16 code unit — exactly
 * what JS `src[i]` indexes. No conversion layer is needed (the Swift port has
 * to scan `[UInt16]` because Swift `String` iterates grapheme clusters, which
 * breaks on CRLF and on combining marks).
 *
 * Range checks are code-unit exact by construction: e.g. U+212A KELVIN SIGN
 * (canonically "K") is a single code unit and does NOT satisfy `c in 'A'..'Z'`,
 * matching the JS lexer.
 */
internal fun tokenize(src: String): List<Token> {
    val tokens = ArrayList<Token>()
    var i = 0
    val n = src.length

    while (i < n) {
        // Horizontal whitespace only — `\n` is a significant token. A lone `\r`
        // (and the `\r` of a CRLF pair) is horizontal whitespace (spec §2).
        while (i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\r')) i++
        if (i >= n) break
        val c = src[i]

        when (c) {
            '\n' -> { tokens.add(Token(TokType.NEWLINE)); i++; continue }
            '(' -> { tokens.add(Token(TokType.LPAREN)); i++; continue }
            ')' -> { tokens.add(Token(TokType.RPAREN)); i++; continue }
            '[' -> { tokens.add(Token(TokType.LBRACK)); i++; continue }
            ']' -> { tokens.add(Token(TokType.RBRACK)); i++; continue }
            '{' -> { tokens.add(Token(TokType.LBRACE)); i++; continue }
            '}' -> { tokens.add(Token(TokType.RBRACE)); i++; continue }
            ',' -> { tokens.add(Token(TokType.COMMA)); i++; continue }
            ':' -> { tokens.add(Token(TokType.COLON)); i++; continue }
            '.' -> { tokens.add(Token(TokType.DOT)); i++; continue }
            '?' -> { tokens.add(Token(TokType.QUESTION)); i++; continue }
            '+' -> { tokens.add(Token(TokType.PLUS)); i++; continue }
            '*' -> { tokens.add(Token(TokType.STAR)); i++; continue }
            '/' -> { tokens.add(Token(TokType.SLASH)); i++; continue }
            '%' -> { tokens.add(Token(TokType.PERCENT)); i++; continue }
            else -> Unit
        }

        if (c == '=') {
            if (i + 1 < n && src[i + 1] == '=') { tokens.add(Token(TokType.EQEQ)); i += 2 }
            else { tokens.add(Token(TokType.EQUALS)); i++ }
            continue
        }
        if (c == '!') {
            if (i + 1 < n && src[i + 1] == '=') { tokens.add(Token(TokType.NOTEQ)); i += 2 }
            else { tokens.add(Token(TokType.NOT)); i++ }
            continue
        }
        if (c == '>') {
            if (i + 1 < n && src[i + 1] == '=') { tokens.add(Token(TokType.GREATER_EQ)); i += 2 }
            else { tokens.add(Token(TokType.GREATER)); i++ }
            continue
        }
        if (c == '<') {
            if (i + 1 < n && src[i + 1] == '=') { tokens.add(Token(TokType.LESS_EQ)); i += 2 }
            else { tokens.add(Token(TokType.LESS)); i++ }
            continue
        }
        // A single `&` lexes as `&&`; a single `|` lexes as `||` (spec §3.1).
        if (c == '&') {
            tokens.add(Token(TokType.AND))
            i += if (i + 1 < n && src[i + 1] == '&') 2 else 1
            continue
        }
        if (c == '|') {
            tokens.add(Token(TokType.OR))
            i += if (i + 1 < n && src[i + 1] == '|') 2 else 1
            continue
        }

        // ── String literal: "..." ────────────────────────────────────────────
        if (c == '"') {
            val start = i
            i++
            var isClosed = false
            while (i < n) {
                when {
                    src[i] == '\\' -> i += 2 // skip backslash and the escaped char
                    src[i] == '"' -> { i++; isClosed = true }
                    else -> i++
                }
                if (isClosed) break
            }
            val end = if (i < n) i else n
            val raw = src.substring(start, end)
            tokens.add(Token(TokType.STR, s = parseDoubleQuotedString(raw, isClosed)))
            continue
        }

        // ── String literal: '...' (single quotes) ────────────────────────────
        if (c == '\'') {
            i++
            val result = StringBuilder()
            while (i < n) {
                if (src[i] == '\\') {
                    i++
                    if (i < n) {
                        when (val esc = src[i]) {
                            '\'' -> result.append('\'')
                            '\\' -> result.append('\\')
                            'n' -> result.append('\n')
                            't' -> result.append('\t')
                            else -> result.append(esc) // pass through
                        }
                        i++
                    }
                } else if (src[i] == '\'') {
                    i++
                    break
                } else {
                    result.append(src[i])
                    i++
                }
            }
            tokens.add(Token(TokType.STR, s = result.toString()))
            continue
        }

        // ── Minus: negative-number prefix or subtraction operator ────────────
        var startNumber = false
        if (c == '-') {
            val afterValue = tokens.isNotEmpty() && tokens[tokens.size - 1].isValueToken
            if (!afterValue && i + 1 < n && isDigit(src[i + 1])) {
                startNumber = true
            } else {
                tokens.add(Token(TokType.MINUS))
                i++
                continue
            }
        }

        // ── Number literal: 42, -3, 1.5, 1e10 ───────────────────────────────
        if (isDigit(c) || startNumber) {
            val start = i
            if (src[i] == '-') i++
            while (i < n && isDigit(src[i])) i++
            // The decimal point is consumed only if a digit follows it.
            if (i < n && src[i] == '.' && i + 1 < n && isDigit(src[i + 1])) {
                i++
                while (i < n && isDigit(src[i])) i++
            }
            if (i < n && (src[i] == 'e' || src[i] == 'E')) {
                i++
                if (i < n && (src[i] == '+' || src[i] == '-')) i++
                while (i < n && isDigit(src[i])) i++
            }
            // JS `+slice` semantics. The slice can only contain
            // [0-9.eE+-], so `toDoubleOrNull` agrees with `Number()` — a
            // trailing exponent marker ("1e") yields NaN in both.
            tokens.add(Token(TokType.NUM, n = src.substring(start, i).toDoubleOrNull() ?: Double.NaN))
            continue
        }

        // ── State variable: $identifier ─────────────────────────────────────
        if (c == '$' && i + 1 < n && isAlpha(src[i + 1])) {
            val start = i
            i++
            while (i < n && isWordChar(src[i])) i++
            tokens.add(Token(TokType.STATE_VAR, s = src.substring(start, i)))
            continue
        }

        // ── Keyword or identifier ───────────────────────────────────────────
        if (isAlpha(c)) {
            val start = i
            while (i < n && isWordChar(src[i])) i++
            when (val word = src.substring(start, i)) {
                "true" -> tokens.add(Token(TokType.TRUE))
                "false" -> tokens.add(Token(TokType.FALSE))
                "null" -> tokens.add(Token(TokType.NULL))
                else -> tokens.add(
                    Token(if (c in 'A'..'Z') TokType.TYPE else TokType.IDENT, s = word)
                )
            }
            continue
        }

        // ── Builtin call: @identifier ───────────────────────────────────────
        if (c == '@' && i + 1 < n && isAlpha(src[i + 1])) {
            i++
            val start = i
            while (i < n && isWordChar(src[i])) i++
            tokens.add(Token(TokType.BUILTIN, s = src.substring(start, i)))
            continue
        }

        i++ // silently skip any other code unit (#, emoji surrogates, ;, …)
    }
    tokens.add(Token(TokType.EOF))
    return tokens
}

/**
 * Reproduces the double-quote branch (spec §3.2): hand the raw slice (with
 * quotes; a closing quote appended if unclosed) to a JSON string parser; on
 * ANY failure fall back to the raw text with the boundary quotes stripped and
 * no unescaping at all.
 */
internal fun parseDoubleQuotedString(raw: String, isClosed: Boolean): String {
    val candidate = if (isClosed) raw else raw + "\""
    parseJsonStringLiteral(candidate)?.let { return it }
    // Fallback: rawString.replace(/^"|"$/g, "") — strip one leading and one
    // trailing quote code unit (which may be the same unit).
    var lo = 0
    var hi = raw.length
    if (lo < hi && raw[lo] == '"') lo++
    if (hi > lo && raw[hi - 1] == '"') hi--
    return raw.substring(lo, hi)
}

/**
 * Strict JSON string-literal parser (RFC 8259) over UTF-16 code units,
 * matching `JSON.parse` on a single string token. Returns `null` on any
 * invalid escape, control character, or malformed shape — which is what makes
 * the whole-string raw fallback fire.
 *
 * DELIBERATE DIVERGENCE FROM THE SWIFT PORT (its KNOWN-DEVIATION #2): a `\uXXXX`
 * escape appends its code unit verbatim, so an UNPAIRED surrogate survives
 * exactly as it does in JS. Kotlin `String` can hold a lone surrogate; Swift
 * `String` cannot and substitutes U+FFFD there.
 */
internal fun parseJsonStringLiteral(text: String): String? {
    if (text.length < 2 || text[0] != '"' || text[text.length - 1] != '"') return null
    val out = StringBuilder(text.length)
    var i = 1
    val end = text.length - 1

    // JSON hex digits are exactly [0-9a-fA-F] — code-unit exact (JS rejects
    // e.g. fullwidth digits, which `Character.digit` would accept).
    fun hexDigit(u: Char): Int = when (u) {
        in '0'..'9' -> u - '0'
        in 'a'..'f' -> u - 'a' + 10
        in 'A'..'F' -> u - 'A' + 10
        else -> -1
    }

    while (i < end) {
        val c = text[i]
        if (c == '\\') {
            i++
            if (i >= end) return null
            when (text[i]) {
                '"' -> out.append('"')
                '\\' -> out.append('\\')
                '/' -> out.append('/')
                'b' -> out.append('\b')
                'f' -> out.append('\u000C')
                'n' -> out.append('\n')
                'r' -> out.append('\r')
                't' -> out.append('\t')
                'u' -> {
                    var value = 0
                    for (k in 1..4) {
                        if (i + k >= text.length) return null
                        val d = hexDigit(text[i + k])
                        if (d < 0) return null
                        value = value * 16 + d
                    }
                    i += 4
                    out.append(value.toChar())
                }

                else -> return null // invalid escape → whole-string raw fallback
            }
            i++
        } else {
            if (c < ' ') return null // JSON.parse rejects raw control chars
            if (c == '"') return null // interior unescaped quote (defensive)
            out.append(c)
            i++
        }
    }
    return out.toString()
}
