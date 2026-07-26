package dev.appless.openuilang

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The one place the two ports deliberately DISAGREE, pinned from both sides.
 *
 * Kotlin `String` is a UTF-16 code-unit sequence, so it can hold a lone
 * surrogate; Swift `String` cannot and substitutes U+FFFD (the Swift port's
 * KNOWN-DEVIATION #2). Everything below is what this port emits — which is also
 * what the JS oracle emits, byte for byte.
 *
 * The scope of that deviation used to be written as "programs containing an
 * unpaired surrogate escape in a double-quoted string". That is wrong, and this
 * test exists to keep it wrong-proof: a WELL-FORMED astral character plus an
 * ordinary index reaches it with no escape anywhere. `"a😀b"` is four code
 * units, so `s[1]` is the lone high surrogate `\ud83d` — and any astral
 * character in an indexed or `@Sort`ed label lands in the same place.
 *
 * The expectation below is the verbatim output of
 *
 *     node probes/expected-tree.mjs <this program>
 *
 * from `spec/fixtures/generator`. It is NOT a corpus fixture because the Swift
 * `FixtureOracleTests` gate would fail on it; the Swift sibling
 * `LoneSurrogateTests.swift` pins the U+FFFD answer for the same program, so
 * the cross-port difference is recorded on both sides instead of rediscovered.
 */
class LoneSurrogateTest {

    private val program: String =
        "s = \"a\uD83D\uDE00b\"\n" +
            "lab = @Sort([\"b\", s[1], \"a\"])\n" +
            "root = Card([TextContent(\"u1=\" + s[1]), TextContent(\"esc=\\ud800\"), " +
            "KVList([{ label: \"j\", value: lab }])])\n"

    /** Oracle output, verbatim (see the class doc for the command). */
    private val expected: String = """
{
  "root": {
    "component": "Card",
    "statementId": "root",
    "props": {},
    "children": [
      {
        "component": "TextContent",
        "props": {
          "text": "u1=\ud83d"
        }
      },
      {
        "component": "TextContent",
        "props": {
          "text": "esc=\ud800"
        }
      },
      {
        "component": "KVList",
        "props": {
          "rows": [
            {
              "label": "j",
              "value": [
                "a",
                "b",
                "\ud83d"
              ]
            }
          ]
        }
      }
    ]
  },
  "meta": {
    "incomplete": false,
    "unresolved": [],
    "errors": []
  },
  "state": {},
  "runtimeErrors": []
}
""".trimStart()

    private fun schema(): LibrarySchema =
        LibrarySchema.load(File(FixtureCorpus.fixturesRoot, "../contract/genos.schema.json"))

    @Test
    fun astralIndexAndSurrogateEscapeMatchTheOracle() {
        val result = OpenUIParser(schema()).parse(program)
        assertEquals(expected, TreeSerializer.serialize(result))
    }

    /**
     * The mechanism, isolated: indexing an astral character yields a LONE
     * surrogate here, and `TreeSerializer.quote` re-escapes it as `\udXXX`
     * (well-formed `JSON.stringify`, ES2019) rather than letting the UTF-8
     * encoder turn it into `?`.
     */
    @Test
    fun aStringIndexYieldsALoneSurrogate() {
        val s = "a\uD83D\uDE00b"
        assertEquals(4, s.length, "an astral character is TWO UTF-16 code units")
        val unit = JsObjects.getMember(RtValue.Str(s), "1") as RtValue.Str
        assertEquals("\uD83D", unit.value)
        assertEquals("\"\\ud83d\"", TreeSerializer.quote(unit.value))
        // The pair itself still round-trips unescaped.
        assertEquals("\"a\uD83D\uDE00b\"", TreeSerializer.quote(s))
    }
}
