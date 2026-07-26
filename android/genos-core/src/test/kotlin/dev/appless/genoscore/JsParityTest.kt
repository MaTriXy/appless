package dev.appless.genoscore

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * JS-primitive parity: `parseInt`, `slice`, `decodeURIComponent`,
 * `encodeURIComponent`, `JSON.parse` strictness and `JSON.stringify` number
 * formatting. Expected values are differentially verified against node.
 */
class JsParseIntTest {
    @Test
    fun `full StrWhiteSpace set is skipped`() {
        // node: parseInt("\u00A05", 10) === 5 (NBSP is StrWhiteSpace; a
        // ' \t\n\r'-only skip stops at the NBSP and returns NaN).
        assertEquals(5.0, jsParseInt("\u00A05"))
        // U+2028 (LineTerminator), U+FEFF and \v are all skipped too.
        assertEquals(42.0, jsParseInt("\u2028\uFEFF\u000B \t42rest"))
    }

    @Test
    fun `long digit runs saturate through Double like JS`() {
        // node: parseInt("12345678901234567890123", 10) === 1.2345678901234568e+22
        assertEquals(1.2345678901234568e22, jsParseInt("12345678901234567890123"))
        // node: parseInt("9".repeat(400), 10) === Infinity
        assertEquals(Double.POSITIVE_INFINITY, jsParseInt("9".repeat(400)))
        assertEquals(Double.NEGATIVE_INFINITY, jsParseInt("-" + "9".repeat(400)))
    }

    @Test
    fun `NaN and sign handling match parseInt`() {
        assertTrue(jsParseInt("abc").isNaN())
        assertTrue(jsParseInt("").isNaN())
        assertTrue(jsParseInt("   ").isNaN())
        assertEquals(12.0, jsParseInt("+12"))
        assertEquals(-7.0, jsParseInt("-7"))
        assertEquals(12.0, jsParseInt("12ab"))
    }

    @Test
    fun `the JS whitespace set diverges from every JVM notion of whitespace`() {
        // U+0085 NEL is NOT JS whitespace, but Java's UNICODE_CHARACTER_CLASS
        // `\s` accepts it — which is why the ported patterns spell the class
        // out instead of ever reaching for `(?U)`.
        assertTrue(!isJsWhiteSpace('\u0085'))
        assertTrue(Regex("(?U)\\A\\s\\z").matches("\u0085"))
        assertEquals("\u0085x\u0085", jsTrim("\u0085x\u0085"))

        // U+FEFF IS JS whitespace, and NO JVM predicate agrees.
        assertTrue(isJsWhiteSpace('\uFEFF'))
        assertTrue(!'\uFEFF'.isWhitespace())
        assertTrue(!Regex("(?U)\\A\\s\\z").matches("\uFEFF"))

        // U+00A0 IS JS whitespace; java.util.regex's DEFAULT `\s` (ASCII-only)
        // misses it, even though Char.isWhitespace() happens to accept it.
        assertTrue(isJsWhiteSpace('\u00A0'))
        assertTrue(!Regex("\\A\\s\\z").matches("\u00A0"))
        assertEquals("x", jsTrim("\u00A0\uFEFFx\u00A0"))

        // U+2028/U+2029 are LineTerminators in JS, and \v is WhiteSpace.
        assertTrue(isJsWhiteSpace('\u2028'))
        assertTrue(isJsWhiteSpace('\u2029'))
        assertTrue(isJsWhiteSpace('\u000B'))
    }
}

class JsSliceTest {
    @Test
    fun `truncation counts UTF-16 units, and Kotlin String already is UTF-16`() {
        // "e\u0301" is ONE grapheme but TWO UTF-16 units — JS slice(0, 2) keeps
        // both, and so does substring on the JVM.
        assertEquals("e\u0301", jsSliceTo("e\u0301xy", 2))
        assertEquals("abc", jsSliceTo("abc", 500))
        assertEquals(" x", jsSliceFrom("data: x", 5))
        assertEquals("", jsSliceFrom("ab", 5))
    }

