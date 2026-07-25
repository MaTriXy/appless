//
//  Renderers.swift
//  AppLessUI
//
//  The renderer type the SwiftUI layer registers into
//  `AppLessCore.RendererRegistry`, plus the node dispatcher.
//
//  SCAFFOLD: `registerCupertinoRenderers()` is intentionally empty - the
//  renderer implementations land in the follow-up renderers task. The registry
//  already declares all 30 required components, so
//  `RendererRegistry.shared.conformanceReport()` reports every one of them as
//  missing until they are wired here, one `registry.register(...)` per
//  component.
//

#if canImport(SwiftUI)

import AppLessCore
import OpenUILang
import SwiftUI

/// Everything a renderer needs beyond its own props: how to render nested
/// nodes, and the resolved theme. Mirrors the RN `Renderer` signature
/// (`contract.tsx` L181-184: `{ props, renderNode }`).
public struct RenderContext {
    public let theme: CdsTheme
    /// Render a child element (or a list of them) - the Swift equivalent of
    /// `renderNode`.
    public let renderNode: (PropValue?) -> AnyView

    public init(theme: CdsTheme, renderNode: @escaping (PropValue?) -> AnyView) {
        self.theme = theme
        self.renderNode = renderNode
    }

    public func render(_ elements: [ElementNode]) -> AnyView {
        renderNode(.array(elements.map { PropValue.element($0) }))
    }
}

/// One design system's renderer for one contract component.
public typealias GenosRenderer = (ElementNode, RenderContext) -> AnyView

extension RendererRegistry {
    /// Type-safe wrapper over the erased `register` in `AppLessCore`.
    public func register(
        _ component: RenderableComponent,
        file: String = #fileID,
        _ renderer: @escaping GenosRenderer
    ) {
        register(component, renderer: renderer, file: file)
    }

    /// The typed renderer for a component, if one was registered.
    public func genosRenderer(for component: RenderableComponent) -> GenosRenderer? {
        renderer(for: component) as? GenosRenderer
    }
}

/// Wire up the Cupertino renderer set.
///
/// Called once at app start (see `AppLessApp`). Idempotent: re-registering a
/// component replaces the previous renderer.
public func registerCupertinoRenderers(into registry: RendererRegistry = .shared) {
    // SCAFFOLD - no renderers yet. The renderers task adds one line per
    // component here, e.g.:
    //
    //     registry.register(.CardHeader) { node, ctx in
    //         AnyView(CardHeaderView(node: node, ctx: ctx))
    //     }
    //
    // `ConformanceGateTests` fails on macOS CI until
    // `registry.conformanceReport().isComplete` is true.
    _ = registry
}

/// Renders one resolved element by looking its renderer up in the registry.
///
/// Unknown or unregistered components render nothing rather than crashing -
/// the same "never break the screen" posture as the icon fallback.
public struct GenosNodeView: View {
    public let node: ElementNode
    public let context: RenderContext

    public init(node: ElementNode, context: RenderContext) {
        self.node = node
        self.context = context
    }

    public var body: some View {
        if let component = RenderableComponent(rawValue: node.component),
           let renderer = RendererRegistry.shared.genosRenderer(for: component) {
            renderer(node, context)
        } else {
            // Structural placeholders (TabItem / SelectItem / Series) reach
            // here too: their parents consume them, so rendering nothing is
            // correct, not a gap.
            EmptyView()
        }
    }
}

#endif
