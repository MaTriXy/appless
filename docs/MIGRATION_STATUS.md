# AppLess native migration — status

**What this document is.** A living, measured account of where the React
Native → native (Swift/SwiftUI + Kotlin/Compose) migration actually stands. The
plan is in [`NATIVE_MIGRATION_PLAN.md`](NATIVE_MIGRATION_PLAN.md); this is the
ground truth against it.

Every number below was produced by running the gate, not by reading a summary.
Reproduce them with the commands in the "Verification" column.

- Measured in the working tree at commit `f62cf0d` (`WIP checkpoint: Compose
  switcher`) plus uncommitted changes.
- Toolchains used: Swift 6.1 (swift-6.1-RELEASE, Linux x86_64), OpenJDK
  21.0.10, Node v22.22.2.
- Several modules are being written concurrently by different agents, so the
  working tree moves — `android/app` went from *not compiling* at `b052036` to
  compiling with 71 green unit tests at `f62cf0d`, during the writing of this
  document. The counts are a snapshot; the *shape* of the table — which modules
  are converged and which are not, and why — is the durable part.

---

## 1. Module table

Legend for **State**:

- **converged** — has a green automated gate, and that gate is meaningful (it
  compiles and executes the real code).
- **in-flight** — code exists but does not compile, or compiles but has no
  gate that executes it.

| Module (path) | Language | Purpose | Verification | Count | State |
|---|---|---|---|---|---|
| `spec/` | Markdown + JSON | Platform-neutral source of truth: grammar (`openui-lang.md`), capability map, icon map, contract JSON Schema, prompt sections | `spec-gates.yml` | 33 contract components; **30 renderable** | converged |
| `spec/fixtures/` | `.oui` + `.expected.json` | The golden oracle both ports are graded against | `cd spec/fixtures/generator && npm test` | **97 fixtures** (82 complete + 15 partial), all paired | converged |
| `spec/fixtures/generator/` | Node ESM | Generates expected trees from the *real* react-lang parser; scanner + streaming-sync probes; differential-fuzz corpus generator | `npm test` (3 sub-gates: corpus integrity, determinism, scanner, streaming sync) | corpus regenerates byte-identically across two runs | converged |
| `ios/Packages/OpenUILang/` | Swift | Streaming openui-lang parser (lexer → Pratt expressions → JS value model → materialization → streaming watermark cache) | `swift test` | **25 test functions**, one parameterized over all **97 fixtures** | converged |
| `ios/Packages/GenOSCore/` | Swift | Models, `ScreenStore` + controller, SSE client + tool loop, Exa/Unsplash tools, key store, telemetry | `swift test` | **203 tests** | converged |
| `ios/AppLess/Sources/AppLessCore/` | Swift (no SwiftUI) | Everything visual-but-not-SwiftUI: design tokens, icon→SF Symbol map, contract schema tables, renderer registry, chart/map/form geometry, shell decision logic, wordmark vector geometry | `cd ios/AppLess && swift test` | **220 tests** (19 source files) | converged |
| `ios/AppLess/Sources/AppLessUI/` | SwiftUI | 30 Cupertino renderers + the OS shell (home, screen host, switcher, key gate, chrome) | `swiftc -parse` only on Linux; real compile is macOS-only | **21 files, 22 parsed units**; **0 type-checked on Linux** | **in-flight** |
| `android/openui-lang/` | Kotlin/JVM | The Kotlin port of the same parser | `./gradlew :openui-lang:test` | **121 tests** (99 in `FixtureOracleTest` = 97 fixtures + 2 meta) | converged |
| `android/genos-core/` | Kotlin/JVM | The Kotlin port of `GenOSCore` | `./gradlew :genos-core:test` | **279 tests** | converged |
| `android/ui-core/` | Kotlin/JVM | The Android analog of `AppLessCore`: M3 tokens, Material Symbols map, renderer registry (30/30), platform-independent renderer logic | `./gradlew :ui-core:test` | **95 tests** | converged |
| `android/app/` | Kotlin + Compose | Material 3 renderers, shell, switcher, key gate, `MainActivity`, OkHttp/Keystore platform layer | `./gradlew :app:assembleDebug :app:testDebugUnitTest` | compiles + assembles; **71 JVM unit tests** green | **in-flight** — see below |
| `src/`, `App.tsx`, `__tests__/` | TypeScript / RN | The original Expo app — **frozen behavioral reference** | `npm test` (jest-expo) | 4 suites: `render`, `render-material`, `store`, `tools` | reference (unchanged) |

Totals across the two native ports in this tree: **448 Swift test functions**
and **566 Kotlin tests**, all green.

### Why `android/app` is still "in-flight" even though it is green

