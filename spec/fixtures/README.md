# Golden fixtures — the openui-lang parser oracle

This corpus keeps the future Swift (`ios/Packages/OpenUILang`) and Kotlin
(`android/openui-lang`) parsers honest: every `NNN-name.oui` input has a
`NNN-name.expected.json` tree **generated from the real reference parser**
(`@openuidev/lang-core` 0.1.2, the parsing engine inside `@openuidev/react-lang`
0.1.5) driven with the **real GenOS component contract**
(`src/genos/ui/contract.tsx`). A native parser is correct when, for every
fixture, it produces a byte-identical canonical JSON document.

Normative grammar: [`../openui-lang.md`](../openui-lang.md). Machine-readable
contract: [`../contract/genos.schema.json`](../contract/genos.schema.json)
(regenerate with `node spec/contract/export-schema.mjs` from the repo root).

```
spec/fixtures/
├── NNN-name.oui            complete-program fixtures (001–074)
├── NNN-name.expected.json  GENERATED — never edit by hand
├── partial/                prefix-truncated streaming snapshots (101–115)
│   ├── NNN-name.oui        NO trailing newline — the cut point is the last byte
│   └── NNN-name.expected.json
└── generator/              the generator package (see "Regenerating")
```

## How expected trees are produced

For each `.oui` file (bytes fed **verbatim** — no trimming), the generator
replays the app's steady-state Renderer pipeline (spec §1, §10):

1. `sp = createStreamingParser(library.toJSONSchema(), library.root)` — the
   exact entry point react-lang's `useOpenUIState` uses.
2. `result = sp.set(<file text>)` — full text, like every store flush. Partial
   fixtures are just truncated files; `isStreaming` does not change parsing
   (spec §10.7), so the same call yields the streaming partial tree, including
   `meta.incomplete` and auto-closing.
3. `store = createStore(); store.initialize(result.stateDeclarations, {})` —
   `$` defaults seeded, exactly like the Renderer's store initialization.
4. `evaluateElementProps(result.root, { ctx, library, store, errors })` with
   the same `EvaluationContext` react-lang builds (`getState` unwraps
   `{value, componentType}` wrappers; `resolveRef` returns undefined — AppLess
   never uses Query/Mutation).
5. Deterministic serialization (all object keys sorted, 2-space indent,
   trailing newline).

Fixtures therefore capture the **post-runtime-evaluation** tree — operators,
builtins, member/index access, `$state` reads and `@Each` loops are already
resolved; only deferred click-time values (ActionPlans) remain symbolic.

## Expected-tree format (normative for native fixture runners)

Top-level document:

```jsonc
{
  "root": <element> | null,      // null: no renderable root (host shows skeleton)
  "meta": {
    "incomplete": bool,          // pending tail needed auto-closing this pass
    "unresolved": [string, ...], // refs that failed to resolve, in resolution
                                 // order, duplicates preserved
    "errors": [                  // parser validation errors, in emission order
      { "code": "missing-required" | "null-required" | "unknown-component"
              | "inline-reserved",
        "component": string,     // e.g. "Toggle"
        "path": string,          // JSON pointer into props, e.g. "/on" ("" for
                                 // component-level errors)
        "message": string,       // reference impl's text — compare informationally
        "statementId": string?   // omitted when undefined
      }
    ]
  },
  "state": { "$name": <value>, ... },  // stateDeclarations (materialized
                                       // defaults; auto-declared refs → null),
                                       // keys sorted
  "runtimeErrors": [                   // per-prop evaluation errors (rare)
    { "source": "runtime", "code": "runtime-error", "message": string,
      "component": string?, "statementId": string? }
  ]
}
```

Element node (`ElementNode` after prop evaluation):

```jsonc
{
  "component": string,      // typeName, e.g. "CardHeader"
  "statementId": string?,   // present iff the element came from a named
                            // statement (inline elements omit it)
  "props": { ... },         // named props (positional args mapped via the
                            // contract's property order), keys sorted,
                            // EXCLUDING "children"; props that evaluated to
                            // undefined are omitted, null is kept
  "children": <value>?      // present iff the element has a "children" prop
                            // (Card, TabItem); usually an array of nodes
}
```

Prop values:

| Runtime value | JSON encoding |
|---|---|
| string / number / boolean / null | as-is (`undefined` → `null` at value position) |
| array | array (element order preserved; parser has already applied array-drop rules) |
| plain object | object, keys sorted, `undefined` entries omitted |
| ElementNode | element node (shape above) |
| ActionPlan `{steps:[...]}` | `{"$action": {"steps": [<step>, ...]}}` |
| ActionStep | step object with sorted keys, e.g. `{"message": "...", "type": "continue_conversation"}`; a `@Set` step's deferred `valueAST` is `{"$ast": <ast>}` |
| leftover AST node (has a `k` kind tag; only in deferred slots) | `{"$ast": <node, keys sorted, deep>}` |
| non-finite number (NaN/±Infinity — e.g. fixture p114) | `{"$number": "NaN" \| "Infinity" \| "-Infinity"}` |

