# AppLess Native Migration Plan

> **Status:** this is the *plan*. For what has actually been built and measured,
> see **[MIGRATION_STATUS.md](MIGRATION_STATUS.md)** — it carries the live test
> counts, the module-by-module converged/in-flight table, and an explicit list
> of what is not verified anywhere. Where the two disagree, the status document
> is right; this one is edited only to correct outright errors and to record
> phase progress (§9) and how execution diverged from the plan (§12).

**Goal:** migrate AppLess from React Native/Expo to two fully native apps — **iOS in Swift/SwiftUI** and **Android in Kotlin/Jetpack Compose** — in this repository (monorepo), building iOS first, keeping the existing RN app untouched as the behavioral reference until parity is reached.

The plan is bottom-to-top: a platform-neutral spec at the base, pure-logic runtimes above it, UI renderers above that, the OS shell on top.

---

## 1. What the app is (inventory of the current system)

```
┌─────────────────────────────────────────────────────┐
│ Shell   GenOS.tsx, HomeScreen, Switcher, KeyGate     │  navigation, sessions, chrome
├─────────────────────────────────────────────────────┤
│ Render  @openuidev/react-lang <Renderer> + contract  │  openui-lang → live native UI
│         ui/cupertino (iOS), ui/material (Android)    │
├─────────────────────────────────────────────────────┤
│ State   store.ts (ScreenStore + controller)          │  cache, prefetch, navigation index
├─────────────────────────────────────────────────────┤
│ I/O     stream.ts (SSE + tool loop), tools/, config  │  Cerebras, Exa, Unsplash, Keychain
└─────────────────────────────────────────────────────┘
```

The single most important fact for this migration: **parsing and rendering of the
openui-lang DSL lives in the `@openuidev/react-lang` npm package (v0.1.5 +
`patches/@openuidev+react-lang+0.1.5.patch`), not in this repo.** There is no Swift or
Kotlin implementation of OpenUI. Building one per platform is the core engineering
effort; everything else is a mechanical port.

---

## 2. Target repository layout (monorepo)

```
appless/
├── spec/                          # LAYER 0 — platform-neutral source of truth
│   ├── openui-lang.md             #   grammar + streaming/partial-render semantics
│   ├── contract/genos.schema.json #   the 33-component contract as JSON Schema
│   ├── capabilities.md            #   capability map (this doc's §6, kept live)
│   ├── prompt/                    #   shared system prompt source
│   └── fixtures/                  #   golden fixtures: NNN-name.oui → NNN-name.expected.json
│       └── partial/               #   streaming fixtures: truncated input → expected partial tree
├── ios/                           # LAYER 1–4 (Swift)
│   ├── Packages/OpenUILang/       #   streaming parser — pure Swift, Linux-testable
│   ├── Packages/GenOSCore/        #   models, store, SSE client, tools — pure Swift
│   └── AppLess/                   #   SwiftUI app: Cupertino renderers + shell (Xcode)
├── android/                       # LAYER 5–6 (Kotlin)
│   ├── openui-lang/               #   parser — pure Kotlin/JVM, unit-testable
│   ├── genos-core/                #   models, store, client
│   └── app/                       #   Compose app: Material 3 renderers + shell
└── src/, App.tsx, …               # existing RN app — KEPT AS REFERENCE, untouched
```

---

## 3. Layer 0 — the shared spec (the foundation everything is built against)

### 3.1 openui-lang grammar

Extracted from the system prompt (`src/genos/generated/system-prompt.ts`), the
react-lang parser behavior, and the patch file. Must cover:

- Line-based statements: `identifier = Expression`; `root = Card(...)` is the entry point.
- Expressions: strings (double-quoted, backslash escapes), numbers, booleans, `null`,
  arrays `[...]`, objects `{...}`, component calls `TypeName(arg1, arg2, ...)`.
- **Positional args only** (no named args); optional args omitted from the end.
- Variable references; unreferenced variables are silently dropped from the render tree.
- `Action([@ToAssistant("...")])` / `@OpenUrl("...")` action expressions.
- `$variable` two-way bindings for form inputs.
- `@OS(back|home|switcher|open, "arg")` whole-response commands (handled by shell, §6).
- **Streaming semantics** — the differentiator: the parser must produce a best-effort
  partial tree from an incomplete program (unterminated string, half-open call, missing
  root) and re-resolve as lines complete. Fixture-tested, not hand-waved.