    @Test
    fun `slicing through a surrogate pair keeps the lone surrogate like JS`() {
        // node: ("a".repeat(499)+"\u{1F600}zz").slice(0, 500) ends in a lone
        // HIGH surrogate. Kotlin's String is UTF-16 and holds it verbatim —
        // the Swift port has to materialize U+FFFD there instead.
        val s = "a".repeat(499) + "\uD83D\uDE00zz"
        val sliced = jsSliceTo(s, 500)
        assertEquals(500, sliced.length)
        assertEquals('\uD83D', sliced[499])
        assertTrue(Character.isHighSurrogate(sliced[499]))
    }
}

class PercentCodecTest {
    @Test
    fun `malformed escapes return null like the URIError throw`() {
        // node: decodeURIComponent("a%20%") and decodeURIComponent("%ED%A0%80")
        // (a percent-encoded lone surrogate) both throw URIError.
        assertNull(jsDecodeURIComponent("a%20%"))
        assertNull(jsDecodeURIComponent("%ED%A0%80"))
        assertNull(jsDecodeURIComponent("%zz"))
        assertNull(jsDecodeURIComponent("%C3"))
        assertNull(jsDecodeURIComponent("%C0%80")) // overlong
        assertNull(jsDecodeURIComponent("%F5%80%80%80")) // > U+10FFFF lead
        assertEquals("a b", jsDecodeURIComponent("a%20b"))
        assertEquals("café", jsDecodeURIComponent("caf%C3%A9"))
        assertEquals("\uD83D\uDE00", jsDecodeURIComponent("%F0%9F%98%80"))
    }

    @Test
    fun `encodeURIComponent keeps the unreserved set and upper-cases escapes`() {
        assertEquals("ABZaz09-_.!~*'()", jsEncodeURIComponent("ABZaz09-_.!~*'()"))
        assertEquals("a%20b", jsEncodeURIComponent("a b"))
        assertEquals("sushi%2Cplatter", jsEncodeURIComponent("sushi,platter"))
        assertEquals("caf%C3%A9", jsEncodeURIComponent("café"))
        assertEquals("%F0%9F%98%80", jsEncodeURIComponent("\uD83D\uDE00"))
    }
}

/**
 * `JSON.parse` strictness parity for the hand-rolled parser: where `JSON.parse`
 * throws, [JsonValue.parse] must return null so the SSE layer skips the chunk
 * exactly where RN's try/catch does.
 */
class JsonParseStrictnessTest {
    @Test
    fun `leading-zero numbers are rejected like JSON parse`() {
        assertNull(JsonValue.parse("01"))
        assertNull(JsonValue.parse("-01"))
        assertNull(JsonValue.parse("00"))
        assertNull(JsonValue.parse("{\"a\":01}"))
        assertEquals(JsonValue.Num(0.0), JsonValue.parse("0"))
        assertEquals(JsonValue.Num(0.5), JsonValue.parse("0.5"))
        assertEquals(JsonValue.Num(0.0), JsonValue.parse("0e2"))
        assertEquals(JsonValue.Num(10.0), JsonValue.parse("10"))
    }

    @Test
    fun `raw control chars inside strings are rejected like JSON parse`() {
        assertNull(JsonValue.parse("\"a\tb\""))
        assertNull(JsonValue.parse("\"a\u0001b\""))
        assertNull(JsonValue.parse("{\"k\":\"a\nb\"}"))
        // Escaped forms and DEL (U+007F, allowed by JSON.parse) still work.
        assertEquals(JsonValue.Str("a\tb"), JsonValue.parse("\"a\\tb\""))
        assertEquals(JsonValue.Str("a\u007Fb"), JsonValue.parse("\"a\u007Fb\""))
    }

