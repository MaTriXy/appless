//
//  Renderers.swift
//  AppLessUI
//
//  The renderer type the SwiftUI layer registers into
//  `AppLessCore.RendererRegistry`, the render context renderers receive, and
//  the node dispatcher.
//
//  `registerCupertinoRenderers()` wires all 30 contract components; the
//  implementations live in the `Renderers+*.swift` files, one per group.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

// MARK: - Action dispatch

/// Where a tap goes. The shell installs one of these; renderers only ever
/// build the ``ActionEvent`` and hand it over.
///
/// The handler is `@Sendable` because the dispatcher is stored in a
/// `RenderContext` that SwiftUI may copy across the view graph; it is always
/// CALLED on the main actor, from a button action or gesture.
public struct GenosActionDispatcher: Sendable {
    private let handler: @Sendable (ActionEvent) -> Void

    public init(_ handler: @escaping @Sendable (ActionEvent) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ event: ActionEvent) { handler(event) }

    /// Drops every event - the default, so a renderer used without a shell
    /// (previews, tests) still works.
    public static let ignoring = GenosActionDispatcher { _ in }
}

// MARK: - Form store

/// Live values for every named input on screen, keyed by the enclosing
/// `Form`'s name.
///
/// A reference type because the `Button` that submits is a sibling of the
/// inputs, not their parent: they need to share one store, and the store must
/// survive the re-renders that streaming causes. Locked rather than
/// `@MainActor`-isolated so it can be held in a `RenderContext` that SwiftUI
/// copies freely - the same posture as `RendererRegistry`.
public final class GenosFormStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = FormStateModel()

    public init() {}

    /// A snapshot of the whole model.
    public var state: FormStateModel {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func value(form: String?, name: String) -> FormValue? {
        lock.lock()
        defer { lock.unlock() }
        return storage.value(form: form ?? FormStateModel.unscopedFormName, name: name)
    }

    public func set(form: String?, name: String, componentType: String, value: FormValue) {
        lock.lock()
        defer { lock.unlock() }
        storage.set(
            form: form ?? FormStateModel.unscopedFormName,
            name: name,
            componentType: componentType,
            value: value)
    }

    /// Seed the model-supplied `value` / `defaultValue` prop, once.
    /// `useSetDefaultValue` - `shared/forms.ts` L24-30.
    public func seed(form: String?, name: String, componentType: String, prop: PropValue?) {
        guard let seeded = FormValue(seed: prop) else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.seedDefault(
            form: form ?? FormStateModel.unscopedFormName,
            name: name,
            componentType: componentType,
            value: seeded)
    }

    public func reset(form: String?, names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        storage.reset(form: form ?? FormStateModel.unscopedFormName, names: names)
    }

    /// The `formState` an ActionEvent carries.
    public func payload(formName: String?) -> OrderedJSON {
        lock.lock()
        defer { lock.unlock() }
        return storage.payload(formName: formName)
    }
}

// MARK: - Render context

/// Everything a renderer needs beyond its own props: how to render nested
/// nodes, the resolved theme, the shared form store, the action sink, and the
/// name of the `Form` it is inside (if any).
///
/// Mirrors the RN `Renderer` signature (`contract.tsx` L181-184:
/// `{ props, renderNode }`) plus the three React contexts the RN renderers read
/// through hooks (`useCds`, `useFormName`, `useTriggerAction`).
public struct RenderContext {
    public let theme: CdsTheme
    /// Render a child element (or a list of them) - the Swift equivalent of
    /// `renderNode`.
    public let renderNode: (PropValue?) -> AnyView
    /// Shared input values. `useFormName` + react-lang's state store.
    public let forms: GenosFormStore
    /// Where dispatched events go.
    public let actions: GenosActionDispatcher
    /// The enclosing `Form`'s `name`, or `nil` outside one (`useFormName()`).
    public let formName: String?

    public init(
        theme: CdsTheme,
        forms: GenosFormStore = GenosFormStore(),
        actions: GenosActionDispatcher = .ignoring,
        formName: String? = nil,
        renderNode: @escaping (PropValue?) -> AnyView
    ) {
        self.theme = theme
        self.renderNode = renderNode
        self.forms = forms
        self.actions = actions
        self.formName = formName
    }

