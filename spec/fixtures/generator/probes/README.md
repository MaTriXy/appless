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
path filters — so editing either side without the other fails CI.

The Swift file must keep the machine-readable shape the parser understands
(plain literals in `steps: [ (text, expected), ... ]`, shared trees only via
`rootWithText`); the parser fails loudly on anything it cannot extract.

The Kotlin port carries the same seven scenarios in
`android/openui-lang/src/test/kotlin/dev/appless/openuilang/StreamingSemanticsTest.kt`.
That file is NOT parsed by `--check` (the scanner understands Swift literals
only); it is kept in sync by hand against the `SCENARIOS` table, and its
expectations are regenerable with `expected-tree.mjs --steps`.

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

- `expected-tree.mjs`, `regen-streaming-expectations.mjs` and `scanner-tests.mjs`
  write no files; they print to stdout only. Fixture generation stays
  `../generate.mjs`'s job, and nothing here ever touches `spec/fixtures/*.oui`
  or `*.expected.json`.
- Output format is `lib/serialize.mjs`'s `stableStringify` (sorted keys,
  2-space indent, trailing newline) — the same bytes as `*.expected.json`
  fixtures and the Swift `TreeSerializer`.

---

# Differential fuzzing (CI gate)

Every real divergence found between the JS reference implementation and the two
native ports was found by **differential fuzzing** — built out-of-repo and
thrown away each time. `gen-fuzz-corpus.mjs` + `run-differential.mjs` + the two
thin native drivers make that permanent, and
`.github/workflows/differential-fuzz.yml` runs it on every push/PR touching
`ios/Packages/OpenUILang/**`, `android/openui-lang/**`, `spec/**` or the
workflow itself.

Three implementations, one byte stream each:

| program | entry point |
| --- | --- |
| JS oracle | `expected-tree.mjs`'s `createOracle`/`serializeResult`, run in-process by `run-differential.mjs` |
| Swift port | `ios/Packages/OpenUILang/Sources/OpenUILangFuzzDriver/main.swift` (product `openui-fuzz-driver`) |
| Kotlin port | `android/openui-lang/src/main/kotlin/dev/appless/openuilang/fuzz/FuzzDriver.kt` (task `:openui-lang:fuzzDriver`) |

All three print exactly

```
=== <session name> step <N> ===
<serialized tree>
```

so the streams are `cmp`-able byte-for-byte.

## `gen-fuzz-corpus.mjs` — campaign generator

Deterministic: mulberry32 with a **fixed seed** and one independent PRNG stream
per campaign (seed XOR a per-campaign salt), so `--campaign mutation` yields the
same sessions whether or not the other campaigns are generated alongside it. No
`Date`, no `Math.random` — regeneration is byte-identical (CI asserts this for
the committed pinned campaign).

```sh
node probes/gen-fuzz-corpus.mjs --campaign prefix --stats            # counts only
node probes/gen-fuzz-corpus.mjs --campaign all --out /tmp/c.json     # inputs only
node probes/gen-fuzz-corpus.mjs --campaign pinned --with-expected \
  --out probes/fuzz-campaign-pinned.json                             # + oracle trees
```

