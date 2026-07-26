package dev.appless.app

import dev.appless.app.icons.MaterialSymbols
import dev.appless.uicore.IconMap
import dev.appless.uicore.IconResolution
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The icon bridge must be TOTAL over `spec/icon-map.md`.
 *
 * `ui-core`'s [IconMap] resolves a Lucide/Phosphor name to a Material Symbols
 * NAME; if this module has no vector for that name the icon silently degrades
 * to the placeholder dot, which looks like a rendering bug and is invisible in
 * a screenshot diff. So every name the spec maps is asserted to have a vector.
 */
class MaterialSymbolsTest {

    @Test
    fun `every Lucide mapping resolves to a real vector`() {
        val missing = IconMap.lucideToMaterial.entries
            .filter { (_, symbol) -> MaterialSymbols.vectors[symbol] == null }
            .map { (lucide, symbol) -> "$lucide -> $symbol" }
        assertTrue(
            missing.isEmpty(),
            "Material Symbols names with no Compose vector: ${missing.joinToString(", ")}",
        )
        // §2 (73) + §3 (5) + §4 (10) = 88 distinct Lucide names.
        assertEquals(88, IconMap.lucideToMaterial.size)
    }

    @Test
    fun `every Phosphor mapping resolves to a real vector`() {
        val missing = IconMap.phosphorToMaterial.entries
            .filter { (_, symbol) -> MaterialSymbols.vectors[symbol] == null }
            .map { (phosphor, symbol) -> "$phosphor -> $symbol" }
        assertTrue(missing.isEmpty(), "unbridged Phosphor icons: ${missing.joinToString(", ")}")
    }

    @Test
    fun `the icons the renderers hard-code all resolve`() {
        // These are emitted by AppLess code, never by the model: the chevrons,
        // the chip check, the callout glyphs, the shell chrome.
        val chrome = listOf(
            "chevron-left", "chevron-right", "chevron-down", "house", "check",
            "info", "circle-check", "triangle-alert", "octagon-alert",
        )
        for (name in chrome) {
            val resolution = IconMap.resolve(name)
            assertTrue(resolution is IconResolution.Symbol, "$name did not resolve to a symbol")
            assertNotNull(MaterialSymbols.vector(resolution), "$name has no vector")
        }
    }

    @Test
    fun `every callout variant has a resolvable icon`() {
        for ((variant, lucide) in dev.appless.uicore.MaterialMetrics.calloutIcons) {
            val resolution = IconMap.resolve(lucide)
            assertNotNull(MaterialSymbols.vector(resolution), "callout $variant ($lucide)")
        }
    }

    @Test
    fun `an unknown name degrades to the placeholder dot, never an error`() {
        // spec/icon-map.md §1 and §3: native ports are not required to ship the
        // full Lucide catalogue.
        val resolution = IconMap.resolve("definitely-not-an-icon")
        assertEquals(IconResolution.PlaceholderDot, resolution)
        assertNull(MaterialSymbols.vector(resolution))
    }

    @Test
    fun `name normalization survives the bridge`() {
        val expected = MaterialSymbols.vectors["credit_card"]
        assertNotNull(expected)
        for (spelling in listOf("credit-card", "credit_card", "Credit-Card", " credit card ")) {
            assertEquals(
                expected,
                MaterialSymbols.vector(IconMap.resolve(spelling)),
                "spelling: $spelling",
            )
        }
    }

    @Test
    fun `the table has no unreachable entries`() {
        // Every vector must be reachable from one of the spec's tables —
        // otherwise it is dead weight in the APK's icon set.
        val reachable = IconMap.lucideToMaterial.values.toSet() +
            IconMap.phosphorToMaterial.values.toSet()
        val orphans = MaterialSymbols.vectors.keys - reachable
        assertTrue(orphans.isEmpty(), "vectors no spec table can reach: $orphans")
    }
}
