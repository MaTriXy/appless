import Foundation
import Testing

@testable import AppLessCore

/// The REGISTRY side of the conformance gate: the counts and the gate line,
/// computed from the contract rather than typed.
///
/// The SOURCE side - which renderers `Renderers.swift` actually wires, under
/// which contract names, reading which props, drawing which icons - lives in
/// ``RendererSourceGateTests``, which reads `Sources/AppLessUI/*.swift` as
/// TEXT. The three text checks that used to live here (`contains` on the
/// guard, `contains` on each registration, and a count of
/// `registry.register(.` occurrences) were strictly weaker and have been
/// replaced there: a `contains` count cannot tell 30 distinct registrations
/// from 29 distinct plus one duplicate.
///
/// Neither side is a type check. On Linux the SwiftUI target compiles to
/// nothing, so `conformanceReport().registeredCount` is always 0 here and only
/// macOS CI can assert the LIVE count.
@Suite struct RendererWiringTests {

    /// 33 contract components minus the 3 structural placeholders. Derived
    /// from the schema tables both ways, so a change to one that is not
    /// mirrored in the other is red.
    @Test func theRenderableSetIsThirtyAndIsDerivedNotTyped() {
        #expect(ContractSchema.componentCount == 33)
        #expect(ContractSchema.structuralPlaceholders.count == 3)
        #expect(ContractSchema.renderableComponents.count == 30)
        #expect(RenderableComponent.requiredCount == 30)
        #expect(RenderableComponent.allCases.count == 30)
        #expect(
            Set(RenderableComponent.allCases.map(\.rawValue))
                == Set(ContractSchema.renderableComponents))
        // The placeholders are consumed by their parents, so they must NOT be
        // representable as a renderable component.
        for name in ContractSchema.structuralPlaceholders {
            #expect(RenderableComponent(rawValue: name) == nil, "\(name)")
        }
    }

    /// An empty registry reports nothing registered but still DECLARES 30 -
    /// the distinction Linux depends on, since nothing can register here. The
    /// negative half matters: a report that claimed `isComplete` on Linux
    /// would make the whole gate meaningless.
    @Test func anEmptyRegistryDeclaresThirtyAndRegistersNone() {
        let report = RendererRegistry(designSystem: "cupertino").conformanceReport()
        #expect(report.declaredGateLine == "renderers registered: 30/30")
        #expect(report.registeredCount == 0)
        #expect(!report.isComplete)
        #expect(report.gateLine == "renderers registered: 0/30")
        #expect(report.gateLine != report.declaredGateLine)
        print(report.declaredGateLine)
    }
}