`:app:assembleDebug` now succeeds and `:app:testDebugUnitTest` reports 71 tests,
0 failures — `RoutingTest` (27), `ShellStateTest` (25), `FormBridgeTest` (7),
`MaterialSymbolsTest` (7), `RendererConformanceTest` (5). That is real progress
and worth more than the equivalent iOS state, because Android's UI toolchain,
unlike SwiftUI's, runs on Linux.

It is still in-flight for two reasons:

1. **No Compose composable is ever executed.** All five suites are plain JVM
   unit tests — no Robolectric, no `createComposeRule`. They test routing
   decisions, shell state reduction, the form bridge, symbol mapping and
   registry conformance, i.e. exactly the logic that could have lived in
   `ui-core`. The `@Composable` functions themselves are compiled and never
   run.
2. **The module is uncommitted and moving.** At `b052036`,
   `:app:compileDebugKotlin` failed on `HomeScreen.kt:167` (a `Modifier.padding`
   overload). It was fixed while this document was being written. There is no
   workflow gating it (see §3), so nothing yet prevents it going red again.

Adding a Compose UI test tier (`createComposeRule`, or Robolectric with
`ComposeContentTestRule`) would be the single highest-value verification
addition on the Android side, and it is one the iOS side cannot copy — SwiftUI
has no headless-on-Linux equivalent.

---

## 2. The renderable-component count

The contract exports **33** components (`spec/contract/genos.schema.json`,
`componentCount: 33`). Three of them — `Series`, `SelectItem`, `TabItem` — are
structural placeholders consumed by their parents and defined as
`component: () => null` in `src/genos/ui/contract.tsx`. They render nothing in
every design system.

**33 − 3 = 30 renderable components.** Both registries derive this from the
schema rather than hard-coding it (`ContractSchema.renderableComponents` in
Swift, `RendererRegistry` in `ui-core`), so the number cannot drift from the
contract silently.

The migration plan's Phase 3 row says "29 SwiftUI renderers". That is an
arithmetic slip and is corrected in the plan.

The conformance gate line is `renderers registered: N/30`:

- On **Linux** the suite prints the *declared* count, `30/30`, and explicitly
  annotates why: "the SwiftUI layer cannot compile on Linux, so nothing
  registers here". This proves the contract is fully enumerated, not that the
  renderers exist.
- On **macOS** (`ios-app.yml`) the same line is asserted against the *live*
  count, i.e. that `registerCupertinoRenderers()` really did register 30. That
  assertion has never run in this container.

---

## 3. What each CI workflow gates

| Workflow | Runner | Path filter | What it actually proves |
|---|---|---|---|
| `spec-gates.yml` | ubuntu | `spec/`, `patches/`, `contract.tsx`, `src/genos/generated/`, `scripts/embed-prompt.mjs`, `ios/Packages/OpenUILang/Tests/` | The fixture corpus regenerates deterministically and the committed trees are fresh; the contract schema matches `contract.tsx`; the prompt assembled from `spec/prompt/` is byte-identical to the shipped `SYSTEM_PROMPT`; every `.oui` has a valid-JSON twin and the corpus floors hold (≥60 complete, ≥12 partial — currently 82 and 15) |
| `ios-app.yml` | **macos-15** | `ios/`, `spec/` | The tier Linux cannot provide. Selects Xcode ≥16.3, runs all three Swift package suites, asserts the **live** `renderers registered: 30/30`, then `xcodebuild`s `AppLessUI` for both `generic/platform=iOS` and `generic/platform=iOS Simulator`. This is the only place SwiftUI is ever type-checked. |
| `differential-fuzz.yml` | ubuntu ×2 (one plain, one `swift:6.1-jammy`) | `ios/Packages/OpenUILang/`, `android/openui-lang/`, `spec/` | Byte-identical serialization of both ports against the JS oracle beyond the fixture corpus: a pinned campaign (39 sessions / 313 steps, seed `0xf122ed5`) plus `prefix` (~23k cumulative streaming steps), `nonmonotonic` (cache-reset paths) and `mutation` (hazard-alphabet single-code-point edits) campaigns. Two two-way comparisons against a *common* oracle, which is a three-way gate without paying for a macOS runner. |
| `all-gates.yml` | ubuntu ×3 | **none — every push and PR** | The umbrella. Re-runs the spec generator gates, all three Swift package suites (in `swift:6.1-jammy`), and the three pure-Kotlin Gradle modules, with no path filter, so one required check means "the Linux-runnable half of the repo is green at this commit". Deliberately excludes the macOS tier, the Android SDK tier, and the fuzz campaigns. |

There is **no `android-app.yml`**. The Android SDK tier has no workflow at all,
which is now the largest gap in CI coverage: `:app` compiles, assembles and has
71 green unit tests locally, and *none of that is gated*. It was deliberately
left out of `all-gates.yml`, which keeps to SDK-free jobs; it belongs in its own
workflow (`./gradlew :app:assembleDebug :app:testDebugUnitTest` on
`ubuntu-latest` with `android-actions/setup-android`), owned by whoever finishes
the module.

