package dev.appless.app

import dev.appless.app.render.material.MaterialRenderers
import dev.appless.uicore.Components
import dev.appless.uicore.ContractSchema
import dev.appless.uicore.RenderableComponent
import dev.appless.uicore.RendererRegistry
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The conformance gate: the Material design system must supply a renderer for
 * EVERY renderable contract component.
 *
 * This is a JVM unit test on purpose. Registration only stores composable
 * objects — no Android framework call happens — so the count that CI greps is
 * produced by the same `:app` sources the APK is built from, without an
 * emulator. `:app:assembleDebug` proves those composables COMPILE; this proves
 * they are all WIRED.
 */
class RendererConformanceTest {

    @Test
    fun `every contract component has a Material renderer`() {
        // A fresh registry, so a previously-registered shared one cannot make
        // this pass by accident.
        val registry = RendererRegistry(designSystem = "material")
        val report = MaterialRenderers.conformanceReport(registry)

        println(report.formatted())

        assertEquals(
            emptyList(),
            report.missing,
            "missing Material renderers: ${report.missing.joinToString(", ")}",
        )
        assertTrue(report.isComplete)
        assertEquals(30, report.declaredCount, "the contract declares 30 renderable components")
        assertEquals(30, report.registeredCount)

        // The literal string the CI workflow greps for.
        assertEquals("renderers registered: 30/30", report.gateLine)
    }

    @Test
    fun `the renderer table is keyed by the schema-derived component set`() {
        assertEquals(
            RenderableComponent.ALL.sorted(),
            MaterialRenderers.table.keys.sorted(),
            "the renderer table must cover exactly the schema's renderable set",
        )
        assertEquals(Components.all.sorted(), MaterialRenderers.table.keys.sorted())
    }

    @Test
    fun `structural placeholders are deliberately unrendered`() {
        // Series, SelectItem and TabItem are consumed by their parents
        // (`component: () => null` in ui/contract.tsx), so they must NOT appear
        // in the renderer set — and the count must still be 30, not 33.
        for (name in ContractSchema.structuralPlaceholders) {
            assertTrue(
                RenderableComponent.of(name) == null,
                "$name is a structural placeholder and must not be renderable",
            )
        }
        assertEquals(33, ContractSchema.COMPONENT_COUNT)
        assertEquals(30, MaterialRenderers.table.size)
    }

    @Test
    fun `registration is idempotent`() {
        val registry = RendererRegistry(designSystem = "material")
        MaterialRenderers.register(registry)
        MaterialRenderers.register(registry)
        assertEquals(30, registry.registeredCount)
    }

    @Test
    fun `every registration reports the Material design system`() {
        val registry = RendererRegistry(designSystem = "material")
        MaterialRenderers.register(registry)
        for (registration in registry.conformanceReport().registrations) {
            assertEquals("material", registration.designSystem)
            assertEquals("MaterialRenderers.kt", registration.sourceFile)
        }
    }
}
