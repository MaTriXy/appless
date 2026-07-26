package dev.appless.genoscore

import java.math.BigDecimal
import kotlin.math.abs
import kotlin.math.floor

/**
 * JSON model used for tool-call arguments, form state, request bodies and
 * request-body assertions in tests.
 *
 * [Obj] holds a `LinkedHashMap`, so key order is INSERTION order — which is
 * exactly what `JSON.stringify` emits (modulo canonical array indices, handled
 * in [stringified]). The Swift port needed an explicit `keyOrder` hint here
 * because `Dictionary` is unordered; on the JVM the parity is free, and object
 * keys parsed out of a document keep document order too.
 */
public sealed interface JsonValue {
    public data class Str(val value: String) : JsonValue
    public data class Num(val value: Double) : JsonValue
    public data class Bool(val value: Boolean) : JsonValue
    public data object Null : JsonValue
    public data class Arr(val values: List<JsonValue>) : JsonValue
    public data class Obj(val values: Map<String, JsonValue>) : JsonValue

    /** `obj[key]` — null for a non-object or an absent key. */
    public operator fun get(key: String): JsonValue? =
        (this as? Obj)?.values?.get(key)

    /** `arr[index]` — null for a non-array or an out-of-range index. */
    public operator fun get(index: Int): JsonValue? =
        (this as? Arr)?.values?.getOrNull(index)

    public val str: String?
        get() = (this as? Str)?.value

    public val num: Double?
        get() = (this as? Num)?.value

    public val bool: Boolean?
        get() = (this as? Bool)?.value

    public val arr: List<JsonValue>?
        get() = (this as? Arr)?.values

    public val obj: Map<String, JsonValue>?
        get() = (this as? Obj)?.values

    /**
     * JS truthiness (`if (value)`): "" / 0 / NaN / false / null are falsy; any
     * object or array — even an empty one — is truthy.
     */
    public val isJsTruthy: Boolean
        get() = when (this) {
            is Str -> value.isNotEmpty()
            is Num -> value != 0.0 && !value.isNaN()
            is Bool -> value
            Null -> false
            is Arr, is Obj -> true
        }

    /**
     * Serialize like `JSON.stringify` (no pretty printing, `/` unescaped).
     *
     * Object keys follow `OrdinaryOwnPropertyKeys` (ES 10.1.11.1): every
     * canonical array-index key first in ascending NUMERIC order, then the
     * remaining keys in insertion order. So `{"b":1,"10":2,"2":3}` emits
     * `{"2":3,"10":2,"b":1}`, exactly like node.
     */
    public fun stringified(): String = when (this) {
        is Str -> encodeJsonString(value)
        is Num -> numberString(value)
        is Bool -> if (value) "true" else "false"
        Null -> "null"
        is Arr -> values.joinToString(",", "[", "]") { it.stringified() }
        is Obj -> jsOwnKeyOrder(values.keys)
            .joinToString(",", "{", "}") { key ->
                encodeJsonString(key) + ":" + (values[key] ?: Null).stringified()
            }
    }

