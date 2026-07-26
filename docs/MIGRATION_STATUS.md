# AppLess native migration — status

**What this document is.** A living, measured account of where the React
Native → native (Swift/SwiftUI + Kotlin/Compose) migration actually stands. The
plan is in [`NATIVE_MIGRATION_PLAN.md`](NATIVE_MIGRATION_PLAN.md); this is the
ground truth against it.

Every number below was produced by running the gate, not by reading a summary.
Reproduce them with the commands in §7.

- Measured in a clean working tree at commit `fd6a706`
  (`GenOSCore/genos-core: close the parity review against a real RN oracle`).
- Toolchains used: Swift 6.1 (swift-6.1-RELEASE, Linux x86_64), OpenJDK
  21.0.10, Node v22.22.2.
- The counts are a snapshot and will move; the *shape* of the table — which
  modules are converged and which are not, and why — is the durable part.

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
| `spec/fixtures/` | `.oui` + `.expected.json` | The golden oracle both ports are graded against | `cd spec/fixtures/generator && npm test` | **114 fixtures** (99 complete + 15 partial), all paired | converged |
| `spec/fixtures/generator/` | Node ESM | Generates expected trees from the *real* react-lang parser; scanner + streaming-sync probes; differential-fuzz corpus generator | `npm test` (3 sub-gates: corpus integrity, determinism, scanner, streaming sync) | corpus regenerates byte-identically across two runs | converged |
| `ios/Packages/OpenUILang/` | Swift | Streaming openui-lang parser (lexer → Pratt expressions → JS value model → materialization → streaming watermark cache), plus a JS prototype-chain object model | `swift test` | **40 test functions**, one parameterized over all **114 fixtures** | converged |
| `ios/Packages/GenOSCore/` | Swift | Models, `ScreenStore` + controller, SSE client + tool loop, Exa/Unsplash tools, key store, telemetry | `swift test` | **237 tests** | converged |
| `ios/AppLess/Sources/AppLessCore/` | Swift (no SwiftUI) | Everything visual-but-not-SwiftUI: design tokens, icon→SF Symbol map, contract schema tables, renderer registry, chart/map/form geometry, shell decision logic, renderer/shell presentation decisions, wordmark vector geometry | `cd ios/AppLess && swift test` | **296 tests** (23 source files) | converged |
| `ios/AppLess/Sources/AppLessUI/` | SwiftUI | 30 Cupertino renderers + the OS shell (home, screen host, switcher, key gate, chrome) | `swiftc -parse` + a text-level source gate on Linux; real compile is macOS-only | **22 parsed units**; **0 type-checked on Linux**; 30/30 renderers read props through `AppLessCore`, 23/30 delegate a named decision to a Linux-tested Core type | **in-flight** |
| `android/openui-lang/` | Kotlin/JVM | The Kotlin port of the same parser | `./gradlew :openui-lang:test` | **153 tests**, exercising all **114 fixtures** | converged |
| `android/genos-core/` | Kotlin/JVM | The Kotlin port of `GenOSCore` | `./gradlew :genos-core:test` | **313 tests** | converged |
| `android/ui-core/` | Kotlin/JVM | The Android analog of `AppLessCore`: M3 tokens, Material Symbols map, renderer registry (30/30), platform-independent renderer logic | `./gradlew :ui-core:test` | **97 tests** | converged |
| `android/app/` | Kotlin + Compose | Material 3 renderers, shell, switcher, key gate, `MainActivity`, OkHttp/Keystore platform layer | `./gradlew :app:assembleDebug :app:testDebugUnitTest` | compiles + assembles; **183 unit tests**, of which 112 execute real compositions under Robolectric; `compose renderers executed: 30/30` | converged |
| `src/`, `App.tsx`, `__tests__/` | TypeScript / RN | The original Expo app — **frozen behavioral reference** | `npm test` (jest-expo) | 4 suites: `render`, `render-material`, `store`, `tools` | reference (unchanged) |

