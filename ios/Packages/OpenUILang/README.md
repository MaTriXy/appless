# OpenUILang

Swift port of the `@openuidev/lang-core` openui-lang parser + runtime
evaluator, oracle-verified byte-for-byte against the JS reference
implementation over the golden fixture corpus in `spec/fixtures/` (89
fixtures) plus multi-`set()` streaming scenarios and differential probe
sweeps (CRLF chunking, combining-mark adjacency).

- Normative spec: `spec/openui-lang.md`
- JS reference: `spec/fixtures/generator/node_modules/@openuidev/lang-core/dist`
- Fixture format: `spec/fixtures/README.md`
- Probe oracle tooling: `spec/fixtures/generator/probes/` — committed,
  regenerable scripts that emit JS-oracle expected trees for arbitrary
  programs / streaming `set()` sequences (`expected-tree.mjs`) and regenerate
  the `StreamingSemanticsTests` inline expectations
  (`regen-streaming-expectations.mjs`); see `probes/README.md`
- Entry points: `OpenUIParser.parse(_:)` (batch) and `StreamingParser.set(_:)`
  (incremental; call with the full accumulated text on every flush)

Run the oracle suite:

```sh
cd ios/Packages/OpenUILang && swift test
```

## KNOWN-DEVIATIONS

The port aims for byte parity with the JS oracle, and the fixture corpus plus
differential probes hold it there. The following deviations from the reference
implementation are known and deliberate. None of them is observable in the
current fixture corpus; each is listed with the condition under which it
*would* become observable.

1. **`localeCompare` approximation** (`Evaluator.swift`, `sortCompare`).
   `@Sort`'s string comparator in JS is `String.prototype.localeCompare`
   (ICU collation, host default locale). The port uses Foundation's
   `String.compare(_:options:range:locale:)` with the `en_US` locale. For
   ASCII data the two agree; locale-sensitive orderings (case/diacritic
   weighting, non-Latin scripts, locale tailorings) may differ from V8's ICU
   tables.

2. **Lone surrogates become U+FFFD** (`Lexer.swift`,
   `parseJSONStringLiteral`). `JSON.parse` (and thus the JS lexer's
   double-quoted-string branch) preserves unpaired `\uD800`–`\uDFFF`
   escapes as lone UTF-16 surrogates inside JS strings. Swift `String`
   cannot represent a lone surrogate, so the port substitutes U+FFFD
   (REPLACEMENT CHARACTER). Only observable for programs containing an
   unpaired surrogate escape in a double-quoted string.

3. **Object-identity loose equality is always false**
   (`RuntimeValue.swift`, `jsLooseEquals`). JS `==` between two objects
   compares references; the port has value semantics and no stable
   identities, so object==object comparisons uniformly evaluate to
   `false`. In the reference pipeline materialized values are freshly
   built distinct objects, so `false` is what the oracle produces too —
   a divergence would require the same JS object instance to reach both
   sides of `==`, which the materializer never does.

4. **`runtimeErrors` is always empty** (`Pipeline.swift`). The serialized
   document's `runtimeErrors[]` mirrors the `errors` array the JS
   `evaluateElementProps` call can append to. The reference evaluator
   only pushes there from code paths that AppLess never reaches (no
   QueryManager, no tool providers), and across the whole corpus the
   oracle emits `[]`. The port therefore does not collect runtime errors
   at all. If a future contract routes evaluation failures into
   `runtimeErrors`, collection must be implemented.

5. **Property access on an element returns `undefined`**
   (`Evaluator.swift`, `propertyGet`). In JS an `ElementNode` is a plain
   object, so `someElement.typeName` / `.props` / `.partial` /
   `.hasDynamicProps` / `.type` are readable from expressions. The port
   models elements as a distinct case and returns `undefined` for any
   field access on them. Observable only for programs that
   member-access an element value (e.g. `header.typeName`), which the
   corpus and the system prompt never do. (Note: where elements are
   *spread into plain objects* by the reference — `@Each` substitution
   via `toLiteralAST`, `$ast` serialization — the port replicates the
   spread faithfully; see `Evaluator.toLiteralAST` and
   `Pipeline.convertAstPlain`.)

6. **Literal objects whose `k` is a real AST kind are not runtime-evaluated**
   (`Evaluator.swift`, `evaluatePropValue`). JS AST nodes are plain
   objects, so the runtime duck-types any object with `k ∈ AST_KINDS`
   (`"Str"`, `"Num"`, `"BinOp"`, …) as an AST node: a *literal* object
   like `{k: "Str", v: "x"}` written in a program is indistinguishable
   from an AST node, counts as dynamic (`containsDynamicValue`), and
   evaluates to `"x"` during prop evaluation. The port's typed values
   keep it as plain data. The *serializer-level* duck-typing (any plain
   object with a string `k` serializes as `{"$ast": ...}`, regardless of
   whether `k` is a real kind — see fixture `070-kvlist-k-key-astnode`)
   IS replicated in `Pipeline.convertValue`; only the runtime-evaluation
   collision for the 18 exact kind strings is not.

### Implemented quirk parity (not deviations)

