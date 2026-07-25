import Foundation
import Testing

@testable import AppLessCore

/// The SwiftUI renderers cannot be COMPILED on Linux (no SwiftUI SDK), so
/// nothing can register there and `conformanceReport().registeredCount` is
/// always 0. These tests read `Sources/AppLessUI/*.swift` as text instead, so
/// Linux CI still fails loudly when a component is left unwired - macOS CI then
/// proves the same thing for real by asserting `report.isComplete`.
@Suite struct RendererWiringTests {

    private static let uiDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AppLessCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppLess
        .appendingPathComponent("Sources/AppLessUI")

    private func uiSource(_ name: String) throws -> String {
        try String(
            contentsOf: Self.uiDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every renderer file must compile to nothing on Linux - that is the whole
    /// reason `swift build` is green here.
    @Test func everyUIFileIsGuarded() throws {
        let files = try FileManager.default
            .contentsOfDirectory(atPath: Self.uiDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(!files.isEmpty)
        for file in files {
            let source = try uiSource(file)
            #expect(
                source.contains("#if canImport(SwiftUI)"),
                "\(file) is not wrapped in `#if canImport(SwiftUI)`")
        }
    }

    @Test func registerCupertinoRenderersWiresEveryContractComponent() throws {
        let source = try uiSource("Renderers.swift")
        for component in RenderableComponent.allCases.sorted() {
            #expect(
                source.contains("registry.register(.\(component.rawValue))"),
                "registerCupertinoRenderers() never registers \(component.rawValue)")
        }
    }

    /// One registration per component and no more - a duplicated line would
    /// silently shadow an earlier renderer.
    @Test func thereAreExactlyThirtyRegistrations() throws {
        let source = try uiSource("Renderers.swift")
        let registrations = source
            .components(separatedBy: "registry.register(.")
            .dropFirst()
            .count
        #expect(registrations == RenderableComponent.requiredCount)
        #expect(registrations == 30)
    }

    /// The registry's own gate line, printed for CI to grep. On Linux this is
    /// the DECLARED count; macOS CI asserts the live one equals it.
    @Test func declaredGateLineIsComplete() {
        let report = RendererRegistry(designSystem: "cupertino").conformanceReport()
        #expect(report.declaredGateLine == "renderers registered: 30/30")
        print(report.declaredGateLine)
    }
}
