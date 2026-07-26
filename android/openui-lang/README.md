# openui-lang (Kotlin/JVM)

Kotlin port of the `@openuidev/lang-core` openui-lang parser + runtime
evaluator, oracle-verified byte-for-byte against the JS reference
implementation over the golden fixture corpus in `spec/fixtures/`
(114 fixtures) plus differential probe sweeps.

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
| `StringJs.kt` | the JVM-vs-JS trap list, `jsStringSplit`, the `JSON.stringify` own-key order (`JS_OWN_KEY_ORDER`, incl. canonical-array-index hoisting) and the CLDR-root ASCII collation table (`jsAsciiLocaleCompare`) |
| `Ast.kt` | `AstNode` sealed hierarchy, `walkAst`, `collectStateRefs` |
| `Lexer.kt` | `tokenize`, double-quoted strings via strict JSON parsing with whole-string raw fallback, single-quoted escapes, numbers, `&`→`&&` / `|`→`||` |
| `Preprocess.kt` | exact ECMAScript whitespace set, `jsTrim`/`jsTrimEnd`, `stripFences` (string-aware), `stripComments` |
| `Statements.kt` | `autoClose` (§7), `splitStatements` (§6, ternary lookahead) |
| `Expressions.kt` | Pratt parser (§5), the `isBuiltin` collision rule (only `Action` parses bare) |
| `JsObject.kt` | **the JS plain-object model**: `Object.prototype`'s own-name table (+ the Array/Number/String/Boolean/Function intrinsics), every value's `[[Prototype]]`, and the single implementations of `.`/`[]` (`getMember`) and `in` (`hasProperty`) |
| `Builtins.kt` | builtin / lazy / action-step / reserved-call name registries, all routed through `JsObject.kt` |
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
- **`Math.round`.** JS is "the integral Number closest to x, ties toward
  **+∞**" (ES 21.3.2.28) — NOT Kotlin's `Math.round`/`roundToInt`, which is
  half-**away-from-zero** and disagrees on every negative tie (`-0.5`, `-1.5`,
  `-2.5`, …), and NOT the `floor(x + 0.5)` shorthand either. `floor(x + 0.5)`
  is wrong twice: the addition can round UP before the floor sees it
  (`Math.round(0.49999999999999994)` is `0` in JS, but
  `0.49999999999999994 + 0.5` is exactly `1.0` in binary64, so the shorthand
  answers `1`), and it loses the negative zero (JS `Math.round(-0.5)` is `-0`).
  `@Round(x, d)` scales first (`round(x * 10^d) / 10^d`), so the same
  counterexample is reachable from an ordinary decimal:
  `@Round(0.049999999999999994, 1)` is `0` in JS and `0.1` under the shorthand.
  `Evaluator.jsMathRound` implements the spec rule with an exact tie test
  (`x >= floor(x) + 0.5`; a non-integral double always has |x| < 2^52, so
  `floor(x) + 0.5` is representable and the comparison cannot round —
  unlike `x - floor(x) >= 0.5`, where the subtraction itself can).
  Pinned against node by `MathRoundSemanticsTest`.
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
known and deliberate — but "not in the corpus" is not "not reachable", so each
entry says how far it reaches, with a command that reproduces it.

**The numbering is IDENTICAL in `ios/Packages/OpenUILang/README.md`.** A code
comment saying "KNOWN-DEVIATION #5" means the same entry in both ports; the two
lists are maintained as one.