Totals across the two native ports in this tree: **573 Swift test functions**
(40 + 237 + 296) and **746 Kotlin tests** (153 + 313 + 97 + 183), all green.

### Why `android/app` is now converged, and `AppLessUI` is not

`android/app` used to be in-flight for a specific reason: its 71 tests were all
plain JVM unit tests, so **no `@Composable` was ever executed** — the renderers
were compiled and never run. That is closed. A Robolectric +
`createComposeRule()` tier now runs inside `testDebugUnitTest` on Linux with no
emulator, and `RendererExecutionGate` composes every contract component and
prints `compose renderers executed: 30/30`, with a companion test asserting the
table equals `RenderableComponent.ALL` so nothing can be silently skipped. 28
renderers are pinned by text reaching the semantics tree; `PhotoGrid` and
`MapView` emit no text and are pinned by layout and by `ShadowWebView`; the five
charts draw only into `Canvas` and additionally get a real draw pass, with an
empty chart as a negative control.

**`AppLessUI` cannot copy any of this, and that asymmetry is now the single
largest verification gap in the repo.** SwiftUI has no headless-on-Linux
equivalent: `canImport(SwiftUI)` is false, the target compiles to an empty
module, no `body` is ever type-checked let alone executed. What exists on Linux
instead is a *text-level* gate (`RendererSourceGateTests`) that catches a
renderer unregistered, registered twice, wired under the wrong contract name,
declared but never wired, reading a prop the schema does not declare, or using
an icon with no SF Symbol — plus `swiftc -parse` with the guards forced on. All
nine of those checks were falsified by mutating the source and confirming each
goes red. They are text checks, not type checks, and the distinction is the
whole point: only `ios-app.yml` on macOS type-checks SwiftUI, **and it has never
run**.

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

The migration plan's Phase 3 row used to say "29 SwiftUI renderers". That was an
arithmetic slip; it has been corrected to 30 in the plan, along with an explicit
33 − 3 = 30 note in §7.

The conformance gate line is `renderers registered: N/30`:

- On **Linux** the suite prints the *declared* count, `30/30`, and explicitly
  annotates why: "the SwiftUI layer cannot compile on Linux, so nothing
  registers here". This proves the contract is fully enumerated, not that the
  renderers exist.
- On **macOS** (`ios-app.yml`) the gate asserts two things: that the
  SwiftUI-guarded `AppLessUITests` suite actually COMPILED AND RAN, and that it
  saw a *live* 30/30. The second check alone would be vacuous — `AppLessCore`
  prints the same string on Linux, where nothing registers — so the workflow
  greps for a test name that exists only inside `#if canImport(SwiftUI)`.
  Neither assertion has ever run in this container.
- On **Android** the equivalent line is genuinely live on Linux:
  `compose renderers executed: 30/30` comes from real compositions.

---

## 3. What each CI workflow gates

