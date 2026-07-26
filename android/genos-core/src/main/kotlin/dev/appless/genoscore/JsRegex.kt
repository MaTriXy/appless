package dev.appless.genoscore

/**
 * ECMAScript regex + string-primitive semantics on `java.util.regex`.
 *
 * What Kotlin/JVM gives us for free that the Swift port had to shim: `String`
 * IS a UTF-16 code-unit sequence, exactly like a JS string, so `==`,
 * `startsWith`, `indexOf`, `substring`, `split` and `HashMap` keys are already
 * code-unit exact. Swift's `String` compares by Unicode canonical equivalence
 * and indexes by grapheme, which is why `GenOSCore/JSRegex.swift` carries
 * `jsSlice`/`jsHasPrefix`/`jsSplit`/`jsUTF16Index` wrappers. Here those are the
 * native operations and are used directly at their call sites.
 *
 * What does NOT transfer, and is spelled out below:
 *
 * - `\s`: `java.util.regex`'s `\s` is `[ \t\n\x0B\f\r]` (ASCII only); with
 *   `UNICODE_CHARACTER_CLASS` it becomes `\p{IsWhite_Space}`, which ADDS
 *   U+0085 (NEL) — a character JS does not treat as whitespace — and still
 *   omits U+FEFF. The ECMAScript set (WhiteSpace ∪ LineTerminator) is spelled
 *   out in [WS] instead of trusting either.
 * - `.`: JS `.` (no `s` flag) excludes exactly `\n \r U+2028 U+2029`. Java's
 *   `.` additionally excludes U+0085. Use [DOT].
 * - `\w`: ASCII in both engines by default, but spelled `[A-Za-z0-9_]` at the
 *   call sites so no future `UNICODE_CHARACTER_CLASS` flag can change meaning.
 * - `$`: Java's `$` (no `MULTILINE`) also matches BEFORE a final line
 *   terminator; JS's `$` (no `m`) does not. Ported patterns use `\z`.
 * - `CASE_INSENSITIVE`: ASCII-only on the JVM unless `UNICODE_CASE` is set,
 *   which happens to agree with JS `/i` (no `u` flag) for ASCII patterns.
 *   Ported `i` patterns still spell their case variants out, so the parity is
 *   visible in the pattern rather than resting on a flag default.
 * - `String.lowercase()/uppercase()` are `Locale.ROOT` in Kotlin (the
 *   deprecated `toLowerCase()` was locale-sensitive); JS is locale-independent
 *   too, so `lowercase()`/`uppercase()` are used directly.
 * - `java.lang.String.split` drops trailing empty segments; JS does not.
 *   Kotlin's `String.split` keeps them, so it is used directly — never
 *   `java.lang.String.split`.
 */
internal object JsRegex {
    /**
     * ECMAScript `WhiteSpace ∪ LineTerminator` members, spelled explicitly:
     * TAB, LF, VT, FF, CR, every `Zs` space separator (U+0020, U+00A0, U+1680,
     * U+2000–U+200A, U+202F, U+205F, U+3000), LS, PS and the BOM.
     */
    const val WS_MEMBERS =
        "\\t\\n\\x0B\\f\\r\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"

    /** ECMAScript `\s` as a character class. */
    const val WS = "[$WS_MEMBERS]"

    /** ECMAScript `[^\S\n]` — whitespace except the newline. */
    const val WS_NO_NEWLINE =
        "[\\t\\x0B\\f\\r\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"

    /** ECMAScript `.` — anything but `\n \r U+2028 U+2029`. */
    const val DOT = "[^\\n\\r\\u2028\\u2029]"

    private val cache = HashMap<String, Regex>()

    fun compile(pattern: String): Regex = synchronized(cache) {
        cache.getOrPut(pattern) { Regex(pattern) }
    }

    private fun groups(match: MatchResult): List<String?> = match.groupValues.indices.map { i ->
        match.groups[i]?.value
    }

