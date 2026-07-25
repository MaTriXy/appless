//
//  RendererRegistry.swift
//  AppLessCore
//
//  The conformance harness: which contract components a design system must be
//  able to render, which ones it actually registered, and a report the tests
//  print as a CI gate.
//
//  Deliberately free of SwiftUI so the whole thing is exercisable on Linux -
//  registrations carry a type-erased `Any` payload that only `AppLessUI`
//  (and, on macOS, the renderer tests) knows how to unwrap.
//

import Foundation

// MARK: - Renderable components

/// A contract component that a design system must supply a renderer for.
///
/// Exactly ``ContractSchema/renderableComponents`` - the schema's components
/// minus the three structural placeholders. `RendererRegistryTests` asserts
/// this enum's cases equal that computed list, which is itself checked against
/// `spec/contract/genos.schema.json` on disk, so the set can never silently
/// drift from the contract.
public enum RenderableComponent: String, CaseIterable, Sendable, Hashable, Comparable {
    // Structure
    case Card
    case CardHeader
    case TextContent
    case TextCallout
    // Lists
    case ListBlock
    case ListItem
    case Toggle
    case KVList
    // Stats & charts
    case HeroStat
    case StatTiles
    case BarChart
    case LineChart
    case AreaChart
    case PieChart
    case HorizontalBarChart
    // Media & social
    case ImageBlock
    case PhotoGrid
    case Bubbles
    case Chips
    case Tabs
    case MapView
    // Forms & buttons
    case Form
    case FormControl
    case Input
    case TextArea
    case Select
    case DatePicker
    case Slider
    case Buttons
    case Button

    /// Component name as it appears in the contract and in openui-lang source.
    public var name: String { rawValue }

    /// Positional parameters, in openui-lang call order (`schema.paramOrder`).
    public var paramOrder: [ContractSchema.Param] {
        ContractSchema.paramOrder[rawValue] ?? []
    }

    public static func < (lhs: RenderableComponent, rhs: RenderableComponent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The number of renderers a conforming design system must provide.
    /// Computed from the enum, never typed by hand.
    public static var requiredCount: Int { allCases.count }
}

// MARK: - Registration

/// One design system's renderer for one component.
///
/// ``erasedRenderer`` is `Any` because `AppLessCore` cannot name a SwiftUI
/// type. `AppLessUI` stores a `GenosRenderer` closure here and casts it back at
/// render time; Linux tests only ever look at the metadata.
public struct RendererRegistration {
    public let component: RenderableComponent
    /// Design system that supplied it, e.g. `"cupertino"`.
    public let designSystem: String
    /// `#fileID` of the registering call site - shows up in the conformance
    /// report so a missing renderer is easy to trace.
    public let sourceFile: String
    public let erasedRenderer: Any

    public init(
        component: RenderableComponent,
        designSystem: String,
        sourceFile: String,
        erasedRenderer: Any
    ) {
        self.component = component
        self.designSystem = designSystem
        self.sourceFile = sourceFile
        self.erasedRenderer = erasedRenderer
    }
}

/// Registry of the renderers a design system has wired up.
///
/// The SwiftUI layer calls ``register(_:designSystem:renderer:file:)`` once per
/// component at startup; tests call ``conformanceReport()`` to see what is
/// missing.
public final class RendererRegistry: @unchecked Sendable {

    /// Registry the app and the conformance tests share.
    public static let shared = RendererRegistry(designSystem: "cupertino")

    /// Design system this registry describes.
    public let designSystem: String

    private var storage: [RenderableComponent: RendererRegistration] = [:]
    private let lock = NSLock()

    public init(designSystem: String) {
        self.designSystem = designSystem
    }

    // MARK: Registration API (called by AppLessUI)

    /// Register `renderer` for `component`.
    ///
    /// - Returns: `false` if a renderer was already registered for that
    ///   component (the new one still wins - last registration applies, which
    ///   is what a design-system override needs); `true` on first registration.
    @discardableResult
    public func register(
        _ component: RenderableComponent,
        designSystem: String? = nil,
        renderer: Any,
        file: String = #fileID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isNew = storage[component] == nil
        storage[component] = RendererRegistration(
            component: component,
            designSystem: designSystem ?? self.designSystem,
            sourceFile: file,
            erasedRenderer: renderer
        )
        return isNew
    }

    /// Register many at once.
    public func register(
        _ renderers: [RenderableComponent: Any],
        designSystem: String? = nil,
        file: String = #fileID
    ) {
        for (component, renderer) in renderers {
            register(component, designSystem: designSystem, renderer: renderer, file: file)
        }
    }

    public func isRegistered(_ component: RenderableComponent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[component] != nil
    }

    /// The type-erased renderer for `component`, if any. `AppLessUI` casts the
    /// result back to its concrete renderer type.
    public func renderer(for component: RenderableComponent) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[component]?.erasedRenderer
    }

    public func registration(for component: RenderableComponent) -> RendererRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return storage[component]
    }

    /// Every registered component, sorted by name.
    public var registeredComponents: [RenderableComponent] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted()
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// Drop every registration - used by tests that need a clean registry.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    // MARK: Conformance

    /// Snapshot of how complete this design system's renderer set is.
    public func conformanceReport() -> ConformanceReport {
        let registered = registeredComponents
        let registeredSet = Set(registered)
        return ConformanceReport(
            designSystem: designSystem,
            declared: RenderableComponent.allCases.sorted(),
            registered: registered,
            missing: RenderableComponent.allCases.sorted().filter { !registeredSet.contains($0) },
            registrations: registered.compactMap { registration(for: $0) }
        )
    }
}

// MARK: - Conformance report

/// Result of comparing a registry against the contract.
public struct ConformanceReport {
    /// Design system the report describes.
    public let designSystem: String
    /// Every component the contract requires a renderer for (30).
    public let declared: [RenderableComponent]
    /// Components that actually have a renderer.
    public let registered: [RenderableComponent]
    /// `declared` minus `registered`.
    public let missing: [RenderableComponent]
    public let registrations: [RendererRegistration]

    /// The number of renderers the contract requires - the gate's denominator.
    public var declaredCount: Int { declared.count }
    /// The number of renderers wired up right now.
    public var registeredCount: Int { registered.count }
    public var isComplete: Bool { missing.isEmpty }

    /// CI gate line for the count actually wired up:
    /// `renderers registered: 0/30` while the SwiftUI layer is a stub,
    /// `renderers registered: 30/30` once it is complete.
    public var gateLine: String {
        "renderers registered: \(registeredCount)/\(declaredCount)"
    }

    /// CI gate line for the count the contract DECLARES.
    ///
    /// The scaffold prints this so the gate exists before the SwiftUI renderers
    /// are written (they cannot compile on Linux, so nothing can register
    /// there); the renderers task switches the assertion over to ``gateLine``
    /// on macOS CI, where the two must agree.
    public var declaredGateLine: String {
        "renderers registered: \(declaredCount)/\(declaredCount)"
    }

    /// Human-readable multi-line summary.
    public func formatted() -> String {
        var lines = [
            gateLine,
            "design system: \(designSystem)",
            "contract components: \(ContractSchema.componentCount) "
                + "(\(ContractSchema.structuralPlaceholders.count) structural placeholders excluded)",
        ]
        if missing.isEmpty {
            lines.append("missing: none")
        } else {
            lines.append("missing (\(missing.count)): " + missing.map(\.rawValue).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
