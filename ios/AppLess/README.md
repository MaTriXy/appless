# AppLess (SwiftUI)

The iOS shell for the GenOS runtime: it consumes the verified Swift packages
`../Packages/OpenUILang` (openui-lang parser + evaluator) and
`../Packages/GenOSCore` (screen store, controller, streaming, app catalog), and
renders the resolved element tree with SwiftUI.

**Status: scaffold.** Tokens, the icon map, the contract tables, the prop
decoders and the conformance registry are complete and tested. The SwiftUI
renderers are not written yet — `registerCupertinoRenderers()` is an empty stub,
so the registry currently reports 0 of 30 renderers wired.

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
  AppLessUI/              SwiftUI only — every file is `#if canImport(SwiftUI)`
    AppLessApp.swift        @main App struct + RootView
    Theme+SwiftUI.swift     CdsColor → Color, TextStyle → Font, \.cds environment
    IconView.swift          LucideIcon, IconBadge
    Renderers.swift         GenosRenderer type, registration hook, node dispatch
Tests/
  AppLessCoreTests/       Linux-runnable
```

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
live line reads `renderers registered: 0/30`. As the renderers task adds
`registry.register(.Foo) { … }` calls to `Renderers.swift`, macOS CI should
assert `report.gateLine == report.declaredGateLine` — i.e. `isComplete`.

> The scaffolding brief said 29 renderable components; 33 − 3 is 30, and the
> contract's own renderer interface declares 30. The count in the code is
> computed from the schema, never typed, and a test pins it both ways.

## Sources of truth

| Ported artifact | Source |
|---|---|
| `CdsTheme` light/dark, `useCds` | `src/genos/ui/cupertino/theme.ts` |
| `CdsMetrics` radii/spacing/type | `src/genos/ui/cupertino/components.tsx`, `forms.tsx` |
| `IconMap`, `iconTint`, dot fallback | `spec/icon-map.md`, `src/genos/ui/icons.tsx` |
| `ContractSchema`, `RenderableComponent` | `spec/contract/genos.schema.json`, `src/genos/ui/contract.tsx` |

Regenerate `ContractSchema.swift` whenever the contract changes; the tests fail
loudly if it drifts.