    public companion object {
        /** Parse a JSON document; null on malformed input (JS `JSON.parse` throws). */
        public fun parse(text: String): JsonValue? {
            val parser = JsonParser(text)
            val value = parser.parseValue() ?: return null
            parser.skipWhitespace()
            return if (parser.isAtEnd) value else null
        }

        public fun parse(data: ByteArray): JsonValue? = parse(data.toString(Charsets.UTF_8))

        /** Convenience builder preserving argument order. */
        public fun obj(vararg pairs: Pair<String, JsonValue>): Obj =
            Obj(linkedMapOf(*pairs))

        /**
         * `JSON.stringify` of an object built from an ORDERED key/value list —
         * RN's `JSON.stringify(formState)` emits keys in insertion order, and
         * the shell passes form values in UI insertion order.
         */
        public fun stringifyOrdered(pairs: List<Pair<String, JsonValue>>): String {
            val map = LinkedHashMap<String, JsonValue>(pairs.size)
            for ((k, v) in pairs) map[k] = v
            return Obj(map).stringified()
        }

        /** Largest canonical array index: 2^32 - 2. */
        private const val MAX_ARRAY_INDEX: Long = 4294967294L

        /** The numeric value of [key] when it is a canonical array index, else -1. */
        internal fun canonicalArrayIndex(key: String): Long {
            val n = key.length
            if (n == 0 || n > 10) return -1
            if (key[0] == '0' && n > 1) return -1
            var value = 0L
            for (c in key) {
                if (c < '0' || c > '9') return -1
                value = value * 10 + (c - '0')
            }
            return if (value > MAX_ARRAY_INDEX) -1 else value
        }

        private fun jsOwnKeyOrder(keys: Collection<String>): List<String> {
            val indices = ArrayList<String>()
            val rest = ArrayList<String>()
            for (k in keys) if (canonicalArrayIndex(k) >= 0) indices.add(k) else rest.add(k)
            if (indices.isEmpty()) return rest
            indices.sortBy { canonicalArrayIndex(it) }
            return indices + rest
        }

        public fun encodeJsonString(s: String): String {
            val out = StringBuilder(s.length + 2)
            out.append('"')
            for (c in s) {
                when {
                    c == '"' -> out.append("\\\"")
                    c == '\\' -> out.append("\\\\")
                    c == '\n' -> out.append("\\n")
                    c == '\r' -> out.append("\\r")
                    c == '\t' -> out.append("\\t")
                    c == '\u0008' -> out.append("\\b")
                    c == '\u000C' -> out.append("\\f")
                    c.code < 0x20 -> out.append(String.format("\\u%04x", c.code))
                    else -> out.append(c)
                }
            }
            out.append('"')
            return out.toString()
        }

        private const val TWO_POW_53 = 9_007_199_254_740_992.0

        /**
         * ECMAScript `Number::toString` — what `JSON.stringify` emits for
         * numbers — mirroring OpenUILang's `TreeSerializer.formatNumber`, whose
         * algorithm is pinned there against a 267-entry table of node
         * `String(x)` outputs (powers of two, Int64 boundaries, the 1e21/1e-7
         * thresholds, subnormals, -0.0).
         *
         * Since JDK 19 `Double.toString` emits the SHORTEST decimal that
         * round-trips, like ECMAScript — so the digits are reusable and only
         * the positional/exponential rendering rules differ (JS writes
         * `10000000000000000` where Java writes `1.0E16`, `0.00001` where Java
         * writes `1.0E-5`, `1e-7` where Java writes `1.0E-7`).
         *
         * One exception Swift does NOT have: Java's spec floors the digit count
         * at TWO, so `Double.toString(Double.MIN_VALUE)` is `"4.9E-324"` where
         * JS `String(5e-324)` is `"5e-324"`. Stripping zeros cannot recover
         * that, so [shortenToOneDigit] re-tests the one-digit candidates for
         * round-trip. For p >= 2 the two specs agree exactly.
         */
        public fun numberString(n: Double): String {
            // JSON.stringify serializes non-finite numbers as null.
            if (n.isNaN() || n.isInfinite()) return "null"
            if (n == 0.0) return "0" // JSON.stringify(-0) === "0"

            // Integer fast path, valid only below 2^53: there every integer is
            // exactly representable, so the exact decimal expansion IS the
            // shortest round-trip form. At or above 2^53 ECMAScript renders
            // SHORTEST digits (String(2 ** 56) is "72057594037927940", not
            // "...936"), so those fall through even though they fit a Long.
            if (abs(n) < TWO_POW_53 && n == floor(n)) return n.toLong().toString()

            val repr = n.toString() // JDK >= 19: shortest round-trip digits
            val eIndex = repr.indexOfFirst { it == 'e' || it == 'E' }
            if (eIndex < 0) {
                // Java's positional range (1e-3 <= |x| < 1e7) sits strictly
                // inside the JS positional range, so the digits already match —
                // except Java always appends ".0" to integer-valued doubles.
                return if (repr.endsWith(".0")) repr.dropLast(2) else repr
            }

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
            while (digits.length > 1 && digits.endsWith("0")) digits = digits.dropLast(1)

            // pos: value == 0.<digits> * 10^pos
            var pos = exponent + pointOffset
            if (digits.length == 2) {
                shortenToOneDigit(digits, pos, abs(n))?.let { (shortDigits, shortPos) ->
                    digits = shortDigits
                    pos = shortPos
                }
            }
            val k = digits.length

            if (k <= pos && pos <= 21) return sign + digits + "0".repeat(pos - k)
            if (pos in 1..21) return sign + digits.substring(0, pos) + "." + digits.substring(pos)
            if (pos in -5..0) return sign + "0." + "0".repeat(-pos) + digits
            val first = digits.substring(0, 1)
            val rest = digits.substring(1)
            val e = pos - 1
            val expPart = (if (e >= 0) "e+" else "e-") + abs(e).toString()
            return sign + first + (if (rest.isEmpty()) "" else ".$rest") + expPart
        }

        /**
         * Given Java's two-digit rendering `0.<digits> * 10^pos` of [magnitude],
         * returns the one-digit `(digits, pos)` ECMAScript would have chosen, or
         * null when no one-digit decimal round-trips. Only the two neighbours of
         * `digits[0]` can round-trip; ties go to the candidate closest to the
         * exact binary value, compared through [BigDecimal] so the tie-break is
         * not itself decided by double rounding.
         */
        private fun shortenToOneDigit(digits: String, pos: Int, magnitude: Double): Pair<String, Int>? {
            val lead = digits[0] - '0'
            val exact = BigDecimal(magnitude)
            var best: Pair<String, Int>? = null
            var bestDelta: BigDecimal? = null
            for (candidate in intArrayOf(lead, lead + 1)) {
                val (candDigits, candPos) =
                    if (candidate == 10) "1" to (pos + 1) else candidate.toString() to pos
                if (candDigits == "0") continue
                val literal = candDigits + "E" + (candPos - 1)
                if (literal.toDouble() != magnitude) continue
                val delta = BigDecimal(literal).subtract(exact).abs()
                val currentBest = bestDelta
                if (currentBest == null || delta < currentBest) {
                    best = candDigits to candPos
                    bestDelta = delta
                }
            }
            return best
        }
    }
}