- Markdown-fence tolerance (`cleanLang` behavior: strip leading/trailing ``` fences,
  safe on partial streams).

### 3.2 Golden fixtures

The trick that keeps two native parsers honest: **generate expected outputs from the
actual react-lang parser** via a small Node script in the RN app (parse fixture `.oui`
→ serialize resolved component tree → JSON). Each fixture is input + expected tree;
both complete programs and prefix-truncated streaming snapshots. Target: 60–80
fixtures covering every component, nesting, references, actions, bindings, escapes,
malformed input, fences, `@OS` responses.

> **Actual:** 97 fixtures — 82 complete (`spec/fixtures/*.oui`) and 15 streaming
> (`spec/fixtures/partial/*.oui`). The corpus grew past the target because
> cross-port checking kept finding behavior no existing fixture pinned:
> 89 → 90 (JS own-key ordering, fixture 075) → 97 (the `schemaCtx` two-mode
> evaluator and the reserved-call / `@Each` / `__proto__` / `toString`-shadowing
> family, fixtures 076–082). `spec-gates.yml` enforces floors of ≥60 complete
> and ≥12 partial so the corpus can only grow.

### 3.3 Component contract as JSON Schema

`ui/contract.tsx` already defines every component with Zod. Export via
`z.toJSONSchema` to `spec/contract/genos.schema.json`; also emit the prompt's
"Component Signatures" section from it so the model-facing prompt and both native
apps derive from one artifact (replacing the web-repo embed in `scripts/embed-prompt.mjs`).

---

## 4. Data model map (TypeScript → Swift → Kotlin)

| TS (file) | Fields / notes | Swift | Kotlin |
|---|---|---|---|
| `Screen` (store.ts) | id, appId, appName, request, parentId?, content, status, error?, speculative, startedAt, genMs?, prefetched?, truncated?, osCommand?, searching? | `struct Screen` | `data class Screen` |
| `ScreenStatus` | pending / streaming / done / error | `enum` | `enum class` |
| `OsCommand` | cmd: back/home/switcher/open, arg? | `enum` w/ assoc. value | `sealed class` |
| `ChatMessage` (stream.ts) | role, content, tool_calls?, tool_call_id? | `struct` (Codable) | `@Serializable data class` |
| `ToolCall` | id, type, function{name, arguments} | `struct` | `data class` |
| `StreamEndInfo` | truncated, dropped | `struct` | `data class` |
| `AppDef` (apps.ts) | id, name, emoji, tile [2 colors], request | `struct` | `data class` |
| `Suggestion` (apps.ts) | emoji, label, command (10 entries) | `struct` | `data class` |
| `KeyStatus` (config.ts) | loading / missing / present / rejected | `enum` | `enum class` |
| `SearchResult` (tools/search.ts) | title, url, snippet, published? | `struct` | `data class` |
| `ImgQuery` (tools/images.ts) | q, seed, w, h | `struct` | `data class` |
| `AppMeta`, `RunningApp` (shell) | name, emoji, tile | `struct` | `data class` |
| `GenActionEvent` (GenOS.tsx) | params?, humanFriendlyMessage?, formState? | `struct` | `data class` |

**Stores & controller** (pure logic, port 1:1 with constants preserved):

| Concern | Current | Swift | Kotlin |
|---|---|---|---|
| `ScreenStore` | Map + subscriber set, **50 ms flush throttle** during streaming | `@MainActor @Observable` class; throttle kept | class + `StateFlow`, `sample(50ms)` |
| `KeyStore` | env key → SecureStore fallback; markRejected(401/403) | Keychain (Security fw) | Jetpack `Keystore`/EncryptedSharedPreferences |
| Controller | openApp / openDeepLink / resolveAction / retryScreen / setActiveScreen / maybePrefetch; indices: actionIndex, appHomeIndex, deepLinkIndex, inflight | same functions on a `ScreenController` | same, coroutine scoped |
| Constants | MAX_PREFETCH 6 · CONTEXT_DEPTH 2 · STALE_MS 30 000 · MAX_TOOL_ROUNDS 3 · STREAM_FLUSH_MS 50 | identical | identical |
| Pure helpers | `cleanLang`, `extractActions`, `parseOsCommand`, `parseGenosUrl`, `parseImgUrl` | ported + fixture-tested | ported + fixture-tested |

---

## 5. Streaming / networking map

`stream.ts` is an OpenAI-compatible SSE client with a real tool loop:

| Behavior | Current | Swift | Kotlin |
|---|---|---|---|
| SSE POST `/chat/completions`, `data:` lines, `[DONE]` | expo/fetch + manual reader | `URLSession.bytes(for:)` + line splitter | OkHttp SSE (or Ktor) |
| Incremental UTF-8 across chunk boundaries | manual decoder fallback | `AsyncBytes` handles it | OkHttp handles it |
| Request params | model, temperature 0.8, max_completion_tokens 3072, stream | identical | identical |
| Tool-call delta accumulation by index | Map<index, ToolCall> | identical | identical |
| Tool loop | ≤ 3 rounds then tools withheld; `onToolRound` may abort (prefetch quota → `NEEDS_LIVE_DATA` error, regenerates with tools on tap) | identical semantics | identical semantics |
| 401/403 | markRejected → KeyGate reappears | identical | identical |
| Dropped stream detection | no `[DONE]` + no finish_reason → retryable error | identical | identical |
| Cancellation | AbortController per screen; superseded-stream staleness guard | `Task` cancellation + generation token | coroutine `Job` + token |
| Context building | replay ≤ 2 ancestor screens as user/assistant turns, `cleanLang`ed | identical | identical |

---

## 6. Capability map

| Capability | Current implementation | iOS | Android |
|---|---|---|---|
| BYOK key gate | SecureStore, env override, rejected-key flow | Keychain; build setting override | Keystore; BuildConfig override |
| web_search tool | Exa API, 5 results, 400-char snippets; prompt section appended only when key present; ERROR-string degradation | port 1:1 | port 1:1 |
| Semantic images | model emits `/api/img?q&seed&w&h`; resolved to LoremFlickr (no key) or Unsplash search (cached, keyed) | URL rewriter + `AsyncImage` | rewriter + Coil |
| Speculative prefetch | top-visible done screen → extractActions → ≤ 6 children generated speculatively; tools refused on speculative streams | identical | identical |
| Deep links | `genos://open?app&request`, `genos://toast`, `genos://back`, `genos://home` from action URLs | identical (custom scheme also registrable OS-wide) | identical |
| `@OS(...)` commands | whole-response back/home/switcher/open; pending command screen removed from stack | identical | identical |
| Command routing | ask-bar/chips regexes: back, home, close app, switcher, "open <app>", else generate; navigation-shaped action guard; "still materializing" toast while parent streams | identical | identical |
| Summoned apps | any free-text request becomes `summon-<slug>` app; renamed from first CardHeader | identical | identical |
| Form submission | formState JSON appended to request; form screens never served from prefetch cache | identical | identical |
| Session/back semantics | per-app screen stacks, minimize-to-icon, switcher, hardware back (Android) | swipe-back + chrome buttons | predictive back + chrome |
| Telemetry | single anonymous PostHog `appless_app_launched` event; DO_NOT_TRACK/env opt-out; stable device id in secure storage | port 1:1 | port 1:1 |
| System prompt | embedded at build time + tools section + "Today is <date>" | generated from spec/ at build | generated from spec/ at build |

## 7. UI component map (the 33-component contract)

Each contract entry becomes **one SwiftUI view** (Cupertino) and **one Compose
composable** (Material 3). The iOS app drops the Material renderer set entirely and
vice-versa — each native app is *simpler* than the RN original.

> **The number that matters is 30, not 33.** The contract exports 33 components
> (`spec/contract/genos.schema.json`, `componentCount: 33`); three of them —
> `Series`, `SelectItem`, `TabItem` — are structural placeholders defined as
> `component: () => null` and consumed by their parents. **33 − 3 = 30
> renderable components**, which is what `GenosRenderers` in `contract.tsx`
> declares and what each design system must implement. Both registries
> (`ContractSchema.renderableComponents` in Swift, `RendererRegistry` in
> `ui-core`) *derive* this from the schema rather than hard-coding it, and the
> CI gate line is `renderers registered: N/30`.

| Group | Components | iOS notes | Android notes |
|---|---|---|---|
| Structure | Card (root), CardHeader, TextContent, TextCallout | large-title header; vertical scroll | M3 typography; `LazyColumn` |
| Lists | ListBlock, ListItem, Toggle, KVList | inset grouped style, SF Symbols badge mapping for icon names | M3 list items, Material Symbols mapping |
| Stats & charts | HeroStat, StatTiles, BarChart, LineChart, AreaChart, PieChart, HorizontalBarChart, Series* | **Swift Charts** | Vico or custom Canvas (decide in Phase 5) |
| Media & social | ImageBlock, PhotoGrid, Bubbles, Chips (live filter), Tabs, TabItem*, MapView | MapKit; AsyncImage | Compose Google Maps or WebView map (decide in Phase 5); Coil |
| Forms | Form, FormControl, Input, TextArea, Select, SelectItem*, DatePicker, Slider, Buttons, Button | native pickers; local form state + `$bindings` | Compose equivalents |

\* structural placeholders consumed by parents; render nothing (same as today).

Icon names (`"wifi"`, `"credit-card"`, …) come from the Lucide set today — the spec
must include the icon-name → SF Symbol / Material Symbol mapping table.

## 8. Shell screens map

| Screen / element | Current | Native notes |
|---|---|---|
| HomeScreen | wordmark, ask bar, rotating suggestion chips, minimized-app icon grid | SwiftUI / Compose rewrite; chips ARE commands (same routing) |
| Generated screen host | skeleton → live streaming render → error+Retry; gradient background; "materializing…" / "searching the web…" pill | identical states |
| Transitions | launch (zoom-up 380 ms), push (slide 300 ms), pop (settle 260 ms), minimize-to-icon | spring/`Animatable` equivalents; exact curves are polish, not parity |
| Switcher | recent-apps cards, resume/close | port |
| KeyGate | first-launch key entry, rejected-key re-entry | port |
| Chrome | back/home button (top-left), switcher button (top-right), one-time gesture hint, toasts | port |

## 9. Execution phases

Each phase has an exit criterion. **The original plan said later phases don't
start until it's met; in practice they were run in parallel — see §12.**

Status column measured at commit `b052036`; counts and the full evidence are in
[MIGRATION_STATUS.md](MIGRATION_STATUS.md).

| Phase | Work | Exit criterion | Status |
|---|---|---|---|
| **0. Spec & fixtures** | Write `spec/` (grammar, JSON-Schema contract, capability map, icon map); fixture generator script in RN app; review the react-lang **patch** to capture behavioral deviations; wire prompt generation from spec | Fixtures generated & reviewed; RN app's prompt regenerated from spec byte-identical to today's | **DONE** — 97 fixtures; `spec-gates.yml` enforces prompt byte-identity, schema freshness and corpus floors |
| **1. Swift parser** (`OpenUILang`) | Tokenizer → statement parser → reference resolver → partial-tree builder; fixture runner | 100% of golden fixtures pass on Linux CI (`swift test`) | **DONE** — 25 test functions, one parameterized over all 97 fixtures |
| **2. Swift core** (`GenOSCore`) | Models, ScreenStore + controller, SSE client + tool loop, tools (Exa/images), Keychain, telemetry | Unit tests green incl. mocked stream/tool-loop tests; parity constants asserted | **DONE** — 203 tests |
| **3. iOS app** | **30** SwiftUI renderers, shell, transitions, KeyGate; Xcode project | App runs on device/simulator; manual parity script vs RN app passes | **IN FLIGHT** — all 30 renderers and the full shell are written; `AppLessCore` carries 220 Linux tests. **Exit criterion NOT met:** SwiftUI has never been type-checked (Linux compiles it to an empty module) and no simulator or device has run it. Blocked on the first `ios-app.yml` run. |
| **4. iOS parity & hardening** | Side-by-side checklist vs RN (per capability row in §6), streaming perf at ~1 850 tok/s, memory | Checklist signed off | **NOT STARTED** — requires a running app |
| **5. Kotlin parser + core** | Port Layers 1–2 informed by the settled spec; same fixtures | Fixtures + unit tests green on JVM CI | **DONE** — `openui-lang` 121 tests (97 fixtures), `genos-core` 279, plus `ui-core` 95 (an added module, see §12) |
| **6. Android app** | Compose renderers (M3), shell, predictive back | Parity checklist vs RN Material build | **IN FLIGHT** — Compose renderers, shell, chrome, key gate and the OkHttp/Keystore layer are written but `:app:compileDebugKotlin` currently **fails**; nothing in the Compose layer is executed by any test |
| **7. Wrap-up** | README rewrite, CI for all three, decide RN app's long-term fate (kept as reference per current decision) | Docs merged | **IN FLIGHT** — `MIGRATION_STATUS.md`, the README rewrite and the `all-gates.yml` umbrella workflow are in; the Android SDK workflow does not exist yet |

**Environment note:** Phases 0, 1, 2 and 5 are pure logic and can be built and tested
in this cloud environment (Swift-on-Linux / JVM). Phases 3, 4, 6 need Xcode/Android
SDK — code is written here; build-and-run feedback comes from your machine or CI
(GitHub Actions `macos` runners for iOS, `ubuntu` + Android SDK for Android).

**How that note played out.** It is the single most consequential line in this
plan. Because Phases 3 and 6 cannot be verified here, both ports respond the
same way: push every decision that *can* be tested on Linux/JVM out of the view
layer and into a pure module (`AppLessCore` on iOS, `ui-core` on Android) —
chart domains and tick geometry, pie geometry, stacking, form state and payload
shape, action-plan → outcome mapping, map zoom → span, semantic-image policy,
icon and token tables, command routing, session/shell reducers, even the
wordmark's vector path. What is left in SwiftUI/Compose is layout and platform
API calls. It is a real mitigation, and it is not a substitute: see
[MIGRATION_STATUS.md §5](MIGRATION_STATUS.md#5-what-is-not-verified--anywhere).

### 9.1 CI workflows

| Workflow | Runner | Gates |
|---|---|---|
| `spec-gates.yml` | ubuntu | Fixture determinism/freshness, contract schema vs `contract.tsx`, prompt byte-identity, fixture pairing + corpus floors |
| `ios-app.yml` | **macos-15** | All three Swift suites, the **live** `renderers registered: 30/30`, and `xcodebuild` of `AppLessUI` for the iOS device and simulator SDKs — the only real SwiftUI compile anywhere |
| `differential-fuzz.yml` | ubuntu ×2 | Both parser ports byte-compared to the JS oracle over pinned + prefix + non-monotonic + mutation campaigns |
| `all-gates.yml` | ubuntu ×3 | Umbrella, no path filter: the spec gates, all three Swift suites, and the three pure-Kotlin modules on every push and PR |

There is no Android-SDK workflow yet, because `:app` does not compile yet.

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| react-lang has undocumented parsing behavior the spec misses | Fixtures are *generated from react-lang itself*; the patch file is reviewed in Phase 0; RN app kept runnable as oracle |
| Streaming partial-render semantics subtly differ → visual flicker/divergence | Dedicated `fixtures/partial/` suite of prefix-truncated snapshots |
| Re-render storm at ~1 850 tok/s (RN needed 50 ms throttling) | Keep the throttle; SwiftUI/Compose diffing is cheaper than RN bridge, but measure in Phase 4 |
| Chart/map library fidelity gaps on Android | Decision gate in Phase 5 (Vico vs custom Canvas; Maps SDK vs WebView) |
| Prompt drift between RN reference and native apps | Single prompt source in `spec/`, all three builds generate from it |
| Two parsers drifting over time | Same fixture corpus runs in both CIs; contract changes must add fixtures first |

## 11. Explicitly out of scope

- New features beyond parity (Liquid Glass renderer, real integrations, voice input).
- Publishing/App Store work.
- Rewriting the RN app (it stays frozen as the reference implementation).

---

## 12. What changed vs. the original plan

Four things about how this was actually executed differ from §9 enough to be
worth recording, because they are the parts worth reusing.

### 12.1 Phases ran in parallel, not in sequence

§9 says "later phases don't start until [the exit criterion] is met". That held
for the *dependency* order — nothing was built before the spec it depends on —
but not for the *calendar*. Multiple agents worked concurrently on different
layers, and the commit history shows it plainly: `WIP checkpoint: genos-core and
ui-core mid-implementation (does NOT compile)` describes two Android modules in
flight at once; `WIP checkpoint: SwiftUI shell views, Compose app packages, fuzz
drivers` describes three.

That only works with a discipline the plan did not anticipate, and it is the
convention worth keeping: **every checkpoint commit states which modules are red
and re-verifies that the converged ones are still green.** A commit that leaves
a module non-compiling says so in its subject line (`does NOT compile`,
`work in progress`, `mid-write`) and names the modules that remain green
underneath. "Converged" and "in-flight" became the two states a module can be
in, and `MIGRATION_STATUS.md` exists to make that distinction permanently
visible rather than buried in commit bodies.

The cost is that the tree is red more often than a strictly sequential build
would be. The mitigation is `all-gates.yml`: one unconditional check that runs
every Linux-runnable gate on every push, so "which converged modules are green
right now" is answerable without reading commit messages.

### 12.2 Differential fuzzing became a first-class technique

The plan's verification story was the fixture corpus: 60–80 golden files, both
ports pass them, done. That is necessary and it is not sufficient — a fixture
only pins behavior somebody thought to write a fixture for, and the interesting
divergences between an ECMAScript reference and a Swift/Kotlin port are exactly
the ones nobody thinks of (`Math.round` at `0.49999999999999994`;
`Double.MIN_VALUE` printing `4.9E-324` instead of `5e-324`; a valid byte
swallowed at stream end by a UTF-8 decoder's tail scan).

Every real divergence found in review was found by *ad-hoc* differential
fuzzing — generating inputs, running them through both the JS oracle and the
port, and byte-comparing. `differential-fuzz.yml` promotes that from a review
habit into a standing gate, with four campaigns over a fixed seed:

- **pinned** — a committed corpus (39 sessions / 313 steps) whose oracle
  expectations are checked in, so a regression is a diff rather than a rerun;
  the same job regenerates it and requires byte-identity, which gates the
  generator's determinism too.
- **prefix** — every UTF-16 code-unit prefix of every fixture fed cumulatively
  to one streaming parser (~23k steps). This is the streaming/incremental path
  that `fixtures/partial/` samples and this exhausts.
- **nonmonotonic** — seeded shrink and cross-fixture switch sequences, i.e. the
  cache-reset path prefix fuzzing structurally cannot reach.
- **mutation** — seeded single-code-point insert/delete/replace over every
  fixture from a hazard alphabet (quotes, brackets, backslash, CR, LF, NBSP,
  U+FEFF, combining acute, `@`, `$`, `#`, `//`).

The topology is worth stealing: rather than pay for a macOS runner to compare
Swift against Kotlin directly, two ubuntu jobs each compare one port against the
*same* JS oracle (node + Kotlin on plain ubuntu, node + Swift in the
`swift:6.1-jammy` container). Agreement with a common oracle is agreement with
each other, so it is a three-way gate at two-thirds the runner cost.

### 12.3 The shared oracle found defects neither port's own suite could

§10 lists "two parsers drifting over time" as a risk mitigated by "same fixture
corpus runs in both CIs". The corpus did more than prevent drift — writing the
second port *found bugs in the first*, and comparing both against the JS found
bugs in both:

- Kotlin found Swift's **tool-message key order** bug. RN emits
  `{role, content, tool_calls}` for assistant messages but
  `{role, tool_call_id, content}` for tool messages; Swift used one flat order
  hint and got the second shape wrong. Kotlin models per-object insertion order
  directly and was right. Swift's own assertions *re-parsed the request body*,
  so they could not see key order at all — a whole class of defect its suite was
  structurally blind to.
- Both ports had independently **collapsed lang-core's two-mode evaluator**:
  `evaluate(node, context, schemaCtx)` branches on whether the third argument is
  present, and action-plan construction deliberately omits it so raw `StateRef`
  ASTs survive unresolved. Both resolved unconditionally. Fixtures 076–082 and
  the corpus jump 90 → 97 came out of that one finding and its neighbors.
- Both ports had the same wrong `@Round` (`floor(x + 0.5)`) and the same wrong
  serialized key ordering (flat sort, missing JS's array-index-first rule).

Two independent implementations of the same spec disagree in ways one
implementation plus its own tests never will. That is the argument for keeping
both ports graded by one oracle even after the migration lands, and for the
rule that a contract change must add fixtures first.

### 12.4 Two modules the plan did not name

`AppLessCore` (iOS) and `ui-core` (Android) do not appear in §2's target
layout. They exist because of the environment note in §9: they are the
Linux/JVM-testable homes for everything the view layer would otherwise hide.
`ui-core` alone carries 95 tests covering M3 tokens, the Material Symbols map,
the 30/30 renderer registry, chart and pie geometry, form state, action mapping
and image policy — all of which §2 implicitly assigned to `android/app`, where
none of it would be testable today.

Their test suites also adopted a convention the plan did not specify:
**re-parse the RN source rather than trust a copy.** Token tests check that each
cited value points at its exact declaring line in the RN theme; icon tables are
re-extracted from `spec/icon-map.md`; the iOS shell tests re-read `GenOS.tsx`,
`HomeScreen.tsx`, `Switcher.tsx`, `KeyGate.tsx` and `applessLogo.ts` from the
working tree. This makes the RN app a live oracle for the port rather than a
snapshot someone transcribed once, which is what §10's "RN app kept runnable as
oracle" mitigation actually requires to work.
