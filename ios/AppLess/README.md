# AppLess (SwiftUI)

The iOS shell for the GenOS runtime: it consumes the verified Swift packages
`../Packages/OpenUILang` (openui-lang parser + evaluator) and
`../Packages/GenOSCore` (screen store, controller, streaming, app catalog), and
renders the resolved element tree with SwiftUI.

**Status: renderers + shell complete.** Tokens, the icon map, the contract
tables, the prop decoders and the conformance registry are done and tested, all
**30** Cupertino renderers are implemented and wired by
`registerCupertinoRenderers()`, and the OS shell (home screen, screen stack,
switcher, chrome, key gate) is ported from `src/genos/GenOS.tsx`.
See [Known differences](#known-differences-vs-the-react-native-renderers) for
every place SwiftUI cannot reproduce the RN behavior exactly.

## Layout

```
Package.swift
Sources/
  AppLessCore/            platform-independent, NO SwiftUI — builds on Linux
    Tokens.swift            CdsTheme light/dark + Cupertino metrics
    IconMap.swift           Lucide/Phosphor → SF Symbols + dot fallback + iconTint
    ContractSchema.swift    GENERATED from spec/contract/genos.schema.json
    RendererRegistry.swift  RenderableComponent, registry, conformanceReport()
    PropDecoding.swift      PropValue/ElementNode readers, placeholder decoders
    JSValue.swift           ECMAScript Number::toString, Math.round, and what
                            React paints for a prop (`jsText` vs `String(v)`)
    RendererProps.swift     prop shapes + the rules the renderers branch on
    RendererPresentation.swift  the per-renderer decisions a `body` used to make:
                            Select/Tabs/Chips/Slider/Buttons/Toggle/Bubbles,
                            flex-wrap rows, field seeding
    FormState.swift         form-state model, {value, componentType} payload
    Actions.swift           ActionPlan → ActionEvent (spec §9.3-9.4)
    ChartData.swift         domain rounding, ticks, stacking, pie geometry
    ChartLayout.swift       CartesianChartInput (decode + point flattening),
                            axis-label slots, pie disc geometry, bridge numbers
    MapGeometry.swift       contract zoom levels → MKCoordinateSpan deltas
    SemanticImage.swift     /api/img resolution policy over GenOSCore.Images
    CommandRouter.swift     routeCommand / handleAction as pure decisions
    ShellState.swift        sessions, activeApp, recents, minimized set, @OS
    ShellChrome.swift       every shell number/color/string/curve + key gate rules
    ShellPresentation.swift screen-host state, switcher preview gating, layer
                            guards, back-swipe thresholds, home typing frames,
                            parsed-tree cache, active-screen reporting
    HomeTiles.swift         home tile icon + one-word label choice
    SuggestionRotation.swift the 4s three-slot suggestion rotation
    VectorPath.swift        SVG path-data reader (M/L/H/V/C/Z, abs + rel)
    Wordmark.swift          the AppLess wordmark path, verbatim from the asset
  AppLessUI/              SwiftUI only — every file is `#if canImport(SwiftUI)`
    AppLessApp.swift        @main App struct + RootView + setup diagnostics
    GenOSShellView.swift    the shell: layers, chrome, minimize, overlays
    ShellModel.swift        the observable object driving ShellState/GenOSCore
    ShellRuntime.swift      clock / Keychain / URLSession seams + the factory
    HomeScreenView.swift    wordmark, tiles, rotating suggestions, ask bar
    ScreenHostView.swift    skeleton → streamed render → error+retry, transitions
    SwitcherView.swift      switcher cards with live miniature previews
    KeyGateView.swift       BYOK first-launch / rejected-key gate
    ShellChromeViews.swift  chrome buttons, hint, generating pill, toast, glass
    WordmarkView.swift      the wordmark path as a SwiftUI Shape
    Theme+SwiftUI.swift     CdsColor → Color, TextStyle → Font, \.cds environment
    IconView.swift          LucideIcon, IconBadge
    Renderers.swift         RenderContext, form store, dispatcher, all 30 registrations
    Renderers+Support.swift semantic image, separators, press styles, width reader
    Renderers+Text.swift    Card, CardHeader, TextContent, TextCallout
    Renderers+Lists.swift   ListItem, Toggle, ListBlock, KVList
    Renderers+Stats.swift   HeroStat, StatTiles
    Renderers+Media.swift   ImageBlock, PhotoGrid, Bubbles, Chips, Tabs
    Renderers+Charts.swift  Bar/HorizontalBar/Line/Area (Swift Charts) + Pie (Shape)
    Renderers+Map.swift     MapView (MapKit)
    Renderers+Forms.swift   Form, FormControl, Input, TextArea, Select,
                            DatePicker, Slider, Buttons, Button
Tests/
  AppLessCoreTests/       Linux-runnable
  AppLessUITests/         guarded — empty on Linux, live conformance on macOS
Scripts/
  parse-swiftui.py        `swiftc -parse` with the canImport guards forced on
```

## The shell

`GenOSShellView` is the SwiftUI port of `src/genos/GenOS.tsx`. Its layers,
bottom to top: the home screen (always mounted), the active app's top screen,
the chrome (back/home top-left, switcher top-right), the one-time gesture hint,
the generating pill, the toast, the switcher, and the BYOK key gate.

Nothing about the shell is *decided* in a view:

| RN | Swift |
|---|---|
| `sessions` / `activeApp` / `recentOrder` / `appMeta` / `minimizedIds` | `AppLessCore.ShellState` |
| `routeCommand` (ask bar, chips) | `ShellRouter.route(_:activeApp:topScreenId:apps:)` |
| `handleAction` (taps inside a screen) | `ShellRouter.decide(event:…)` |
| chrome copy, curves, paddings, gate rules | `ShellChrome` |
| `TILE_ICONS` / `KEYWORD_ICONS` / `oneWordName` | `HomeTiles` |
| the 4s suggestion rotation | `SuggestionRotation` |
| `APPLESS_LOGO_XML` | `AppLessWordmark` + `VectorPath` |
| screens, caching, prefetch, `@OS`, cancellation | `GenOSCore.GenOSController` |

`GenOSShellModel` (in `AppLessUI`, because it is `ObservableObject`) holds only
what React kept *outside* state: the store subscription, the minimize
animation and its re-entrancy guard, the toast and hint timers, the one-shot
`@OS` execution pass, and one `StreamingParser` per visible screen.

Transitions come from `ShellChrome.transition(_:)` — launch zooms up over
380ms, push slides in from the right over 300ms, pop settles back from the left
over 260ms, Home shrinks the screen toward the icon grid over 360ms, all on
RN's `Easing.bezier(0.22, 1, 0.32, 1)`.

### Running it

The shell needs two files at runtime that this package deliberately does NOT
copy (a copy goes stale silently):

- `spec/contract/genos.schema.json` → bundled as `genos.schema.json`
- `spec/prompt/system-prompt.generated.txt` → bundled as
  `system-prompt.generated.txt`

Add both to the host app target's resources. `AppLessConfiguration.load()`
reads them from `Bundle.main`, along with an optional
`AppLessCerebrasAPIKey` / `AppLessExaAPIKey` (Info.plist or the
`EXPO_PUBLIC_*` environment variables). Without the contract, `RootView` shows
a diagnostics screen saying exactly that instead of a home screen that could
never generate anything.

## How a screen renders

```swift
GenosScreenView(root: parseResult.root!, actions: GenosActionDispatcher { event in
    // event.params / .humanFriendlyMessage / .formState / .formName
    controller.resolveAction(parentId: topId,
                             message: event.humanFriendlyMessage,
                             formState: event.formState.pairs)
})
```

`GenosScreenView` resolves the theme from the environment color scheme
(`useCds()`), owns one `GenosFormStore` for the screen, and builds the
`RenderContext` every renderer receives:

| RN hook | Swift equivalent |
|---|---|
| `useCds()` | `RenderContext.theme` (+ the `\.cds` environment value) |
| `renderNode(value)` | `RenderContext.renderNode` / `.render([ElementNode])` |
| `useFormName()` | `RenderContext.formName`, rebound by `Form` via `.scoped(formName:)` |
| `useTriggerAction()` | `RenderContext.trigger(_:action:)` → `GenosActionDispatcher` |
| react-lang state store | `GenosFormStore` → `AppLessCore.FormStateModel` |

`RenderContext.trigger` implements `triggerAction(userMessage, formName?, action?)`
verbatim (`spec/openui-lang.md` §9.4): an `ActionPlan`'s steps run in order, and
with **no** plan the default `continue_conversation` carrying the element's own
label fires — which is what makes an action-less `Button` send its label while an
action-less `ListItem` stays inert.

## Build and test (Linux, and macOS)

```sh
export PATH=/opt/swift/usr/bin:$PATH   # Swift 6.1
cd ios/AppLess
swift build --build-tests              # sources AND tests, so a test-only
                                       # warning cannot hide
swift test
python3 Scripts/parse-swiftui.py       # the SwiftUI syntax gate
```

All three are green on Linux with no Xcode and no SwiftUI SDK. That means
`AppLessCore` is compiled, executed and asserted; `AppLessUI` is parsed and
text-inspected, and **not** type-checked — see
[the Linux gate](#the-linux-gate-over-applessui--and-its-limits).

## The Linux/macOS split

This container — and CI's cheap tier — is Linux. There is no SwiftUI there, so
the package is cut in two:

- **`AppLessCore` never imports SwiftUI.** Everything that is really data —
  design token values, the icon table, the contract's component list and
  positional parameter order, prop decoding, and the renderer registry — lives
  here. It compiles and its tests run on Linux, which is what lets CI pin the
  port against the TypeScript source on every push.
- **`AppLessUI` is entirely inside `#if canImport(SwiftUI)`.** On Linux the
  predicate is false, every file compiles to nothing, and SwiftPM produces an
  empty module — the build stays green instead of failing on a missing SDK. On
  macOS/iOS the same files compile normally.

The rule to keep this working: **a value never gets decided inside
`AppLessUI`.** The SwiftUI layer bridges (`Color(token)`, `Image(systemName:)`)
but every number, color and name comes from `AppLessCore`, where a Linux test
can assert it against `src/genos/`.

Tests read `spec/contract/genos.schema.json`, `spec/icon-map.md`,
`src/genos/ui/cupertino/theme.ts` and `src/genos/ui/contract.tsx` straight from
the working tree rather than from copied fixtures, so the port cannot drift from
the spec without a red test.

## Opening it in Xcode

There is no `.xcodeproj` — this is a plain SwiftPM package, which Xcode opens
directly:

```sh
open ios/AppLess/Package.swift        # or: File ▸ Open… and pick Package.swift
```

Xcode resolves the two local path dependencies from `../Packages/*` in place, so
edits to `OpenUILang` / `GenOSCore` are picked up without a version bump.

`AppLessApp` is the `@main` entry point. To run it on a simulator or device you
need an app target, which SwiftPM cannot declare: create an iOS App target in a
workspace alongside this package (File ▸ New ▸ Project ▸ App, then File ▸ Add
Package Dependencies… ▸ Add Local… ▸ `ios/AppLess`), add `AppLessUI` to its
frameworks, and delete the template's generated `App` struct so `AppLessApp`
is the only `@main`. Until then, `swift build` and SwiftUI previews in Xcode
cover the UI layer.

`AppLessCore` alone is enough for `swift test`; no Xcode step is needed for the
conformance gate.

## The conformance gate

`RendererRegistry` declares the components a design system must implement:
the contract's 33 components minus the 3 structural placeholders
(`TabItem`, `SelectItem`, `Series` — consumed by their parents, `component: () =>
null` in `contract.tsx`) = **30**, cross-checked against the 30 `Renderer<…>`
slots in `GenosRenderers`.

`AppLessCoreTests` prints the gate line:

```
renderers registered: 30/30
```

That is the DECLARED count. Nothing can register on Linux (the SwiftUI target
compiles to nothing), so `conformanceReport().registeredCount` is 0 there and the
live line reads `renderers registered: 0/30`.

`registerCupertinoRenderers()` in `Renderers.swift` now wires all 30, so on
macOS CI `report.gateLine == report.declaredGateLine` — i.e. `isComplete` is
true and that is what CI should assert.

`.github/workflows/ios-app.yml` is that macOS tier: it runs `swift test` for
all three packages (which on macOS includes `AppLessUITests`, the LIVE
conformance suite), greps the gate line, and — the reason the workflow exists —
compiles the SwiftUI for iOS with
`xcodebuild -scheme AppLessUI -destination 'generic/platform=iOS'`. If a view
does not build, that job is red.

### The Linux gate over `AppLessUI` — and its limits

`AppLessUI` **cannot be type-checked on Linux.** `canImport(SwiftUI)` is false,
every file compiles to nothing, and `swift build` proving green says nothing at
all about the views. Two cheap-tier gates cover what text can cover; neither is
a type check, and neither should ever be described as one.

**1. `Scripts/parse-swiftui.py`** — copies each file with the outer guard
FORCED ON and runs `swiftc -parse` over the copies. That is a SYNTAX check: it
catches malformed expressions and unbalanced braces, including inside inactive
`#if` branches (Swift requires those to parse), and nothing else. It also
verifies the guard shape it depends on — the guard must be the first
non-comment line, `#endif` the last, and no code may escape the outer pair —
and fails on any diagnostic. `--check-only` runs the structural half with no
toolchain.

**2. `RendererSourceGateTests`** — reads `Sources/AppLessUI/*.swift` as TEXT
and fails on:

| Failure it catches | How |
|---|---|
| a component never registered | the parsed registration table vs `RenderableComponent.allCases` |
| a component registered TWICE | per-component counts, not a total (a total cannot tell 30 distinct from 29 + 1 duplicate) |
| a renderer wired under the WRONG contract name | `FooView` must render `Foo`, with the two chart pairs and `MapViewRenderer` as declared exceptions |
| a chart pair whose two registrations do not disagree | the `horizontal:` / `area:` literal must differ |
| a renderer struct that exists and is never wired (and the reverse) | `(node:, ctx:)` declarations vs the registration table |
| a `body` reading a prop the contract does not declare | every `p.text("x")`-style literal vs `ContractSchema.paramOrder[component]` |
| an icon name with no SF Symbol | every literal passed to `LucideIcon` / `IconBadge` / `PhosphorIcon`, plus every name the Core tables can produce |
| a number formatted inside a view | no `String(format:` in `AppLessUI` |
| code escaping the SwiftUI guard | first/last directive + nesting depth |

Each of those nine was verified by mutating the source and watching the named
test go red. What the gate still cannot see: type errors, wrong modifier order,
and any view that compiles and draws the wrong thing. Only the macOS job
(`xcodebuild -scheme AppLessUI -destination 'generic/platform=iOS'`) covers
those, and it has never run.

The rule that keeps the gate meaningful is the one in the section above: **a
value is never decided inside `AppLessUI`.** All 30 renderers read their props
exclusively through `AppLessCore.PropReader` / `GenosProps` / `StructuralProps`
— there is no `node.props` access anywhere in `AppLessUI` — and 23 of the 30
additionally delegate a named branching or geometry decision to a Core type
with its own Linux test.

> The scaffolding brief said 29 renderable components; 33 − 3 is 30, and the
> contract's own renderer interface declares 30. The count in the code is
> computed from the schema, never typed, and a test pins it both ways.

## Known differences vs. the React Native renderers

Everything below is a place where SwiftUI/UIKit cannot express what React
Native does, or where the platform-native answer is clearly better than a
literal transcription. Nothing here changes what a component *means* — the
contract, the prop shapes and the action semantics are identical.

### Charts

1. **Swift Charts instead of react-native-svg.** `BarChart`,
   `HorizontalBarChart`, `LineChart` and `AreaChart` are `BarMark` / `LineMark` /
   `AreaMark`, so bar widths, group insets, gridline placement and the exact
   pixel geometry are Apple's, not the RN SVG code's. Everything that decides
   what the chart *says* — `niceMax` domain rounding, the `1.2M`/`3.4k` tick
   formatter, stacked column totals, the grouped/stacked and
   linear/natural/step tables, the ≤16-point marker rule, the 0.18 area opacity
   — is `AppLessCore.ChartData`, pinned by Linux tests against
   `shared/charts.tsx`.
2. **`PieChart` is a `Shape`, not `SectorMark`.** `SectorMark` is iOS 17 and
   this package targets iOS 16, so wedges are drawn from
   `ChartData.pieSlices`. Angles, the donut's 0.6 inner-radius factor, the
   semi-circular anchor (6pt above the bottom edge) and the 0.008rad wedge gap
   are the RN `arcPath` numbers exactly.
3. **Axis-label thinning is Swift Charts'.** RN drops every *n*th x label using
   a ~44pt budget (`ChartData.labelStride`, kept and tested for parity); Swift
   Charts decides collisions itself, so the helper is not called by the
   renderer. Long labels are still elided at the RN limits (8 chars on the x
   axis, 9 in horizontal rows) — which means two categories that differ only
   after the cut-off collapse onto one horizontal-bar row, as they do in RN.
4. **The legend wraps three per line.** RN uses `flexWrap`; the port chunks the
   entries, which is identical for the six-color palette at phone widths and
   only differs for very long category names.
5. **Stacking is Swift Charts'.** Stacked bars are expressed by giving every
   series the same `position(by:)` group; the visual stack order therefore
   follows Swift Charts' rules rather than the RN accumulator.

### Map

6. **MapKit instead of a Google Maps WebView.** RN has no first-party map, so
   `shared/map.tsx` loads `maps.google.com/…&output=embed` inside a WebView.
   On iOS the native answer is `Map` + `MapMarker`, so the port geocodes
   `placeName` with `CLGeocoder` and drops a marker on the result. Consequences:
   the map is Apple's cartography, not Google's; a place the geocoder cannot
   resolve shows the empty themed surface with no marker (RN would show
   Google's "not found" map); and there is no web `&z=` parameter, so the
   contract's zoom levels are converted to an `MKCoordinateSpan` by
   `MapGeometry` (`360 / (256·2^z)` degrees per point at the 215pt map height,
   Mercator-corrected by `cos(latitude)`). MapKit widens the longitude span to
   the view's aspect ratio on its own.

### Forms

7. **`Select` opens a sheet, not a centered translucent modal.** RN renders a
   `Modal` with a 40%-black backdrop and the options floated in the middle.
   `.fullScreenCover` is unavailable on macOS (which compiles this target in
   CI), so the port uses `.sheet` — the platform-standard presentation.
8. **Placeholders are drawn, not styled.** SwiftUI has no placeholder color
   before iOS 17, so `Input` / `TextArea` / `DatePicker` draw the placeholder
   as a non-hit-testing `Text` in `t.ink3` behind the field.
9. **No `persist` distinction on field writes.** RN calls
   `field.set(text, false)` while typing and `field.set(text, true)` on
   end-editing. `GenosFormStore` has a single write path; every keystroke
   updates the store. Nothing observable changes — the value the model receives
   at submit time is the same — but a future react-lang-style "commit" hook has
   no hook to attach to yet.
10. **`DatePicker` is still a text field**, exactly as in RN: an ISO string the
    model can read back (`YYYY-MM-DD`, or `YYYY-MM-DD → YYYY-MM-DD` in `range`
    mode). It is deliberately NOT a `SwiftUI.DatePicker` — a native wheel cannot
    express `range` mode or an empty/unset value, and the contract's `value`
    prop is free-form.
11. **Form-state key order is only preserved at the top level.**
    `FormStateModel` keeps fields in UI insertion order, but
    `GenOSCore.JSONValue.stringifyOrdered` (the existing, verified serializer)
    sorts NESTED object keys, so the per-form field object arrives at the model
    alphabetically rather than in UI order. Field order carries no meaning in
    the request, and changing the serializer is a `GenOSCore` decision.
12. **`@Set` steps apply only resolved values.** An `ActionPlan`'s `set` step
    carries a deferred `valueAST`; evaluating it needs the openui-lang
    evaluator, which the shell owns. `RenderContext.trigger` applies a `set`
    whose value is already a literal and ignores one that is still an AST.
    `@Reset` works fully. Neither step appears in any AppLess-generated screen
    today (`@Run` likewise is documented as unused).
13. **An empty `ActionPlan` dispatches nothing** — matching react-lang, where
    the label fallback only fires when there is no plan at all. A `Button` with
    `Action([])` is therefore inert in both implementations.

### Layout and typography

14. **`flexWrap` is chunked, not measured.** `StatTiles` (2 per row) and
    `PhotoGrid` (3 per row) chunk their items and let a short last row's tiles
    stretch, which reproduces RN's `flexBasis` + `flexGrow: 1` result without a
    custom `Layout`.
15. **`StyleSheet.hairlineWidth` is pinned to 0.5.** RN resolves it per screen
    scale (0.5 @2x, ~0.33 @3x); SwiftUI has no equivalent, and 0.5 is the
    thinnest line that renders on every supported device.
16. **Absolute `lineHeight` becomes `lineSpacing`.** RN sets a line BOX height;
    SwiftUI sets the GAP between lines, so `Theme+SwiftUI` subtracts the font
    size. Single-line text is identical; multi-line paragraphs can differ by a
    fraction of a point per line because the system font's intrinsic leading is
    not exactly the font size.
17. **Lucide `strokeWidth` maps onto SF Symbol weight.** SF Symbols have no
    stroke width, so `LucideIcon` draws every glyph at `.semibold`; the RN
    2.0/2.2/2.4 stroke widths collapse onto that. `spec/icon-map.md` §1 already
    governs the unknown-name placeholder dot.
18. **`Toggle` is hand-drawn, not `SwiftUI.Toggle`.** RN draws its own 47×28
    track so the switch looks the same in every design system; the port matches
    it (including the knob shadow) instead of using `UISwitch`, whose size and
    tint are not configurable to the same values.
19. **Bubble width caps once measured.** The 78% cap needs the thread's width;
    it is read with a `GeometryReader` in the background and published from
    `onAppear`/`onChange`. On the very first layout pass the cap is not applied,
    so a long bubble can be full width for one frame.
20. **The `Toggle`'s local flip is `@State`-backed per view identity.** RN keeps
    `useState<boolean | null>(null)` so a fresh `on` prop wins until the user
    touches the switch; the port does the same, but SwiftUI's `@State` is keyed
    on view identity, so a row that changes position inside a `ListBlock`
    mid-stream can reset to the model's value where React would have kept the
    override.

### The shell

21. **The wordmark is drawn, not decoded.** RN hands `APPLESS_LOGO_XML` to
    `react-native-svg`; SwiftUI has no SVG reader, so the asset's single
    `<path d="…">` lives in `AppLessCore.AppLessWordmark` and is parsed by
    `VectorPath` into a SwiftUI `Shape`. A Linux test re-reads
    `src/genos/shell/applessLogo.ts` and fails if the two ever diverge.
22. **The home wallpaper is a gradient.** `assets/home-bg.jpg` belongs to the
    Expo app, and this package ships no bitmaps, so the backdrop is
    `ShellChrome.Home.backdropStops` under the same 22% scrim. Drop the image
    into the host app and swap the `backdrop` view to match RN exactly.
23. **The minimize completion is time-based.** RN gets a `finished` flag from
    `Animated.timing(...).start(cb)`. SwiftUI's `withAnimation` has no
    completion on iOS 16, so the model waits the animation's own 360ms and
    commits under a token: a newer minimize supersedes an older one, and
    `ShellState.commitMinimize` still refuses to dismiss an app the user
    resumed mid-flight — the same two guards RN has.
24. **Back is a button, not a hardware key.** iOS has no hardware back, so RN's
    `BackHandler` table is exposed as `GenOSShellModel.handleBackGesture()`
    (backed by `ShellState.hardwareBackIntent(minimizing:)`) for the shell to
    bind to an edge-swipe; the top-left chrome button drives the same
    back/home decision.
25. **The switcher's miniatures re-render, they do not snapshot.** Like RN,
    each card renders the real element tree at full phone size and scales it
    by 0.5 — so a streaming screen keeps painting inside its card.
26. **Keyboard traits are iOS-only.** `submitLabel` / `textInputAutocapitalization`
    are applied through a `#if os(iOS)` modifier so the same views still
    compile for macOS, which is what `swift test` builds in CI.

### Text fitting

27. **The 56pt hero numbers shrink instead of wrapping.** RN puts no
    `numberOfLines` on `HeroStat.value`, so a long value wraps onto a second
    56pt line. `HeroStatView` uses `lineLimit(1)` + `minimumScaleFactor(0.5)`
    instead, because a SwiftUI text that wraps inside a fixed-height hero
    block pushes the rest of the card off screen. `StatTiles.value` is the
    same trade at `0.6`, on top of RN's own `numberOfLines={1}` — RN
    ellipsizes where the port shrinks. `ListItem.trailing` is NOT in this
    group: RN leaves it unlimited and so does the port.

## RN-parity corrections

Six places where the Swift port and `src/genos/` disagreed and the port was
wrong. Each is now pinned by a Linux test that also exercises the branch the
old code took.

| # | What the port did | What RN does | Where the fix lives |
|---|---|---|---|
| 1 | Slider read-out via `String(format: "%g")`, which cuts to 6 significant digits: `123456.7` printed `123457`, `1234567.89` printed `1.23457e+06` | interpolates a JS number into a `<Text>` | `JSNumber.string` (pinned against a node v22 table), `SliderPresentation.readoutText` |
| 2 | `Math.round` via Swift's `rounded()`, which rounds a half AWAY from zero | JS rounds a half toward +∞: `Math.round(-2.505*100)/100` is `-2.5`, not `-2.51` | `JSNumber.round`, used by `GenosProps.sliderReadout` |
| 3 | dropped non-string entries from `labels` / `rows` / `items` / `messages`, shortening the array | keeps the slot; React paints numbers. An all-numeric chart `labels` emptied the array, `hasCartesianData` went false and the **whole chart disappeared** | `PropValue.jsText`, `ChartData.axisLabels`, `GenosProps.{kvRows,statTiles,chipLabels,bubbleMessages}` |
| 4 | `p.string("value") ?? ""` everywhere a prop is painted, so `HeroStat(1234)` rendered an empty hero | `<Text>{props.value}</Text>` renders numbers (and skips booleans) | `PropReader.text(_:)`, now used by every renderer |
| 5 | `Tabs` fell back to `"Tab n"` for an EMPTY label and highlighted the CLAMPED index | `??` fires on `undefined` only; the highlight tests the RAW `active`, so a shrunken list highlights nothing | `TabsPresentation`, `StructuralProps.TabItem.label: String?` |
| 6 | `Select`'s closed control printed the item's raw value for a label-less item | `selected?.label ?? props.placeholder ?? "Select…"` — the placeholder, not the value; only the OPEN list falls back to the value | `SelectPresentation`, `StructuralProps.SelectItem.label: String?` |

Two smaller ones, same treatment: array-typed element props
(`ListBlock.items`, `Tabs.items`, `Select.items`, `Buttons.buttons`,
`Form.fields`, chart `series`) now reject a lone element, matching every RN
reader's `Array.isArray(x) ? x : []`; and `ListItem.trailing` lost its
`lineLimit(1)`, which RN does not have.

## Sources of truth

| Ported artifact | Source |
|---|---|
| `CdsTheme` light/dark, `useCds` | `src/genos/ui/cupertino/theme.ts` |
| `CdsMetrics` radii/spacing/type | `src/genos/ui/cupertino/components.tsx`, `forms.tsx` |
| `IconMap`, `iconTint`, dot fallback | `spec/icon-map.md`, `src/genos/ui/icons.tsx` |
| `ContractSchema`, `RenderableComponent` | `spec/contract/genos.schema.json`, `src/genos/ui/contract.tsx` |
| `RendererProps`, the renderer views | `src/genos/ui/cupertino/components.tsx`, `forms.tsx` |
| `ChartData`, `ChartLayout` | `src/genos/ui/shared/charts.tsx` |
| `JSValue` (`Number::toString`, `Math.round`, React text children) | ECMA-262 §6.1.6.1, pinned against node v22 |
| `RendererPresentation` | `src/genos/ui/cupertino/{components,forms}.tsx` |
| `ShellPresentation` | `src/genos/GenOS.tsx`, `shell/{HomeScreen,Switcher}.tsx` |
| `FormState`, `Actions` | `src/genos/ui/shared/{forms.ts,actions.ts}`, `spec/openui-lang.md` §9.3-9.4 |
| `MapGeometry` | `src/genos/ui/shared/map.tsx`, `contract.tsx` MapView |
| `SemanticImage` | `src/genos/tools/images.ts`, `GenOSCore.Images` |
| `ShellState`, `ShellRouter` | `src/genos/GenOS.tsx` |
| `ShellChrome` | `src/genos/GenOS.tsx`, `shell/{HomeScreen,Switcher,KeyGate}.tsx` |
| `HomeTiles`, `SuggestionRotation` | `src/genos/shell/HomeScreen.tsx`, `apps.ts` |
| `AppLessWordmark` | `src/genos/shell/applessLogo.ts` |

Regenerate `ContractSchema.swift` whenever the contract changes; the tests fail
loudly if it drifts.
