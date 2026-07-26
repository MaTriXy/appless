package dev.appless.uicore

// GENERATED from spec/contract/genos.schema.json (componentCount: 33, root: "Card").
// Regenerate whenever the contract changes; `ContractSchemaTest` re-reads the JSON
// on disk and fails if this file drifts from it. Do not hand-edit the tables.

/**
 * The GenOS contract as declared by `spec/contract/genos.schema.json` — the
 * source of truth for what a design system must be able to render.
 *
 * Kotlin sibling of `ios/AppLess/Sources/AppLessCore/ContractSchema.swift`.
 */
public object ContractSchema {

    /** Root component the model always emits (`schema.root`). */
    public const val ROOT: String = "Card"

    /** `schema.componentCount` — every component the contract defines. */
    public const val COMPONENT_COUNT: Int = 33

    /** `schema.components`, verbatim (alphabetical, as exported). */
    public val allComponents: List<String> = listOf(
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
    )

    /**
     * Structural placeholders: declared in the contract but consumed by their
     * parents, so they render nothing in every design system.
     *
     * Source: `src/genos/ui/contract.tsx` L187-189 ("TabItem, SelectItem and
     * Series are structural placeholders ... not part of the renderer set"),
     * backed by their `component: () => null` definitions.
     */
    public val structuralPlaceholders: Set<String> = setOf("Series", "SelectItem", "TabItem")

    /**
     * `allComponents` minus [structuralPlaceholders] — the renderable
     * components a design system must implement.
     *
     * NOTE: 33 contract components minus 3 structural placeholders is 30. The
     * value is COMPUTED here and re-derived from the JSON in tests; it is never
     * typed by hand.
     */
    public val renderableComponents: List<String> =
        allComponents.filter { it !in structuralPlaceholders }

    /** One positional parameter of a component, in openui-lang call order. */
    public data class Param(val name: String, val required: Boolean)

    private fun P(name: String, required: Boolean) = Param(name, required)

    /**
     * `schema.paramOrder` — positional argument order per component. The JSON
     * Schema `properties` maps are sorted alphabetically for diff stability, so
     * this table (not the schema body) carries positional order.
     */
    public val paramOrder: Map<String, List<Param>> = linkedMapOf(
        "AreaChart" to listOf(P("labels", true), P("series", true), P("xLabel", false), P("yLabel", false), P("variant", false)),
        "BarChart" to listOf(P("labels", true), P("series", true), P("xLabel", false), P("yLabel", false), P("variant", false)),
        "Bubbles" to listOf(P("messages", true)),
        "Button" to listOf(P("label", true), P("action", false), P("variant", false), P("type", false), P("size", false)),
        "Buttons" to listOf(P("buttons", true), P("direction", false)),
        "Card" to listOf(P("children", true)),
        "CardHeader" to listOf(P("title", true), P("subtitle", false)),
        "Chips" to listOf(P("labels", true)),
        "DatePicker" to listOf(P("name", true), P("mode", false), P("rules", false), P("value", false)),
        "Form" to listOf(P("name", true), P("buttons", true), P("fields", false)),
        "FormControl" to listOf(P("label", true), P("input", true), P("hint", false)),
        "HeroStat" to listOf(P("value", true), P("label", false), P("sublabel", false)),
        "HorizontalBarChart" to listOf(P("labels", true), P("series", true), P("xLabel", false), P("yLabel", false), P("variant", false)),
        "ImageBlock" to listOf(P("src", true), P("caption", false)),
        "Input" to listOf(P("name", true), P("placeholder", false), P("type", false), P("rules", false), P("value", false)),
        "KVList" to listOf(P("rows", true), P("header", false)),
        "LineChart" to listOf(P("labels", true), P("series", true), P("xLabel", false), P("yLabel", false), P("variant", false)),
        "ListBlock" to listOf(P("items", true), P("header", false)),
        "ListItem" to listOf(P("title", true), P("subtitle", false), P("leading", false), P("trailing", false), P("action", false)),
        "MapView" to listOf(P("placeName", true), P("zoom", false)),
        "PhotoGrid" to listOf(P("images", true)),
        "PieChart" to listOf(P("labels", true), P("values", true), P("variant", false), P("appearance", false)),
        "Select" to listOf(P("name", true), P("items", true), P("placeholder", false), P("rules", false), P("value", false), P("size", false)),
        "SelectItem" to listOf(P("value", true), P("label", true)),
        "Series" to listOf(P("category", true), P("values", true)),
        "Slider" to listOf(P("name", true), P("variant", true), P("min", true), P("max", true), P("step", false), P("defaultValue", false), P("label", false), P("rules", false), P("value", false)),
        "StatTiles" to listOf(P("items", true)),
        "TabItem" to listOf(P("label", true), P("children", true)),
        "Tabs" to listOf(P("items", true)),
        "TextArea" to listOf(P("name", true), P("placeholder", false), P("rows", false), P("rules", false), P("value", false)),
        "TextCallout" to listOf(P("variant", true), P("title", true), P("description", false)),
        "TextContent" to listOf(P("text", true), P("style", false)),
        "Toggle" to listOf(P("title", true), P("on", true), P("icon", false), P("subtitle", false)),
    )
}
