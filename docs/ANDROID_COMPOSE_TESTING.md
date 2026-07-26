# Android — the Compose UI test tier

Everything in `android/app` used to be verified two ways: `:app:assembleDebug`
proved the 30 Material 3 renderers and the OS shell **compiled**, and
`:app:testDebugUnitTest` proved the routing/state/registry logic around them was
**correct**. Neither ran a single `@Composable`. A renderer whose body was
`Unit` would have passed both.

This tier closes that gap. It composes the renderers and the shell for real, on
Linux, with no emulator and no device, inside the same `testDebugUnitTest` task
CI already runs.

## Reproduce

```bash
cd android

# The whole :app tier, old suites and new.
./gradlew :app:testDebugUnitTest

# Just the Compose tier.
./gradlew :app:testDebugUnitTest --tests 'dev.appless.app.compose.*'

# The execution gate on its own (prints `compose renderers executed: 30/30`).
./gradlew :app:testDebugUnitTest --tests 'dev.appless.app.compose.RendererExecutionGate'
```

Requires JDK 21, the Android SDK at `$ANDROID_HOME` (35 + build-tools 35.0.0),
and — on a **cold** machine only — network access, see
[Offline](#offline-and-first-run) below.

## How it runs headlessly

| Piece | Why |
| --- | --- |
| **Robolectric 4.14.1** | A sandboxed Android runtime on the JVM, so `Activity`, `Looper`, resources, `Canvas`, `TextMeasurer` and `WebView` all exist inside a plain unit test. |
| **`androidx.compose.ui:ui-test-junit4`** | `createComposeRule()` / `createAndroidComposeRule()` and the semantics matchers. Compose has supported this rule *under Robolectric* since 1.5 — the `androidTest` variant of the same API is what would need a device. |
| **`ui-test-manifest`** (`debugImplementation`) | Supplies the `ComponentActivity` entry `createComposeRule()` launches into. It is a debug manifest overlay, hence not `testImplementation`. |
| **`junit-vintage-engine`** | Robolectric's runner is JUnit 4; the build is on the JUnit Platform. Vintage runs both in one task, so there is still exactly one test command. |
| **`unitTests.isIncludeAndroidResources = true`** | Robolectric needs the merged resources, assets and manifest. Without it nothing inflates. This is also what lets the harness read the *shipped* `genos.schema.json` out of the app's own assets. |
| **`src/test/resources/robolectric.properties`** | Pins `sdk=34` and `qualifiers=w411dp-h891dp-xhdpi`, so exactly one `android-all` artifact is fetched and every dp-based layout assertion has a known density. |

## What the tier asserts

Nothing here asserts "did not throw" alone. A renderer that drew nothing would
pass that, so every case asserts **observable output** — text in the semantics
tree, a laid-out size, a dispatched action, or painted pixels.

### `RendererExecutionGate` — the headline

One representative openui-lang payload per contract component, composed one at a
time, each required to supply declared evidence. Two tests:

* `the_table_covers_every_contract_component` — the table equals
  `RenderableComponent.ALL`, so a new contract component cannot be silently
  skipped.
* `every_renderer_produces_observable_output` — composes all 30 and collects
  failures by name rather than throwing on the first, then prints
  `compose renderers executed: 30/30`.

28 of the 30 are pinned by **text** reaching the tree. The other two emit no
text at all and are pinned by **layout**, plus dedicated tests elsewhere:

| Renderer | Why no text | Where it is really pinned |
| --- | --- | --- |
| `PhotoGrid` | Nothing but images; Robolectric never completes a network load. | `RendererLayoutTest` — three cells per row, and entries without a `src` take up no space (`components.tsx` L484). |
| `MapView` | A `WebView` inside an `AndroidView`; interop views have no semantics. | `RendererSemanticsTest.mapView_hosts_a_webview_with_the_keyless_embed_url` — asserts the base URL, the iframe and `output=embed` through `ShadowWebView`. |

### Forcing a draw

Compose's own `captureToImage()` never completes under Robolectric — it waits on
a real window callback and throws `ComposeTimeoutException` after 2 s. The
charts are drawn entirely into a `Canvas`, so without a draw pass every chart
assertion would only prove their surrounding `Text` chrome exists.

`RendererSemanticsTest` instead finds the `AndroidComposeView` in the activity's
hierarchy and calls `View.draw(Canvas(bitmap))` itself, under
`@GraphicsMode(NATIVE)` — Robolectric's LEGACY mode stubs `Canvas` out, so the
annotation is load-bearing. The assertion is that the raster is not uniform;
`a_chart_with_no_data_paints_nothing_at_all` is the negative control that proves
the check can tell the two apart (observed: 315-672 distinct colours for a real
chart, 1 for an empty one).

### The other suites

| Suite | What it pins |
| --- | --- |
| `RendererCompositionTest` | Per-renderer happy path, plus the interaction rules only a composition can reach: an action-less `Button` dispatches its label while an action-less `ListItem` is inert; a `Chip` re-tap is a no-op; `Tabs` and `Toggle` change locally and dispatch nothing. |
| `RendererHostileInputTest` | Missing props, wrong-typed props, non-list list props, falsy list entries, bare string children, unknown components, structural placeholders, empty/zero-total charts, 40-deep nesting, and **every prefix of a streamed program** — which is literally what the app does ~20 times a second. |
| `FormRoundTripTest` | Type → tap → payload, end to end. Field order, the `{ value, componentType }` wrapper, per-renderer `componentType`, `Form` scoping, the seeded-default rule, and the exact serialized bytes. |
| `IconCompositionTest` | All 88 Lucide + the Phosphor names composed and **measured** — a resolved glyph lays out at the requested size, an unknown name at the 8dp placeholder dot, so the two are distinguishable without a screenshot. |
| `RendererSemanticsTest` | One row per item, the `WebView` URL, and a forced **draw** pass over the charts with an empty chart as the negative control. |
| `StreamingSeedTest` | The production `ScreenView` streaming path: a program replayed character by character, the `!isStreaming` seed gate, fence stripping, and "no root yet". |
| `RendererLayoutTest` | The flex arithmetic: `PhotoGrid` three per row, `StatTiles` two per row, `ImageBlock` 16:9. |
| `ShellCompositionTest` | home grid → open an app → push a screen → back → home, driven through taps, against the real `GenOSController`/`ScreenStore` with a fake streamer. |

## Three things the tier found

### 1. `Slider` with a non-finite bound never stops animating

`numberOrNull()` is a faithful port of `typeof x === "number"` — and `NaN` **is**
a number in JS. RN's `<RNSlider minimumValue={NaN}>` simply draws a dead track.
Compose's `Slider` instead animates its thumb toward `NaN` forever: the
composition never reaches idle, which on a phone is a pinned core and a flat
battery, and in this suite was an unattributable hang.

Fixed with `Props.finiteOrNull()` (a non-finite number is treated as absent,
the same guard `intOrNull` already applied), used for `min`/`max`/`step` and for
the value read back out of form state. Regression test:
`RendererHostileInputTest.a_slider_with_non_finite_bounds_settles`.

### 2. Form-state key order dropped the array-index hoist

`spec/openui-lang.md` §9.4 step 6 sends the payload as
`"\n\nSubmitted form values: " + JSON.stringify(formState)`, so its key order is
what the model reads as the order of the form. React-lang holds that payload in
a **plain JS object** (`store.set(formName, { ...formData, [name]: wrapped })`,
react-lang `hooks/useOpenUIState.js`), and `JSON.stringify` enumerates a plain
object with `OrdinaryOwnPropertyKeys` (ES 10.1.11.1): every **canonical array
index** first, in ascending numeric order, then the remaining keys in insertion
order.

The port carried insertion order only, so a form with fields named `10`, `zeta`,
`2` would have reached the model as `{"10":…,"zeta":…,"2":…}` where RN sends
`{"2":…,"10":…,"zeta":…}`. `:openui-lang` already pins the same rule for the
tree serializer (`spec/fixtures/075-object-key-index-order`), but that helper is
`internal` to the module.

Fixed in `render/ScreenView.kt`'s `toControllerFormState()` — the one bridge
between the prop world and the wire world, and the only piece of that path in
`android/app`. Tests: `FormBridgeTest` (three JVM cases) and
`FormRoundTripTest.canonical_array_index_field_names_are_hoisted_and_sorted_numerically`
(through a real composition). Verified by mutation: reverting the fix fails
exactly those four tests.

### 3. Two RN behaviours the port had dropped

**`useSetDefaultValue` was missing its `!isStreaming` guard.** react-lang seeds
a model-supplied `value` only when the screen is NOT streaming
(`context.js` L85). The port provided `LocalIsStreaming` from `ScreenView` but
no consumer ever read it, so a prefill appeared as soon as any parse resolved
the prop rather than when the screen finished. Seeding is one-shot — the
"only when unset" guard refuses every later write — so the seeded value must
come from the settled tree. Fixed in `Forms.kt`'s `rememberField`; pinned by
`StreamingSeedTest`.

*Measured, so as not to overclaim:* this port's incremental parser withholds an
incomplete statement entirely rather than auto-closing it, so a **truncated**
string value is not reachable here. The guard is carried because RN carries it
and the resulting UI differs, not because a truncation was observed.

**Five icon-only controls had lost their `accessibilityLabel`.** The RN shell
labels all of them — `"Back"`/`"Home"` (`GenOS.tsx` L658), `"App switcher"`
(L703), `` `Close ${app.name}` `` (`HomeScreen.tsx` L259, `Switcher.tsx` L89)
and `"Send"` (`HomeScreen.tsx` L467). The Compose port had none, which is both
an RN-parity gap and a real TalkBack regression: every one of them announced as
an unlabeled button. Restored as `semantics { contentDescription = …; role =
Role.Button }` in `Chrome.kt`, `HomeScreen.kt` and `Switcher.kt`. This is also
what makes them addressable, so `ShellCompositionTest` drives them by label.

## Offline and first run

Robolectric resolves its `android-all-instrumented` runtime from Maven Central
the first time a test runs and caches it under `~/.m2/repository`. That is the
only network access the tier needs; every later run is offline. On CI this is a
~50 MB download per cold runner.

Everything else is offline by construction. In particular, images are never
loaded: `SemanticImage.resolve` returns a URL, Coil starts a request that
Robolectric never completes, and the tests assert around it (captions, layout)
rather than waiting on it.

## Known limits

* **No pixel baselines.** The draw pass proves a chart *painted*, not that it
  painted the right thing. A screenshot baseline is only meaningful on a real
  device/renderer, so it belongs in `androidTest`, not here.
* **Animations are not asserted.** `ScreenFrame`'s direction-aware transitions
  and the minimize animation are driven by the test clock and settle
  immediately; their *timing* is not pinned.
* **Coil is never exercised past the request.** `SemanticImage`'s resolution
  policy is tested in `:ui-core`; the loading path is not.
* **`waitForIdle` hangs on a non-settling composition.** That is a Compose test
  framework property, not something the suite can catch cleanly — driving the
  clock by hand (`mainClock.autoAdvance = false`) was tried and rejected because
  a state write that adds a *new* layout node then never reaches the semantics
  tree, which would turn every content assertion into a silent no-op. The
  backstop is `timeout.set(Duration.ofMinutes(20))` on the `Test` task.
