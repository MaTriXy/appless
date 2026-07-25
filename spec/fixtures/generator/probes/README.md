# Probe oracle utilities

Committed, regenerable replacements for the throwaway scripts that produced
the JS-oracle-derived expectations used by the Swift port
(`ios/Packages/OpenUILang`): the inline expected trees in
`StreamingSemanticsTests.swift` and the differential probe sweeps referenced
by that package's README. Everything here reuses the fixture generator's own
pipeline (`../lib/build-library.mjs` for the real `@openuidev/lang-core` +
GenOS contract, `../lib/serialize.mjs` for expected-tree serialization) — the
exact `set()` → `store.initialize` → `evaluateElementProps` →
`serializeExpected` chain `../generate.mjs` runs per fixture.

Prerequisite: `npm install` in `spec/fixtures/generator/` (same as for the
generator itself). Run all commands from `spec/fixtures/generator/`.

## `expected-tree.mjs` — differential probe driver

Emit the JS reference implementation's serialized expected tree for an
arbitrary program or streaming `set()` sequence:

```sh
# One fresh parser, one set() with the file's verbatim bytes (like a fixture).
# Raw JSON to stdout — byte-comparable against the Swift port's
# TreeSerializer.serialize output for the same program.
node probes/expected-tree.mjs path/to/program.oui

# Streaming: steps.json is a JSON array of strings; each is the FULL
# accumulated text (the Renderer's store-flush contract, spec §10) fed to ONE
# parser in order. Prints each step's tree under an "=== step N ===" marker.
node probes/expected-tree.mjs --steps steps.json

# --raw prints only the last step's tree, unmarked, for byte-comparison.
node probes/expected-tree.mjs --steps steps.json --raw
```

Typical differential use: write a probe program, run it through this driver
and through the Swift parser, and byte-compare the two serializations. The
whitespace-semantics probes pinned in
`ios/Packages/OpenUILang/Tests/OpenUILangTests/WhitespaceSemanticsTests.swift`
(U+0085 / NBSP / U+2028 in trim and `Number()` positions) were produced this
way; their inline expected JSON is this driver's verbatim output.

The module also exports `createOracle()`, `serializeResult()` and
`runSteps()` for scripted sweeps (see `regen-streaming-expectations.mjs`).

## `regen-streaming-expectations.mjs` — StreamingSemanticsTests oracle

Regenerates — and mechanically verifies — the expected trees inlined in
`ios/Packages/OpenUILang/Tests/OpenUILangTests/StreamingSemanticsTests.swift`.
The scenarios (names and `set()` step texts) are encoded as data at the top
of the script; sync with the Swift test is enforced by the `--check` mode
below (no manual bookkeeping — drift fails the generator's `npm test`).

### Print mode

```sh
node probes/regen-streaming-expectations.mjs
```

Prints, for every scenario step,

```
=== <scenarioName> step <N> ===
{ ...expected JSON... }
```

byte-identical (modulo the Swift triple-quote indentation) to the literal
inlined in the corresponding Swift test. To update the Swift file after a
scenario change: re-run and paste each regenerated document back into the
matching test's expectation.

### Check mode (drift gate)

```sh
node probes/regen-streaming-expectations.mjs --check \
  ../../../ios/Packages/OpenUILang/Tests/OpenUILangTests/StreamingSemanticsTests.swift
```

Parses the Swift test file directly — every `runScenario` step's `set()`
text and inline expected-JSON literal, applying Swift semantics (escape
sequences, `+` literal concatenation, triple-quote dedenting to the closing
delimiter, and expansion of the shared `rootWithText(_:incomplete:)`
template) — and verifies both directions:

1. the Swift scenarios and the script's `SCENARIOS` table agree (same test
   names, step counts, byte-identical step texts), and
2. every Swift inline expectation byte-matches a freshly generated oracle
   tree for that step.

Any drift is listed and the process exits non-zero. The generator's
`npm test` runs this check (script `check:streaming`), and the `spec-gates`
CI workflow runs `npm test`, with `ios/Packages/OpenUILang/Tests/**` in its
path filters — so editing either side without the other fails CI. The Swift
file must keep the machine-readable shape the parser understands (plain
literals in `steps: [ (text, expected), ... ]`, shared trees only via
`rootWithText`); the parser fails loudly on anything it cannot extract.

## `scanner-tests.mjs` — SwiftScanner unit tests

Scanner-level tests for the minimal Swift scanner used by `--check`
(run by the generator's `npm test` as `test:scanner`, before the drift gate).
Synthetic snippets prove the multiline-literal `\(...)` interpolation capture
tracks quote/escape state (escaped quotes/backslashes and parens inside string
literals within the expression), that unsupported shapes (nested
interpolations inside those strings, `"""` inside an interpolation,
unterminated strings) fail loudly with a clear message, and that the real
`StreamingSemanticsTests.swift` still extracts byte-identically to the
`SCENARIOS` table.

## Invariants

- Neither script writes files; both print to stdout only. Fixture generation
  stays `../generate.mjs`'s job.
- Output format is `lib/serialize.mjs`'s `stableStringify` (sorted keys,
  2-space indent, trailing newline) — the same bytes as `*.expected.json`
  fixtures and the Swift `TreeSerializer`.

## `gen-utf8-fuzz.mjs` — UTF-8 streaming-decode oracle

GenOSCore's `UTF8StreamDecoder` is a verbatim port of the [WHATWG utf-8
decoder](https://encoding.spec.whatwg.org/#utf-8-decoder) state machine — the
algorithm `new TextDecoder()` runs with `{stream: true}`. This script proves the
port by differential testing against the real thing.

```bash
node probes/gen-utf8-fuzz.mjs                 # print JSON to stdout
node probes/gen-utf8-fuzz.mjs --out FILE      # write JSON
```

It generates a deterministic corpus (mulberry32, fixed seed `0x5eed1234`): 8
pinned counterexamples that defeated earlier tail-scan decoders, then ~212
random byte sequences (mixed valid/malformed, 0–64 bytes) split at random chunk
boundaries. Each case is decoded through node's `TextDecoder` with
`{stream: true}` and the **per-chunk** emissions are recorded — timing, not just
final totals.

The output is committed at
`ios/Packages/GenOSCore/Tests/GenOSCoreTests/Resources/utf8-fuzz-corpus.json`
and asserted by `UTF8StreamDecoderTests.fuzzCorpusMatchesTextDecoderPerChunk`.
Re-running the script must reproduce that file byte-identically; regenerate it
(and re-run `swift test`) if the corpus is ever intentionally extended.
