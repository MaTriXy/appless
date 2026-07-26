package dev.appless.openuilang

import kotlin.math.abs
import kotlin.math.floor

/**
 * Hand-written deterministic serializer emitting the canonical expected-tree
 * JSON documented in `spec/fixtures/README.md` (result shapes:
 * spec/openui-lang.md Appendix A):
 *
 * - 2-space indent, exactly like `JSON.stringify(value, null, 2)`;
 * - trailing newline;
 * - the document, element nodes, `meta.errors[]` entries and
 *   `runtimeErrors[]` entries use the reference implementation's fixed key
 *   order; all other objects (props, state, plain objects, action steps,
 *   `$ast` nodes) have their keys sorted;
 * - JS number formatting (`125` not `125.0`, shortest round-trip for
 *   doubles); non-finite numbers become `{"$number": ...}`;
 * - `undefined` at a value position becomes `null` (modeled as [PropValue.Null]).
 *
 * Ordering is NEVER delegated to a JSON library — every library the JVM
 * offers either sorts differently, re-orders on `Map` type, or reformats
 * numbers through `Double.toString`.
 *
 * Mirrors `TreeSerializer.swift`.
 */
public object TreeSerializer {

    public fun serialize(result: ParseResult): String {
        val out = StringBuilder()
        out.append("{\n")

        // Document key order: root, meta, state, runtimeErrors.
        out.append("  \"root\": ")
        val root = result.root
        if (root != null) out.append(serializeElement(root, 1)) else out.append("null")
        out.append(",\n")

        out.append("  \"meta\": ").append(serializeMeta(result.meta, 1)).append(",\n")

        out.append("  \"state\": ").append(serializeStringKeyedObject(result.state, 1)).append(",\n")

        out.append("  \"runtimeErrors\": ")
        if (result.runtimeErrors.isEmpty()) {
            out.append("[]")
        } else {
            out.append("[\n")
            out.append(
                result.runtimeErrors.joinToString(",\n") {
                    pad(2) + serializeRuntimeError(it, 2)
                }
            )
            out.append("\n").append(pad(1)).append("]")
        }
        out.append("\n}\n")
        return out.toString()
    }

    // ---- Sections -----------------------------------------------------------

    private fun serializeMeta(meta: ParseMeta, indent: Int): String {
        val out = StringBuilder("{\n")
        val inner = indent + 1
        out.append(pad(inner)).append("\"incomplete\": ")
            .append(if (meta.incomplete) "true" else "false").append(",\n")

        out.append(pad(inner)).append("\"unresolved\": ")
        if (meta.unresolved.isEmpty()) {
            out.append("[]")
        } else {
            out.append("[\n")
            out.append(meta.unresolved.joinToString(",\n") { pad(inner + 1) + quote(it) })
            out.append("\n").append(pad(inner)).append("]")
        }
        out.append(",\n")

        out.append(pad(inner)).append("\"errors\": ")
        if (meta.errors.isEmpty()) {
            out.append("[]")
        } else {
            out.append("[\n")
            out.append(
                meta.errors.joinToString(",\n") {
                    pad(inner + 1) + serializeParseError(it, inner + 1)
                }
            )
            out.append("\n").append(pad(inner)).append("]")
        }
        out.append("\n").append(pad(indent)).append("}")
        return out.toString()
    }

    private fun serializeParseError(error: ParseError, indent: Int): String {
        // Fixed key order: code, component, path, message, statementId?.
        val inner = indent + 1
        val lines = ArrayList<String>(5)
        lines.add(pad(inner) + "\"code\": " + quote(error.code.wire))
        lines.add(pad(inner) + "\"component\": " + quote(error.component))
        lines.add(pad(inner) + "\"path\": " + quote(error.path))
        lines.add(pad(inner) + "\"message\": " + quote(error.message))
        error.statementId?.let { lines.add(pad(inner) + "\"statementId\": " + quote(it)) }
        return "{\n" + lines.joinToString(",\n") + "\n" + pad(indent) + "}"
    }

