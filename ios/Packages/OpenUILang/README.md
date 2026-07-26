# OpenUILang

Swift port of the `@openuidev/lang-core` openui-lang parser + runtime
evaluator, oracle-verified byte-for-byte against the JS reference
implementation over the golden fixture corpus in `spec/fixtures/` (105
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
implementation are known and deliberate; each is listed with the condition
under which it *would* become observable.

1. **Collation outside ASCII** (`Evaluator.swift`, `sortCompare`;
   `StringJS.swift`, `jsASCIILocaleCompare`). `@Sort`'s string comparator in
   JS is `String.prototype.localeCompare` — V8's ICU collation with the CLDR
   root table and ICU's `alternate = non-ignorable` default.

   **ASCII no longer goes through Foundation.** The port carries the
   CLDR-root PRIMARY weight table for U+0000–U+007F and runs the Unicode
   Collation Algorithm over it directly (primary weights, ignorables removed,
   then the tertiary case level; lowercase before uppercase). The same table
   is compiled into the Kotlin port, so the two are byte-identical here by
   construction — and the answer no longer depends on which ICU version
   Foundation happens to be linked against, which differs between Linux CI and
   iOS devices. Verified: 235,233 ordered pairs over the full 0x00–0x7F
   alphabet against V8, zero mismatches; plus a 40-program × ~80-string
   `@Sort` sweep byte-identical across the oracle and both ports. Fixture
   `090-sort-ascii-collation` pins the inputs the old Kotlin collator got
   wrong (`"a-b"`/`"ab"`, `" s"`, `"a b c"`, `"a.b"`, `"[object Object]"`).

   What remains a deviation: a string containing any code unit **above
   U+007F** still falls back to Foundation's `en_US`
   `String.compare(_:options:range:locale:)`, which can differ from V8's ICU
   tables on compatibility ligatures and locale tailorings (and from the
   Kotlin port's `java.text.Collator` fallback).

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

4. **Only `TypeError`s from `ToPrimitive` reach `runtimeErrors`**
   (`Evaluator.evaluateElementProps`, `RuntimeValue.JSTypeError`). This
   REPLACES the former "`runtimeErrors` is always empty" deviation, which
   was wrong: `evaluate-tree.js` wraps every prop in try/catch, and JS
   `String(obj)` THROWS `TypeError: Cannot convert object to primitive
   value` whenever the object shadows `toString` — reachable from ordinary
   source (`$s = { toString: 1 }` then `"t" + $s`), and observable twice
   over, because the caught prop also keeps its RAW `$ast` value instead of
   an evaluated one (fixtures `081-tostring-shadow-throws`,
   `082-runtime-error-outer-prop`). The port now models exactly that throw
   and records the entry with the reference's message text — including the
   case an own-key check can never see, an object with NO prototype at all
   (`{"__proto__": null, a: 1}` has neither `toString` nor `valueOf`, so
   `"t" + $s` throws; fixture `087-proto-null-toprimitive-throws`).

   Two further reachable throws are modelled as well, both found by taking
   the JS object model seriously: `TypeError: builtin.fn is not a function`,
   raised when `BUILTINS[name]` resolves through `Object.prototype`
   (`"x" + @toString(1)`; fixture `084-reserved-call-expression-throws`), and
   V8's `'caller', 'callee', and 'arguments' ...` poison-pill message when
   `Function.prototype.arguments` / `.caller` is read off an inherited native
   function (`$obj.toString.arguments`). What is still NOT modelled is any
   other JS runtime throw inside prop evaluation — there is no other
   reachable one in this value model (there are no *callable* values,
   `toNumber` never throws, and lang-core's own pushes into `errors` come
   from QueryManager/tool-provider paths AppLess never reaches). A future
   contract that adds throwing paths must extend the catch.

5. **Synthetic AST-shaped objects are not runtime-evaluated**
   (`Evaluator.swift`, `evaluatePropValue`; `JSObjects.astNodeView`). JS AST
   nodes are plain objects, so the runtime duck-types any object whose `k` is
   in `AST_KINDS` (`"Str"`, `"Num"`, `"BinOp"`, …) as an AST node. The port's
   typed values only recognise a real `.ast` — reached either directly or
   **through the prototype chain**, which is the reachable case and IS now
   modelled (fixture `085-proto-object-valued`: a row that inherits
   `k: "StateRef"` from a `{"__proto__": $x}` entry is evaluated, not copied).
   What is still not modelled is a literal `{k: "Str", v: "x"}` written by
   hand, and an object whose OWN keys SHADOW an inherited AST field
   (`{"__proto__": $x, n: "$y"}` reads `n` off the prototype here, off the own
   key in JS).

   The *serializer-level* duck-typing (any object with a string `k` —
   inherited or own — serializes as `{"$ast": ...}`, regardless of whether `k`
   is a real kind; fixtures `070-kvlist-k-key-astnode`,
   `085-proto-object-valued`) IS replicated in `Pipeline.convertValue`.

   (The former deviation #5, "property access on an element returns
   `undefined`", is GONE: element receivers now read their own fields
   (`typeName`, `props`, `partial`, `hasDynamicProps`, `type`, `statementId`)
   through the same `JSObjects.getMember` every other receiver uses — fixture
   `088-prototype-member-access`.)

6. **`@Sort` on an array that mixes numeric-parsable and non-numeric strings**
   (`Evaluator.callDataBuiltin`). lang-core's comparator switches to a
   NUMERIC comparison when *both* operands parse as numbers and to collation
   otherwise, which is not a strict weak ordering: `" "` (→ 0) beats `"-0"`
   numerically while `"_x"` beats both by collation, and transitivity fails.
   The result then depends on which pairs the sort algorithm happens to
   compare, and V8's TimSort, Swift's `sorted(by:)` and Kotlin's `sortedWith`
   visit different pairs. Both ports agree with the oracle and with each other
   on any array where the comparator IS consistent (all-numeric or
   all-non-numeric), which is every corpus fixture; a mixed array of ~80
   strings diverges in roughly 5% of programs. Closing it means porting V8's
   TimSort verbatim.

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
  Not expressed as a corpus fixture to keep the 97-fixture CI gate stable.

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
- **`isReservedCall` is prototype-chain aware** (`Builtins.swift`).
  lang-core writes `RESERVED_CALLS = { Query, Mutation }` and tests
  membership with `name in RESERVED_CALLS` — the `in` operator, which walks
  the prototype chain, so all twelve `Object.prototype` own names
  (`toString`, `valueOf`, `constructor`, `hasOwnProperty`, `isPrototypeOf`,
  `propertyIsEnumerable`, `toLocaleString`, `__proto__`,
  `__defineGetter__`, `__defineSetter__`, `__lookupGetter__`,
  `__lookupSetter__`) answer `true` too. `@ident` lexes to a BUILTIN token
  with ANY name, so `q = @toString("tool")` is a reserved-call DECLARATION —
  it resolves to a `RuntimeRef` (undefined here) rather than an
  `unknown-component` error, and an inline `@constructor(...)` reports
  `inline-reserved` (fixture `078-reserved-call-prototype-names`).
- **Falsy, not nil, iterator-name guard** (`Materialize.swift`,
  `Evaluator.swift`). `materialize.js` and `evaluator.js` both write
  `if (!varName)`, so an EMPTY-string iterator (`@Each(items, "", …)`)
  aborts the lazy path: the template's refs resolve as ordinary refs (and
  land in `meta.unresolved`) and the loop yields `[]` rather than iterating
  (fixture `079-each-empty-iterator-name`).
- **`__proto__` vanishes on ASSIGNMENT but survives `Object.fromEntries`**
  (`RTObject.assign`, `Materialize.swift`, `Pipeline.jsAssign`). A plain
  `{}` inherits `Object.prototype`'s `__proto__` accessor, so `o[k] = v`
  never creates that own key — which is what `materialize.js`'s object
  case, `evaluate-prop.js`'s plain-object recursion and every
  `serialize.mjs` output object do. `evaluator.js`'s `Obj` case uses
  `Object.fromEntries` (a define, not an assignment) and DOES keep it, so
  the port keeps it there too; the serializer drops it again on the way out
  (fixture `080-proto-object-key`).
- **The `schemaCtx` argument's PRESENCE is threaded, not hardcoded**
  (`Evaluator.SchemaCtx`). See "Schema context" below.
- **`PropObject` iteration is `Object.keys` order**
  (`StringJS.jsOwnPropertyKeys`) — canonical array indices first in
  ascending numeric order, then the rest in insertion order. Distinct from
  the serializer's order, which additionally sorts the string group; pinned
  by `PropObjectKeyOrderTests`.
- **Serializer key ORDER is `JSON.stringify`'s, not
  `Array.prototype.sort`'s** (`StringJS.jsOwnKeyLess`). The reference
  serializer sorts keys and re-inserts them into a fresh object, but the
  bytes come from `JSON.stringify`, which re-derives the order from
  `OrdinaryOwnPropertyKeys`: canonical array indices (`"0"`–
  `"4294967294"`, `ToString(ToUint32(k)) === k`) come FIRST in ascending
  numeric order, then everything else in UTF-16 code-unit order. So
  `"10"` follows `"2"`, and `"4294967295"` is demoted to the string group
  (fixture `075-object-key-index-order`).
- **ECMAScript `Math.round`** (`Evaluator.jsMathRound`): "closest integral
  Number, ties toward +∞" — not Swift's half-away-from-zero `rounded()`
  and not `floor(x + 0.5)`, whose addition can round up first
  (`Math.round(0.49999999999999994)` is `0` in JS, the shorthand says `1`)
  and which loses `-0`. Reachable through `@Round`'s scaling as
  `@Round(0.049999999999999994, 1)`; pinned by `MathRoundSemanticsTests`.
- **ECMAScript `Number::toString`** (`TreeSerializer.formatNumber`):
  shortest-round-trip digits, positional for decimal exponents in
  (-7, 21) — including integer-valued doubles beyond Int64
  (`12345678901234567168` prints `"12345678901234567000"`) — and
  `1e+21` / `1e-7` style exponential outside.

## Schema context (`evaluate`'s third argument)

`evaluator.js` takes `evaluate(node, context, schemaCtx)` and branches on
schemaCtx's PRESENCE at four sites. The port threads a `SchemaCtx?` marker to
exactly the same places rather than hardcoding the "present" branch:

| evaluator.js | What presence controls | Port |
|---|---|---|
| 61 | catalog def lookup feeding the reactive-prop test one line below | modelled but inert — the GenOS contract marks no prop `reactive()`, so evaluator.js:65 is dead in BOTH states |
| 75 | `props[key] = schemaCtx ? context.getState(val.n) : val` — a bare `$state` prop is READ or PRESERVED as a raw `StateRef` AST | `Evaluator.evaluate`, `.comp` mappedProps branch |
| 89 | nested ElementNodes in props are re-evaluated inline, or left as the recursion already built them | same branch, gated on `schemaCtx != nil` |
| 421 | the `@Each` per-item element re-evaluation gate | `evaluateLazyBuiltin` |

The load-bearing consequence is the ACTION path: `evaluateActionCall` calls the
TWO-argument form (`evaluate(args[0], context)`, evaluator.js:264), so every
step inside `Action([…])` is evaluated WITHOUT schema context and keeps its
`$state` props as `{"$ast": {"k": "StateRef", …}}` for click-time evaluation.
Fixtures `076-action-staterefs-preserved` (direct + nested-element step) and
`077-action-each-staterefs` (`@Each` inside an `Action`).

Every other recursion in `evaluator.js` — array elements, object entries,
operator operands, ternary branches, member/index receivers, eager builtin
arguments — calls the two-argument form as well, so the port passes `nil`
there. Those drops converge back because `evaluate-prop.js` re-enters
`evaluateElementProps` on any element/array result, but they are reproduced
literally rather than assumed harmless.

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