1. **Collation outside ASCII** (`Evaluator.sortCompare`,
   `StringJs.jsAsciiLocaleCompare`). `@Sort`'s string comparator in JS is
   `String.prototype.localeCompare` — V8's ICU collation with the CLDR root
   table and ICU's `alternate = non-ignorable` default.

   **ASCII is no longer an approximation.** The port carries the CLDR-root
   PRIMARY weight table for U+0000–U+007F and runs the Unicode Collation
   Algorithm over it directly (primary weights, ignorables removed, then the
   tertiary case level; lowercase before uppercase). The same table, generated
   from the same V8 dump, is compiled into the Swift port, so the two ports are
   byte-identical here by construction rather than by luck.

   This REPLACES `java.text.Collator.getInstance(Locale.US)`, whose legacy
   en_US rules treat **hyphen and space as ignorable at primary strength**:
   it answered `"a-b" > "ab"` and `"co-op" > "coop"` where V8 says `<`, and
   ordered `"a/b"`/`"a*b"` and `"a.b"`/`"a/b"` the other way round. The
   previous edition of this entry called that "not observable in the current
   fixture corpus"; that framing was wrong. It is observable the moment a
   `@Sort` input contains a hyphen or an embedded space, which is the common
   case for model-generated labels. Fixture `090-sort-ascii-collation` now
   pins exactly those inputs (`"a-b"`/`"ab"`, `" s"`, `"a b c"`, `"a.b"`,
   `"[object Object]"`, leading-space strings).

   **Verified, reproducibly** — this used to be an uncommitted claim about
   "235,233 ordered pairs"; it is now a committed probe:

   ```sh
   cd spec/fixtures/generator && node probes/verify-collation.mjs
   # [collation] corpus 700 strings, 244650 pairs (V8 v22.22.2, seed 0xc011a7e)
   # [collation] ok: committed corpus matches V8 v22.22.2 on all pairs
   # [collation] ok: swift ASCIICollationTests
   # [collation] ok: kotlin AsciiCollationTest
   # [collation] PASS - V8 and both ports agree on all 244650 ASCII pairs.
   ```

   `probes/collation-corpus.json` records V8's answer for every pair of a
   deterministic 700-string corpus over the FULL 0x00–0x7F alphabet
   (`--emit` regenerates it); `AsciiCollationTest` and the Swift
   `ASCIICollationTests` assert against that one file, which makes it a
   cross-port gate as well as a V8 conformance gate.

   What remains a deviation: a string containing any code unit **above
   U+007F** falls back to `java.text.Collator.getInstance(Locale.US)` (Swift
   falls back to Foundation's `en_US` compare). Those two disagree with each
   other and with V8 on compatibility ligatures (U+FB01 `ﬁ`, U+FB00 `ﬀ`,
   U+01C6 `ǆ`, which V8 decomposes to `f`+`i` / `f`+`f` / `d`+`z`) and on some
   non-Latin scripts. Closing that means extending the weight table beyond
   ASCII (or vendoring ICU4J with `alternate = non-ignorable`).

   Still deliberately NOT `String.compareTo`, which is raw code-unit order and
   would sort `"a" > "B"`.

2. **Lone surrogates — a CROSS-PORT difference, and this port is the one that
   matches the oracle** (`Lexer.parseJsonStringLiteral`, `TreeSerializer.quote`;
   Swift `Lexer.parseJSONStringLiteral`).

   Kotlin `String` is a UTF-16 code-unit sequence and CAN hold an unpaired
   surrogate, so this port keeps it and the serializer re-escapes it as
   `\udXXX` (well-formed `JSON.stringify`, ES2019) — byte-identical to the
   oracle. Swift `String` cannot represent one and substitutes U+FFFD, so the
   Swift port diverges from the oracle here and from this port.

   **Scope correction.** Both READMEs used to scope this to "programs
   containing an unpaired surrogate escape in a double-quoted string". That is
   wrong: no escape is needed. A WELL-FORMED astral character plus an ordinary
   index reaches it, because indexing is UTF-16 in JS and in both ports:

   ```sh
   # spec/fixtures/generator
   printf 's = "a\360\237\230\200b"\nroot = Card([TextContent("u1=" + s[1])])\n' > /tmp/astral.oui
   node probes/expected-tree.mjs /tmp/astral.oui   # "text": "u1=\ud83d"
   ```

   oracle `\ud83d`, Kotlin `\ud83d`, Swift U+FFFD. Any astral character in an
   indexed or `@Sort`ed label lands here. Pinned from both sides —
   `LoneSurrogateTest.kt` asserts the oracle-matching bytes, the Swift
   `LoneSurrogateTests.swift` asserts the U+FFFD bytes — so the difference is
   recorded, not rediscovered. It is deliberately NOT a corpus fixture: the
   Swift `FixtureOracleTests` gate compares against the oracle and would fail.

3. **Object-identity loose equality is always false**
   (`RuntimeValue.jsLooseEquals`). JS `==` between two objects compares
   references; this port has value semantics and no stable identities. The
   materializer never routes the same JS object instance to both sides, so the
   oracle produces `false` too.

4. **Only `TypeError`s from `ToPrimitive` reach `runtimeErrors`**
   (`Evaluator.evaluateElementProps`, `RuntimeValue.JsTypeError`). This
   REPLACES the former "`runtimeErrors` is always empty" deviation, which was
   wrong: `evaluate-tree.js` wraps every prop in try/catch, and JS
   `String(obj)` THROWS `TypeError: Cannot convert object to primitive value`
   whenever the object shadows `toString` — reachable from ordinary source
   (`$s = { toString: 1 }` then `"t" + $s`), and observable twice over,
   because the caught prop also keeps its RAW `$ast` value instead of an
   evaluated one (fixtures `081-tostring-shadow-throws`,
   `082-runtime-error-outer-prop`). The port now models exactly that throw and
   records the entry with the reference's message text — including the case an
   own-key check can never see, an object with NO prototype at all
   (`{"__proto__": null, a: 1}` has neither `toString` nor `valueOf`, so
   `"t" + $s` throws; fixture `087-proto-null-toprimitive-throws`).

   Two further reachable throws are modelled as well, both discovered by
   taking the JS object model seriously:
   `TypeError: builtin.fn is not a function`, raised when `BUILTINS[name]`
   resolves through `Object.prototype` (`"x" + @toString(1)`; fixture
   `084-reserved-call-expression-throws`), and V8's `'caller', 'callee', and
   'arguments' ...` poison-pill message when `Function.prototype.arguments` /
   `.caller` is read off an inherited native function
   (`$obj.toString.arguments`; fixture `098-function-poison-pill`, plus
   `JsObjectModelTest.poisonPillsThrowV8sMessage`). What is still NOT modelled
   is any other JS runtime throw inside prop evaluation — there is no other
   reachable one in this value model (there are no *callable* values,
   `toNumber` never throws, and lang-core's own pushes into `errors` come from
   QueryManager / tool-provider paths AppLess never reaches). A future
   contract that adds throwing paths must extend the catch.

5. **Synthetic AST-shaped objects are not runtime-evaluated**
   (`Evaluator.evaluatePropValue`, `JsObjects.astNodeView`). JS AST nodes are
   plain objects, so the runtime duck-types any object whose `k` is in
   `AST_KINDS` as an AST node. The port's typed values only recognise a real
   `RtValue.Ast` — reached either directly or **through the prototype chain**,
   which is the reachable case and IS now modelled (fixture
   `085-proto-object-valued`: a row that inherits `k: "StateRef"` from a
   `{"__proto__": $x}` entry is evaluated, not copied). What is still not
   modelled is a literal `{k: "Str", v: "x"}` written by hand, and an object
   whose OWN keys SHADOW an inherited AST field (`{"__proto__": $x, n: "$y"}`
   reads `n` off the prototype here, off the own key in JS).

   Why it is not closed: the port's `AstNode` is a typed sealed hierarchy and
   an object literal is not. `{k: "Str", v: -1}` evaluates to the NUMBER `-1`
   in JS (`evaluate` returns `node.v` verbatim), and `AstNode.Str.v` is a
   `String`. Closing it means re-implementing `evaluate` over untyped objects.

   Reproduction (the first run of the `synthesis` fuzz campaign found exactly
   this, in 3 of 400 programs):

   ```sh
   printf 'row = { k: "Str", v: -1 }\nroot = Card([KVList([row])])\n' > /tmp/ast.oui
   node probes/expected-tree.mjs /tmp/ast.oui     # "rows": [ -1 ]
   # both ports:                                  # "rows": [ {"$ast": {"k":"Str","v":-1}} ]
   ```

   AST discriminants are therefore excluded from the `synthesis` campaign's
   `k` alphabet (`probes/gen-fuzz-corpus.mjs`, `SYNTH_K_VALUES`), which says so
   and points here.

   The *serializer-level* duck-typing (any object with a string `k` —
   inherited or own — serializes as `{"$ast": …}`, regardless of whether `k` is
   a real kind — fixtures `070-kvlist-k-key-astnode`, `085-proto-object-valued`)
   IS replicated in `Pipeline.convertValue`.

6. **`@Sort` on an array that mixes numeric-parsable and non-numeric strings**
   (`Evaluator.callDataBuiltin`). lang-core's comparator switches to a NUMERIC
   comparison when *both* operands parse as numbers and to collation otherwise,
   which is not a strict weak ordering: `" "` (→ 0) beats `"-0"` numerically
   while `"_x"` beats both by collation, and transitivity fails. The result
   then depends on which pairs the sort algorithm happens to compare, and V8's
   TimSort, Kotlin's `sortedWith` and Swift's `sorted(by:)` visit different
   pairs. Both ports agree with the oracle and with each other on any array
   where the comparator IS consistent (all-numeric or all-non-numeric), which
   is every corpus fixture.

   **How often it bites is corpus-dependent, so no bare rate is quoted here.**
   The rate tracks how many of the strings `Number()` happens to parse: an
   earlier sweep of 40 programs × ~80 strings drawn from a label-like alphabet
   measured ~5%, and an independent random-ASCII corpus of 60 programs measured
   13% (8/60). Neither number generalises; the honest statement is that any
   `@Sort` input mixing numeric-parsable and non-numeric strings is at risk.
   Closing it means porting V8's TimSort verbatim.

7. **Serializer-level `TypeError`: shapes for which NO expected tree exists.**
   Two shapes make `lib/serialize.mjs` itself throw
   `TypeError: Cannot convert undefined or null to object`, taking the fixture
   generator down with it, so the reference has no answer to port:

   | shape | site |
   | --- | --- |
   | a `null`/`undefined` ACTION STEP — `{steps: [null]}` | `Object.keys(step)`, serialize.mjs:51 |
   | an object that duck-types as an element with no `props` — `{type: "element", typeName: "X"}` | `Object.keys(el.props)`, serialize.mjs:84 |

   ```sh
   printf 'root = Card([KVList([{ steps: [null] }])])\n' > /tmp/thr.oui
   node probes/expected-tree.mjs /tmp/thr.oui
   # [expected-tree] FAILED: TypeError: Cannot convert undefined or null to object
   #     at serializeStep (…/lib/serialize.mjs:51:28)
   ```

   Both ports emit `{}` for the step and an element with empty props
   respectively (`JsObjects.objectKeys` answers `null` and the caller treats it
   as "no keys"), and the two ports agree with each other. Because there is
   nothing to compare against, `probes/run-differential.mjs` detects an oracle
   throw, reports it in the summary (`oracle threw : N step(s)`) and
   cross-compares the two PORTS on that step instead of failing the run. No
   fixture can pin these shapes for the same reason.

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
- **`isReservedCall` is prototype-chain aware** (`Builtins.isReservedCall`).
  lang-core writes `RESERVED_CALLS = { Query, Mutation }` and tests membership
  with `name in RESERVED_CALLS` — the `in` operator, which walks the prototype
  chain, so all twelve `Object.prototype` own names (`toString`, `valueOf`,
  `constructor`, `hasOwnProperty`, `isPrototypeOf`, `propertyIsEnumerable`,
  `toLocaleString`, `__proto__`, `__defineGetter__`, `__defineSetter__`,
  `__lookupGetter__`, `__lookupSetter__`) answer `true` too. `@ident` lexes to
  a BUILTIN token with ANY name, so `q = @toString("tool")` is a reserved-call
  DECLARATION — it resolves to a `RuntimeRef` (undefined here) rather than an
  `unknown-component` error, and an inline `@constructor(...)` reports
  `inline-reserved` (fixture `078-reserved-call-prototype-names`).
- **Falsy, not null, iterator-name guard** (`Materialize.materializeLazyBuiltin`,
  `Evaluator.evaluateLazyBuiltin`). Both JS sites write `if (!varName)`, so an
  EMPTY-string iterator (`@Each(items, "", …)`) aborts the lazy path: the
  template's refs resolve as ordinary refs (and land in `meta.unresolved`) and
  the loop yields `[]` rather than iterating (fixture
  `079-each-empty-iterator-name`).
- **`__proto__` vanishes on ASSIGNMENT but survives `Object.fromEntries`**
  (`RtObject.assign`, `Materialize`, `Pipeline.jsAssign`). A plain `{}`
  inherits `Object.prototype`'s `__proto__` accessor, so `o[k] = v` never
  creates that own key — which is what `materialize.js`'s object case,
  `evaluate-prop.js`'s plain-object recursion and every `serialize.mjs` output
  object do. `evaluator.js`'s `Obj` case uses `Object.fromEntries` (a define,
  not an assignment) and DOES keep it, so the port keeps it there too; the
  serializer drops it again on the way out (fixture `080-proto-object-key`).
- **The `schemaCtx` argument's PRESENCE is threaded, not hardcoded**
  (`Evaluator.SchemaCtx`). See "Schema context" below.
- **`PropObject` iteration is `Object.keys` order**
  (`StringJs.jsOwnPropertyKeys`) — canonical array indices first in ascending
  numeric order, then the rest in insertion order. Distinct from the
  serializer's order, which additionally sorts the string group; pinned by
  `PropObjectKeyOrderTest`.
- **Serializer key ORDER is `JSON.stringify`'s, not `Array.prototype.sort`'s**
  (`StringJs.JS_OWN_KEY_ORDER`). The reference serializer sorts keys and
  re-inserts them into a fresh object, but the bytes come from
  `JSON.stringify`, which re-derives the order from `OrdinaryOwnPropertyKeys`:
  canonical array indices (`"0"`–`"4294967294"`, `ToString(ToUint32(k)) === k`)
  come FIRST in ascending numeric order, then everything else in code-unit
  order. So `"10"` follows `"2"`, and `"4294967295"` is demoted to the string
  group (fixture `075-object-key-index-order`).
- **Schema `default` application** (`Materialize.materializeComp`): a
  missing/null REQUIRED prop takes the JSON Schema property's `default` before
  `missing-required` / `null-required` is reported. The shipped GenOS contract
  declares no defaults; this is future-proofing.
- **CRLF and combining-mark adjacency** parse exactly like JS because every
  scanner is code-unit based (fixtures 073, 074).

## Schema context (`evaluate`'s third argument)

`evaluator.js` takes `evaluate(node, context, schemaCtx)` and branches on
schemaCtx's PRESENCE at four sites. The port threads a `SchemaCtx?` marker to
exactly the same places rather than hardcoding the "present" branch:

| evaluator.js | What presence controls | Port |
|---|---|---|
| 61 | catalog def lookup feeding the reactive-prop test one line below | modelled but inert — the GenOS contract marks no prop `reactive()`, so evaluator.js:65 is dead in BOTH states |
| 75 | `props[key] = schemaCtx ? context.getState(val.n) : val` — a bare `$state` prop is READ or PRESERVED as a raw `StateRef` AST | `Evaluator.evaluateComp` mappedProps loop |
| 89 | nested ElementNodes in props are re-evaluated inline, or left as the recursion already built them | same function, gated on `schemaCtx != null` |
| 421 | the `@Each` per-item element re-evaluation gate | `Evaluator.evaluateLazyBuiltin` |

The load-bearing consequence is the ACTION path: `evaluateActionCall` calls the
TWO-argument form (`evaluate(args[0], context)`, evaluator.js:264), so every
step inside `Action([…])` is evaluated WITHOUT schema context and keeps its
`$state` props as `{"$ast": {"k": "StateRef", …}}` for click-time evaluation.
Fixtures `076-action-staterefs-preserved` (direct + nested-element step) and
`077-action-each-staterefs` (`@Each` inside an `Action`).

Every other recursion in `evaluator.js` — array elements, object entries,
operator operands, ternary branches, member/index receivers, eager builtin
arguments — calls the two-argument form as well, so the port passes `null`
there. Those drops converge back because `evaluate-prop.js` re-enters
`evaluateElementProps` on any element/array result, but they are reproduced
literally rather than assumed harmless.

`evaluate-tree.js`'s `evaluateElementProps` (per-prop try/catch) and
`evaluator.js`'s `evaluateElementInline` (no catch) are DIFFERENT functions in
the reference, and the port keeps them separate for the same reason: a throw
raised while inline-evaluating a nested element must escape to the OUTER prop's
catch, so the recorded `runtimeErrors` entry names the outer component and the
outer prop key (fixture `082-runtime-error-outer-prop`: the error is reported
against `Card`'s `children`, not against the inner `ListItem`).

## Phase 2 handoff

The spec §11 app-level pure helpers (`cleanLang`, `extractActions`,
`parseOsCommand`, `parseGenosUrl`, `parseImgUrl`) live in the app layer
(store.ts / GenOS.tsx / tools/images.ts), NOT in lang-core, and are out of
scope here. See the Swift sibling's README "PHASE-2 HANDOFF" section for the
per-helper port checklist; both native ports must reproduce them byte-exact in
their Phase 2 GenOSCore packages. Notably `cleanLang` is NOT string-aware and
must not reuse `Preprocess.stripFences`.
