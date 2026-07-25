# AppLess (SwiftUI)

The iOS shell for the GenOS runtime: it consumes the verified Swift packages
`../Packages/OpenUILang` (openui-lang parser + evaluator) and
`../Packages/GenOSCore` (screen store, controller, streaming, app catalog), and
renders the resolved element tree with SwiftUI.

**Status: renderers complete.** Tokens, the icon map, the contract tables, the
prop decoders and the conformance registry are done and tested, and all **30**
Cupertino renderers are implemented and wired by `registerCupertinoRenderers()`.
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
    RendererProps.swift     prop shapes + the rules the renderers branch on
    FormState.swift         form-state model, {value, componentType} payload
    Actions.swift           ActionPlan → ActionEvent (spec §9.3-9.4)
    ChartData.swift         domain rounding, ticks, stacking, pie geometry
    MapGeometry.swift       contract zoom levels → MKCoordinateSpan deltas
    SemanticImage.swift     /api/img resolution policy over GenOSCore.Images
  AppLessUI/              SwiftUI only — every file is `#if canImport(SwiftUI)`
    AppLessApp.swift        @main App struct + RootView
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
```

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
swift build
swift test
```

Both are green on Linux with no Xcode and no SwiftUI SDK.

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

Linux still gets a real check on the wiring: `RendererWiringTests` reads
`Sources/AppLessUI/Renderers.swift` as TEXT and fails if any
`RenderableComponent` case has no `registry.register(.Foo)` line, if there are
more or fewer than 30 registrations, or if any `AppLessUI` file is missing its
`#if canImport(SwiftUI)` guard. A component left unwired therefore goes red on
the cheap tier, before macOS CI ever runs.

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

## Sources of truth

| Ported artifact | Source |
|---|---|
| `CdsTheme` light/dark, `useCds` | `src/genos/ui/cupertino/theme.ts` |
| `CdsMetrics` radii/spacing/type | `src/genos/ui/cupertino/components.tsx`, `forms.tsx` |
| `IconMap`, `iconTint`, dot fallback | `spec/icon-map.md`, `src/genos/ui/icons.tsx` |
| `ContractSchema`, `RenderableComponent` | `spec/contract/genos.schema.json`, `src/genos/ui/contract.tsx` |
| `RendererProps`, the renderer views | `src/genos/ui/cupertino/components.tsx`, `forms.tsx` |
| `ChartData` | `src/genos/ui/shared/charts.tsx` |
| `FormState`, `Actions` | `src/genos/ui/shared/{forms.ts,actions.ts}`, `spec/openui-lang.md` §9.3-9.4 |
| `MapGeometry` | `src/genos/ui/shared/map.tsx`, `contract.tsx` MapView |
| `SemanticImage` | `src/genos/tools/images.ts`, `GenOSCore.Images` |

Regenerate `ContractSchema.swift` whenever the contract changes; the tests fail
loudly if it drifts.