    @Test
    fun `lone-surrogate escapes are ACCEPTED, unlike the Swift port`() {
        // node: JSON.parse('"\\ud800x"') yields a 2-unit string with an
        // unpaired surrogate. A Kotlin String can hold it, so — unlike
        // GenOSCore's Swift JSONValue, which must reject the whole document —
        // this parser matches JS exactly.
        val parsed = JsonValue.parse("\"\\ud800x\"")
        assertEquals(2, parsed?.str?.length)
        assertEquals('\uD800', parsed?.str?.get(0))
        assertEquals(JsonValue.Str("\uD83D\uDE00"), JsonValue.parse("\"\\ud83d\\ude00\""))
    }

    @Test
    fun `structural malformations are rejected`() {
        assertNull(JsonValue.parse(""))
        assertNull(JsonValue.parse("{"))
        assertNull(JsonValue.parse("{\"a\":1,}"))
        assertNull(JsonValue.parse("[1,]"))
        assertNull(JsonValue.parse("{'a':1}"))
        assertNull(JsonValue.parse("nul"))
        assertNull(JsonValue.parse("1 2"))
        assertNull(JsonValue.parse("1.")) // no fraction digits
        assertNull(JsonValue.parse("1e")) // no exponent digits
        assertNull(JsonValue.parse("\"unterminated"))
        assertNull(JsonValue.parse("\"bad \\x escape\""))
    }

    @Test
    fun `parsed object keys keep document order like JS`() {
        val parsed = JsonValue.parse("{\"zeta\":1,\"alpha\":2,\"mid\":3}")
        assertEquals(listOf("zeta", "alpha", "mid"), parsed?.obj?.keys?.toList())
    }

    @Test
    fun `accessors and JS truthiness`() {
        val v = JsonValue.parse("{\"a\":[1,\"x\",true,null],\"b\":{}}")!!
        assertEquals(1.0, v["a"]?.get(0)?.num)
        assertEquals("x", v["a"]?.get(1)?.str)
        assertEquals(true, v["a"]?.get(2)?.bool)
        assertNull(v["a"]?.get(9))
        assertNull(v["missing"])
        assertTrue(v["b"]!!.isJsTruthy) // an EMPTY object is truthy in JS
        assertTrue(JsonValue.Arr(emptyList()).isJsTruthy)
        assertTrue(!JsonValue.Str("").isJsTruthy)
        assertTrue(!JsonValue.Num(0.0).isJsTruthy)
        assertTrue(!JsonValue.Num(Double.NaN).isJsTruthy)
        assertTrue(!JsonValue.Bool(false).isJsTruthy)
        assertTrue(!JsonValue.Null.isJsTruthy)
    }
}

/**
 * `JSON.stringify` number formatting is ECMAScript `Number::toString`, whose
 * positional/exponential thresholds and exponent spelling differ from Java's
 * `Double.toString` (JS writes `10000000000000000` / `0.00001` / `1e-7` where
 * Java writes `1.0E16` / `1.0E-5` / `1.0E-7`). Expectations below are node
 * `JSON.stringify` outputs.
 */
class JsonStringifyNumberTest {
    @Test
    fun `numberString matches JSON stringify`() {
        val cases = listOf(
            1e16 to "10000000000000000",
            9007199254740994.0 to "9007199254740994",
            -1e17 to "-100000000000000000",
            1e-5 to "0.00001",
            1e-6 to "0.000001",
            1e-7 to "1e-7",
            -1e-7 to "-1e-7",
            1e-10 to "1e-10",
            1e20 to "100000000000000000000",
            1e21 to "1e+21",
            -0.0 to "0",
            0.1 to "0.1",
            (0.1 + 0.2) to "0.30000000000000004",
            1.7976931348623157e308 to "1.7976931348623157e+308",
            Math.pow(2.0, 56.0) to "72057594037927940",
            Math.pow(2.0, 53.0) to "9007199254740992",
            -9007199254740994.0 to "-9007199254740994",
            (1.0 / 3.0) to "0.3333333333333333",
            -0.5 to "-0.5",
            3072.0 to "3072",
            0.8 to "0.8",
        )
        for ((input, expected) in cases) {
            assertEquals(expected, JsonValue.numberString(input), "numberString($input)")
        }
        // JSON.stringify emits null for non-finite numbers.
        assertEquals("null", JsonValue.numberString(Double.NaN))
        assertEquals("null", JsonValue.numberString(Double.POSITIVE_INFINITY))
    }