    /** `text.match(re)` for a non-global regex: whole match + captures, or null. */
    fun first(pattern: String, text: String): List<String?>? =
        compile(pattern).find(text)?.let { groups(it) }

    /** Global scan: every match's whole text + captures. */
    fun all(pattern: String, text: String): List<List<String?>> =
        compile(pattern).findAll(text).map { groups(it) }.toList()

    /** `text.replace(re, template)` for a NON-global regex: first match only. */
    fun replaceFirst(pattern: String, text: String, template: String): String =
        compile(pattern).replaceFirst(text, template)

    /** `text.replace(re, template)` for a GLOBAL regex. */
    fun replaceAll(pattern: String, text: String, template: String): String =
        compile(pattern).replace(text, template)

    /** `re.test(text)`. */
    fun test(pattern: String, text: String): Boolean = compile(pattern).containsMatchIn(text)
}

/**
 * ECMAScript `StrWhiteSpace` membership (the same set as [JsRegex.WS]):
 * `\t \n \v \f \r`, U+2028, U+2029, U+FEFF and every `Zs` space separator.
 *
 * `Char.isWhitespace()` on the JVM disagrees in both directions (it accepts
 * U+0085 and the `Zl`/`Zp` separators but rejects U+00A0 and U+FEFF).
 */
internal fun isJsWhiteSpace(c: Char): Boolean = when (c) {
    '\t', '\n', '\u000B', '\u000C', '\r', '\u2028', '\u2029', '\uFEFF' -> true
    else -> Character.getType(c) == Character.SPACE_SEPARATOR.toInt()
}

/**
 * JS `String.prototype.trim()`: strips the exact ECMAScript whitespace set.
 * Kotlin's `trim()` uses `Char.isWhitespace`, which diverges (see
 * [isJsWhiteSpace]), so every ported `.trim()` call site uses this.
 */
public fun jsTrim(s: String): String {
    var start = 0
    var end = s.length
    while (start < end && isJsWhiteSpace(s[start])) start++
    while (end > start && isJsWhiteSpace(s[end - 1])) end--
    return s.substring(start, end)
}

/**
 * JS `s.slice(0, end)` in UTF-16 code units. Kotlin `String` is UTF-16, so a
 * slice that splits a surrogate pair leaves a lone surrogate here exactly as
 * it does in JS (Swift cannot represent that and materializes U+FFFD instead).
 */
internal fun jsSliceTo(s: String, end: Int): String =
    if (s.length <= end) s else s.substring(0, maxOf(0, end))

/** JS `s.slice(start)` in UTF-16 code units. */
internal fun jsSliceFrom(s: String, start: Int): String =
    if (start >= s.length) "" else s.substring(maxOf(0, start))

/**
 * JS `parseInt(s, 10)`: skips the FULL `StrWhiteSpace` set (NBSP, U+2028/29,
 * U+FEFF included), then an optional sign and the leading decimal-digit run.
 * Returns NaN when no digits follow.
 *
 * The digit run is converted through `Double` (JS Number semantics) so long
 * runs saturate rather than fail: a 23-digit seed becomes ~1.23e22 (correctly
 * rounded, like JS) and hundreds of digits become +Infinity — both then clamp
 * downstream exactly as in RN, instead of collapsing to the NaN path.
 */
internal fun jsParseInt(s: String): Double {
    var i = 0
    while (i < s.length && isJsWhiteSpace(s[i])) i++
    var negative = false
    if (i < s.length && (s[i] == '+' || s[i] == '-')) {
        negative = s[i] == '-'
        i++
    }
    val start = i
    while (i < s.length && s[i] in '0'..'9') i++
    if (i == start) return Double.NaN
    val magnitude = s.substring(start, i).toDouble()
    return if (negative) -magnitude else magnitude
}

/** ECMAScript unreserved set for `encodeURIComponent`. */
private const val URI_UNRESERVED =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"