---

## 4. Cross-port verification: the shared oracle

Both parsers are graded against **the same fixture corpus**, generated from the
actual `@openuidev/react-lang` runtime (v0.1.5 + `patches/@openuidev+react-lang+0.1.5.patch`)
rather than from anyone's reading of the grammar. The Swift suite runs all 97
fixtures through one parameterized test; the Kotlin suite runs them as 97
individual cases. A contract or grammar change must add fixtures first.

This is not redundancy. Cross-checking two independent ports against one oracle
has repeatedly found defects that **neither port's own suite could see**. From
the commit history:

**Defects one port found in the other:**

- **Swift's tool-message key order** (`6593afc`). RN emits two message shapes
  with different key orders — assistant is `{role, content, tool_calls}`, tool
  is `{role, tool_call_id, content}`. Swift used a single flat order hint that
  put `content` first, so tool messages went out as
  `{role, content, tool_call_id}`. The Kotlin port models per-object insertion
  order directly and therefore produced the right bytes; the divergence
  surfaced when the two were compared. Swift's existing assertions *re-parsed
  the request body*, so they were structurally incapable of seeing key order —
  the fix also byte-pinned the replayed wire bytes.
- **A test-coverage asymmetry** (`eb87254`). Review comparing the two suites
  found 16 Swift regression tests against Kotlin's 1. The missing Kotlin
  suites (`StreamingSemanticsTest`, `WhitespaceSemanticsTest`,
  `SchemaDefaultValueTest`) were ported, and both ports' fixture "include"
  lines converged.

**Defects present in *both* ports, found by re-reading the JS against them:**

- **`Math.round`** (`60eafa3`, `2176f5a`). Both ports implemented `@Round` as
  `floor(x + 0.5)`, which diverges from ECMAScript `Math.round` at
  `0.49999999999999994`. Fixed in both, with a 16-row oracle-derived probe
  including the `-0` branch (which `JSON.stringify` flattens, so it cannot be
  pinned end-to-end).
- **JS own-key ordering** (`60eafa3`). Both ports sorted serialized object keys
  flat, missing JS's rule that canonical array-index keys are emitted first in
  numeric order. Fixture 075 pins it; corpus 89 → 90.
- **The `schemaCtx` two-mode evaluator** (`1ab9a4a`). This is the sharpest
  example. lang-core's `evaluate(node, context, schemaCtx)` *branches on the
  third parameter's presence*, and action-plan construction deliberately calls
  the two-argument form so that raw `StateRef` ASTs survive unresolved. **Both
  ports had collapsed the two modes into one** and resolved them
  unconditionally. The same commit closed four adjacent findings: prototype-chain
  membership in `isReservedCall`, `@Each`'s falsy iterator-name check,
  `__proto__` keys vanishing on assignment, and `toString`-shadowing throwing
  during string coercion. Fixtures 076–082 pin every case; **corpus 90 → 97 on
  both sides**.

**Divergences only one platform could have:**

- **JVM `Double.toString`** (`18fed99`) floors the digit count at two, so
  `MIN_VALUE` prints `4.9E-324` where JS prints `5e-324`. Found by porting the
  Swift port's 267-entry node-derived formatting table into Kotlin; closed with
  round-trip re-testing plus a `BigDecimal` tie-break, then differentially
  validated against node over 44,000 doubles and 20,000 strings — zero
  mismatches.
- **Lone surrogates** (`736ab21`). Kotlin preserves them end-to-end because a
  JVM `String` can hold one; Swift substitutes U+FFFD because a Swift `String`
  cannot. This is a documented, permanent asymmetry, not a bug — it is recorded
  in both ports' `KNOWN-DEVIATIONS` sections.
- **WHATWG UTF-8 decoding** (`07f3b7e`, `86fc1b6`). Three review rounds each
  found the Swift tail-scan decoder diverging from `TextDecoder` one level
  deeper (invalid leads, then out-of-range continuations, which could also
  swallow a trailing valid byte at stream end). Replaced with a verbatim port
  of the Encoding Standard's decoder state machine and pinned by a 220-case
  seeded fuzz differential whose expectations come from real node `TextDecoder`.
- **Guessed expectations corrected against real JS** (`fa9d584`). While writing
  `ui-core`, two hand-written expectations were wrong and were fixed against
  actual JS behavior: `encodeURIComponent` on the LoremFlickr comma, and
  Unsplash raw URLs concatenating with `&w=`.

**Where the technique is now permanent.** Every real divergence above was
originally found by *ad-hoc* differential fuzzing during review.
`differential-fuzz.yml` promotes that into a standing gate, so the next one is
found by CI rather than by someone thinking to look.