    @Test
    fun `Java's two-significant-digit floor is undone for MIN_VALUE`() {
        // Double.toString(4.9E-324) is "4.9E-324" (Java floors the digit count
        // at two); node String(5e-324) is "5e-324". The one-digit re-test is
        // the only place the two specs disagree.
        assertEquals("4.9E-324", java.lang.Double.toString(Double.MIN_VALUE))
        assertEquals("5e-324", JsonValue.numberString(Double.MIN_VALUE))
        assertEquals("-5e-324", JsonValue.numberString(-Double.MIN_VALUE))
        // A genuine two-digit shortest form must NOT be shortened.
        assertEquals("1.5e-323", JsonValue.numberString(1.5e-323))
    }

    /**
     * Pins the RAW serialized bytes — key ordering AND number formatting —
     * rather than laundering them through a re-parse the way every other body
     * assertion does.
     */
    @Test
    fun `stringified emits exact bytes in insertion order`() {
        val body = JsonValue.obj(
            "model" to JsonValue.Str("gemma-4-31b"),
            "temperature" to JsonValue.Num(0.8),
            "max_completion_tokens" to JsonValue.Num(3072.0),
            "stream" to JsonValue.Bool(true),
        )
        assertEquals(
            "{\"model\":\"gemma-4-31b\",\"temperature\":0.8," +
                "\"max_completion_tokens\":3072,\"stream\":true}",
            body.stringified(),
        )
        val form = listOf(
            "zeta" to JsonValue.Num(1e16),
            "alpha" to JsonValue.Num(1e-7),
            "nested" to JsonValue.obj(
                "b" to JsonValue.Num(-0.0),
                "a" to JsonValue.Arr(listOf(JsonValue.Num(1.0), JsonValue.Null)),
            ),
        )
        assertEquals(
            "{\"zeta\":10000000000000000,\"alpha\":1e-7,\"nested\":{\"b\":0,\"a\":[1,null]}}",
            JsonValue.stringifyOrdered(form),
        )
    }

    @Test
    fun `canonical array-index keys sort numerically before the rest`() {
        // node: JSON.stringify({"b":1,"10":2,"2":3,"4294967295":4,"01":5})
        // === '{"2":3,"10":2,"b":1,"4294967295":4,"01":5}'
        val v = JsonValue.obj(
            "b" to JsonValue.Num(1.0),
            "10" to JsonValue.Num(2.0),
            "2" to JsonValue.Num(3.0),
            "4294967295" to JsonValue.Num(4.0),
            "01" to JsonValue.Num(5.0),
        )
        assertEquals("{\"2\":3,\"10\":2,\"b\":1,\"4294967295\":4,\"01\":5}", v.stringified())
        assertEquals(0L, JsonValue.canonicalArrayIndex("0"))
        assertEquals(4294967294L, JsonValue.canonicalArrayIndex("4294967294"))
        assertEquals(-1L, JsonValue.canonicalArrayIndex("4294967295"))
        assertEquals(-1L, JsonValue.canonicalArrayIndex("01"))
        assertEquals(-1L, JsonValue.canonicalArrayIndex(""))
        assertEquals(-1L, JsonValue.canonicalArrayIndex("-0"))
    }

    /**
     * `JSON.stringify` uses the two-character shortcuts, `\uXXXX` for the
     * remaining C0 controls, leaves "/" and U+007F DEL raw, and does NOT escape
     * U+2028/U+2029 (a classic port bug: some serializers do).
     */
    @Test
    fun `encodeJsonString matches JSON stringify bytes`() {
        val cases = listOf(
            "plain" to "\"plain\"",
            "quote\" back\\slash" to "\"quote\\\" back\\\\slash\"",
            "tab\tnewline\ncr\r" to "\"tab\\tnewline\\ncr\\r\"",
            "form\u000Cback\u0008" to "\"form\\fback\\b\"",
            "ctrl\u0001\u001F" to "\"ctrl\\u0001\\u001f\"",
            "slash/and\u007Fdel" to "\"slash/and\u007Fdel\"",
            "line\u2028para\u2029" to "\"line\u2028para\u2029\"",
            "astral\uD83C\uDF27end" to "\"astral\uD83C\uDF27end\"",
            "nbsp\u00A0bom\uFEFF" to "\"nbsp\u00A0bom\uFEFF\"",
            "combining e\u0301" to "\"combining e\u0301\"",
        )
        for ((input, expected) in cases) {
            assertEquals(
                expected.toByteArray(Charsets.UTF_8).toList(),
                JsonValue.encodeJsonString(input).toByteArray(Charsets.UTF_8).toList(),
                "encodeJsonString($input)",
            )
        }
    }

