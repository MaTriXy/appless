package dev.appless.openuilang

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Deterministic multi-`set()` streaming scenarios (spec/openui-lang.md §10)
 * that the single-shot fixture corpus cannot express: prefix-extension
 * caching, completed-duplicate overwrite vs pending-cannot-overwrite,
 * non-prefix reset, the apostrophe-comment glue hazard, and a chunk boundary
 * that lands INSIDE a CRLF pair.
 *
 * Every `.oui` fixture is one `set(fullText)` on a fresh parser, so none of
 * the incremental machinery in `StreamCore` — the completed-statement
 * watermark, the prefix test, the pending-vs-completed merge — is exercised by
 * more than its first call there. These scenarios are the only coverage of the
 * second and later `set()`.
 *
 * EXPECTED TREES: every inline JSON document below is verbatim JS-oracle
 * output, not a hand-written approximation. Each scenario's `set()` texts were
 * written to a steps file (a JSON array of strings; each entry is the FULL
 * accumulated text, the Renderer's store-flush contract) and replayed through
 * ONE reference `createStreamingParser` by the committed probe driver:
 *
 * ```sh
 * cd spec/fixtures/generator
 * node probes/expected-tree.mjs --steps <scenario>.steps.json
 * ```
 *
 * which prints each step's `stableStringify(serializeExpected(...))` under an
 * `=== step N ===` marker (see `spec/fixtures/generator/probes/README.md`).
 *
 * Twin of `ios/Packages/OpenUILang/Tests/OpenUILangTests/StreamingSemanticsTests.swift`
 * — same seven scenarios, same step texts. The Swift file additionally carries
 * a machine-checked drift gate (`probes/regen-streaming-expectations.mjs
 * --check`) that parses Swift syntax; this file is kept in sync by hand
 * against the same `SCENARIOS` table.
 */
class StreamingSemanticsTest {

    private val schema: LibrarySchema by lazy {
        LibrarySchema.load(FixtureCorpus.schemaFile)
    }

    /**
     * Runs the steps through ONE streaming parser and asserts each step's
     * serialization byte-matches the JS oracle's output for the same call
     * sequence.
     */
    private fun runScenario(name: String, vararg steps: Pair<String, String>) {
        val parser = StreamingParser(schema)
        for ((i, step) in steps.withIndex()) {
            val actual = TreeSerializer.serialize(parser.set(step.first))
            assertEquals(
                step.second,
                actual,
                "$name step $i: serialized tree diverged from JS oracle",
            )
        }
    }

    /**
     * set(p1) then set(p1+p2): the completed `root` statement is served from
     * the prefix-extension cache while the appended pending `$n = 5` joins the
     * parse — the auto-declared `$n: null` upgrades to 5.
     */
    @Test
    fun prefixExtensionCaching() {
        runScenario(
            "prefixExtension",
            "root = Card([CardHeader(\"Count: \" + \$n)])\n" to
                """
                {
                  "root": {
                    "component": "Card",
                    "statementId": "root",
                    "props": {},
                    "children": [
                      {
                        "component": "CardHeader",
                        "props": {
                          "title": "Count: "
                        }
                      }
                    ]
                  },
                  "meta": {
                    "incomplete": false,
                    "unresolved": [],
                    "errors": []
                  },
                  "state": {
                    "${'$'}n": null
                  },
                  "runtimeErrors": []
                }
                """.tree(),
            "root = Card([CardHeader(\"Count: \" + \$n)])\n\$n = 5" to
                """
                {
                  "root": {
                    "component": "Card",
                    "statementId": "root",
                    "props": {},
                    "children": [
                      {
                        "component": "CardHeader",
                        "props": {
                          "title": "Count: 5"
                        }
                      }
                    ]
                  },
                  "meta": {
                    "incomplete": false,
                    "unresolved": [],
                    "errors": []
                  },
                  "state": {
                    "${'$'}n": 5
                  },
                  "runtimeErrors": []
                }
                """.tree(),
        )
    }

    /**
     * Batch (single set): two COMPLETED statements with the same id — the
     * later one overwrites (`Map.set` semantics), keeping insertion position.
     */
    @Test
    fun batchCompletedDuplicateOverwrites() {
        runScenario(
            "batchDuplicateOverwrite",
            "root = Card([TextContent(\"one\")])\nroot = Card([TextContent(\"two\")])\n" to
                rootWithText("two"),
        )
    }

    /**
     * Streaming: a PENDING statement (no trailing newline) whose id is already
     * in the completed cache is DISCARDED — pending can never overwrite
     * completed (spec §10.1 step 3 / §10.6).
     */
    @Test
    fun pendingCannotOverwriteCompleted() {
        runScenario(
            "pendingCannotOverwriteCompleted",
            "root = Card([TextContent(\"one\")])\n" to rootWithText("one"),
            // Redefinition is still pending (no trailing newline): "one" must
            // survive.
            "root = Card([TextContent(\"one\")])\nroot = Card([TextContent(\"two\")])" to
                rootWithText("one"),
        )
    }

    /**
     * Streaming: once the duplicate is newline-terminated it COMPLETES and
     * overwrites its predecessor (contrast with the pending case above).
     */
    @Test
    fun streamedCompletedDuplicateOverwrites() {
        runScenario(
            "streamedDuplicateOverwrite",
            "root = Card([TextContent(\"one\")])\n" to rootWithText("one"),
            "root = Card([TextContent(\"one\")])\nroot = Card([TextContent(\"two\")])\n" to
                rootWithText("two"),
        )
    }

    /**
     * set() with text that is NOT a prefix-extension of the previous text
     * resets the parser: the old completed cache is discarded entirely. The
     * second text is LONGER than the first and shares its first 26 code units,
     * so a length check alone would accept it — only the code-unit prefix test
     * rejects it and reparses `reset` from scratch.
     */
    @Test
    fun nonPrefixResets() {
        runScenario(
            "nonPrefixReset",
            "root = Card([TextContent(\"one\")])\n" to rootWithText("one"),
            "root = Card([TextContent(\"reset\")])\n" to rootWithText("reset"),
        )
    }

    /**
     * Apostrophe-comment glue hazard: the statement scanner is comment-BLIND
     * and quote-aware, so the `'` in `# don't split here` opens a bogus string
     * context and every later newline is glued into one pending statement (the
     * completed watermark never advances past the comment). The pending blob is
     * comment-stripped and re-parsed on EVERY set, so statements after the
     * comment still resolve — across multiple sets — and a genuinely unclosed
     * string at the tail flags `meta.incomplete`.
     */
    @Test
    fun apostropheCommentGlue() {
        runScenario(
            "apostropheCommentGlue",
            "root = Card([header, tail])\n# don't split here\n" +
                "header = CardHeader(\"Streams\")\n" to
                """
                {
                  "root": {
                    "component": "Card",
                    "statementId": "root",
                    "props": {},
                    "children": [
                      {
                        "component": "CardHeader",
                        "statementId": "header",
                        "props": {
                          "title": "Streams"
                        }
                      }
                    ]
                  },
                  "meta": {
                    "incomplete": false,
                    "unresolved": [
                      "tail"
                    ],
                    "errors": []
                  },
                  "state": {},
                  "runtimeErrors": []
                }
                """.tree(),
            "root = Card([header, tail])\n# don't split here\n" +
                "header = CardHeader(\"Streams\")\n" +
                "tail = TextContent(\"done: \" + \$ok)\n\$ok = \"yes" to
                """
                {
                  "root": {
                    "component": "Card",
                    "statementId": "root",
                    "props": {},
                    "children": [
                      {
                        "component": "CardHeader",
                        "statementId": "header",
                        "props": {
                          "title": "Streams"
                        }
                      },
                      {
                        "component": "TextContent",
                        "statementId": "tail",
                        "props": {
                          "text": "done: yes"
                        }
                      }
                    ]
                  },
                  "meta": {
                    "incomplete": true,
                    "unresolved": [],
                    "errors": []
                  },
                  "state": {
                    "${'$'}ok": "yes"
                  },
                  "runtimeErrors": []
                }
                """.tree(),
        )
    }

    /**
     * Chunk boundary INSIDE a CRLF pair: the first set() ends with the `\r` of
     * a `\r\n` (the `\n` and the next statements arrive in the second set()).
     * With code-unit scanning this is chunk-boundary-independent: the `\r` is
     * horizontal whitespace, the later `\n` splits statements exactly as if the
     * full text had arrived in one set(). (Grapheme-cluster scanning merges
     * `\r\n` into ONE character and never splits — the bug the Swift port hit.)
     *
     * Step 0: `hd` completes at the mid-buffer `\r\n`; the trailing `\r` leaves
     * no pending statement, so `incomplete` is false and only `tl` is
     * unresolved. Step 1: the appended `\n` completes the CRLF, and `tl` / `$z`
     * parse normally.
     */
    @Test
    fun chunkBoundaryInsideCrlf() {
        runScenario(
            "chunkBoundaryInsideCRLF",
            "root = Card([hd, tl])\r\nhd = CardHeader(\"Split\")\r" to
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
                          "title": "Split"
                        }
                      }
                    ]
                  },
                  "meta": {
                    "incomplete": false,
                    "unresolved": [
                      "tl"
                    ],
                    "errors": []
                  },
                  "state": {},
                  "runtimeErrors": []
                }
                """.tree(),
            "root = Card([hd, tl])\r\nhd = CardHeader(\"Split\")\r" +
                "\ntl = TextContent(\"tail: \" + \$z)\r\n\$z = 9\r\n" to
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
                          "title": "Split"
                        }
                      },
                      {
                        "component": "TextContent",
                        "statementId": "tl",
                        "props": {
                          "text": "tail: 9"
                        }
                      }
                    ]
                  },
                  "meta": {
                    "incomplete": false,
                    "unresolved": [],
                    "errors": []
                  },
                  "state": {
                    "${'$'}z": 9
                  },
                  "runtimeErrors": []
                }
                """.tree(),
        )
    }

    // ---- Helpers ------------------------------------------------------------

    /**
     * `trimIndent()` plus the trailing newline every oracle document ends with
     * (`stableStringify` appends one; so does `TreeSerializer.serialize`).
     */
    private fun String.tree(): String = trimIndent() + "\n"

    /**
     * Shared oracle output for the single-TextContent scenarios above
     * (identical modulo the text), byte-for-byte as printed by the JS
     * pipeline. Every one of them serializes with `incomplete: false`.
     */
    private fun rootWithText(text: String): String =
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
                  "text": "$text"
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
        """.tree()
}
