package dev.appless.openuilang

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Differential probe pinning `@Round` against ECMAScript `Math.round`.
 *
 * lang-core evaluates `@Round(x, d)` as `Math.round(x * 10**d) / 10**d`
 * (`parser/builtins.js`). `Math.round` is NOT `Math.round`-the-JVM-method
 * (half-away-from-zero) and — the bug this pins — it is NOT `floor(x + 0.5)`
 * either: `x + 0.5` can round UP to the next double before the floor sees it,
 * so `Math.round(0.49999999999999994)` is 0 in JS while the shorthand answers
 * 1. `@Round`'s scaling makes the same input reachable from ordinary decimals
 * (`@Round(0.049999999999999994, 1)`).
 *
 * EXPECTED TREE regenerable with the committed probe driver — write the
 * program below to a file and run, from `spec/fixtures/generator`:
 *
 * ```sh
 * node probes/expected-tree.mjs <program.oui>
 * ```
 *
 * Twin of `ios/Packages/OpenUILang/Tests/OpenUILangTests/MathRoundSemanticsTests.swift`
 * (identical program, identical expectation).
 *
 * Not a corpus fixture: this keeps the 90-fixture CI gate stable, and the
 * boundary values are about the evaluator, not about the parse tree.
 *
 * `@Round(-0.5)` and `@Round(0 * -1)` are `-0` in JS; `JSON.stringify(-0)` is
 * `"0"`, so the sign is not observable in the serialized tree. The sign IS
 * handled in `Evaluator.jsMathRound` (ES step 4) — the rest of the table is
 * what the tree can see.
 */
class MathRoundSemanticsTest {

    private val program: String =
        """
        root = Card([
          KVList([
            {label: "tiny", n: @Round(0.49999999999999994)},
            {label: "half", n: @Round(0.5)},
            {label: "neghalf", n: @Round(-0.5)},
            {label: "onehalf", n: @Round(1.5)},
            {label: "twohalf", n: @Round(2.5)},
            {label: "negonehalf", n: @Round(-1.5)},
            {label: "negtwohalf", n: @Round(-2.5)},
            {label: "scaled", n: @Round(0.049999999999999994, 1)},
            {label: "scaled2", n: @Round(1.005, 2)},
            {label: "zero", n: @Round(0)},
            {label: "negzero", n: @Round(0 * -1)},
            {label: "inf", n: @Round(1e308 * 10)},
            {label: "neginf", n: @Round(-1e308 * 10)},
            {label: "nan", n: @Round(1e308 * 10 - 1e308 * 10)},
            {label: "negsmall", n: @Round(-0.4)},
            {label: "big", n: @Round(4503599627370495.5)}
          ], "ROUND")
        ])
        """.trimIndent() + "\n"

    /** Verbatim `node probes/expected-tree.mjs` output for [program]. */
    private val expected: String =
        """
        {
          "root": {
            "component": "Card",
            "statementId": "root",
            "props": {},
            "children": [
              {
                "component": "KVList",
                "props": {
                  "header": "ROUND",
                  "rows": [
                    {
                      "label": "tiny",
                      "n": 0
                    },
                    {
                      "label": "half",
                      "n": 1
                    },
                    {
                      "label": "neghalf",
                      "n": 0
                    },
                    {
                      "label": "onehalf",
                      "n": 2
                    },
                    {
                      "label": "twohalf",
                      "n": 3
                    },
                    {
                      "label": "negonehalf",
                      "n": -1
                    },
                    {
                      "label": "negtwohalf",
                      "n": -2
                    },
                    {
                      "label": "scaled",
                      "n": 0
                    },
                    {
                      "label": "scaled2",
                      "n": 1
                    },
                    {
                      "label": "zero",
                      "n": 0
                    },
                    {
                      "label": "negzero",
                      "n": 0
                    },
                    {
                      "label": "inf",
                      "n": {
                        "${'$'}number": "Infinity"
                      }
                    },
                    {
                      "label": "neginf",
                      "n": {
                        "${'$'}number": "-Infinity"
                      }
                    },
                    {
                      "label": "nan",
                      "n": {
                        "${'$'}number": "NaN"
                      }
                    },
                    {
                      "label": "negsmall",
                      "n": 0
                    },
                    {
                      "label": "big",
                      "n": 4503599627370496
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
        """.trimIndent() + "\n"

    @Test
    fun roundMatchesEcmaScriptMathRound() {
        val schema = LibrarySchema.load(FixtureCorpus.schemaFile)
        val actual = TreeSerializer.serialize(OpenUIParser(schema).parse(program))
        assertEquals(expected, actual, "@Round diverged from the JS oracle")
    }
}
