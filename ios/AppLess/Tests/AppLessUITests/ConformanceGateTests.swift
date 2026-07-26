//
//  ConformanceGateTests.swift
//  AppLessUITests
//
//  The LIVE conformance gate. On Linux the SwiftUI target compiles to nothing,
//  so `RendererWiringTests` can only read the registrations as text and assert
//  the DECLARED count; here - on macOS/iOS, where the renderers actually exist
//  - `registerCupertinoRenderers()` is run and the registry is asked what it
//  really holds.
//
//  The whole file is guarded, so on Linux this target builds to an empty test
//  bundle instead of failing to compile.
//

#if canImport(SwiftUI)

    import Foundation
    import Testing

    @testable import AppLessCore
    @testable import AppLessUI

    @Suite struct ConformanceGateTests {

        /// A private registry, so the test never depends on whether the app
        /// already populated the shared one.
        private func registered() -> RendererRegistry {
            let registry = RendererRegistry(designSystem: "cupertino")
            registerCupertinoRenderers(into: registry)
            return registry
        }

        @Test func everyContractComponentHasALiveRenderer() {
            let report = registered().conformanceReport()
            #expect(report.isComplete, "\(report.formatted())")
            #expect(report.gateLine == report.declaredGateLine)
            print(report.gateLine)
        }

        @Test func theGateLineIsTheOneCIGreps() {
            #expect(registered().conformanceReport().gateLine == "renderers registered: 30/30")
        }

        @Test func everyRendererIsTheTypedGenosRenderer() {
            let registry = registered()
            for component in RenderableComponent.allCases {
                #expect(
                    registry.genosRenderer(for: component) != nil,
                    "\(component.rawValue) is registered with the wrong closure type")
            }
        }

        /// The shell's own entry points exist and are wired to the same
        /// registry - a compile-level check that the views in this module are
        /// reachable from the app.
        @Test func theShellSurfaceIsPublic() {
            #expect(RendererRegistry.shared.designSystem == "cupertino")
            #expect(ShellChrome.leadingButton(stackDepth: 1) == .home)
        }
    }

#endif
