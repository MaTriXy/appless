package dev.appless.openuilang

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The CLDR-root ASCII collation table (`StringJs.jsAsciiLocaleCompare`) against
 * V8 itself.
 *
 * Both READMEs used to claim "235,233 ordered pairs vs V8 localeCompare — zero
 * mismatches" from a sweep that was never committed. This is the committed
 * replacement: `spec/fixtures/generator/probes/collation-corpus.json` records
 * `Math.sign(a.localeCompare(b))` for every pair of a deterministic 700-string
 * corpus drawn from the full 0x00-0x7F alphabet, and is regenerable with
 *
 *     node probes/verify-collation.mjs --emit
 *
 * The Swift sibling (`ASCIICollationTests.swift`) asserts against the SAME
 * file, so the two hand-compiled weight tables are gated against V8 and — as a
 * consequence — against each other. `probes/verify-collation.mjs` (no flags)
 * drives V8 plus both suites in one command and is wired into
 * `.github/workflows/differential-fuzz.yml`.
 */
class AsciiCollationTest {

    private data class Corpus(val strings: List<String>, val signs: String, val pairCount: Int)

    private fun load(): Corpus {
        val file = File(FixtureCorpus.fixturesRoot, "generator/probes/collation-corpus.json")
        assertTrue(file.isFile, "missing ${file.path} — run `node probes/verify-collation.mjs --emit`")
        val doc = JsonValue.parse(file.readText()) as JsonValue.Obj
        val strings = (doc["strings"] as JsonValue.Arr).value.map { (it as JsonValue.Str).value }
        val signs = (doc["signs"] as JsonValue.Str).value
        val pairCount = (doc["pairCount"] as JsonValue.Num).value.toInt()
        return Corpus(strings, signs, pairCount)
    }

    @Test
    fun everyAsciiPairMatchesV8() {
        val (strings, signs, pairCount) = load()
        assertEquals(strings.size * (strings.size - 1) / 2, pairCount, "corpus pairCount")
        assertEquals(pairCount, signs.length, "one sign per pair")

        var k = 0
        var mismatches = 0
        val examples = StringBuilder()
        for (i in strings.indices) {
            for (j in i + 1 until strings.size) {
                val expected = signs[k++]
                val got = jsAsciiLocaleCompare(strings[i], strings[j])
                    ?: error("ASCII pair answered null: ${strings[i]} / ${strings[j]}")
                val gotSign = if (got < 0) '<' else if (got > 0) '>' else '='
                if (gotSign != expected) {
                    mismatches++
                    if (mismatches <= 5) {
                        examples.append(
                            "\n  ${quote(strings[i])} vs ${quote(strings[j])}: " +
                                "V8 $expected, port $gotSign"
                        )
                    }
                }
            }
        }
        assertEquals(0, mismatches, "collation mismatches vs V8 over $pairCount pairs:$examples")
    }

    /**
     * The comparator must be a strict weak ordering on THIS alphabet: the ports
     * hand it to `sortedWith` / `sorted(by:)`, and an inconsistent comparator
     * there is the whole reason `@Sort` over MIXED numeric/non-numeric strings
     * is a documented deviation. Spot-checked over the pinned adversarial
     * prefix, where the interesting shapes live (hyphen, space, case, digits).
     */
    @Test
    fun comparatorIsAntisymmetricAndTransitive() {
        val strings = load().strings.take(70)
        for (a in strings) {
            for (b in strings) {
                val ab = jsAsciiLocaleCompare(a, b)!!
                val ba = jsAsciiLocaleCompare(b, a)!!
                assertEquals(0, Integer.signum(ab) + Integer.signum(ba), "antisymmetry: $a / $b")
            }
        }
        for (a in strings) {
            for (b in strings) {
                if (jsAsciiLocaleCompare(a, b)!! > 0) continue
                for (c in strings) {
                    if (jsAsciiLocaleCompare(b, c)!! > 0) continue
                    assertTrue(
                        jsAsciiLocaleCompare(a, c)!! <= 0,
                        "transitivity: ${quote(a)} <= ${quote(b)} <= ${quote(c)}",
                    )
                }
            }
        }
    }

    private fun quote(s: String): String = TreeSerializer.quote(s)
}
