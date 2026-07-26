package dev.appless.genoscore

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The SAME cases the Swift suite pins, so the two ports cannot drift apart.
 *
 * Findings 1-3 of the three-way audit were Swift-only divergences that this
 * port already got right; they are pinned here anyway, because "already right"
 * is exactly the state a future refactor breaks silently. Findings 4-6 changed
 * BOTH ports.
 *
 * Every expectation was verified against node running the verbatim RN
 * expression (see the comment above each one).
 */
class ThreeWayParityTest {

    // FINDING 1: JSON.stringify preserves insertion order at EVERY depth, and
    // promotes canonical array-index keys numerically. Form state is three
    // levels deep, so the Swift port's top-level-only ordering alphabetized
    // every submitted form.
    @Test
    fun `insertion order is preserved at every depth`() {
        // node: JSON.stringify({signup:{email:{value:"a@b.c",componentType:"TextField"},
        //                               age:{value:30,componentType:"Slider"}}})
        val formState = listOf(
            "signup" to JsonValue.obj(
                "email" to JsonValue.obj(
                    "value" to JsonValue.Str("a@b.c"),
                    "componentType" to JsonValue.Str("TextField"),
                ),
                "age" to JsonValue.obj(
                    "value" to JsonValue.Num(30.0),
                    "componentType" to JsonValue.Str("Slider"),
                ),
            ),
        )
        assertEquals(
            "{\"signup\":{\"email\":{\"value\":\"a@b.c\",\"componentType\":\"TextField\"}," +
                "\"age\":{\"value\":30,\"componentType\":\"Slider\"}}}",
            JsonValue.stringifyOrdered(formState),
        )

        // Four levels, every one REVERSE-alphabetical, so a sort anywhere in
        // the recursion is visible - the path the fix does not naturally take.
        val deep = listOf(
            "z" to JsonValue.obj(
                "y" to JsonValue.obj(
                    "x" to JsonValue.obj("w" to JsonValue.Num(1.0), "a" to JsonValue.Num(2.0)),
                    "a" to JsonValue.Num(3.0),
                ),
            ),
            "a" to JsonValue.Num(4.0),
        )
        assertEquals(
            "{\"z\":{\"y\":{\"x\":{\"w\":1,\"a\":2},\"a\":3}},\"a\":4}",
            JsonValue.stringifyOrdered(deep),
        )

        // Objects nested inside ARRAYS recurse through the same path.
        val inArray = JsonValue.obj(
            "items" to JsonValue.Arr(
                listOf(JsonValue.obj("b" to JsonValue.Num(1.0), "a" to JsonValue.Num(2.0))),
            ),
        )
        assertEquals("{\"items\":[{\"b\":1,\"a\":2}]}", inArray.stringified())
    }

    @Test
    fun `canonical array-index keys sort numerically first at depth`() {
        // node: JSON.stringify({f:{"10":1,"2":2,"b":3}}) === '{"f":{"2":2,"10":1,"b":3}}'
        val nested = listOf(
            "f" to JsonValue.obj(
                "10" to JsonValue.Num(1.0),
                "2" to JsonValue.Num(2.0),
                "b" to JsonValue.Num(3.0),
            ),
        )
        assertEquals("{\"f\":{\"2\":2,\"10\":1,\"b\":3}}", JsonValue.stringifyOrdered(nested))

        // NON-canonical numeric-looking keys are NOT array indices and stay in
        // insertion order among the rest. node:
        // JSON.stringify({"01":1,"1.0":2,"+1":3,"-1":4,"1e2":5,
        //                 "4294967295":6,"4294967294":7,"1":8})
        // === '{"1":8,"4294967294":7,"01":1,"1.0":2,"+1":3,"-1":4,"1e2":5,"4294967295":6}'
        val tricky = JsonValue.obj(
            "01" to JsonValue.Num(1.0),
            "1.0" to JsonValue.Num(2.0),
            "+1" to JsonValue.Num(3.0),
            "-1" to JsonValue.Num(4.0),
            "1e2" to JsonValue.Num(5.0),
            "4294967295" to JsonValue.Num(6.0), // 2^32-1: one PAST the last index
            "4294967294" to JsonValue.Num(7.0), // 2^32-2: the LAST array index
            "1" to JsonValue.Num(8.0),
        )
        assertEquals(
            "{\"1\":8,\"4294967294\":7,\"01\":1,\"1.0\":2,\"+1\":3," +
                "\"-1\":4,\"1e2\":5,\"4294967295\":6}",
            tricky.stringified(),
        )

        // node: JSON.stringify({"":1,"0":2,"b":3}) === '{"0":2,"":1,"b":3}'
        assertEquals(
            "{\"0\":2,\"\":1,\"b\":3}",
            JsonValue.obj(
                "" to JsonValue.Num(1.0),
                "0" to JsonValue.Num(2.0),
                "b" to JsonValue.Num(3.0),
            ).stringified(),
        )
    }