| Workflow | Runner | Path filter | What it actually proves |
|---|---|---|---|
| `spec-gates.yml` | ubuntu | `spec/`, `patches/`, `contract.tsx`, `src/genos/generated/`, `scripts/embed-prompt.mjs`, `ios/Packages/OpenUILang/Tests/` | The fixture corpus regenerates deterministically and the committed trees are fresh; the contract schema matches `contract.tsx`; the prompt assembled from `spec/prompt/` is byte-identical to the shipped `SYSTEM_PROMPT`; every `.oui` has a valid-JSON twin and the corpus floors hold (≥60 complete, ≥12 partial — currently 99 and 15) |
| `ios-app.yml` | **macos-15** | `ios/`, `spec/` | The tier Linux cannot provide. Selects Xcode ≥16.3, runs all three Swift package suites, asserts the **live** `renderers registered: 30/30`, then `xcodebuild`s `AppLessUI` for both `generic/platform=iOS` and `generic/platform=iOS Simulator`. This is the only place SwiftUI is ever type-checked. |
| `differential-fuzz.yml` | ubuntu ×2 (one plain, one `swift:6.1-jammy`) | `ios/Packages/OpenUILang/`, `android/openui-lang/`, `spec/` | Byte-identical serialization of both ports against the JS oracle beyond the fixture corpus: a pinned campaign (49 sessions / 389 steps, seed `0xf122ed5`, carrying committed oracle expectations) plus `prefix` (109/28,087 cumulative streaming steps), `nonmonotonic` (48/566, cache-reset paths), `mutation` (2,616 hazard-alphabet single-code-point edits) and `synthesis` (1,200/2,400) campaigns — **40,459 steps total**. It also runs `verify-collation.mjs` (244,650 ASCII pairs against V8 and both ports). `synthesis` is the only campaign NOT derived from the committed fixtures: it generates from a duck-typing key alphabet, and found a real bug on its first run that the hand-written fixtures had missed. Two two-way comparisons against a *common* oracle, which is a three-way gate without paying for a macOS runner. |
| `all-gates.yml` | ubuntu ×3 | **none — every push and PR** | The umbrella. Re-runs the spec generator gates, all three Swift package suites (in `swift:6.1-jammy`), and the three pure-Kotlin Gradle modules, with no path filter, so one required check means "the Linux-runnable half of the repo is green at this commit". Deliberately excludes the macOS tier, the Android SDK tier, and the fuzz campaigns. |

`android-app.yml` now exists (ubuntu, `android/**` + `spec/**`): it installs the
pinned SDK, runs the three pure modules, runs `:app:testDebugUnitTest`, greps
`renderers registered: 30/30` from the `:app` log **specifically** — `:ui-core`
prints the same line for its declared count, so grepping the whole build would
pass on a completely unwired UI — then does the real Compose compile via
`:app:assembleDebug` and checks the APK carries the staged spec assets. It is
deliberately kept out of `all-gates.yml`, which stays SDK-free.

**Every workflow above except `spec-gates.yml` and `all-gates.yml` has never
run**, so their green-ness is a claim about the YAML, not an observation. One
gate was already found broken by reading: the iOS conformance step grepped a
line `AppLessCore` also prints on Linux, and so could not distinguish a live
registration from a declared one.

---

## 4. Cross-port verification: the shared oracle

Both parsers are graded against **the same fixture corpus**, generated from the
actual `@openuidev/react-lang` runtime (v0.1.5 + `patches/@openuidev+react-lang+0.1.5.patch`)
rather than from anyone's reading of the grammar. The Swift suite runs all 114
fixtures through one parameterized test; the Kotlin suite runs them as
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

### Adversarial review rounds, and what they cost

Both port pairs were then scored by independent adversarial reviewers held to a
99/100 bar, each required to author its own probes rather than re-run the
suites. Neither passed on the first attempt, and the findings are instructive
about where verification was weakest:

- **Parsers scored 84/100.** Three divergences present *identically in both
  ports*, all in the serializer's duck-typing layer: `serializeStep` ignored
  JS's `Object.keys(step)` semantics, `valueAST` was wrapped by value type
  instead of by key name, and element identity was not read through the
  prototype chain. **31,269 differential-fuzz steps had missed all three; 61
  hand-written probe steps found them** — because every campaign was derived
  from the committed fixtures by mutation. That is what the `synthesis`
  campaign now fixes, and on its first run it found a further bug the
  hand-written fixtures had missed.
- **Cores scored 73/100**, including a **remotely-triggerable process abort**:
  `StreamClient` narrowed the provider-controlled `tool_calls[].index` with
  Swift's `Int(_: Double)`, which *traps* rather than clamps, so one SSE chunk
  containing `{"index":1e300}` killed the app. The package already shipped the
  correct clamping helper; it simply was not called. The same review found a
  Swift string-corruption bug (`NSString.replacingCharacters` rounds ranges to
  grapheme boundaries) reachable from every model-generated screen.

