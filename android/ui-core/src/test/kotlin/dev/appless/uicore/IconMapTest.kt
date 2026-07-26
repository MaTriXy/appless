package dev.appless.uicore

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Re-parses `spec/icon-map.md` and fails if the Kotlin tables miss a row, add a
 * row, or disagree on a Material Symbol; plus the documented unknown-name
 * fallback and the byte-exact `iconTint` hash.
 */
class IconMapTest {

    // ------------------------------------------------------------ spec parsing

    /** All markdown table rows under the `## N.` section heading. */
    private fun rows(sectionPrefix: String): List<List<String>> {
        val out = mutableListOf<List<String>>()
        var inSection = false
        for (line in RepoSources.iconMapMarkdown.split("\n")) {
            if (line.startsWith("## ")) {
                inSection = line.startsWith("## $sectionPrefix")
                continue
            }
            if (!inSection || !line.startsWith("|")) continue
            if (Regex("""^\|[\s\-|]+\|$""").matches(line)) continue // separator row
            out += line.trim().trim('|').split("|").map { it.trim() }
        }
        return out
    }

    /** The first `` `backticked` `` token of a cell, with the spec's `⚠` marker stripped. */
    private fun cell(text: String): String? =
        Regex("""^⚠?\s*`([^`]+)`""").find(text.trim())?.groupValues?.get(1)