| campaign | sessions | steps | what it reaches |
| --- | ---: | ---: | --- |
| `prefix` | 101 | 26,021 | EXHAUSTIVE PREFIX: every UTF-16 code-unit prefix of every corpus entry (surrogate-pair-safe cuts), fed **cumulatively** to ONE streaming parser per entry — the Renderer's store-flush contract (spec §10) |
| `nonmonotonic` | 48 | 566 | seeded shrink / cross-fixture switch / reset-to-empty sequences — `StreamCore`'s cache-**reset** branch, which prefix fuzzing can never reach because prefixes only grow |
| `mutation` | 2,424 | 2,424 | seeded single-code-point insert/delete/replace using a hazard alphabet (`"` `'` `` ` `` brackets, backslash, CR, LF, CRLF, NBSP, U+FEFF, combining acute, `@`, `$`, `#`, `//`, `:`, `,`, `.`), one fresh parser per mutant |
| `all` | 2,573 | 29,011 | the three above |
| `pinned` | 39 | 313 | small committed cross-section **with oracle expectations inlined** (`fuzz-campaign-pinned.json`, ~310 KB) |

### Campaign file shape

```jsonc
{ "version": 1, "seed": "0x...", "campaigns": ["prefix"],
  "corpusSize": 101, "sessionCount": 101, "stepCount": 26021,
  "sessions": [
    { "campaign": "prefix", "name": "prefix/001-minimal-card",
      "sources": ["<full text>"],
      "steps": [[0, 0], [0, 1], ...],       // [sourceIndex, utf16PrefixLength]
      "expected": ["<tree>", ...]           // only with --with-expected
    }
  ] }
```

A step's text is `sources[srcIndex]` truncated to `len` **UTF-16 code units**,
and all of a session's steps go to ONE parser in order. That single rule is the
entire contract the two ~90-line native drivers implement (`String.substring`
on the JVM; `String(decoding: Array(s.utf16)[0..<n], as: UTF16.self)` in Swift).
The generator never emits a cut that splits a surrogate pair.

### `fuzz-seeds/` — hazard seed programs

`probes/fuzz-seeds/*.oui` are extra corpus entries (named `seed/<file>`) that are
**not** fixtures — nothing under `spec/fixtures` is added, changed or gated by
them. They exist because the fixture corpus is a *feature* corpus, not a *hazard*
corpus: it contains no `@Round` tie, no `-0`, no `Infinity`, no `1e21`, no lone
combining mark. Measured: reverting the Swift `@Round` tie rule to
`floor(x + 0.5)` produced **zero** divergences across all 25,919 fixture-only
steps, and 2 divergences once `seed/001-round-ties` was in the corpus. Without
these seeds the gate would not catch the very bug class ad-hoc probing caught.

| seed | targets |
| --- | --- |
| `001-round-ties.oui` | `@Round` halves both signs, `0.49999999999999994`, `2^52 + 0.5`, negative and multi-digit precision |
| `002-number-format.oui` | `1e21`, `1e-7`, `5e-324`, `-0`, `±Infinity`, `NaN`, `2^53±`, number→string coercion |
| `003-builtins-edges.oui` | `Floor`/`Ceil` on negative halves, `Abs(-0)`, aggregates over mixed number/numeric-string arrays, empty-array aggregates |
| `004-string-hazards.oui` | escapes and invalid escapes, NBSP / U+FEFF / U+2028 / U+0085 / combining acute / astral pairs, whitespace-sensitive trim and numeric coercion |

## `run-differential.mjs` — orchestrator

```sh
# from spec/fixtures/generator/
node probes/run-differential.mjs                          # pinned smoke (default)
node probes/run-differential.mjs --campaign all           # the full gate
node probes/run-differential.mjs --campaign prefix --skip-kotlin
node probes/run-differential.mjs --campaign-file probes/fuzz-campaign-pinned.json
```

| flag | effect |
| --- | --- |
| `--campaign NAME[,NAME]` | `prefix` \| `nonmonotonic` \| `mutation` \| `pinned` \| `all` |
| `--campaign-file FILE` | replay a pre-generated campaign instead of generating one |
| `--out-dir DIR` | where `node.txt` / `swift.txt` / `kotlin.txt` land (default: a temp dir) |
| `--keep` | keep the streams for `cmp` / `diff` |
| `--skip-swift`, `--skip-kotlin` | run only the toolchains available |
| `--max-divergences N` | how many divergences to print (default 5) |

It builds the Swift driver in release, invokes the Kotlin driver through Gradle,
runs the JS oracle in-process, then compares every step of every stream. A
campaign carrying `expected` (the pinned one) is compared as a fourth program,
which also regression-gates the JS oracle itself. Exit codes: `0` agree,
`1` divergence, `2` usage/toolchain error.

Failure output names the failing program, the step, the first differing byte
offset and both trees around it:

```
DIVERGENCE (tree) in swift
  step        : === prefix/seed/001-round-ties step 393 ===
  byte offset : 910 (node 1086 bytes, swift 1086 bytes)
  node   tree : …"label": "eps-below-half",\n "value": 0\n …
  swift  tree : …"label": "eps-below-half",\n "value": 1\n …
```

## Runtime

Measured on this repo (Swift 6.1 / JDK 21 / node 22), campaign `all`
(2,573 sessions, 29,011 steps, ~21 MB per stream):

| program | wall |
| --- | ---: |
| JS oracle (in-process) | ~2.0 s |
| Swift driver (release, excludes build) | ~3.4 s |
| Kotlin driver | ~2.7 s (≈4 s including Gradle start-up) |
| **whole `--campaign all` run** | **~10 s** |

Cold toolchain setup dominates CI: `swift build -c release` ≈ 1–2 min from
scratch, Gradle ≈ 1 min. Both CI jobs stay well under the 5-minute target.

## Reproducing a CI failure locally

The workflow prints the campaign name and uploads the diverging streams as the
`differential-streams-{kotlin,swift}` artifact. To reproduce:

```sh
cd spec/fixtures/generator
npm ci                                   # once

# Same campaign CI runs, keeping the streams:
node probes/run-differential.mjs --campaign prefix,nonmonotonic,mutation \
  --out-dir /tmp/difffuzz --keep

# Byte-compare by hand / bisect the first differing record:
cmp   /tmp/difffuzz/node.txt /tmp/difffuzz/swift.txt
diff  /tmp/difffuzz/node.txt /tmp/difffuzz/kotlin.txt | head -40
```

The campaign is seeded and deterministic, so `/tmp/difffuzz/campaign.json` is
byte-identical to CI's. Once the failing step is known, minimise it: the step
header is `=== <session> step <N> ===`, and the session's `sources` + `steps[N]`
in `campaign.json` give the exact input text. Feed that text back through a
single program:

```sh
# one step, JS oracle
node -e 'const c=require("/tmp/difffuzz/campaign.json");
  const s=c.sessions.find(x=>x.name==="prefix/seed/001-round-ties");
  require("fs").writeFileSync("/tmp/steps.json",
    JSON.stringify(s.steps.slice(0,394).map(([i,n])=>s.sources[i].slice(0,n))))'
node probes/expected-tree.mjs --steps /tmp/steps.json --raw

# same steps through one port
swift run -c release --package-path ../../../ios/Packages/OpenUILang \
  openui-fuzz-driver /tmp/difffuzz/campaign.json | less
(cd ../../../android && ./gradlew :openui-lang:fuzzDriver \
  -PfuzzCampaign=/tmp/difffuzz/campaign.json)
```

## Proving the gate bites

Two perturbations, each reverted afterwards (`git diff` clean), were used to
verify the gate is not vacuous:

| perturbation | result |
| --- | --- |
| Swift `jsMathRound` → `floor(x + 0.5)` | **0 divergences** over fixtures alone; **2 divergences** with `fuzz-seeds/` in the corpus, at `prefix/seed/001-round-ties` step 393 (`@Round(0.49999999999999994)`: oracle `0`, Swift `1`) |
| Kotlin serializer: `JS_OWN_KEY_ORDER` → flat `sorted()` | **2 divergences** at `prefix/075-object-key-index-order` steps 680–681 (integer-index keys not hoisted ahead of `"-dash"`) |

Re-run either experiment before trusting a green result after a large refactor.

## Invariants (differential fuzzing)

- Nothing here reads or writes `spec/fixtures/*.oui` / `*.expected.json` except
  read-only, and no existing gate is weakened.
- The native drivers are build-only tooling: the Swift target is a separate
  `.executableTarget` (not a dependency of `OpenUILang` or its tests) and the
  Kotlin `fuzzDriver` is a `JavaExec` task, so `swift test` and
  `:openui-lang:test` counts are unchanged.
- `fuzz-campaign-pinned.json` is generated, not hand-edited; CI regenerates it
  and fails on any diff.

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
