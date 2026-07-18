# AppLess Native Migration Plan

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

Each phase has an exit criterion; later phases don't start until it's met.

| Phase | Work | Exit criterion |
|---|---|---|
| **0. Spec & fixtures** | Write `spec/` (grammar, JSON-Schema contract, capability map, icon map); fixture generator script in RN app; review the react-lang **patch** to capture behavioral deviations; wire prompt generation from spec | Fixtures generated & reviewed; RN app's prompt regenerated from spec byte-identical to today's |
| **1. Swift parser** (`OpenUILang`) | Tokenizer → statement parser → reference resolver → partial-tree builder; fixture runner | 100% of golden fixtures pass on Linux CI (`swift test`) |
| **2. Swift core** (`GenOSCore`) | Models, ScreenStore + controller, SSE client + tool loop, tools (Exa/images), Keychain, telemetry | Unit tests green incl. mocked stream/tool-loop tests; parity constants asserted |
| **3. iOS app** | 29 SwiftUI renderers, shell, transitions, KeyGate; Xcode project | App runs on device/simulator; manual parity script vs RN app passes |
| **4. iOS parity & hardening** | Side-by-side checklist vs RN (per capability row in §6), streaming perf at ~1 850 tok/s, memory | Checklist signed off |
| **5. Kotlin parser + core** | Port Layers 1–2 informed by the settled spec; same fixtures | Fixtures + unit tests green on JVM CI |
| **6. Android app** | Compose renderers (M3), shell, predictive back | Parity checklist vs RN Material build |
| **7. Wrap-up** | README rewrite, CI for all three, decide RN app's long-term fate (kept as reference per current decision) | Docs merged |

**Environment note:** Phases 0, 1, 2 and 5 are pure logic and can be built and tested
in this cloud environment (Swift-on-Linux / JVM). Phases 3, 4, 6 need Xcode/Android
SDK — code is written here; build-and-run feedback comes from your machine or CI
(GitHub Actions `macos` runners for iOS, `ubuntu` + Android SDK for Android).

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