    private fun serializeRuntimeError(error: RuntimeError, indent: Int): String {
        // Fixed key order: source, code, message, component?, statementId?.
        val inner = indent + 1
        val lines = ArrayList<String>(5)
        lines.add(pad(inner) + "\"source\": " + quote(error.source))
        lines.add(pad(inner) + "\"code\": " + quote(error.code))
        lines.add(pad(inner) + "\"message\": " + quote(error.message))
        error.component?.let { lines.add(pad(inner) + "\"component\": " + quote(it)) }
        error.statementId?.let {
            lines.add(pad(inner) + "\"statementId\": " + serializeRawValue(it, inner))
        }
        return "{\n" + lines.joinToString(",\n") + "\n" + pad(indent) + "}"
    }

    /**
     * A value the reference serializer copies VERBATIM rather than rebuilding
     * (`out.statementId = el.statementId`): the bytes come straight from
     * `JSON.stringify`, which uses `OrdinaryOwnPropertyKeys` — canonical array
     * indices first, then **INSERTION** order. The rest of the document is
     * additionally SORTED because `serializeValue` re-inserts keys from
     * `Object.keys(v).sort()` into a fresh object; nothing sorts this one.
     *
     * [PropObject.entries] is already in `Object.keys` order, so this is
     * [serializeValue] minus the sort — and minus every wrapper shape, since
     * [Pipeline.rawJson] only ever produces plain JSON.
     */
    private fun serializeRawValue(value: PropValue, indent: Int): String = when (value) {
        is PropValue.Arr ->
            if (value.items.isEmpty()) {
                "[]"
            } else {
                "[\n" + value.items.joinToString(",\n") {
                    pad(indent + 1) + serializeRawValue(it, indent + 1)
                } + "\n" + pad(indent) + "]"
            }

        is PropValue.Obj -> {
            val entries = value.entries.entries
            if (entries.isEmpty()) {
                "{}"
            } else {
                "{\n" + entries.joinToString(",\n") { (key, v) ->
                    pad(indent + 1) + quote(key) + ": " + serializeRawValue(v, indent + 1)
                } + "\n" + pad(indent) + "}"
            }
        }

        else -> serializeValue(value, indent)
    }

    private fun serializeElement(element: ElementNode, indent: Int): String {
        // Fixed key order: component, statementId?, props, children?.
        val inner = indent + 1
        val lines = ArrayList<String>(4)
        // `{ component: el.typeName }` with an UNDEFINED typeName is an object
        // with an undefined-valued key, which JSON.stringify omits.
        if (element.componentPresent) {
            lines.add(pad(inner) + "\"component\": " + quote(element.component))
        }
        element.statementId?.let {
            lines.add(pad(inner) + "\"statementId\": " + serializeRawValue(it, inner))
        }
        lines.add(pad(inner) + "\"props\": " + serializeStringKeyedObject(element.props, inner))
        element.children?.let {
            lines.add(pad(inner) + "\"children\": " + serializeValue(it, inner))
        }
        return "{\n" + lines.joinToString(",\n") + "\n" + pad(indent) + "}"
    }

    // ---- Values -------------------------------------------------------------