    /**
     * `jsStringCoerce` is JS `String(value)` / `"" + value`, NOT
     * `JSON.stringify`. It used to return JSON text for arrays and objects, and
     * this very test asserted `"[1,2]"` under the name "matches String() for
     * every JSON shape" — while `String([1,2])` is `"1,2"`. Both READMEs
     * excused it with "the only call site is args.query, where a non-string
     * never survives the non-empty check", which is false: "1,2" is non-empty,
     * so a model-supplied array `query` reached the Exa request body with
     * different bytes in each runtime.
     *
     * Table generated by `node gen-tostring.mjs` (JSON document →
     * `String(JSON.parse(doc))`); see the Swift sibling's `JSToStringTests`.
     */
    @Test
    fun `jsStringCoerce matches node String() for every JSON shape`() {
        val table = listOf(
            // A top-level null is "" rather than String(null) === "null":
            // every call site fuses the `?? ""` / truthiness guard.
            "null" to "",
            "\"hi\"" to "hi", "\"\"" to "",
            "3072" to "3072", "1e-7" to "1e-7", "0" to "0", "-0" to "0",
            "1e21" to "1e+21", "1e999" to "Infinity", "-1e999" to "-Infinity",
            "3.5" to "3.5", "-2.5" to "-2.5",
            "9007199254740993" to "9007199254740992",
            "true" to "true", "false" to "false",
            "[1,2]" to "1,2", "[]" to "", "[null]" to "",
            "[\"a\",\"b\"]" to "a,b", "[[1],[2]]" to "1,2", "[1,[2,[3]]]" to "1,2,3",
            "[[]]" to "", "[{\"a\":1}]" to "[object Object]",
            "[null,null]" to ",", "[\"\",\"\"]" to ",", "[true,false]" to "true,false",
            "[1e999]" to "Infinity", "[-0]" to "0",
            "{\"a\":1}" to "[object Object]", "{}" to "[object Object]",
        )
        for ((doc, expected) in table) {
            val parsed = JsonValue.parse(doc)
            assertNotNull(parsed, "fixture $doc failed to parse")
            assertEquals(expected, jsStringCoerce(parsed), "String($doc)")
        }
        assertEquals("", jsStringCoerce(null))
    }

    /**
     * The path ToString takes that `JSON.stringify` does not: non-finite
     * numbers. `numberString` renders them "null" (correct for a request body);
     * ToString must not.
     *
     *     $ node -e 'console.log(String(1/0), String(-1/0), String(0/0))'
     *     Infinity -Infinity NaN
     */
    @Test
    fun `non-finite numbers stringify differently from JSON stringify`() {
        assertEquals("Infinity", jsNumberToString(Double.POSITIVE_INFINITY))
        assertEquals("-Infinity", jsNumberToString(Double.NEGATIVE_INFINITY))
        assertEquals("NaN", jsNumberToString(Double.NaN))
        assertEquals("null", JsonValue.numberString(Double.POSITIVE_INFINITY))
        assertEquals("null", JsonValue.numberString(Double.NaN))
        // Reachable: JSON.parse("1e999") is Infinity, not an error.
        assertEquals(Double.POSITIVE_INFINITY, JsonValue.parse("1e999")?.num)
        assertEquals("Infinity", jsStringCoerce(JsonValue.parse("1e999")))
    }
}