Both ports also document their deviations in prose:
`ios/Packages/OpenUILang/README.md` §KNOWN-DEVIATIONS and
`android/openui-lang/README.md` §KNOWN-DEVIATIONS (plus a "JVM-vs-JS notes"
section and an explicit "Deliberate improvement over the Swift port" section).
`ios/AppLess/README.md` §"Known differences vs. the React Native renderers"
records 20 documented SwiftUI-vs-RN differences with rationale.

---

## 5. What is NOT verified — anywhere

This section is the point of the document. Be blunt about it.

1. **SwiftUI has never been type-checked in this container, and until
   `ios-app.yml` runs on a real macOS runner it has never been type-checked at
   all.** `swift build` / `swift test` on Linux compile every
   `#if canImport(SwiftUI)` file to *nothing*. All 21 files of `AppLessUI` —
   the 30 renderers and the entire OS shell — produce an empty module here.
   What Linux *can* say is limited to two weak signals: a text-scanning test
   asserting that all 30 registrations and the `canImport` guards are present,
   and `swiftc -parse` over every UI file with the guards forced on (22 files
   parsed). Both are syntax-level. Neither catches a type error, a missing
   argument label, a wrong `ViewBuilder` shape, or a `@State` misuse.

2. **The Android `:app` module does not compile.** Compose renderers, shell,
   chrome, key gate and the OkHttp/Keystore platform layer are written but red.
   Nothing in the Compose layer is executed by any test.

3. **No simulator or device has ever run either native app.** Layout,
   scrolling, animation curves (the RN launch/push/pop transitions),
   gesture handling, predictive back, keyboard behavior, `MapKit`/Maps
   rendering, image loading, Keychain/Keystore round-trips against real
   platform APIs, and streaming performance at ~1,850 tok/s are **entirely
   unverified**. Even a fully green `ios-app.yml` only proves the SwiftUI
   *compiles*, not that it looks or behaves like the RN app.

4. **End-to-end generation has never run natively.** No native build has talked
   to Cerebras, streamed a real screen, run the tool loop against Exa, or
   resolved a semantic image. Every stream test on both sides is against a
   mocked transport.

5. **Parity is asserted per-unit, not per-screen.** The ports are verified
   against the RN *source* (drift guards re-read `GenOS.tsx`, `HomeScreen.tsx`,
   `Switcher.tsx`, `KeyGate.tsx`, `applessLogo.ts`, `contract.tsx`,
   `spec/icon-map.md` from the working tree) and against the fixture oracle.
   Nobody has put an RN screen and a native screen side by side. Plan Phase 4's
   "manual parity checklist" has not been executed.

6. **The RN app remains the behavioral reference and the only shippable
   build.** It is frozen and untouched. Where a native port and the RN app
   disagree and no fixture covers it, the RN app is right by definition.

7. **The fuzz campaigns have not been run in CI at this commit.**
   `differential-fuzz.yml` is committed and its local driver
   (`node probes/run-differential.mjs`) works, but the workflow's first real
   execution on GitHub-hosted runners has not been observed here.

---

## 6. Phase status

See [`NATIVE_MIGRATION_PLAN.md`](NATIVE_MIGRATION_PLAN.md) §9 for the phase
definitions and their exit criteria. Summary:

| Phase | State |
|---|---|
| 0. Spec & fixtures | **done** |
| 1. Swift parser | **done** |
| 2. Swift core | **done** |
| 3. iOS app | **in-flight** — code complete, verification blocked on macOS CI |
| 4. iOS parity & hardening | **not started** |
| 5. Kotlin parser + core | **done** (parser, `genos-core`, and `ui-core`) |
| 6. Android app | **in-flight** — `:app` does not compile |
| 7. Wrap-up | **in-flight** — this document, the README rewrite and `all-gates.yml` |

---

## 7. Reproducing every number in this document

```bash
export PATH=/opt/swift/usr/bin:$PATH

# Layer 0 — spec, fixtures, contract schema, prompt
cd spec/fixtures/generator && npm ci && npm test

# iOS — the Linux-runnable half
cd ios/Packages/OpenUILang && swift test    #  25 test functions / 97 fixtures
cd ios/Packages/GenOSCore   && swift test   # 203 tests
cd ios/AppLess              && swift test   # 220 tests (AppLessCore only)
python3 ios/AppLess/Scripts/parse-swiftui.py  # 22 files parsed, not type-checked

# Android — the pure JVM modules
cd android && ./gradlew :openui-lang:test :genos-core:test :ui-core:test --console=plain
#   openui-lang 121 · genos-core 279 · ui-core 95

# Android — the app module (currently RED)
cd android && ./gradlew :app:assembleDebug --console=plain

# Cross-port differential fuzzing (local three-way, in one process)
cd spec/fixtures/generator && node probes/run-differential.mjs

# The RN reference app
npm install && npm test
```
