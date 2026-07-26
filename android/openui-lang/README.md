# openui-lang (Kotlin/JVM)

Kotlin port of the `@openuidev/lang-core` openui-lang parser + runtime
evaluator, oracle-verified byte-for-byte against the JS reference
implementation over the golden fixture corpus in `spec/fixtures/`
(89 fixtures) plus differential probe sweeps.

- Normative spec: `spec/openui-lang.md`
- JS reference: `spec/fixtures/generator/node_modules/@openuidev/lang-core/dist`
- Fixture format: `spec/fixtures/README.md`
- Swift sibling (same structure, same quirks): `ios/Packages/OpenUILang`
- Probe oracle tooling: `spec/fixtures/generator/probes/expected-tree.mjs`
- Entry points: `OpenUIParser.parse(text)` (batch) and `StreamingParser.set(text)`
  (incremental; call with the full accumulated text on every flush)

Run the oracle suite:

```sh
cd android && ./gradlew :openui-lang:test --console=plain
```

Deliberately a PURE Kotlin/JVM library (no Android dependency), so the suite
runs headlessly on any JDK 21.

## Module layout

Dependency order, mirroring the Swift port file-for-file:

| File | Role |
|---|---|
| `JsonValue.kt` | hand-rolled JSON reader for the contract schema only |
| `LibrarySchema.kt` | `spec/contract/genos.schema.json` → root, components, `paramOrder`, per-param `default` |
| `StringJs.kt` | JS string-semantics wrappers + the JVM-vs-JS trap list |
| `Ast.kt` | `AstNode` sealed hierarchy, `walkAst`, `collectStateRefs` |
| `Lexer.kt` | `tokenize`, double-quoted strings via strict JSON parsing with whole-string raw fallback, single-quoted escapes, numbers, `&`→`&&` / `|`→`||` |
| `Preprocess.kt` | exact ECMAScript whitespace set, `jsTrim`/`jsTrimEnd`, `stripFences` (string-aware), `stripComments` |
| `Statements.kt` | `autoClose` (§7), `splitStatements` (§6, ternary lookahead) |
| `Expressions.kt` | Pratt parser (§5), the `isBuiltin` collision rule (only `Action` parses bare) |
| `Builtins.kt` | builtin / lazy / action-step / reserved-call name registries |
| `RuntimeValue.kt` | `RtValue` JS value model, `RtObject`, `RtElement`, `toNumber`/`String()`/truthiness/loose-equality |
| `Materialize.kt` | statement classification, ref resolution with per-path cycle guard, positional→named prop mapping, required-prop validation, array drop rules |
| `Evaluator.kt` | runtime AST evaluation: operators, member/index/pluck, data builtins, `@Each`, action calls |
| `StreamCore.kt` | `OrderedMap`, entry selection (§8.1), `buildResult`, the incremental scanner with prefix-extension caching (§10) |
| `Pipeline.kt` | store init → `evaluateElementProps` → `RtValue`→`PropValue` conversion, incl. the `$action`/`$ast` serializer duck-typing |
| `ParseResult.kt` | public serializable shapes |
| `TreeSerializer.kt` | canonical expected-tree JSON, ECMAScript `Number::toString` |

`OpenUIParser.parse` is exactly a fresh `StreamCore` plus one `set(text)` —
the same way the fixture generator drives the reference implementation.

## JVM-vs-JS notes (what this port had to spell out)

Kotlin `String` IS a UTF-16 code-unit sequence, exactly like a JS string, so
every scanner here indexes `Char` directly and `==`, `compareTo`, `startsWith`,
`indexOf`, `contains` and `HashMap` keys are already code-unit exact. That is a
real advantage over the Swift port, which needs `[UInt16]` arrays and a `JSKey`
wrapper because Swift `String` iterates grapheme clusters and compares by
canonical equivalence. What did NOT come for free:

- **Whitespace.** `Character.isWhitespace` excludes U+00A0/U+2007/U+202F/U+FEFF
  and includes U+001C–U+001F; `java.util.regex`'s `\s` is ASCII-only by default
  and, with `UNICODE_CHARACTER_CLASS`, adds U+0085 NEL which JS does not treat
  as whitespace. `Preprocess.kt` spells out ECMAScript *WhiteSpace* ∪
  *LineTerminator* as an explicit `Set<Char>`; `Number(string)`'s
  *StrWhiteSpace* is the same set, so `jsStringToNumber` reuses it.
- **`Number(string)`.** `String.toDoubleOrNull()` is `Double.parseDouble`, which
  accepts `"1f"`, `"1d"`, `"0x1p3"` and `Character.isWhitespace` padding (JS
  → NaN) while rejecting `"0x10"`, `"0b101"` and `"Infinity"` (JS → 16, 5, ∞).
  `RuntimeValue.jsStringToNumber` implements the ECMAScript grammar directly.
- **`Math.round`.** JS is `floor(x + 0.5)`; Kotlin's `Math.round`/`roundToInt`
  is half-away-from-zero and disagrees on `-0.5`, `-2.5`, …
- **`split`.** `java.lang.String.split` drops trailing empty segments; JS does
  not. `jsSplitLines` / `jsStringSplit` keep them.