    @Test
    fun `re-assignment keeps the original key position and parse keeps document order`() {
        // JS: o.a=1; o.b=2; o.a=3 still emits "a" first, with the LAST value.
        assertEquals(
            "{\"a\":3,\"b\":2}",
            JsonValue.stringifyOrdered(
                listOf(
                    "a" to JsonValue.Num(1.0),
                    "b" to JsonValue.Num(2.0),
                    "a" to JsonValue.Num(3.0),
                ),
            ),
        )
        // node: JSON.stringify(JSON.parse('{"z":1,"a":{"y":2,"b":3}}')) round-trips verbatim.
        assertEquals(
            "{\"z\":1,\"a\":{\"y\":2,\"b\":3}}",
            JsonValue.parse("{\"z\":1,\"a\":{\"y\":2,\"b\":3}}")!!.stringified(),
        )
    }

    // FINDING 3: a decoded BOM must survive at EVERY position. Foundation's
    // removingPercentEncoding swallowed a LEADING one in the Swift port while
    // keeping a mid-string one, a position-dependent character loss.
    @Test
    fun `a decoded BOM survives at every position`() {
        // node: decodeURIComponent("%EF%BB%BF").length === 1
        assertEquals("\uFEFF", jsDecodeURIComponent("%EF%BB%BF"))
        assertEquals("\uFEFFa", jsDecodeURIComponent("%EF%BB%BFa"))
        assertEquals("a\uFEFFb", jsDecodeURIComponent("a%EF%BB%BFb"))
        assertEquals("\uFEFF\uFEFF", jsDecodeURIComponent("%EF%BB%BF%EF%BB%BF"))
    }

    @Test
    fun `hand-rolled Decode matches the spec acceptance and rejection sets`() {
        // Accepted (node).
        assertEquals("\u0000", jsDecodeURIComponent("%00"))
        assertEquals("\u007F", jsDecodeURIComponent("%7F"))
        assertEquals("😀", jsDecodeURIComponent("%F0%9F%98%80"))
        assertEquals("plain-☃", jsDecodeURIComponent("plain-☃"))
        assertEquals("", jsDecodeURIComponent(""))
        // Rejected: node throws URIError on every one of these.
        assertNull(jsDecodeURIComponent("%C0%80")) // overlong 2-byte
        assertNull(jsDecodeURIComponent("%E0%80%80")) // overlong 3-byte
        assertNull(jsDecodeURIComponent("%F0%80%80%80")) // overlong 4-byte
        assertNull(jsDecodeURIComponent("%F4%90%80%80")) // > U+10FFFF
        assertNull(jsDecodeURIComponent("%80")) // stray continuation
        assertNull(jsDecodeURIComponent("%FF")) // invalid lead
        assertNull(jsDecodeURIComponent("%C2")) // truncated sequence
        assertNull(jsDecodeURIComponent("%C2%41")) // bad continuation byte
        assertNull(jsDecodeURIComponent("%GG")) // non-hex
        assertNull(jsDecodeURIComponent("%2")) // dangling
    }

    // FINDING 5: JS Math.round semantics + clamping. This port used to throw on
    // NaN and saturate silently; the Swift port trapped AND broke ties away
    // from zero.
    @Test
    fun `Math round ties go toward positive infinity, not away from zero`() {
        // node: Math.round(x) for each input.
        val cases = listOf(
            0.5 to 1.0,
            -0.5 to -0.0,
            1.5 to 2.0,
            -1.5 to -1.0,
            2.5 to 3.0,
            -2.5 to -2.0,
            4.5 to 5.0,
            -4.5 to -4.0,
            -0.4 to -0.0,
            0.4 to 0.0,
            -1.6 to -2.0,
            2.4 to 2.0,
            0.0 to 0.0,
            -0.0 to -0.0,
            // floor(x + 0.5) answers 1 here because the ADDITION rounds up;
            // node's Math.round answers 0.
            0.49999999999999994 to 0.0,
            -0.49999999999999994 to -0.0,
            // Already-integral doubles beyond 2^52 pass straight through.
            9_007_199_254_740_993.0 to 9_007_199_254_740_992.0,
            1e300 to 1e300,
        )
        for ((input, expected) in cases) {
            assertEquals(expected, jsMathRound(input), "jsMathRound($input)")
        }
        assertTrue(jsMathRound(Double.NaN).isNaN())
        assertEquals(Double.POSITIVE_INFINITY, jsMathRound(Double.POSITIVE_INFINITY))
        assertEquals(Double.NEGATIVE_INFINITY, jsMathRound(Double.NEGATIVE_INFINITY))
        // node: Object.is(Math.round(-0.5), -0) === true.
        assertTrue(1.0 / jsMathRound(-0.5) < 0)
    }