The recurring pattern across all rounds is worth stating plainly: **the exact
line that was fixed gets pinned by a test, while the identical hazard one line
away stays untested.** The grapheme-rounding bug on the *closing* code fence
was found, fixed and pinned — while the same hazard on the opening fence was
not. Fixes are therefore now required to test the hazard *class*, and every new
test is falsified (broken, confirmed red, restored) before it is trusted.

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
   `#if canImport(SwiftUI)` file to *nothing*; `AppLessUI` — the 30 renderers
   and the entire OS shell — produces an empty module here. What Linux *can*
   say has been strengthened but is still only two syntax-level signals: a
   text-scanning source gate (registration present, not duplicated, not
   misnamed, no undeclared prop read, no unmapped icon, nothing escaping the
   `canImport` guard — all nine checks falsified by mutation), and
   `swiftc -parse` over every UI file with the guards forced on (22 units).
   Neither catches a type error, a missing argument label, a wrong
   `ViewBuilder` shape, or a `@State` misuse. What *did* change is how much
   logic is left in those bodies: all 30 renderers now read props through
   `AppLessCore`, and 23/30 delegate a named decision to a Core type with
   Linux tests behind it.

2. **~~No Compose composable has ever been executed.~~ CLOSED.** All 30
   renderers plus the shell now execute in real Robolectric compositions
   (`compose renderers executed: 30/30`), gated by `android-app.yml`. The
   equivalent gap on iOS remains fully open and cannot be closed on Linux.

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
| 3. iOS app | **in-flight** — code complete; decision logic extracted into 296 Linux-tested `AppLessCore` cases, but SwiftUI type-checking is still blocked on macOS CI |
| 4. iOS parity & hardening | **in-flight** — six RN divergences found and fixed by source-level audit (see §4); the manual side-by-side checklist is still not executed |
| 5. Kotlin parser + core | **done** (parser, `genos-core`, and `ui-core`) |
| 6. Android app | **done** — `:app` compiles, assembles a real APK, and passes 183 tests, 112 of which execute real Compose compositions (`compose renderers executed: 30/30`); gated by `android-app.yml` |
| 7. Wrap-up | **in-flight** — this document, the README rewrite and `all-gates.yml` |

---

## 7. Reproducing every number in this document

```bash
export PATH=/opt/swift/usr/bin:$PATH

# Layer 0 — spec, fixtures, contract schema, prompt
cd spec/fixtures/generator && npm ci && npm test

# iOS — the Linux-runnable half
cd ios/Packages/OpenUILang && swift test    #  40 test functions / 114 fixtures
cd ios/Packages/GenOSCore   && swift test   # 237 tests
cd ios/AppLess              && swift test   # 296 tests (AppLessCore only)
python3 ios/AppLess/Scripts/parse-swiftui.py  # 22 files parsed, NOT type-checked

# Android — the pure JVM modules
cd android && ./gradlew :openui-lang:test :genos-core:test :ui-core:test --console=plain
#   openui-lang 153 · genos-core 313 · ui-core 97

# Android — the app module (needs the Android SDK; gated by android-app.yml)
cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest --console=plain
#   183 unit tests, 0 failures — 112 of them execute real Compose compositions
#   under Robolectric; prints `compose renderers executed: 30/30`

# Cross-port differential fuzzing (local three-way, in one process)
cd spec/fixtures/generator
node probes/run-differential.mjs --campaign-file probes/fuzz-campaign-pinned.json
node probes/run-differential.mjs --campaign prefix,nonmonotonic,mutation,synthesis
#   49/389 and 4,198/40,459 steps, 0 divergences
node probes/verify-collation.mjs            # 244,650 ASCII pairs vs V8

# The RN reference app
npm install && npm test
```