- **Number formatting.** `Double.toString` always emits a decimal point,
  switches to scientific at 1e7 / 1e-3 (JS: 1e21 / 1e-6), writes `E16` not
  `e+16`, and floors the digit count at two (`4.9E-324` where JS says
  `5e-324`). `TreeSerializer.formatNumber` re-renders JDK 19+ shortest-round-trip
  digits under the ECMAScript rules.
- **No locale-sensitive case mapping** is used anywhere; nothing calls
  `toUpperCase`/`toLowerCase`.

## KNOWN-DEVIATIONS

The port aims for byte parity with the JS oracle. The following deviations are
known and deliberate; none is observable in the current fixture corpus.

1. **`localeCompare` approximation** (`Evaluator.sortCompare`). `@Sort`'s
   string comparator in JS is `String.prototype.localeCompare` (V8 ICU
   collation, host default locale). The port uses
   `java.text.Collator.getInstance(Locale.US)`. Verified equal to the oracle on
   a mixed case/diacritic/underscore/digit probe
   (`"" < "_zed" < "10" < "apple" < "Apple" < "Ápple" < "banana" < "cherry"`),
   but locale tailorings and non-Latin scripts may differ from V8's ICU tables.
   Deliberately NOT `String.compareTo`, which is raw code-unit order and would
   sort `"a" > "B"`.
2. **Object-identity loose equality is always false**
   (`RuntimeValue.jsLooseEquals`). JS `==` between two objects compares
   references; this port has value semantics and no stable identities. The
   materializer never routes the same JS object instance to both sides, so the
   oracle produces `false` too.
3. **`runtimeErrors` is always empty** (`Pipeline.run`). The JS
   `evaluateElementProps` errors array is only appended to from code paths
   AppLess never reaches (no QueryManager, no tool providers), and the oracle
   emits `[]` across the whole corpus.
4. **Property access on an element returns `undefined`**
   (`Evaluator.propertyGet`). In JS an `ElementNode` is a plain object, so
   `someElement.typeName` / `.props` / `.partial` / `.hasDynamicProps` /
   `.type` are readable from expressions. Observable only for programs that
   member-access an element value. (Where elements are *spread into plain
   objects* by the reference — `@Each` substitution via `toLiteralAST`, `$ast`
   serialization — the spread IS replicated: `Evaluator.toLiteralAst`,
   `Pipeline.convertAstPlain`.)
5. **Literal objects whose `k` is a real AST kind are not runtime-evaluated**
   (`Evaluator.evaluatePropValue`). JS AST nodes are plain objects, so the
   runtime duck-types any object with `k ∈ AST_KINDS` as an AST node. The
   port's typed values keep it as plain data. The *serializer-level*
   duck-typing (any plain object with a string `k` serializes as `{"$ast": …}`,
   regardless of whether `k` is a real kind — fixture `070-kvlist-k-key-astnode`)
   IS replicated in `Pipeline.convertValue`; only the runtime-evaluation
   collision for the 18 exact kind strings is not.

### Deliberate improvement over the Swift port

**Lone surrogates are preserved** (`Lexer.parseJsonStringLiteral`,
`TreeSerializer.quote`). `JSON.parse` keeps an unpaired `\uD800`–`\uDFFF`
escape as a lone UTF-16 surrogate inside the JS string; Swift `String` cannot
represent one and the Swift port substitutes U+FFFD (its KNOWN-DEVIATION #2).
Kotlin `String` CAN hold a lone surrogate, so the escape's code unit is
appended verbatim and the serializer re-escapes lone surrogates as `\udXXX`
(matching well-formed `JSON.stringify`, ES2019) rather than letting the UTF-8
encoder replace them with `?`. Verified against the JS oracle with a
`"lone:\ud800 pair:😀 hi:\udc00"` probe: byte-identical.

### Implemented quirk parity (not deviations)

- **§10.3 apostrophe-glue hazard**: the completed-statement scanner
  (`StreamCore.scanNewCompleted`) is quote-aware but deliberately NOT
  comment-aware, so an apostrophe inside a `//` comment glues following lines
  into one pending statement (fixture `partial/115`).
- **Whole-string raw fallback** on ANY invalid escape in a double-quoted
  string — one bad escape means *every* escape in that string stays literal
  (fixture 017).
- **Serializer duck-typing**: any object with a `steps` array serializes as
  `{"$action": …}`; any plain object with a string-valued `k` serializes as
  `{"$ast": …}` (mirrors `spec/fixtures/generator/lib/serialize.mjs`).
- **Schema `default` application** (`Materialize.materializeComp`): a
  missing/null REQUIRED prop takes the JSON Schema property's `default` before
  `missing-required` / `null-required` is reported. The shipped GenOS contract
  declares no defaults; this is future-proofing.
- **CRLF and combining-mark adjacency** parse exactly like JS because every
  scanner is code-unit based (fixtures 073, 074).

## Phase 2 handoff

The spec §11 app-level pure helpers (`cleanLang`, `extractActions`,
`parseOsCommand`, `parseGenosUrl`, `parseImgUrl`) live in the app layer
(store.ts / GenOS.tsx / tools/images.ts), NOT in lang-core, and are out of
scope here. See the Swift sibling's README "PHASE-2 HANDOFF" section for the
per-helper port checklist; both native ports must reproduce them byte-exact in
their Phase 2 GenOSCore packages. Notably `cleanLang` is NOT string-aware and
must not reuse `Preprocess.stripFences`.
