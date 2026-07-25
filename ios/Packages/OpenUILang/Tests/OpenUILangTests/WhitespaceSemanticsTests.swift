import Foundation
import Testing

@testable import OpenUILang

/// Regression coverage for former KNOWN-DEVIATION #7 (U+0085 over-trim):
/// `jsTrim`/`jsTrimEnd` and `jsStringToNumber` must use the EXACT ECMAScript
/// *WhiteSpace* ∪ *LineTerminator* set, not Foundation's
/// `whitespacesAndNewlines` (which additionally contains U+0085 NEL).
///
/// The membership tables below were verified empirically against node v22:
/// for every candidate scalar, `(ws + "x" + ws).trim() === "x"` and
/// `Number(ws + "5" + ws)` — U+0085, U+200B and U+180E are NOT JS whitespace;
/// everything in `jsScalars` is (in BOTH positions, trim and Number).
@Suite struct WhitespaceSemanticsTests {
    /// The 25 scalars JS strips: TAB LF VT FF CR SP NBSP OGHAM, Zs run
    /// U+2000–200A, LS PS NNBSP MMSP IDSP and ZWNBSP/BOM.
    static let jsScalars: [Unicode.Scalar] = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
        "\u{00A0}", "\u{1680}",
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
        "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
    ]

    /// Near-miss scalars JS does NOT treat as whitespace (node: trim keeps
    /// them, Number(...) is NaN): NEL, ZWSP, MONGOLIAN VOWEL SEPARATOR.
    static let nonJsScalars: [Unicode.Scalar] = ["\u{0085}", "\u{200B}", "\u{180E}"]

    @Test func trimStripsExactlyTheJSSet() {
        for scalar in Self.jsScalars {
            let ws = String(scalar)
            #expect((ws + "x" + ws).jsTrim() == "x", "U+\(String(scalar.value, radix: 16))")
        }
        for scalar in Self.nonJsScalars {
            let ws = String(scalar)
            #expect(
                (ws + "x" + ws).jsTrim() == ws + "x" + ws,
                "U+\(String(scalar.value, radix: 16)) must survive trim")
        }
    }

    @Test func trimEndStripsExactlyTheJSSet() {
        for scalar in Self.jsScalars {
            #expect(("x" + String(scalar)).jsTrimEnd() == "x")
        }
        for scalar in Self.nonJsScalars {
            let s = "x" + String(scalar)
            #expect(s.jsTrimEnd() == s)
        }
        // Non-whitespace tail shields inner whitespace, like JS trimEnd.
        #expect("x \u{3000}y".jsTrimEnd() == "x \u{3000}y")
    }

    @Test func numberCoercionUsesExactStrWhiteSpace() {
        // Every JS whitespace scalar is valid leading/trailing padding.
        for scalar in Self.jsScalars {
            let ws = String(scalar)
            #expect(jsStringToNumber(ws + "5" + ws) == 5, "U+\(String(scalar.value, radix: 16))")
            // Whitespace-only coerces to 0 (empty after StrWhiteSpace trim).
            #expect(jsStringToNumber(ws) == 0)
        }
        // Non-whitespace near-misses poison the literal: NaN, exactly like
        // node's Number("\u{85}5") etc. (the old Foundation-set port returned
        // 5 for U+0085).
        for scalar in Self.nonJsScalars {
            let ws = String(scalar)
            #expect(jsStringToNumber(ws + "5").isNaN)
            #expect(jsStringToNumber("5" + ws).isNaN)
            #expect(jsStringToNumber(ws).isNaN, "not whitespace, not a number")
        }
    }
}

/// Differential probes: full programs with U+0085 / NBSP / U+2028 in trim
/// positions (statement-boundary padding) and Number() positions (string
/// operands of `*`) parsed by the Swift port and byte-compared against the JS
/// oracle's serialized tree.
///
/// EXPECTED TREES regenerable via the committed probe driver: write the
/// program to a file and run
/// `node spec/fixtures/generator/probes/expected-tree.mjs <program.oui>`
/// (see spec/fixtures/generator/probes/README.md).
@Suite struct WhitespaceDifferentialProbeTests {
    static let schema: LibrarySchema = {
        try! LibrarySchema.load(from: FixtureCorpus.schemaURL)
    }()

    private func expectProbe(_ program: String, _ expected: String, _ name: String) {
        let result = OpenUIParser(schema: Self.schema).parse(program)
        let actual = TreeSerializer.serialize(result)
        #expect(actual == expected, "\(name): serialized tree diverged from JS oracle")
    }

    /// Trim positions: raw U+0085 NEL trailing statement 1, raw NBSP leading
    /// statement 2, raw U+2028 LS trailing statement 2. JS keeps the NEL after
    /// trim and the lexer then skips it as an unknown character; NBSP and LS
    /// are genuine JS whitespace and are trimmed. Byte-identical either way —
    /// this pins that dropping Foundation's set did not change trim coverage
    /// for the scalars that ARE whitespace.
    @Test func trimPositionProbe() {
        expectProbe(
            "root = Card([hd, msg])\u{0085}\n"
                + "\u{00A0}hd = CardHeader(\"ws\")\u{2028}\n"
                + "msg = TextContent(\"t\")\n",
            """
            {
              "root": {
                "component": "Card",
                "statementId": "root",
                "props": {},
                "children": [
                  {
                    "component": "CardHeader",
                    "statementId": "hd",
                    "props": {
                      "title": "ws"
                    }
                  },
                  {
                    "component": "TextContent",
                    "statementId": "msg",
                    "props": {
                      "text": "t"
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

            """,
            "trimPositionProbe"
        )
    }

    /// Number() positions: `"\u{85}5" * 1` must coerce via Number → NaN →
    /// lang-core `toNumber` maps NaN to 0, so `a=0` — the old Foundation-set
    /// port trimmed the NEL and produced `a=5`. NBSP/IDSP (`b`) and LS (`c`)
    /// are real StrWhiteSpace: both yield 5. (`\u00855` etc. are JSON escapes
    /// inside the program's double-quoted strings.)
    @Test func numberPositionProbe() {
        expectProbe(
            "root = Card([TextContent(\"a=\" + (\"\\u00855\" * 1) + \" b=\" + "
                + "(\"\\u00a05\\u3000\" * 1) + \" c=\" + (\"\\u20285\" * 1))])\n",
            """
            {
              "root": {
                "component": "Card",
                "statementId": "root",
                "props": {},
                "children": [
                  {
                    "component": "TextContent",
                    "props": {
                      "text": "a=0 b=5 c=5"
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

            """,
            "numberPositionProbe"
        )
    }
}
