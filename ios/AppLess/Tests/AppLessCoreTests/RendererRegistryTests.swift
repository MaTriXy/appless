import Foundation
import Testing

@testable import AppLessCore

/// The conformance gate: what the contract requires, and what is wired up.
///
/// Everything here is checked against `spec/contract/genos.schema.json` on
/// disk, so `ContractSchema` and `RenderableComponent` can never drift from the
/// contract without a red test.
@Suite struct RendererRegistryTests {

    /// The three components that render nothing in every design system.
    /// `src/genos/ui/contract.tsx` L187-189.
    static let placeholders: Set<String> = ["TabItem", "SelectItem", "Series"]

    private func schemaComponents() throws -> [String] {
        let schema = try Repo.json("spec/contract/genos.schema.json")
        guard let components = schema["components"] as? [String] else {
            throw TestError("genos.schema.json has no `components` array")
        }
        return components
    }

    // MARK: - Schema tables

    @Test func allComponentsMatchTheSchemaFile() throws {
        let schema = try Repo.json("spec/contract/genos.schema.json")
        #expect(ContractSchema.allComponents == (schema["components"] as? [String]))
        #expect(ContractSchema.componentCount == schema["componentCount"] as? Int)
        #expect(ContractSchema.componentCount == ContractSchema.allComponents.count)
        #expect(ContractSchema.root == schema["root"] as? String)
    }

    @Test func placeholdersAreDeclaredComponentsThatRenderNothing() throws {
        let components = Set(try schemaComponents())
        #expect(ContractSchema.structuralPlaceholders == Self.placeholders)
        #expect(ContractSchema.structuralPlaceholders.isSubset(of: components))

        // Each one is defined with `component: () => null` in the contract.
        let contract = try Repo.text("src/genos/ui/contract.tsx")
        for name in ContractSchema.structuralPlaceholders.sorted() {
            #expect(
                contract.contains("name: \"\(name)\""),
                "\(name) is not defined in contract.tsx")
        }
        #expect(contract.contains("component: () => null"))
    }

    @Test func paramOrderCoversEveryComponent() throws {
        let schema = try Repo.json("spec/contract/genos.schema.json")
        let paramOrder = schema["paramOrder"] as? [String: [[String: Any]]]
        #expect(paramOrder?.count == ContractSchema.componentCount)
        for component in ContractSchema.allComponents {
            let expected = (paramOrder?[component] ?? []).map {
                ContractSchema.Param(
                    name: $0["name"] as? String ?? "",
                    required: $0["required"] as? Bool ?? false)
            }
            #expect(
                ContractSchema.paramOrder[component] == expected,
                "paramOrder drifted for \(component)")
        }
    }

    // MARK: - (a) registry set == schema components minus placeholders

    @Test func renderableSetEqualsSchemaMinusPlaceholders() throws {
        let expected = Set(try schemaComponents()).subtracting(Self.placeholders)

        #expect(Set(ContractSchema.renderableComponents) == expected)
        #expect(Set(RenderableComponent.allCases.map(\.rawValue)) == expected)
        #expect(
            RenderableComponent.allCases.map(\.rawValue).sorted()
                == ContractSchema.renderableComponents.sorted())

        // 33 contract components - 3 structural placeholders = 30.
        #expect(expected.count == ContractSchema.componentCount - Self.placeholders.count)
        #expect(RenderableComponent.requiredCount == expected.count)
        #expect(RenderableComponent.requiredCount == 30)
    }

    @Test func renderableSetMatchesTheGenosRenderersInterface() throws {
        // contract.tsx's `GenosRenderers` interface is the RN side's own list of
        // renderer slots; it must agree with the schema-derived set.
        let contract = try Repo.text("src/genos/ui/contract.tsx")
        guard let start = contract.range(of: "export interface GenosRenderers {"),
              let end = contract.range(of: "\n}", range: start.upperBound..<contract.endIndex)
        else {
            throw TestError("GenosRenderers interface not found in contract.tsx")
        }
        let slots = contract[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let colon = trimmed.firstIndex(of: ":"),
                      trimmed[trimmed.index(after: colon)...].hasPrefix(" Renderer<")
                else { return nil }
                return String(trimmed[..<colon])
            }
        #expect(Set(slots) == Set(RenderableComponent.allCases.map(\.rawValue)))
        #expect(slots.count == RenderableComponent.requiredCount)
    }

    @Test func paramOrderIsReachableFromTheEnum() {
        #expect(RenderableComponent.Card.paramOrder.map(\.name) == ["children"])
        #expect(RenderableComponent.CardHeader.paramOrder.map(\.name) == ["title", "subtitle"])
        #expect(RenderableComponent.CardHeader.paramOrder.map(\.required) == [true, false])
        for component in RenderableComponent.allCases {
            #expect(!component.paramOrder.isEmpty, "\(component.rawValue) has no paramOrder")
        }
    }

    // MARK: - Registry behavior

    @Test func registryTracksRegistrations() {
        let registry = RendererRegistry(designSystem: "test")
        #expect(registry.registeredCount == 0)
        #expect(registry.conformanceReport().missing.count == 30)
        #expect(registry.conformanceReport().isComplete == false)

        #expect(registry.register(.Card, renderer: "renderer-a") == true)
        #expect(registry.register(.Card, renderer: "renderer-b") == false)  // replaces
        #expect(registry.registeredCount == 1)
        #expect(registry.isRegistered(.Card))
        #expect(registry.renderer(for: .Card) as? String == "renderer-b")
        #expect(registry.registration(for: .Card)?.designSystem == "test")
        #expect(registry.isRegistered(.CardHeader) == false)

        registry.register(Dictionary(uniqueKeysWithValues: RenderableComponent.allCases.map { ($0, "r") }))
        let full = registry.conformanceReport()
        #expect(full.isComplete)
        #expect(full.registeredCount == 30)
        #expect(full.gateLine == "renderers registered: 30/30")

        registry.reset()
        #expect(registry.registeredCount == 0)
        #expect(registry.conformanceReport().gateLine == "renderers registered: 0/30")
    }

    // MARK: - The CI gate line

    @Test func conformanceGateLine() {
        let report = RendererRegistry.shared.conformanceReport()

        // NOTE ON THE COUNT: the scaffold brief said 29, but 33 contract
        // components minus 3 structural placeholders is 30, and contract.tsx's
        // GenosRenderers declares 30 renderer slots
        // (`renderableSetMatchesTheGenosRenderersInterface` above). The gate
        // denominator is computed from the schema, never typed.
        print(report.declaredGateLine)
        print("(declared count; the SwiftUI layer cannot compile on Linux, so "
            + "nothing registers here. macOS CI asserts report.gateLine instead.)")

        #expect(report.declaredGateLine == "renderers registered: 30/30")
        #expect(report.declaredCount == RenderableComponent.requiredCount)
        #expect(report.declared.count == 30)

        // On Linux the SwiftUI target compiles to nothing, so the live count is
        // 0 and every component is reported missing - which is exactly what the
        // renderers task will drive to zero.
        #expect(report.registeredCount == 0)
        #expect(report.missing.count == 30)
        #expect(report.formatted().hasPrefix("renderers registered: 0/30"))
        #expect(report.formatted().contains("contract components: 33 (3 structural placeholders excluded)"))
    }
}
