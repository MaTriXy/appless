// GENERATED from spec/contract/genos.schema.json (componentCount: 33, root: "Card").
// Regenerate whenever the contract changes; ContractSchemaTests re-reads the JSON
// on Linux and fails if this file drifts from it. Do not hand-edit the tables.

import Foundation

/// The GenOS contract as declared by `spec/contract/genos.schema.json` - the
/// source of truth for what a design system must be able to render.
public enum ContractSchema {

    /// Root component the model always emits (`schema.root`).
    public static let root = "Card"

    /// `schema.componentCount` - every component the contract defines.
    public static let componentCount = 33

    /// `schema.components`, verbatim (alphabetical, as exported).
    public static let allComponents: [String] = [
        "AreaChart",
        "BarChart",
        "Bubbles",
        "Button",
        "Buttons",
        "Card",
        "CardHeader",
        "Chips",
        "DatePicker",
        "Form",
        "FormControl",
        "HeroStat",
        "HorizontalBarChart",
        "ImageBlock",
        "Input",
        "KVList",
        "LineChart",
        "ListBlock",
        "ListItem",
        "MapView",
        "PhotoGrid",
        "PieChart",
        "Select",
        "SelectItem",
        "Series",
        "Slider",
        "StatTiles",
        "TabItem",
        "Tabs",
        "TextArea",
        "TextCallout",
        "TextContent",
        "Toggle",
    ]

    /// Structural placeholders: declared in the contract but consumed by their
    /// parents, so they render nothing in every design system.
    /// Source: `src/genos/ui/contract.tsx` L187-189 ("TabItem, SelectItem and
    /// Series are structural placeholders ... not part of the renderer set"),
    /// backed by their `component: () => null` definitions (L392, L516, L420).
    public static let structuralPlaceholders: Set<String> = [
        "Series",
        "SelectItem",
        "TabItem",
    ]

    /// `allComponents` minus `structuralPlaceholders` - the 30 renderable
    /// components a design system must implement.
    ///
    /// NOTE: 33 contract components minus 3 structural placeholders is 30, and
    /// `GenosRenderers` in `src/genos/ui/contract.tsx` declares exactly 30
    /// renderer slots (verified by `ContractSchemaTests`). Scaffolding notes
    /// that say "29" are an arithmetic slip; this value is computed, never typed.
    public static let renderableComponents: [String] =
        allComponents.filter { !structuralPlaceholders.contains($0) }

    /// One positional parameter of a component, in openui-lang call order.
    public struct Param: Sendable, Equatable {
        public let name: String
        public let required: Bool
        public init(name: String, required: Bool) {
            self.name = name
            self.required = required
        }
    }

    /// `schema.paramOrder` - positional argument order per component. The JSON
    /// Schema `properties` maps are sorted alphabetically for diff stability, so
    /// this table (not the schema body) carries positional order.
    public static let paramOrder: [String: [Param]] = [
        "AreaChart": [.init(name: "labels", required: true), .init(name: "series", required: true), .init(name: "xLabel", required: false), .init(name: "yLabel", required: false), .init(name: "variant", required: false)],
        "BarChart": [.init(name: "labels", required: true), .init(name: "series", required: true), .init(name: "xLabel", required: false), .init(name: "yLabel", required: false), .init(name: "variant", required: false)],
        "Bubbles": [.init(name: "messages", required: true)],
        "Button": [.init(name: "label", required: true), .init(name: "action", required: false), .init(name: "variant", required: false), .init(name: "type", required: false), .init(name: "size", required: false)],
        "Buttons": [.init(name: "buttons", required: true), .init(name: "direction", required: false)],
        "Card": [.init(name: "children", required: true)],
        "CardHeader": [.init(name: "title", required: true), .init(name: "subtitle", required: false)],
        "Chips": [.init(name: "labels", required: true)],
        "DatePicker": [.init(name: "name", required: true), .init(name: "mode", required: false), .init(name: "rules", required: false), .init(name: "value", required: false)],
        "Form": [.init(name: "name", required: true), .init(name: "buttons", required: true), .init(name: "fields", required: false)],
        "FormControl": [.init(name: "label", required: true), .init(name: "input", required: true), .init(name: "hint", required: false)],
        "HeroStat": [.init(name: "value", required: true), .init(name: "label", required: false), .init(name: "sublabel", required: false)],
        "HorizontalBarChart": [.init(name: "labels", required: true), .init(name: "series", required: true), .init(name: "xLabel", required: false), .init(name: "yLabel", required: false), .init(name: "variant", required: false)],
        "ImageBlock": [.init(name: "src", required: true), .init(name: "caption", required: false)],
        "Input": [.init(name: "name", required: true), .init(name: "placeholder", required: false), .init(name: "type", required: false), .init(name: "rules", required: false), .init(name: "value", required: false)],
        "KVList": [.init(name: "rows", required: true), .init(name: "header", required: false)],
        "LineChart": [.init(name: "labels", required: true), .init(name: "series", required: true), .init(name: "xLabel", required: false), .init(name: "yLabel", required: false), .init(name: "variant", required: false)],
        "ListBlock": [.init(name: "items", required: true), .init(name: "header", required: false)],
        "ListItem": [.init(name: "title", required: true), .init(name: "subtitle", required: false), .init(name: "leading", required: false), .init(name: "trailing", required: false), .init(name: "action", required: false)],
        "MapView": [.init(name: "placeName", required: true), .init(name: "zoom", required: false)],
        "PhotoGrid": [.init(name: "images", required: true)],
        "PieChart": [.init(name: "labels", required: true), .init(name: "values", required: true), .init(name: "variant", required: false), .init(name: "appearance", required: false)],
        "Select": [.init(name: "name", required: true), .init(name: "items", required: true), .init(name: "placeholder", required: false), .init(name: "rules", required: false), .init(name: "value", required: false), .init(name: "size", required: false)],
        "SelectItem": [.init(name: "value", required: true), .init(name: "label", required: true)],
        "Series": [.init(name: "category", required: true), .init(name: "values", required: true)],
        "Slider": [.init(name: "name", required: true), .init(name: "variant", required: true), .init(name: "min", required: true), .init(name: "max", required: true), .init(name: "step", required: false), .init(name: "defaultValue", required: false), .init(name: "label", required: false), .init(name: "rules", required: false), .init(name: "value", required: false)],
        "StatTiles": [.init(name: "items", required: true)],
        "TabItem": [.init(name: "label", required: true), .init(name: "children", required: true)],
        "Tabs": [.init(name: "items", required: true)],
        "TextArea": [.init(name: "name", required: true), .init(name: "placeholder", required: false), .init(name: "rows", required: false), .init(name: "rules", required: false), .init(name: "value", required: false)],
        "TextCallout": [.init(name: "variant", required: true), .init(name: "title", required: true), .init(name: "description", required: false)],
        "TextContent": [.init(name: "text", required: true), .init(name: "style", required: false)],
        "Toggle": [.init(name: "title", required: true), .init(name: "on", required: true), .init(name: "icon", required: false), .init(name: "subtitle", required: false)],
    ]
}
