# OpenUILang

Swift port of the `@openuidev/lang-core` openui-lang parser + runtime
evaluator, oracle-verified byte-for-byte against the JS reference
implementation over the golden fixture corpus in `spec/fixtures/` (87
fixtures) plus multi-`set()` streaming scenarios.

- Normative spec: `spec/openui-lang.md`
- JS reference: `spec/fixtures/generator/node_modules/@openuidev/lang-core/dist`
- Fixture format: `spec/fixtures/README.md`
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
