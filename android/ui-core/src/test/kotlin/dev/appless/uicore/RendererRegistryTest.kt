package dev.appless.uicore

import dev.appless.openuilang.JsonValue
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The conformance harness's own conformance: the renderable set must be exactly
 * what `spec/contract/genos.schema.json` declares, minus the three structural
 * placeholders — re-derived from the JSON on disk, never from the Kotlin
 * tables it is being compared to.
 */
class RendererRegistryTest {

    private val schema: JsonValue by lazy { JsonValue.parse(RepoSources.schemaJson) }

    private val schemaComponents: List<String>
        get() = schema["components"]!!.arrayValue!!.map { it.stringValue!! }

    // ------------------------------------------------ schema table conformance

    @Test
    fun `ContractSchema mirrors the schema JSON exactly`() {
        assertEquals(schema["root"]!!.stringValue, ContractSchema.ROOT)
        assertEquals(
            schema["componentCount"]!!.numberValue!!.toInt(),
            ContractSchema.COMPONENT_COUNT,
        )
        assertEquals(schemaComponents, ContractSchema.allComponents)
        assertEquals(
            ContractSchema.COMPONENT_COUNT,
            ContractSchema.allComponents.size,
            "componentCount must agree with the components array",
        )
    }

    @Test
    fun `paramOrder mirrors the schema JSON exactly`() {
        val jsonParamOrder = schema["paramOrder"]!!.objectValue!!
        assertEquals(jsonParamOrder.keys.sorted(), ContractSchema.paramOrder.keys.sorted())
        for ((component, params) in jsonParamOrder) {
            val expected = params.arrayValue!!.map { p ->
                ContractSchema.Param(p["name"]!!.stringValue!!, p["required"]!!.boolValue!!)
            }
            assertEquals(expected, ContractSchema.paramOrder[component], "paramOrder[$component]")
        }
    }

    @Test
    fun `structural placeholders are declared by the contract but never rendered`() {
        // The three placeholders must genuinely be contract components…
        for (placeholder in ContractSchema.structuralPlaceholders) {
            assertTrue(
                placeholder in schemaComponents,
                "$placeholder is claimed as a placeholder but is not in the schema",
            )
        }
        // …and `src/genos/ui/contract.tsx` must still say so.
        val contractTsx = RepoSources.text("src/genos/ui/contract.tsx")
        // The sentence wraps across two comment lines in the RN source.
        assertTrue(
            contractTsx.contains("TabItem, SelectItem and Series are"),
            "contract.tsx no longer names the three structural placeholders",
        )
        assertTrue(
            contractTsx.contains("structural placeholders (consumed by their parents) and render nothing"),
            "contract.tsx no longer documents that the placeholders render nothing",
        )
    }

    // --------------------------------------------------------- the renderable set

    @Test
    fun `the registry's renderable set equals the schema minus the three placeholders`() {
        val expected = schemaComponents.filter {
            it !in setOf("Series", "SelectItem", "TabItem")
        }
        assertEquals(expected, RenderableComponent.ALL.map { it.name })
        assertEquals(expected, ContractSchema.renderableComponents)
    }

    @Test
    fun `there are 30 renderable components, derived not typed`() {
        val derived = schemaComponents.size - ContractSchema.structuralPlaceholders.size
        assertEquals(30, derived, "33 schema components minus 3 placeholders")
        assertEquals(derived, RenderableComponent.REQUIRED_COUNT)
        assertEquals(derived, RenderableComponent.ALL.size)
    }

    @Test
    fun `the named Components handles cover the derived set exactly`() {
        assertEquals(
            RenderableComponent.ALL.sorted(),
            Components.all.sorted(),
            "Components handles drifted from the schema-derived set",
        )
        assertEquals(Components.all.size, Components.all.toSet().size, "duplicate handle")
    }

    @Test
    fun `placeholders are not resolvable as renderable components`() {
        for (placeholder in ContractSchema.structuralPlaceholders) {
            assertNull(RenderableComponent.of(placeholder), placeholder)
        }
        assertNull(RenderableComponent.of("NotAComponent"))
        assertNotNull(RenderableComponent.of("Card"))
    }

    @Test
    fun `every renderable component exposes its schema paramOrder`() {
        for (component in RenderableComponent.ALL) {
            val fromSchema = schema["paramOrder"]!![component.name]!!.arrayValue!!.map {
                it["name"]!!.stringValue!!
            }
            assertEquals(fromSchema, component.paramOrder.map { it.name }, component.name)
        }
    }

    // ------------------------------------------------------------- registration

    @Test
    fun `registration, override and reset behave like the Swift sibling`() {
        val registry = RendererRegistry(designSystem = "material")
        assertTrue(registry.register(Components.Card, renderer = "card-v1"))
        assertFalse(registry.register(Components.Card, renderer = "card-v2"))
        assertEquals("card-v2", registry.renderer(Components.Card), "last registration wins")
        assertTrue(registry.isRegistered(Components.Card))
        assertFalse(registry.isRegistered(Components.Button))
        assertEquals(1, registry.registeredCount)
        registry.reset()
        assertEquals(0, registry.registeredCount)
    }

    @Test
    fun `a fully wired registry reports complete`() {
        val registry = RendererRegistry(designSystem = "material")
        registry.registerAll(RenderableComponent.ALL.associateWith { "renderer:${it.name}" })
        val report = registry.conformanceReport()
        assertTrue(report.isComplete)
        assertTrue(report.missing.isEmpty())
        assertEquals(30, report.registeredCount)
        assertEquals("renderers registered: 30/30", report.gateLine)
        assertEquals(report.gateLine, report.declaredGateLine)
    }

    @Test
    fun `a partial registry names what is missing`() {
        val registry = RendererRegistry(designSystem = "material")
        registry.register(Components.Card, renderer = "card")
        registry.register(Components.Button, renderer = "button")
        val report = registry.conformanceReport()
        assertFalse(report.isComplete)
        assertEquals(28, report.missing.size)
        assertEquals("renderers registered: 2/30", report.gateLine)
        assertTrue(report.formatted().contains("missing (28):"))
        assertTrue(report.formatted().contains("contract components: 33 (3 structural placeholders excluded)"))
    }

    /**
     * The CI gate. The Compose renderer layer does not exist yet and cannot
     * register anything from a headless JVM module, so the gate asserts the
     * count the CONTRACT declares; the renderers task switches this over to the
     * live registry once Compose is wired up.
     */
    @Test
    fun `gate line prints the declared renderer count`() {
        val report = RendererRegistry.shared.conformanceReport()
        assertEquals(30, report.declaredCount)
        assertEquals("renderers registered: 30/30", report.declaredGateLine)
        println(report.declaredGateLine)
        println("design system: ${report.designSystem}")
        println(
            "contract components: ${ContractSchema.COMPONENT_COUNT} " +
                "(${ContractSchema.structuralPlaceholders.size} structural placeholders excluded)"
        )
    }
}