Notes for implementers:

- The per-node `partial` flag is **not** serialized: it equals
  `meta.incomplete` for every node in a pass (spec §10.5), so it carries no
  extra information. `hasDynamicProps` is an internal memo and also excluded.
- `meta.statementCount` is informational-only in the reference implementation
  (duplicate-counting quirks, spec §10.3) and is excluded.
- `meta.errors[].message` strings come from lang-core; a native runner MAY
  compare only `{code, component, path, statementId}` and treat `message` as
  informational — but everything else must match byte-for-byte after
  canonical JSON encoding (sorted keys, JS number formatting: `125` not
  `125.0`, shortest round-trip for doubles).
- Fixture inputs are the raw model response as the **parser** sees it. The
  app-level helpers `cleanLang` / `parseOsCommand` / `extractActions`
  (spec §11–§12) run **before/around** the parser and are ported and tested
  separately; `@OS(...)` fixtures (062, 063) intentionally show that the
  parser itself yields an empty program (`root: null`) for them.

## Corpus taxonomy

| Range | Theme |
|---|---|
| 001–004 | structure basics: Card, CardHeader, TextContent styles, TextCallout variants |
| 005–010 | references: backward/forward, unreferenced-statement dropping, PascalCase ids, duplicate ids (last wins) |
| 011–015 | entry selection tiers when `root` is absent (statement named `Card`; first `Card(...)` call; first component; first statement; non-element root → null) |
| 016–020 | strings & literals: JSON escape set, invalid-escape raw fallback, single quotes, numbers (exponent, negative), unicode/emoji |
| 021–026 | operators: arithmetic incl. div/mod by zero → 0, comparisons + loose `==` (`5 == "5"`), logical/unary, ternary (incl. multi-line), string concat (null → ""), precedence |
| 027–028 | member/index access, array `.length`, array pluck (`PieChart(data.category, data.amount)` idiom) |
| 029–032 | `@`-builtins: aggregates/numeric, Sort/Filter/First/Last, lazy `@Each` (actions capture concrete values), degenerate inputs |
| 033–034 | `$state` declarations (defaults, seeds into `value` props) and auto-declared undeclared refs |
| 035 | `//` and `#` comments |
| 036–045 | malformed input: named-arg colon/equals corruption (silent value loss), missing-required and null-required dropping, unknown component, extra args ignored, error-recovery `null` retained in arrays, skipped lines/junk chars, cycles, `&`/`\|` lexing, inline `Query`/`Mutation` |
| 046–047 | markdown fences: multi-block extraction, unclosed fence |
| 048–051 | Actions: `@ToAssistant` (with context), `@OpenUrl` with `genos://` urls, shared action refs, `@Set`/`@Reset` (deferred `valueAST`) |
| 052–061 | component deep-dives: lists/toggles/KVList, stats, cartesian charts + Series, PieChart, media, Bubbles/Chips, Tabs/TabItem, MapView, full Form, `$bindings` on every input type |
| 062–063 | `@OS` command responses → empty program (`root: null`), incl. fenced |
| 064 | kitchen sink: realistic screen combining most of the surface |
| 065–069 | single-fixture-component hardening: ImageBlock explicit `null` caption vs omitted; Bubbles messages with `me`/`time` omitted per-message; AreaChart `"step"` + single series; LineChart `"natural"` + xLabel/yLabel; HorizontalBarChart `"stacked"`. All five positional args are passed on the charts, so the `variant` **prop** is actually populated (in 054 the 3rd positional lands in `xLabel` — contract order is labels, series, xLabel, yLabel, variant) |
| 070–072 | serializer/runtime edge cases: `{k: ...}` data object duck-typed as `$ast` (070); `Number::toString` boundaries (071); Unicode NFC/NFD code-unit semantics — `==`/`!=` on canonically-equivalent strings, `@Filter` `contains`, distinct precomposed/decomposed object keys surviving into `state`, code-unit key sort (072) |
| partial/101–115 | streaming snapshots: cut mid-string, mid-call, mid-array, before root, mid-escape (lone `\`), inside a comment, partial/unclosed fence, mid-object, mid-ternary, mid-statement-name, pending duplicate id (ignored), mid-action message, mid-number exponent (NaN), comment-with-apostrophe glue hazard |

## Coverage matrix (33 contract components × fixtures)

`pNNN` = `partial/NNN`. Includes fixtures where the component is exercised via
its **dropping** rules (e.g. Toggle in 037 is dropped with `missing-required`).

| Component | Fixtures |
|---|---|
| Card | 001–010, 012, 016–061, 064–069 (all but 011, 013–015, 062–063), p101–p103, p105, p106, p108–p115 |
| CardHeader | 001–007, 009–013, 016–035, 037–040, 042, 044–061, 064–069, p101–p103, p108, p115 |
| TextContent | 003, 005, 006, 008, 010, 012, 016–018, 020, 024, 025, 027, 028, 030, 033–035, 037–039, 041, 043–047, 058, p105, p110, p112 |
| TextCallout | 004, 064 |
| ListItem | 007, 030, 031, 036, 048, 050, 052, 058, 059, 064, p103, p115 |
| Toggle | 037, 038, 052, 064 |
| ListBlock | 007, 030, 031, 036, 048, 050, 052, 058, 059, 064, p103, p115 |
| KVList | 019, 021, 022, 023, 026, 029, 032, 042, 052 |
| HeroStat | 040, 051, 053, 064 |
| StatTiles | 053, 064, p109 |
| ImageBlock | 056, 065 (explicit `null` caption vs omitted) |
| PhotoGrid | 056, 064 |
| Bubbles | 057, 066 (messages with `me`/`time` omitted) |
| Chips | 057, 064 |
| TabItem | 043, 058 |
| Tabs | 043, 058 |
| MapView | 037, 059, 064 |
| BarChart | 037, 054, 064 |
| LineChart | 054, 068 (`variant: "natural"` + xLabel/yLabel) |
| AreaChart | 054, 067 (`variant: "step"`, single series) |
| PieChart | 028, 055 |
| HorizontalBarChart | 054, 069 (`variant: "stacked"`) |
| Series | 054, 064, 067–069 |
| Form | 033, 038, 060, 061 |
| FormControl | 033, 060, 061 |
| Input | 033, 060, 061 |
| TextArea | 060, 061 |
| Select | 060, 061 |
| SelectItem | 060, 061 |
| DatePicker | 060, 061 |
| Slider | 019, 060, 061, p114 |
| Buttons | 007, 033, 048–051, 060, 061, 064, p113 |
| Button | 007, 033, 048–051, 060, 061, 064, p113 |

## Regenerating

```bash
cd spec/fixtures/generator
npm install          # postinstall applies + verifies the react-lang patch
npm run generate     # rewrites every *.expected.json (deterministic)
npm test             # pairing check + double-generation byte-diff + freshness
```

Add a fixture by dropping a new `NNN-name.oui` (or `partial/NNN-name.oui`,
**without** a trailing newline) and running `npm run generate`.

### How the generator gets the real parser and the real contract

- `@openuidev/react-lang@0.1.5` is pinned; its dependency resolves to
  `@openuidev/lang-core@0.1.2` — the actual tokenizer/parser/materializer/
  evaluator. The generator drives lang-core's `createStreamingParser` /
  `evaluateElementProps` directly (no React, no react-test-renderer).
- lang-core ships ESM with extensionless internal imports that Node cannot
  load natively (Metro can), so `generator/lib/build-library.mjs` esbuild-
  bundles lang-core's dist **verbatim** together with the repo's
  `src/genos/ui/contract.tsx` (TS stripped; the type-only `react` import is
  erased) into one module — guaranteeing a single lang-core/zod instance,
  which matters because `defineComponent` registers schemas in zod's global
  registry. The contract's value imports from `@openuidev/react-lang`
  (`createLibrary`, `defineComponent`) are aliased to `@openuidev/lang-core`:
  react-lang's `dist/library.js` re-exports them from lang-core as pure
  pass-throughs, and the alias avoids needing React installed. The bundle is
  rebuilt from the real `contract.tsx` on every run, so contract edits are
  always picked up. `buildGenosLibrary` is invoked with stub renderers
  (renderers are opaque to lang-core and never called during parsing).

### Why the react-lang patch cannot affect these fixtures

`patches/@openuidev+react-lang+0.1.5.patch` is applied to the generator's
installed react-lang copy by `postinstall` (`apply-patch.mjs`, which verifies
each hunk landed and fails loudly otherwise), keeping this package's
`node_modules` identical to the RN app's. But the patch is provably irrelevant
to parsing: all three hunks touch only `react-lang/dist/Renderer.js` —

1. **Error-boundary recovery keyed on the parsed node** (`componentDidUpdate`
   compares `props.children.props.el` identity) — React render-recovery
   policy only;
2. **`DefaultQueryLoader` → `null`** — removes a DOM spinner;
3. **Wrapper `<div>`s → `Fragment`s** around the rendered root — DOM-free
   output for React Native.

None touch `@openuidev/lang-core` (tokenize/parse/materialize/evaluate), which
is a separate, unpatched package — so the expected trees equal what the
patched RN app's Renderer feeds its component renderers. See spec §14.