    /** `lucide -> material` pairs for one spec section. */
    private fun specTable(sectionPrefix: String, materialColumn: Int): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (cells in rows(sectionPrefix)) {
            if (cells.size <= materialColumn) continue
            val key = cell(cells[0]) ?: continue      // header rows have no backticks
            val value = cell(cells[materialColumn]) ?: continue
            out[key] = value
        }
        return out
    }

    private val specPrompt by lazy { specTable("2.", materialColumn = 2) }
    private val specTintExtras by lazy { specTable("3.", materialColumn = 2) }
    private val specChrome by lazy { specTable("4.", materialColumn = 3) }
    private val specPhosphor by lazy { specTable("5.", materialColumn = 3) }

    // ------------------------------------------------------------ table parity

    @Test
    fun `section 2 covers all 73 model-facing names`() {
        assertEquals(73, specPrompt.size, "spec §2 should list 73 names")
        assertEquals(specPrompt, IconMap.promptVocabulary)
    }

    @Test
    fun `section 3 covers the five ICON_TINT extras`() {
        assertEquals(5, specTintExtras.size)
        assertEquals(specTintExtras, IconMap.tintExtras)
    }

    @Test
    fun `section 4 covers the ten chrome icons`() {
        assertEquals(10, specChrome.size)
        assertEquals(specChrome, IconMap.chromeIcons)
    }

    @Test
    fun `section 5 covers the 23 Phosphor home-shell icons`() {
        assertEquals(23, specPhosphor.size)
        assertEquals(specPhosphor, IconMap.phosphorToMaterial)
    }

    @Test
    fun `the merged Lucide table is exactly 88 names`() {
        assertEquals(73 + 5 + 10, IconMap.lucideToMaterial.size)
        val union = LinkedHashMap<String, String>().apply {
            putAll(specPrompt)
            for ((k, v) in specTintExtras) putIfAbsent(k, v)
            for ((k, v) in specChrome) putIfAbsent(k, v)
        }
        assertEquals(union, IconMap.lucideToMaterial)
    }

    @Test
    fun `every Material row in the spec resolves through resolve()`() {
        for ((lucide, material) in specPrompt + specTintExtras + specChrome) {
            assertEquals(material, IconMap.resolve(lucide).symbolName, lucide)
        }
        for ((phosphor, material) in specPhosphor) {
            assertEquals(material, IconMap.resolvePhosphor(phosphor).symbolName, phosphor)
        }
    }

    @Test
    fun `the Material Symbols names look like Material Symbols names`() {
        val nameShape = Regex("""^[a-z0-9_]+$""")
        for ((lucide, material) in IconMap.lucideToMaterial) {
            assertTrue(nameShape.matches(material), "$lucide -> $material is not snake_case")
        }
        for ((phosphor, material) in IconMap.phosphorToMaterial) {
            assertTrue(nameShape.matches(material), "$phosphor -> $material is not snake_case")
        }
        assertTrue(nameShape.matches(IconMap.APPS_ICON_SYMBOL_SUGGESTION))
    }

    // ---------------------------------------------------------- normalization

    @Test
    fun `kebab, snake and space separated names all resolve alike`() {
        assertEquals("credit-card", IconMap.normalize("credit-card"))
        assertEquals("credit-card", IconMap.normalize("credit_card"))
        assertEquals("credit-card", IconMap.normalize(" Credit Card "))
        assertEquals("credit-card", IconMap.normalize("CREDIT__CARD"))
        assertEquals("credit-card", IconMap.normalize("credit - card"))
        for (spelling in listOf("credit-card", "credit_card", " Credit Card ", "CREDIT__CARD")) {
            assertEquals("credit_card", IconMap.resolve(spelling).symbolName, spelling)
        }
    }

    // -------------------------------------------------------------- fallback

    @Test
    fun `unknown names degrade to the placeholder dot, never crash`() {
        val unknown = listOf(
            "", "   ", "definitely-not-an-icon", "🙂", "rocket", "abacus",
            "chevron-up", "Series", "null", "undefined", "wifi2",
        )
        for (name in unknown) {
            val resolution = IconMap.resolve(name)
            assertTrue(resolution.isFallback, "\"$name\" should fall back")
            assertSame(IconResolution.PlaceholderDot, resolution)
            assertNull(resolution.symbolName)
        }
        // The Phosphor table is a different family: a Lucide name is unknown there.
        assertTrue(IconMap.resolvePhosphor("credit-card").isFallback)
        assertFalse(IconMap.resolvePhosphor("CreditCard").isFallback)
        // Phosphor lookup is case-SENSITIVE (PascalCase names, spec §5).
        assertTrue(IconMap.resolvePhosphor("creditcard").isFallback)
    }

    @Test
    fun `the placeholder dot geometry is the one the spec documents`() {
        // "an 8x8 view, `borderRadius 4`, background = the caller-passed tint
        //  color, `opacity 0.6`" — spec/icon-map.md §1.
        assertEquals(8.0, IconMap.PLACEHOLDER_DOT_SIZE)
        assertEquals(4.0, IconMap.PLACEHOLDER_DOT_RADIUS)
        assertEquals(0.6, IconMap.PLACEHOLDER_DOT_OPACITY)
        assertTrue(RepoSources.iconMapMarkdown.contains("`borderRadius 4`"))
        assertTrue(RepoSources.iconMapMarkdown.contains("`opacity 0.6`"))
    }

    // ------------------------------------------------------------ badge tints

    @Test
    fun `BADGE_COLORS match ui icons tsx in order`() {
        val icons = RepoSources.text("src/genos/ui/icons.tsx")
        val block = icons.substringAfter("const BADGE_COLORS = [").substringBefore("];")
        val rn = Regex(""""(#[0-9a-fA-F]{6})"""").findAll(block).map { it.groupValues[1] }.toList()
        assertEquals(9, rn.size)
        assertEquals(rn, IconMap.badgeColors.map { it.raw })
    }

    @Test
    fun `ICON_TINT matches ui icons tsx exactly`() {
        val icons = RepoSources.text("src/genos/ui/icons.tsx")
        val block = icons.substringAfter("const ICON_TINT: Record<string, string> = {").substringBefore("};")
        val rn = LinkedHashMap<String, String>()
        for (m in Regex("""^\s*"?([a-z0-9-]+)"?:\s*"(#[0-9a-fA-F]{6})",""", RegexOption.MULTILINE).findAll(block)) {
            rn[m.groupValues[1]] = m.groupValues[2]
        }
        assertEquals(32, rn.size)
        assertEquals(rn, IconMap.iconTintTable)
        // The spec restates the same table; keep both honest.
        for ((name, hex) in rn) {
            assertTrue(
                RepoSources.iconMapMarkdown.contains("$name `$hex`"),
                "spec/icon-map.md §1 is missing `$name $hex`",
            )
        }
    }

    @Test
    fun `hand-picked tints win over the hash`() {
        assertEquals("#0a84ff", IconMap.iconTint("wifi").raw)
        assertEquals("#ff2d55", IconMap.iconTint("heart-pulse").raw)
        assertEquals("#8e8e93", IconMap.iconTint("camera").raw)
        // `iconTint` lower-cases but does NOT kebab-normalize (ui/icons.tsx L66).
        assertEquals("#0a84ff", IconMap.iconTint("WiFi").raw)
        assertEquals("#34c759", IconMap.iconTint("Credit-Card").raw)
        assertFalse(IconMap.iconTint("credit_card").raw == "#34c759", "underscores are NOT normalized here")
    }

    /**
     * Expectations derived by running the RN `iconTint` hash under node:
     *
     * ```
     * node -e 'let h=0;const k=NAME.toLowerCase();
     *          for(let i=0;i<k.length;i++)h=(h*31+k.charCodeAt(i))|0;
     *          console.log(h, Math.abs(h)%9)'
     * ```
     */
    @Test
    fun `the iconTint hash matches the node-derived values byte for byte`() {
        val expected = listOf(
            // name, raw 32-bit signed hash, BADGE_COLORS index, hex
            Quad("", 0, 0, "#0a84ff"),
            Quad("a", 97, 7, "#ff2d55"),
            Quad("zebra", 115_776_262, 1, "#34c759"),
            Quad("Zebra", 115_776_262, 1, "#34c759"),
            Quad("unknown-icon", -1_365_782_500, 1, "#34c759"),
            Quad("rocket", -925_677_868, 4, "#ff3b30"),
            Quad("café", 3_045_921, 6, "#5e5ce6"),
            Quad("😀", 1_772_899, 7, "#ff2d55"),
            Quad("x".repeat(50), 237_795_072, 6, "#5e5ce6"),
            Quad("ThisIsALongIconName", 1_764_940_953, 3, "#af52de"),
            Quad("gauge", 98_128_121, 5, "#5ac8fa"),
            Quad("waves", 112_905_370, 1, "#34c759"),
            Quad("anchor", -1_413_299_531, 2, "#ff9f0a"),
            Quad("banana", -1_396_355_227, 7, "#ff2d55"),
            Quad("q", 113, 5, "#5ac8fa"),
        )
        for ((name, hash, index, hex) in expected) {
            assertEquals(hash, IconMap.tintHash(name), "hash of \"$name\"")
            assertEquals(hex, IconMap.badgeColors[index].raw, "BADGE_COLORS[$index]")
            assertEquals(hex, IconMap.iconTint(name).raw, "iconTint(\"$name\")")
        }
    }

    @Test
    fun `the hash wraps at 32 bits like JS bitwise or`() {
        // A long ASCII name overflows Int repeatedly; the value must stay in
        // Int range and the index must stay in 0..8 (Math.abs of Int.MIN_VALUE
        // is widened to 64 bits before the modulo, exactly like JS Math.abs).
        for (length in 1..200) {
            val name = "z".repeat(length)
            val index = Math.abs(IconMap.tintHash(name).toLong()) % IconMap.badgeColors.size
            assertTrue(index in 0..8)
            assertFalse(IconMap.iconTint(name).raw.isEmpty())
        }
        assertEquals(Int.MIN_VALUE, Int.MIN_VALUE) // documents the widening path below
        assertTrue(IconMap.badgeColors.all { it.isParsed })
    }

    private data class Quad(
        val name: String,
        val hash: Int,
        val index: Int,
        val hex: String,
    )
}