    @Test
    fun `narrowing to Int clamps instead of throwing or trapping`() {
        assertEquals(1234, jsRoundToInt(1234.4))
        assertEquals(0, jsRoundToInt(-0.5))
        assertEquals(-2, jsRoundToInt(-2.5))
        assertEquals(3, jsRoundToInt(2.5))
        // roundToInt() THREW IllegalArgumentException on NaN; Swift's Int(_:)
        // trapped on all four of these.
        assertEquals(0, jsRoundToInt(Double.NaN))
        assertEquals(Int.MAX_VALUE, jsRoundToInt(Double.POSITIVE_INFINITY))
        assertEquals(Int.MIN_VALUE, jsRoundToInt(Double.NEGATIVE_INFINITY))
        assertEquals(Int.MAX_VALUE, jsRoundToInt(1e30))
        assertEquals(Int.MIN_VALUE, jsRoundToInt(-1e30))
        assertEquals(Int.MAX_VALUE, jsRoundToInt(Int.MAX_VALUE.toDouble()))
        assertEquals(Int.MIN_VALUE, jsRoundToInt(Int.MIN_VALUE.toDouble()))
        assertEquals(Int.MAX_VALUE - 1, jsRoundToInt((Int.MAX_VALUE - 1).toDouble()))
    }

    // FINDING 4: charAt(0) takes a UTF-16 CODE UNIT, so an astral first
    // character has no case mapping and is left alone.
    @Test
    fun `capitalizing the first character follows UTF-16 charAt`() {
        // node: "\u{10428}eseret".charAt(0).toUpperCase() + "\u{10428}eseret".slice(1)
        //       === "\u{10428}eseret"   (NOT the U+10400 uppercase form)
        assertEquals("𐐨eseret", jsCapitalizeFirst("𐐨eseret"))
        assertEquals("😀app", jsCapitalizeFirst("😀app"))
        // The BMP path the fix must not break.
        assertEquals("Stocks", jsCapitalizeFirst("stocks"))
        assertEquals("", jsCapitalizeFirst(""))
        assertEquals("A", jsCapitalizeFirst("a"))
        assertEquals("A", jsCapitalizeFirst("A"))
        assertEquals("1up", jsCapitalizeFirst("1up"))
        // node: "écho".charAt(0).toUpperCase() + slice(1) === "Écho"
        assertEquals("Écho", jsCapitalizeFirst("écho"))
        // One code unit can uppercase to SEVERAL, in JS and on the JVM alike.
        // node: "ßeta".charAt(0).toUpperCase() + slice(1) === "SSeta"
        assertEquals("SSeta", jsCapitalizeFirst("ßeta"))
        // node: "ﬁle".charAt(0).toUpperCase() + slice(1) === "FIle"
        assertEquals("FIle", jsCapitalizeFirst("ﬁle"))
    }

    // FINDING 6: the bare message, never a fully-qualified class prefix (and
    // never Swift's type-and-case description).
    @Test
    fun `a bare message is extracted without class decoration`() {
        assertEquals("boom", jsErrorMessage(StreamException("boom")))
        assertEquals(
            "network unreachable",
            jsErrorMessage(IllegalStateException("network unreachable")),
        )
        // toString() would have said "java.lang.IllegalStateException: x".
        assertTrue(!jsErrorMessage(IllegalStateException("x")).contains("java.lang"))
        // No message to carry: the SIMPLE class name, never the qualified one.
        assertEquals("IllegalStateException", jsErrorMessage(IllegalStateException()))
        assertTrue(!jsErrorMessage(IllegalStateException()).contains("."))
    }
}