- **Exact `trim()` / `Number()` whitespace sets** (`Preprocess.swift`,
  `String.jsWhitespaceScalars` + `jsTrim`/`jsTrimEnd`; `RuntimeValue.swift`,
  `jsStringToNumber`): both helpers use an explicit scalar set encoding the
  real ECMAScript *WhiteSpace* ∪ *LineTerminator* definition (TAB, LF, VT,
  FF, CR, SP, NBSP, OGHAM SPACE MARK, U+2000–200A, LS, PS, NNBSP, MMSP,
  IDEOGRAPHIC SPACE, ZWNBSP/U+FEFF), verified scalar-by-scalar against node
  v22 `''.trim()` and `Number()` probes. `Number(string)`'s *StrWhiteSpace*
  is the same set, so `jsStringToNumber` trims via `jsTrim()`. This FIXED
  former deviation #7: the sets were previously built from Foundation's
  `CharacterSet.whitespacesAndNewlines`, which additionally contains U+0085
  NEXT LINE — the port trimmed a leading/trailing U+0085 that JS keeps
  (JS `Number("5\u{0085}")` is `NaN` → lang-core `toNumber` maps it to 0;
  the old port yielded `5`). U+0085, U+200B ZWSP and U+180E are now
  correctly non-whitespace. Pinned by
  `WhitespaceSemanticsTests` (per-scalar unit coverage) and
  `WhitespaceDifferentialProbeTests` (full programs with U+0085 / NBSP /
  U+2028 in trim and `Number()` positions, byte-compared against JS-oracle
  trees regenerable via `spec/fixtures/generator/probes/expected-tree.mjs`).
  Not expressed as a corpus fixture to keep the 89-fixture CI gate stable.

- **UTF-16 code-unit scanning** (`StreamCore.scanNewCompleted`,
  `Lexer.tokenize`, `Statements.autoClose`, `Preprocess.stripFences` /
  `stripComments`, plus the comparison helpers in `StringJS.swift`): every
  scanner indexes UTF-16 code units exactly like the JS reference
  (`src[i]`/`charCodeAt` semantics). This FIXED a former grapheme-cluster
  deviation class: "\r\n" is ONE Swift `Character`, so cluster scanning
  never fired the `"\n"` statement split (multi-statement CRLF programs
  merged into a single statement), and a combining mark straight after a
  closing quote / digit / bracket glued into that cluster and hid the
  delimiter. CRLF now parses as LF + horizontal `\r` (spec §2) and
  combining-mark adjacency matches JS byte-for-byte — pinned by fixtures
  `073-crlf-statements` / `074-combining-glue`, the
  `chunkBoundaryInsideCRLF` streaming scenario, and a 21-probe
  batch+streaming differential sweep (tooling to run such sweeps is
  committed at `spec/fixtures/generator/probes/expected-tree.mjs`). Token values and statement slices are
  rebuilt from code-unit ranges via `String(decoding:as: UTF16.self)`
  (lone-surrogate behavior stays as documented in deviation #2); all stored
  offsets/watermarks are code-unit indices.
- **Schema `default` application** (`Materialize.swift`,
  `LibrarySchema.Param.defaultValue`): a missing/null REQUIRED prop takes
  the JSON Schema property's `default` before `missing-required` /
  `null-required` is reported, exactly like `materialize.js`. The current
  GenOS contract declares no defaults (asserted by
  `SchemaDefaultValueTests.shippedContractHasNoDefaults`), so this is
  future-proofing for Phase 2+ contracts.
- **Serializer duck-typing quirks** (`Pipeline.swift`): any object with a
  `steps` array serializes as `{"$action": ...}`, and any plain object
  with a string-valued `k` serializes as `{"$ast": ...}` — both mirror
  `spec/fixtures/generator/lib/serialize.mjs`.
- **ECMAScript `Number::toString`** (`TreeSerializer.formatNumber`):
  shortest-round-trip digits, positional for decimal exponents in
  (-7, 21) — including integer-valued doubles beyond Int64
  (`12345678901234567168` prints `"12345678901234567000"`) — and
  `1e+21` / `1e-7` style exponential outside.

## PHASE-2 HANDOFF

This package covers the parser + runtime evaluator only. The spec §11
app-level pure helpers (`spec/openui-lang.md` §11.1–11.5) live in the app
layer (store.ts / GenOS.tsx / tools/images.ts), NOT in lang-core, and are
therefore out of scope here — they MUST be ported byte-exact into the Phase 2
**GenOSCore** package:

- **`cleanLang(text)`** — spec §11.1. Fence stripping for whole responses:
  removes ONE leading ` ```lang ` line and truncates at `\n``` ` only when an
  opener was present (else strips one trailing fence). NOT string-aware —
  deliberately different from the parser's `stripFences` (spec §4), so do not
  reuse `Preprocess.stripFences` for it.
- **`extractActions(content)`** — spec §11.2. Regex-scan for
  `@ToAssistant("...")` captures (double quotes only), unescape by collapsing
  EVERY backslash-pair (`\n` → `n`, not JSON semantics), trim, drop empties,
  dedupe preserving first-seen order (prefetch cap `MAX_PREFETCH = 6`).
- **`parseOsCommand(text)`** — spec §11.3. Whole-response match of
  `@OS(back|home|switcher|open[, "arg"])` after `cleanLang` + trim;
  case-insensitive, command lower-cased, arg double-quoted only, no partial
  match (any other content → null).
- **`parseGenosUrl(url)`** — spec §11.4. Hand-rolled `genos://cmd?query`
  parser: command lower-cased, pairs split on `&`, key/value split at FIRST
  `=` (key-only pair → value `""`), value gets `+`→space THEN
  `decodeURIComponent`, raw fallback on decode failure.
- **`parseImgUrl(src)`** — spec §11.5. Only `/api/img` srcs are semantic;
  key-only query pairs are SKIPPED (unlike §11.4), `q` sanitized to
  `[a-zA-Z0-9, -]` with default `"abstract gradient"`, `seed`/`w`/`h`
  parseInt-with-clamp (NaN → min bound); LoremFlickr/Unsplash resolution per
  spec.

Each helper's verified behavior tables in spec §11 are normative; port them
byte-exact and pin with an oracle harness in the GenOSCore package (the probe
driver pattern in `spec/fixtures/generator/probes/` is the template).