    public func render(_ elements: [ElementNode]) -> AnyView {
        renderNode(.array(elements.map { PropValue.element($0) }))
    }

    /// The standard Cupertino context: `renderNode` walks the registry.
    public static func cupertino(
        theme: CdsTheme,
        forms: GenosFormStore,
        actions: GenosActionDispatcher = .ignoring,
        formName: String? = nil
    ) -> RenderContext {
        RenderContext(
            theme: theme, forms: forms, actions: actions, formName: formName
        ) { value in
            AnyView(
                GenosNodeListView(
                    elements: value?.childElements ?? [],
                    context: .cupertino(
                        theme: theme, forms: forms, actions: actions, formName: formName)))
        }
    }

    /// A context scoped to a `Form`'s name - everything rendered through it
    /// binds into that form. `FormNameContext.Provider`, `forms.tsx` L284.
    ///
    /// - Note: this rebuilds the standard `renderNode`; a caller that supplied
    ///   a custom one gets the standard walker back inside the form.
    public func scoped(formName: String?) -> RenderContext {
        .cupertino(theme: theme, forms: forms, actions: actions, formName: formName)
    }

    /// `triggerAction(userMessage, formName, action)` - the one entry point
    /// every tappable renderer uses (`spec/openui-lang.md` §9.4).
    public func trigger(_ userMessage: String, action: ActionPlan? = nil) {
        let payload = forms.payload(formName: formName)
        let outcomes = GenosActions.outcomes(
            plan: action,
            userMessage: userMessage,
            formName: formName,
            formState: payload)
        for outcome in outcomes {
            switch outcome {
            case .dispatch(let event):
                actions(event)
            case .setState(let target, let value):
                // `@Set` writes into the state store. Only a value that is
                // already resolved can be applied here - a deferred `.ast`
                // needs the openui-lang evaluator, which the shell owns.
                if let formValue = FormValue(seed: value) {
                    forms.set(
                        form: formName,
                        name: target,
                        componentType: "Set",
                        value: formValue)
                }
            case .resetState(let targets):
                forms.reset(form: formName, names: targets)
            case .runStatement:
                // Query/Mutation refs are unused in AppLess (§9.3).
                break
            }
        }
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

// MARK: - Registration

/// Wire up the Cupertino renderer set - all 30 contract components.
///
/// Called once at app start (see `AppLessApp`). Idempotent: re-registering a
/// component replaces the previous renderer, which is what a design-system
/// override needs.
///
/// `ConformanceGateTests` on macOS CI asserts
/// `RendererRegistry.shared.conformanceReport().isComplete` after this runs.
public func registerCupertinoRenderers(into registry: RendererRegistry = .shared) {

    // Structure - Renderers+Text.swift
    registry.register(.Card) { node, ctx in AnyView(CardView(node: node, ctx: ctx)) }
    registry.register(.CardHeader) { node, ctx in AnyView(CardHeaderView(node: node, ctx: ctx)) }
    registry.register(.TextContent) { node, ctx in AnyView(TextContentView(node: node, ctx: ctx)) }
    registry.register(.TextCallout) { node, ctx in AnyView(TextCalloutView(node: node, ctx: ctx)) }

    // Lists - Renderers+Lists.swift
    registry.register(.ListItem) { node, ctx in AnyView(ListItemView(node: node, ctx: ctx)) }
    registry.register(.Toggle) { node, ctx in AnyView(ToggleView(node: node, ctx: ctx)) }
    registry.register(.ListBlock) { node, ctx in AnyView(ListBlockView(node: node, ctx: ctx)) }
    registry.register(.KVList) { node, ctx in AnyView(KVListView(node: node, ctx: ctx)) }

    // Stats - Renderers+Stats.swift
    registry.register(.HeroStat) { node, ctx in AnyView(HeroStatView(node: node, ctx: ctx)) }
    registry.register(.StatTiles) { node, ctx in AnyView(StatTilesView(node: node, ctx: ctx)) }

    // Media & social - Renderers+Media.swift
    registry.register(.ImageBlock) { node, ctx in AnyView(ImageBlockView(node: node, ctx: ctx)) }
    registry.register(.PhotoGrid) { node, ctx in AnyView(PhotoGridView(node: node, ctx: ctx)) }
    registry.register(.Bubbles) { node, ctx in AnyView(BubblesView(node: node, ctx: ctx)) }
    registry.register(.Chips) { node, ctx in AnyView(ChipsView(node: node, ctx: ctx)) }
    registry.register(.Tabs) { node, ctx in AnyView(TabsView(node: node, ctx: ctx)) }

    // Map - Renderers+Map.swift
    registry.register(.MapView) { node, ctx in AnyView(MapViewRenderer(node: node, ctx: ctx)) }

    // Charts - Renderers+Charts.swift
    registry.register(.BarChart) { node, ctx in
        AnyView(CartesianBarChartView(node: node, ctx: ctx, horizontal: false))
    }
    registry.register(.HorizontalBarChart) { node, ctx in
        AnyView(CartesianBarChartView(node: node, ctx: ctx, horizontal: true))
    }
    registry.register(.LineChart) { node, ctx in
        AnyView(CartesianLineChartView(node: node, ctx: ctx, area: false))
    }
    registry.register(.AreaChart) { node, ctx in
        AnyView(CartesianLineChartView(node: node, ctx: ctx, area: true))
    }
    registry.register(.PieChart) { node, ctx in AnyView(PieChartView(node: node, ctx: ctx)) }

    // Forms & buttons - Renderers+Forms.swift
    registry.register(.Form) { node, ctx in AnyView(FormView(node: node, ctx: ctx)) }
    registry.register(.FormControl) { node, ctx in AnyView(FormControlView(node: node, ctx: ctx)) }
    registry.register(.Input) { node, ctx in AnyView(InputView(node: node, ctx: ctx)) }
    registry.register(.TextArea) { node, ctx in AnyView(TextAreaView(node: node, ctx: ctx)) }
    registry.register(.Select) { node, ctx in AnyView(SelectView(node: node, ctx: ctx)) }
    registry.register(.DatePicker) { node, ctx in AnyView(DatePickerView(node: node, ctx: ctx)) }
    registry.register(.Slider) { node, ctx in AnyView(SliderView(node: node, ctx: ctx)) }
    registry.register(.Buttons) { node, ctx in AnyView(ButtonsView(node: node, ctx: ctx)) }
    registry.register(.Button) { node, ctx in AnyView(ButtonView(node: node, ctx: ctx)) }
}

// MARK: - Node dispatch

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

/// A list of sibling elements.
///
/// Deliberately NOT a stack: it resolves to a `ForEach`, so the PARENT's stack
/// supplies the gap - exactly like `renderNode(children)` inside an RN `View`
/// with its own `gap`.
public struct GenosNodeListView: View {
    public let elements: [ElementNode]
    public let context: RenderContext

    public init(elements: [ElementNode], context: RenderContext) {
        self.elements = elements
        self.context = context
    }

    public var body: some View {
        ForEach(elements.indices, id: \.self) { index in
            GenosNodeView(node: elements[index], context: context)
        }
    }
}

/// A whole resolved screen: the root `Card` plus the shared form store.
///
/// This is what a shell renders. It owns the form store so that values survive
/// the re-renders streaming causes, and resolves the theme from the
/// environment color scheme exactly like `useCds()`.
public struct GenosScreenView: View {
    public let root: ElementNode
    public let actions: GenosActionDispatcher

    @Environment(\.colorScheme) private var colorScheme
    @State private var forms = GenosFormStore()

    public init(root: ElementNode, actions: GenosActionDispatcher = .ignoring) {
        self.root = root
        self.actions = actions
    }

    public var body: some View {
        let theme = CdsTheme.resolve(isDark: colorScheme == .dark)
        GenosNodeView(
            node: root,
            context: .cupertino(theme: theme, forms: forms, actions: actions)
        )
        .cdsTheme(colorScheme: colorScheme)
    }
}

#endif