    private fun serializeValue(value: PropValue, indent: Int): String = when (value) {
        is PropValue.Null -> "null"
        is PropValue.Bool -> if (value.value) "true" else "false"
        is PropValue.Num -> {
            val n = value.value
            if (n.isNaN() || n.isInfinite()) {
                val name = if (n.isNaN()) "NaN" else if (n > 0) "Infinity" else "-Infinity"
                "{\n" + pad(indent + 1) + "\"\$number\": " + quote(name) +
                    "\n" + pad(indent) + "}"
            } else {
                formatNumber(n)
            }
        }
        is PropValue.Str -> quote(value.value)
        is PropValue.Arr -> {
            if (value.items.isEmpty()) {
                "[]"
            } else {
                "[\n" +
                    value.items.joinToString(",\n") {
                        pad(indent + 1) + serializeValue(it, indent + 1)
                    } +
                    "\n" + pad(indent) + "]"
            }
        }
        is PropValue.Obj -> serializePropObject(value.entries, indent)
        is PropValue.Element -> serializeElement(value.node, indent)
        is PropValue.Action -> {
            val inner = indent + 1
            "{\n" + pad(inner) + "\"\$action\": {\n" +
                pad(inner + 1) + "\"steps\": " +
                serializeValue(PropValue.Arr(value.plan.steps), inner + 1) +
                "\n" + pad(inner) + "}" +
                "\n" + pad(indent) + "}"
        }
        is PropValue.Ast -> "{\n" + pad(indent + 1) + "\"\$ast\": " +
            serializeValue(value.node, indent + 1) +
            "\n" + pad(indent) + "}"
    }

    /**
     * Serializes a `Map<String, PropValue>` (props, `state`) as an object in
     * [JS_OWN_KEY_ORDER] — canonical array indices first in ascending numeric
     * order, then the remaining keys in UTF-16 code-unit order.
     *
     * The reference serializer sorts with `Object.keys(v).sort()` and
     * re-inserts into a fresh object, but the bytes come out of
     * `JSON.stringify`, which re-derives the order from
     * `OrdinaryOwnPropertyKeys` and hoists the integer-index keys. A flat
     * code-unit sort matches only for objects with no index-shaped keys
     * (fixture `075-object-key-index-order`).
     *
     * The code-unit half is exact on the JVM for free: `String.compareTo`
     * compares `char`s — unlike Swift, where `String` ordering is canonical
     * and can place NFC/NFD keys differently.
     */
    private fun serializeStringKeyedObject(entries: Map<String, PropValue>, indent: Int): String {
        if (entries.isEmpty()) return "{}"
        return "{\n" +
            entries.keys.sortedWith(JS_OWN_KEY_ORDER).joinToString(",\n") { key ->
                pad(indent + 1) + quote(key) + ": " +
                    serializeValue(entries.getValue(key), indent + 1)
            } +
            "\n" + pad(indent) + "}"
    }

    /**
     * Serializes a [PropObject] — plain data objects, `$ast` nodes and action
     * steps — in the same [JS_OWN_KEY_ORDER] as [serializeStringKeyedObject].
     */
    private fun serializePropObject(obj: PropObject, indent: Int): String {
        if (obj.isEmpty()) return "{}"
        return "{\n" +
            obj.entries
                .sortedWith { a, b -> JS_OWN_KEY_ORDER.compare(a.first, b.first) }
                .joinToString(",\n") { (key, value) ->
                    pad(indent + 1) + quote(key) + ": " + serializeValue(value, indent + 1)
                } +
            "\n" + pad(indent) + "}"
    }

    // ---- Scalars ------------------------------------------------------------

    private val PADS = Array(24) { "  ".repeat(it) }

    private fun pad(indent: Int): String =
        if (indent < PADS.size) PADS[indent] else "  ".repeat(indent)

    private const val HEX = "0123456789abcdef"

