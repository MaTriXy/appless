package dev.appless.openuilang

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pins [JS_WHITESPACE] — the hand-typed ECMAScript *WhiteSpace* ∪
 * *LineTerminator* set in `Preprocess.kt` — against node's own answer, scalar
 * by scalar.
 *
 * Why this test exists: the set is a hand-written literal, and NOTHING in the
 * fixture corpus would notice a single wrong member. No fixture pads a
 * statement with U+205F or U+1680, so dropping either (or adding U+0085, which
 * is what `Character.isWhitespace`-adjacent APIs and `\s` with
 * `UNICODE_CHARACTER_CLASS` would give you) still parses all 90 fixtures
 * byte-identically. The sweep below is therefore EXHAUSTIVE over the BMP
 * rather than spot-checked.
 *
 * ORACLE (node v22.22.2), the command that produced [NODE_WHITESPACE] and
 * proved trim's set and `Number()`'s *StrWhiteSpace* set are identical:
 *
 * ```
 * node -e '
 *   const trimWs = [], numWs = [];
 *   for (let u = 0; u < 0x10000; u++) {
 *     const c = String.fromCharCode(u);
 *     if ((c + "x" + c).trim() === "x") trimWs.push(u);
 *     if (Number(c) === 0 && Number(c + "5" + c) === 5) numWs.push(u);
 *   }
 *   console.log(trimWs.length, JSON.stringify(trimWs) === JSON.stringify(numWs));
 *   console.log(trimWs.map((u) => u.toString(16).toUpperCase().padStart(4, "0")).join(","));
 * '
 * # 25 true
 * # 0009,000A,000B,000C,000D,0020,00A0,1680,2000,2001,2002,2003,2004,2005,
 * # 2006,2007,2008,2009,200A,2028,2029,202F,205F,3000,FEFF
 * ```
 *
 * Mirrors `ios/Packages/OpenUILang/Tests/OpenUILangTests/WhitespaceSemanticsTests.swift`
 * (which spot-checks the same 25 scalars plus the near-miss list).
 */
class WhitespaceSemanticsTest {

    private companion object {
        /** Verbatim output of the node sweep above. */
        val NODE_WHITESPACE: Set<Char> = (
            "0009,000A,000B,000C,000D,0020,00A0,1680,2000,2001,2002,2003,2004,2005," +
                "2006,2007,2008,2009,200A,2028,2029,202F,205F,3000,FEFF"
            )
            .split(",")
            .map { it.toInt(16).toChar() }
            .toHashSet()

        /**
         * Scalars that LOOK like whitespace to one JVM API or another but are
         * not JS whitespace: NEL (`\s` with `UNICODE_CHARACTER_CLASS`), ZWSP,
         * MONGOLIAN VOWEL SEPARATOR, and the file/group/record/unit separators
         * that `Character.isWhitespace` accepts.
         */
        val NEAR_MISSES: List<Char> = listOf(
            '\u0085', '\u200B', '\u180E', '\u001C', '\u001D', '\u001E', '\u001F',
        )
    }

    /**
     * The hand-typed set IS node's set — not a subset, not a superset.
     * Exhaustive over the BMP, so one wrong literal fails here.
     */
    @Test
    fun jsWhitespaceSetMatchesNodeExactly() {
        assertEquals(25, NODE_WHITESPACE.size, "oracle table transcribed wrong")
        assertEquals(NODE_WHITESPACE, JS_WHITESPACE)
        for (code in 0..0xFFFF) {
            val c = code.toChar()
            assertEquals(
                NODE_WHITESPACE.contains(c),
                isJsWhitespace(c),
                "U+%04X".format(code),
            )
        }
    }

    /** Every member is stripped from both ends by [jsTrim], like JS `trim()`. */
    @Test
    fun trimStripsExactlyTheJsSet() {
        for (c in NODE_WHITESPACE) {
            val ws = c.toString()
            assertEquals("x", (ws + "x" + ws).jsTrim(), "U+%04X".format(c.code))
        }
        for (c in NEAR_MISSES) {
            val padded = c.toString() + "x" + c.toString()
            assertEquals(padded, padded.jsTrim(), "U+%04X must survive trim".format(c.code))
        }
    }

    /** [jsTrimEnd] strips the same set, and only from the end. */
    @Test
    fun trimEndStripsExactlyTheJsSet() {
        for (c in NODE_WHITESPACE) {
            assertEquals("x", ("x" + c).jsTrimEnd(), "U+%04X".format(c.code))
        }
        for (c in NEAR_MISSES) {
            val s = "x$c"
            assertEquals(s, s.jsTrimEnd(), "U+%04X must survive trimEnd".format(c.code))
        }
        // A non-whitespace tail shields inner whitespace, like JS trimEnd.
        assertEquals("x \u3000y", "x \u3000y".jsTrimEnd())
    }

    /**
     * `Number(string)`'s *StrWhiteSpace* is the SAME set (proved identical by
     * the node sweep above): every member is valid padding and a
     * whitespace-only string coerces to 0, while a near-miss poisons the
     * literal to NaN.
     */
    @Test
    fun numberCoercionUsesExactStrWhiteSpace() {
        for (c in NODE_WHITESPACE) {
            val ws = c.toString()
            assertEquals(5.0, jsStringToNumber(ws + "5" + ws), "U+%04X".format(c.code))
            assertEquals(0.0, jsStringToNumber(ws), "U+%04X".format(c.code))
        }
        for (c in NEAR_MISSES) {
            val ws = c.toString()
            assertTrue(jsStringToNumber(ws + "5").isNaN(), "U+%04X leading".format(c.code))
            assertTrue(jsStringToNumber("5$ws").isNaN(), "U+%04X trailing".format(c.code))
            assertTrue(jsStringToNumber(ws).isNaN(), "U+%04X alone".format(c.code))
        }
    }
}
