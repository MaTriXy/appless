package dev.appless.app.render.material

import dev.appless.app.render.ComposeRenderer
import dev.appless.uicore.Components
import dev.appless.uicore.ConformanceReport
import dev.appless.uicore.RenderableComponent
import dev.appless.uicore.RendererRegistry

/**
 * The Material design system's renderer set — the thing `ui-core`'s conformance
 * gate counts.
 *
 * [table] is keyed by `ui-core`'s schema-DERIVED [Components] handles, not by
 * strings, so a component the contract drops fails to compile here rather than
 * quietly leaving `renderers registered: 29/30` for CI to notice.
 */
public object MaterialRenderers {

    /** Every contract component mapped to the composable that draws it. */
    public val table: Map<RenderableComponent, ComposeRenderer> = linkedMapOf(
        // Structure & text — material/components.tsx
        Components.Card to CardRenderer,
        Components.CardHeader to CardHeaderRenderer,
        Components.TextContent to TextContentRenderer,
        Components.TextCallout to TextCalloutRenderer,

        // Lists — material/components.tsx
        Components.ListBlock to ListBlockRenderer,
        Components.ListItem to ListItemRenderer,
        Components.Toggle to ToggleRenderer,
        Components.KVList to KVListRenderer,

        // Stats — material/components.tsx
        Components.HeroStat to HeroStatRenderer,
        Components.StatTiles to StatTilesRenderer,

        // Charts — shared/charts.tsx
        Components.BarChart to BarChartRenderer,
        Components.LineChart to LineChartRenderer,
        Components.AreaChart to AreaChartRenderer,
        Components.PieChart to PieChartRenderer,
        Components.HorizontalBarChart to HorizontalBarChartRenderer,

        // Media & social — material/components.tsx, shared/media.tsx
        Components.ImageBlock to ImageBlockRenderer,
        Components.PhotoGrid to PhotoGridRenderer,
        Components.Bubbles to BubblesRenderer,
        Components.Chips to ChipsRenderer,
        Components.Tabs to TabsRenderer,
        Components.MapView to MapViewRenderer,

        // Forms & buttons — material/forms.tsx
        Components.Form to FormRenderer,
        Components.FormControl to FormControlRenderer,
        Components.Input to InputRenderer,
        Components.TextArea to TextAreaRenderer,
        Components.Select to SelectRenderer,
        Components.DatePicker to DatePickerRenderer,
        Components.Slider to SliderRenderer,
        Components.Buttons to ButtonsRenderer,
        Components.Button to ButtonRenderer,
    )

    /**
     * Publish the set into the shared registry. Idempotent — the app calls it
     * from `Application.onCreate` and the conformance test calls it directly.
     */
    public fun register(registry: RendererRegistry = RendererRegistry.shared) {
        registry.registerAll(table, designSystem = "material", sourceFile = "MaterialRenderers.kt")
    }

    /** `renderers registered: N/30` and the missing list, for the CI gate. */
    public fun conformanceReport(registry: RendererRegistry = RendererRegistry.shared): ConformanceReport {
        register(registry)
        return registry.conformanceReport()
    }
}