    /**
     * JSON string escaping matching `JSON.stringify`: only `"`, `\` and control
     * characters below U+0020 are escaped; everything else (including
     * non-ASCII) is emitted raw.
     *
     * Well-formed `JSON.stringify` (ES2019) additionally escapes *lone*
     * surrogates as `\udXXX`; Kotlin's UTF-16 `String` can hold them (Swift's
     * cannot — see the Swift port's KNOWN-DEVIATION #2), and `toByteArray(UTF_8)`
     * would silently turn them into `?`, so they are escaped here.
     */
    public fun quote(s: String): String {
        val out = StringBuilder(s.length + 2)
        out.append('"')
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\b' -> out.append("\\b")
                c == '\t' -> out.append("\\t")
                c == '\n' -> out.append("\\n")
                c == '\u000C' -> out.append("\\f")
                c == '\r' -> out.append("\\r")
                c < ' ' -> appendUnicodeEscape(out, c.code)
                Character.isHighSurrogate(c) -> {
                    if (i + 1 < s.length && Character.isLowSurrogate(s[i + 1])) {
                        out.append(c).append(s[i + 1])
                        i++
                    } else {
                        appendUnicodeEscape(out, c.code) // lone high surrogate
                    }
                }
                Character.isLowSurrogate(c) -> appendUnicodeEscape(out, c.code) // lone low
                else -> out.append(c)
            }
            i++
        }
        out.append('"')
        return out.toString()
    }

    private fun appendUnicodeEscape(out: StringBuilder, code: Int) {
        out.append("\\u")
        out.append(HEX[(code shr 12) and 0xF])
        out.append(HEX[(code shr 8) and 0xF])
        out.append(HEX[(code shr 4) and 0xF])
        out.append(HEX[code and 0xF])
    }

    /** 2^53 — above this, doubles no longer represent every integer exactly. */
    private const val TWO_POW_53 = 9007199254740992.0

    /**
     * ECMAScript `Number::toString` for finite doubles (shortest round-trip):
     * integers WITHOUT a decimal point, positional notation for decimal
     * exponents in (-7, 21], exponential (`1e-7`, `1.5e+21`) outside.
     *
     * This is NOT `Double.toString`. The JVM's own rendering differs from JS
     * in three ways that all show up in the fixture corpus (071 is the
     * boundary fixture; the Swift twin is verified against a 267-entry table):
     *
     * 1. Java ALWAYS emits a decimal point: `Double.toString(125.0)` is
     *    `"125.0"`, JS `String(125)` is `"125"`.
     * 2. Java switches to scientific notation at |x| >= 1e7 and < 1e-3;
     *    JS switches at >= 1e21 and < 1e-6. `Double.toString(1e16)` is
     *    `"1.0E16"`, JS gives `"10000000000000000"`.
     * 3. Java writes `E16` / `E-7`; JS writes `e+16` / `e-7`.
     *
     * What MOSTLY transfers: since JDK 19 (JDK-4511638) `Double.toString`
     * emits the shortest decimal digit string that round-trips, which is what
     * ECMAScript specifies too. So the port takes Java's digits and re-renders
     * them under the JS positional/exponential rules — the same strategy the
     * Swift port uses with Swift's `"\(d)"`. The module targets JDK 21, so the
     * shortest-repr guarantee always holds.
     *
     * 4. ...with one exception Swift does NOT have: Java's spec floors the
     *    digit count at TWO ("if p <= 2, let T be the set of all decimals in R
     *    with length 2"). When the shortest round-tripping decimal has a single
     *    significant digit, Java therefore emits the closest 2-digit decimal
     *    instead — and that is not always the 1-digit answer padded with a
     *    zero. `Double.toString(Double.MIN_VALUE)` is `"4.9E-324"` while JS
     *    `String(5e-324)` is `"5e-324"`. Stripping trailing zeros does not
     *    recover it, so [shortenToOneDigit] re-tests the 1-digit candidates for
     *    round-trip. For p >= 2 the two specs agree exactly (both take the
     *    closest decimal of length p), so no other length needs re-testing.
     */
    public fun formatNumber(d: Double): String {
        require(d.isFinite()) { "formatNumber requires a finite double" }
        if (d == 0.0) return "0" // JSON.stringify(-0) === "0"

        // Integer fast path, valid only below 2^53: there every integer is
        // exactly representable, so the exact decimal expansion IS the
        // shortest round-trip form. At |d| >= 2^53 that no longer holds —
        // ECMAScript renders SHORTEST round-trip digits, not the exact
        // expansion (`String(2 ** 56)` is `"72057594037927940"`, not
        // `"72057594037927936"`), so those magnitudes fall through to the
        // re-rendering below even though they fit in a Long.
        if (abs(d) < TWO_POW_53 && d == floor(d)) {
            return d.toLong().toString()
        }

        val repr = d.toString() // JDK >= 19: shortest round-trip digits
        val eIndex = repr.indexOfFirst { it == 'e' || it == 'E' }
        if (eIndex < 0) {
            // Java's positional range (1e-3 <= |x| < 1e7) sits strictly inside
            // the JS positional range, so the digits are already correct —
            // except that Java always appends ".0" to integer-valued doubles.
            return if (repr.endsWith(".0")) repr.dropLast(2) else repr
        }

        // Re-render Java's exponential form under JS rules.
        var mantissa = repr.substring(0, eIndex)
        val exponent = repr.substring(eIndex + 1).toIntOrNull() ?: 0
        var sign = ""
        if (mantissa.startsWith("-")) {
            sign = "-"
            mantissa = mantissa.substring(1)
        }
        var digits = mantissa
        var pointOffset = mantissa.length
        val dot = mantissa.indexOf('.')
        if (dot >= 0) {
            pointOffset = dot
            digits = mantissa.substring(0, dot) + mantissa.substring(dot + 1)
        }
        while (digits.length > 1 && digits.endsWith("0")) {
            digits = digits.dropLast(1)
        }
        // n: value == 0.<digits> * 10^n
        var n = exponent + pointOffset

        // Java's two-significant-digit floor (see #4 above).
        if (digits.length == 2) {
            shortenToOneDigit(digits, n, abs(d))?.let { (shortDigits, shortN) ->
                digits = shortDigits
                n = shortN
            }
        }
        val k = digits.length

        if (k <= n && n <= 21) {
            return sign + digits + "0".repeat(n - k)
        }
        if (n in 1..21) {
            return sign + digits.substring(0, n) + "." + digits.substring(n)
        }
        if (n in -5..0) {
            return sign + "0." + "0".repeat(-n) + digits
        }
        val first = digits.substring(0, 1)
        val rest = digits.substring(1)
        val e = n - 1
        val expPart = (if (e >= 0) "e+" else "e-") + abs(e).toString()
        return sign + first + (if (rest.isEmpty()) "" else ".$rest") + expPart
    }

    /**
     * Given Java's 2-digit rendering `0.<digits> * 10^n` of `magnitude`
     * (`abs(d)`), returns the 1-digit `(digits, n)` ECMAScript would have
     * chosen, or `null` when no 1-digit decimal round-trips.
     *
     * The only 1-digit candidates that can round-trip are the two neighbors of
     * `digits[0]` (its own value and the next one up, which carries `9 -> 10`
     * and shifts `n`). When both round-trip, ECMAScript takes the one closest
     * to the exact binary value — compared with [java.math.BigDecimal] so the
     * tie-break is not itself decided by double rounding.
     */
    private fun shortenToOneDigit(digits: String, n: Int, magnitude: Double): Pair<String, Int>? {
        val lead = digits[0] - '0'
        val exact = java.math.BigDecimal(magnitude)
        var best: Pair<String, Int>? = null
        var bestDelta: java.math.BigDecimal? = null
        for (candidate in intArrayOf(lead, lead + 1)) {
            val (candDigits, candN) =
                if (candidate == 10) "1" to (n + 1) else candidate.toString() to n
            if (candDigits == "0") continue
            // value == 0.<candDigits> * 10^candN == <candDigits> * 10^(candN - 1)
            val literal = candDigits + "E" + (candN - 1)
            val reparsed = literal.toDouble()
            if (reparsed != magnitude) continue
            val delta = java.math.BigDecimal(literal).subtract(exact).abs()
            if (bestDelta == null || delta < bestDelta) {
                best = candDigits to candN
                bestDelta = delta
            }
        }
        return best
    }
}
