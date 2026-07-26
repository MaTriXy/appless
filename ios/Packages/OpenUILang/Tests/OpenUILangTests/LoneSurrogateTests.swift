import Foundation
import Testing

@testable import OpenUILang

/// The one place the two ports deliberately DISAGREE, pinned from both sides.
///
/// Swift `String` cannot hold a lone UTF-16 surrogate, so this port substitutes
/// U+FFFD (KNOWN-DEVIATION #2). Kotlin `String` CAN, so the Kotlin port matches
/// the JS oracle byte for byte — its `LoneSurrogateTest.kt` pins that answer for
/// the SAME program, so the difference is recorded on both sides rather than
/// rediscovered.
///
/// The scope of the deviation used to be written as "programs containing an
/// unpaired surrogate escape in a double-quoted string". That is wrong, and this
/// test exists to keep it wrong-proof: a WELL-FORMED astral character plus an
/// ordinary index reaches it with no escape anywhere. `"a😀b"` is four UTF-16
/// code units, so `s[1]` is the lone high surrogate `\ud83d` — and any astral
/// character in an indexed or `@Sort`ed label lands in the same place.
///
/// Regenerate the oracle side with, from `spec/fixtures/generator`:
///
///     node probes/expected-tree.mjs <this program>
///
/// It is NOT a corpus fixture: `FixtureOracleTests` compares against the oracle
/// and this port cannot match it here.
@Suite struct LoneSurrogateTests {

    private static let program =
        "s = \"a\u{1F600}b\"\n"
        + "lab = @Sort([\"b\", s[1], \"a\"])\n"
        + "root = Card([TextContent(\"u1=\" + s[1]), TextContent(\"esc=\\ud800\"), "
        + "KVList([{ label: \"j\", value: lab }])])\n"

    /// What THIS port emits: every lone surrogate is U+FFFD. The oracle (and
    /// the Kotlin port) emit `"u1=\ud83d"`, `"esc=\ud800"` and `"\ud83d"`
    /// respectively at the three marked positions.
    private static let expected = """
        {
          "root": {
            "component": "Card",
            "statementId": "root",
            "props": {},
            "children": [
              {
                "component": "TextContent",
                "props": {
                  "text": "u1=\u{FFFD}"
                }
              },
              {
                "component": "TextContent",
                "props": {
                  "text": "esc=\u{FFFD}"
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
                        "\u{FFFD}"
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

        """

    @Test func astralIndexBecomesReplacementCharacter() throws {
        let schema = try LibrarySchema.load(from: FixtureCorpus.schemaURL)
        let actual = TreeSerializer.serialize(OpenUIParser(schema: schema).parse(Self.program))
        #expect(Array(actual.utf8) == Array(Self.expected.utf8))
    }

    /// The mechanism, isolated: the astral character IS two code units here too
    /// — the port indexes UTF-16 exactly like JS — but rebuilding a `String`
    /// from a single unpaired unit is what Swift cannot do.
    @Test func aStringIndexIsStillUTF16ButCannotHoldTheUnit() throws {
        let s = "a\u{1F600}b"
        #expect(s.utf16.count == 4, "an astral character is TWO UTF-16 code units")
        guard case .string(let unit) = try JSObjects.getMember(.string(s), "1") else {
            Issue.record("expected a string")
            return
        }
        #expect(unit == "\u{FFFD}", "Swift String cannot represent the lone high surrogate")
        // The PAIR still round-trips exactly — only unpaired units are lost.
        #expect(TreeSerializer.quote(s) == "\"a\u{1F600}b\"")
    }
}