/**
 * `encodeURIComponent` analog: everything but `A-Za-z0-9 -_.!~*'()` becomes
 * upper-case percent-escaped UTF-8.
 *
 * Divergence (unreachable at the call sites): JS throws `URIError` on an
 * unpaired surrogate; `String.toByteArray(UTF_8)` substitutes `?`. The only
 * caller feeds it a string already sanitized to `[a-zA-Z0-9, -]`.
 */
internal fun jsEncodeURIComponent(s: String): String {
    val out = StringBuilder(s.length)
    var i = 0
    while (i < s.length) {
        val c = s[i]
        if (URI_UNRESERVED.indexOf(c) >= 0) {
            out.append(c)
            i++
            continue
        }
        // Consume a full code point so surrogate pairs encode as one sequence.
        val end = if (Character.isHighSurrogate(c) && i + 1 < s.length &&
            Character.isLowSurrogate(s[i + 1])
        ) i + 2 else i + 1
        for (b in s.substring(i, end).toByteArray(Charsets.UTF_8)) {
            out.append('%')
            out.append(HEX[(b.toInt() shr 4) and 0xF])
            out.append(HEX[b.toInt() and 0xF])
        }
        i = end
    }
    return out.toString()
}

private const val HEX = "0123456789ABCDEF"

private fun hexDigit(c: Char): Int = when (c) {
    in '0'..'9' -> c - '0'
    in 'a'..'f' -> c - 'a' + 10
    in 'A'..'F' -> c - 'A' + 10
    else -> -1
}

/**
 * `decodeURIComponent` analog: null where the JS function throws `URIError`.
 *
 * Strict per the spec's `Decode`: a dangling `%`, a non-hex escape, a
 * truncated/invalid UTF-8 continuation, an overlong encoding, a percent-encoded
 * surrogate (`%ED%A0%80`) and anything above U+10FFFF all fail — so the ported
 * call sites take the same raw-fallback branch RN's `catch` takes.
 */
internal fun jsDecodeURIComponent(s: String): String? {
    val out = StringBuilder(s.length)
    var i = 0
    while (i < s.length) {
        val c = s[i]
        if (c != '%') {
            out.append(c)
            i++
            continue
        }
        if (i + 2 >= s.length) return null
        val hi = hexDigit(s[i + 1])
        val lo = hexDigit(s[i + 2])
        if (hi < 0 || lo < 0) return null
        val lead = (hi shl 4) or lo
        i += 3
        if (lead < 0x80) {
            out.append(Char(lead))
            continue
        }
        // Number of leading 1-bits gives the sequence length.
        var n = 0
        var probe = lead
        while (probe and 0x80 != 0) {
            n++
            probe = (probe shl 1) and 0xFF
        }
        if (n < 2 || n > 4) return null
        var value = lead and (0xFF shr (n + 1))
        for (unused in 1 until n) {
            if (i + 2 >= s.length || s[i] != '%') return null
            val chi = hexDigit(s[i + 1])
            val clo = hexDigit(s[i + 2])
            if (chi < 0 || clo < 0) return null
            val byte = (chi shl 4) or clo
            if (byte and 0xC0 != 0x80) return null
            value = (value shl 6) or (byte and 0x3F)
            i += 3
        }
        if (n == 2 && value < 0x80) return null
        if (n == 3 && value < 0x800) return null
        if (n == 4 && value < 0x10000) return null
        if (value > 0x10FFFF) return null
        if (value in 0xD800..0xDFFF) return null
        if (value <= 0xFFFF) {
            out.append(Char(value))
        } else {
            val u = value - 0x10000
            out.append(Char(0xD800 + (u shr 10)))
            out.append(Char(0xDC00 + (u and 0x3FF)))
        }
    }
    return out.toString()
}

/** JS `String(value)` for tool-call argument coercion (`args.query ?? ""`). */
internal fun jsStringCoerce(value: JsonValue?): String = when (value) {
    null, JsonValue.Null -> ""
    is JsonValue.Str -> value.value
    is JsonValue.Num -> JsonValue.numberString(value.value)
    is JsonValue.Bool -> if (value.value) "true" else "false"
    is JsonValue.Arr, is JsonValue.Obj -> value.stringified()
}