/**
 * Recursive-descent `JSON.parse` clone with the strictness that matters to the
 * SSE layer: leading zeros and raw control characters inside strings are
 * REJECTED, so a chunk RN would have skipped in its `try/catch` is skipped here
 * too.
 *
 * Unlike the Swift port, lone-surrogate `\u` escapes are ACCEPTED — `JSON.parse`
 * accepts them and a Kotlin `String` can hold the unpaired surrogate, so there
 * is no divergence to document here.
 */
private class JsonParser(private val text: String) {
    private var index = 0

    val isAtEnd: Boolean
        get() = index >= text.length

    private val current: Char?
        get() = if (index < text.length) text[index] else null

    fun skipWhitespace() {
        while (true) {
            val c = current ?: return
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') index++ else return
        }
    }

    fun parseValue(): JsonValue? {
        skipWhitespace()
        return when (current) {
            null -> null
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> parseString()?.let { JsonValue.Str(it) }
            't' -> if (consumeLiteral("true")) JsonValue.Bool(true) else null
            'f' -> if (consumeLiteral("false")) JsonValue.Bool(false) else null
            'n' -> if (consumeLiteral("null")) JsonValue.Null else null
            else -> parseNumber()
        }
    }

    private fun consumeLiteral(literal: String): Boolean {
        if (index + literal.length > text.length) return false
        if (!text.regionMatches(index, literal, 0, literal.length)) return false
        index += literal.length
        return true
    }

    private fun parseObject(): JsonValue? {
        index++ // {
        val map = LinkedHashMap<String, JsonValue>()
        skipWhitespace()
        if (current == '}') {
            index++
            return JsonValue.Obj(map)
        }
        while (true) {
            skipWhitespace()
            if (current != '"') return null
            val key = parseString() ?: return null
            skipWhitespace()
            if (current != ':') return null
            index++
            val value = parseValue() ?: return null
            map[key] = value
            skipWhitespace()
            when (current) {
                ',' -> index++
                '}' -> {
                    index++
                    return JsonValue.Obj(map)
                }
                else -> return null
            }
        }
    }

    private fun parseArray(): JsonValue? {
        index++ // [
        val values = ArrayList<JsonValue>()
        skipWhitespace()
        if (current == ']') {
            index++
            return JsonValue.Arr(values)
        }
        while (true) {
            values.add(parseValue() ?: return null)
            skipWhitespace()
            when (current) {
                ',' -> index++
                ']' -> {
                    index++
                    return JsonValue.Arr(values)
                }
                else -> return null
            }
        }
    }

    private fun parseString(): String? {
        index++ // opening quote
        val out = StringBuilder()
        while (true) {
            val c = current ?: return null
            index++
            if (c == '"') return out.toString()
            // JSON.parse throws on raw (unescaped) U+0000-U+001F inside strings.
            if (c.code < 0x20) return null
            if (c != '\\') {
                out.append(c)
                continue
            }
            val esc = current ?: return null
            index++
            when (esc) {
                '"' -> out.append('"')
                '\\' -> out.append('\\')
                '/' -> out.append('/')
                'b' -> out.append('\u0008')
                'f' -> out.append('\u000C')
                'n' -> out.append('\n')
                'r' -> out.append('\r')
                't' -> out.append('\t')
                'u' -> out.append(Char(parseHex4() ?: return null))
                else -> return null
            }
        }
    }

    private fun parseHex4(): Int? {
        if (index + 4 > text.length) return null
        var value = 0
        for (unused in 0 until 4) {
            val d = when (val c = text[index]) {
                in '0'..'9' -> c - '0'
                in 'a'..'f' -> c - 'a' + 10
                in 'A'..'F' -> c - 'A' + 10
                else -> return null
            }
            value = value * 16 + d
            index++
        }
        return value
    }

    private fun parseNumber(): JsonValue? {
        val start = index
        if (current == '-') index++
        // JSON.parse rejects leading zeros: the integer part is exactly "0" or
        // [1-9][0-9]*. "01" must fail so the SSE layer skips the chunk exactly
        // where RN's try/catch around JSON.parse does.
        var sawDigit = false
        if (current == '0') {
            sawDigit = true
            index++
            current?.let { if (it in '0'..'9') return null }
        } else {
            while (current?.let { it in '0'..'9' } == true) {
                sawDigit = true
                index++
            }
        }
        if (!sawDigit) return null
        if (current == '.') {
            index++
            var sawFrac = false
            while (current?.let { it in '0'..'9' } == true) {
                sawFrac = true
                index++
            }
            if (!sawFrac) return null
        }
        if (current == 'e' || current == 'E') {
            index++
            if (current == '+' || current == '-') index++
            var sawExp = false
            while (current?.let { it in '0'..'9' } == true) {
                sawExp = true
                index++
            }
            if (!sawExp) return null
        }
        return text.substring(start, index).toDoubleOrNull()?.let { JsonValue.Num(it) }
    }
}
