package dev.appless.openuilang

/**
 * ECMAScript *WhiteSpace* ∪ *LineTerminator*, EXACT (TAB, LF, VT, FF, CR, SP,
 * NBSP, OGHAM SPACE MARK, the Zs run U+2000–200A, LS, PS, NNBSP, MMSP,
 * IDEOGRAPHIC SPACE, ZWNBSP/U+FEFF).
 *
 * Deliberately hand-rolled: `Char.isWhitespace()` on the JVM is
 * `Character.isWhitespace`, which EXCLUDES U+00A0/U+2007/U+202F/U+FEFF and
 * INCLUDES U+001C–U+001F — none of which matches JS. `java.util.regex`'s `\s`
 * is ASCII-only by default and still wrong with `UNICODE_CHARACTER_CLASS`
 * (it adds U+0085 NEL, which JS does NOT treat as whitespace).
 *
 * `Number(string)`'s *StrWhiteSpace* is the same set, so [jsStringToNumber]
 * trims with [jsTrim]. U+0085 NEL, U+200B ZWSP and U+180E are NOT whitespace
 * to JS and are correctly absent here.
 */
private val JS_WHITESPACE: Set<Char> = hashSetOf(
    '\u0009', '\u000A', '\u000B', '\u000C', '\u000D', '\u0020',
    '\u00A0', '\u1680',
    '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
    '\u2006', '\u2007', '\u2008', '\u2009', '\u200A',
    '\u2028', '\u2029', '\u202F', '\u205F', '\u3000', '\uFEFF',
)

internal fun isJsWhitespace(c: Char): Boolean = JS_WHITESPACE.contains(c)

/** JS `String.prototype.trim()`. */
internal fun String.jsTrim(): String {
    var lo = 0
    var hi = length
    while (lo < hi && isJsWhitespace(this[lo])) lo++
    while (hi > lo && isJsWhitespace(this[hi - 1])) hi--
    return if (lo == 0 && hi == length) this else substring(lo, hi)
}

/** JS `String.prototype.trimEnd()`. */
internal fun String.jsTrimEnd(): String {
    var hi = length
    while (hi > 0 && isJsWhitespace(this[hi - 1])) hi--
    return if (hi == length) this else substring(0, hi)
}

/**
 * Extract code from markdown fences, or return the input as-is when no fences
 * are found. String-context-aware: a ``` inside a double-quoted string does
 * not close the fence. Port of `parser/parser.js` `stripFences`
 * (spec/openui-lang.md §4 preprocessing).
 */
internal fun stripFences(input: String): String {
    val n = input.length
    val blocks = ArrayList<String>()
    var i = 0

    while (i < n) {
        val fenceStart = input.indexOf("```", i)
        if (fenceStart < 0) break

        // Skip the language tag up to the newline.
        var j = fenceStart + 3
        while (j < n && input[j] != '\n') j++
        if (j >= n) {
            // No newline after the opening fence (streaming) — take everything
            // after the marker, then drop the first line: replace(/^[^\n]*\n?/, "").
            val tail = input.substring(fenceStart + 3)
            var k = 0
            while (k < tail.length && tail[k] != '\n') k++
            if (k < tail.length) k++ // include the newline
            blocks.add(tail.substring(k))
            i = n
            break
        }
        j++ // skip the newline

        // Scan for the closing ``` while tracking double-quote string context.
        var inStr = false
        var closePos = -1
        var k = j
        while (k < n) {
            val c = input[k]
            if (inStr) {
                if (c == '\\' && k + 1 < n) { k += 2; continue }
                if (c == '"') inStr = false
                k++
                continue
            }
            if (c == '"') { inStr = true; k++; continue }
            if (c == '`' && k + 1 < n && input[k + 1] == '`' && k + 2 < n && input[k + 2] == '`') {
                closePos = k
                break
            }
            k++
        }
        if (closePos != -1) {
            blocks.add(input.substring(j, closePos))
            i = closePos + 3
        } else {
            blocks.add(input.substring(j))
            i = n
        }
    }
    if (blocks.isNotEmpty()) return blocks.joinToString("\n")

    // Fallback: the input starts with ``` but no block matched.
    if (input.startsWith("```")) {
        var j = 3
        while (j < n && input[j] != '\n') j++
        val start = if (j < n) j + 1 else 3
        val body = input.substring(minOf(start, n))
        val trailingFence = body.lastIndexOf("```")
        return if (trailingFence != -1) body.substring(0, trailingFence) else body
    }
    return input
}

/**
 * Strip `//` and `#` line comments outside of strings (both `"` and `'`
 * delimiters, escape-aware, per line). Port of `stripComments`
 * (spec/openui-lang.md §3.5 comments).
 *
 * The line split keeps trailing empty segments (JS `split("\n")` does) —
 * `java.lang.String.split` would drop them, hence the hand-rolled splitter in
 * [jsSplitLines].
 */
internal fun stripComments(input: String): String {
    val lines = jsSplitLines(input)
    val out = ArrayList<String>(lines.size)
    for (line in lines) {
        var inStr: Char? = null
        var i = 0
        var replaced: String? = null
        while (i < line.length) {
            val c = line[i]
            if (inStr != null) {
                if (c == '\\' && i + 1 < line.length) { i += 2; continue }
                if (c == inStr) inStr = null
                i++
                continue
            }
            if (c == '"' || c == '\'') { inStr = c; i++; continue }
            if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
                replaced = line.substring(0, i).jsTrimEnd()
                break
            }
            if (c == '#') {
                replaced = line.substring(0, i).jsTrimEnd()
                break
            }
            i++
        }
        out.add(replaced ?: line)
    }
    return out.joinToString("\n")
}

/** JS `text.split("\n")`: keeps every empty segment, including trailing ones. */
internal fun jsSplitLines(text: String): List<String> {
    val parts = ArrayList<String>()
    var start = 0
    var i = 0
    while (i < text.length) {
        if (text[i] == '\n') {
            parts.add(text.substring(start, i))
            start = i + 1
        }
        i++
    }
    parts.add(text.substring(start))
    return parts
}
