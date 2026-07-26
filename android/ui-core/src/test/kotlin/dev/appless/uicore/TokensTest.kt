package dev.appless.uicore

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pins the Material tokens against the React Native source they were ported
 * from — both the VALUES and the LINE CITATIONS in `Tokens.kt`, so a token that
 * moves in `theme.ts` fails here instead of silently drifting.
 */
class TokensTest {

    /** `role: "#literal",` — one entry of an `MD_LIGHT` / `MD_DARK` object literal. */
    private val colorEntry = Regex("""^\s*(\w+):\s*"([^"]+)",\s*$""")

    /** Every color role in one RN theme block, with the 1-based line it sits on. */
    private fun rnRoles(constName: String): Map<String, Pair<String, Int>> {
        val lines = RepoSources.materialThemeTs
        val start = lines.indexOfFirst { it.startsWith("export const $constName") }
        check(start >= 0) { "$constName not found in material/theme.ts" }
        val out = LinkedHashMap<String, Pair<String, Int>>()
        var i = start + 1
        while (i < lines.size && !lines[i].startsWith("};")) {
            colorEntry.find(lines[i])?.let { m ->
                out[m.groupValues[1]] = m.groupValues[2] to (i + 1)
            }
            i++
        }
        return out
    }

    /** `chartPalette: [...]` from one RN theme block, with its 1-based line. */
    private fun rnChartPalette(constName: String): Pair<List<String>, Int> {
        val lines = RepoSources.materialThemeTs
        val start = lines.indexOfFirst { it.startsWith("export const $constName") }
        for (i in start until lines.size) {
            if (lines[i].startsWith("};")) break
            val m = Regex("""^\s*chartPalette:\s*\[(.*)],\s*$""").find(lines[i]) ?: continue
            val entries = Regex(""""([^"]+)"""").findAll(m.groupValues[1]).map { it.groupValues[1] }.toList()
            return entries to (i + 1)
        }
        error("chartPalette not found in $constName")
    }

    // ------------------------------------------------------------ value parity

    @Test
    fun `MD_LIGHT matches every literal in material theme ts`() {
        val rn = rnRoles("MD_LIGHT")
        assertEquals(23, rn.size, "expected 23 color roles in MD_LIGHT")
        for ((role, color) in Tokens.MD_LIGHT.roles) {
            assertEquals(rn[role]?.first, color.raw, "MD_LIGHT.$role")
        }
        assertEquals(rn.keys.toList(), Tokens.MD_LIGHT.roles.keys.toList(), "role order")
        assertFalse(Tokens.MD_LIGHT.dark)
    }

    @Test
    fun `MD_DARK matches every literal in material theme ts`() {
        val rn = rnRoles("MD_DARK")
        assertEquals(23, rn.size, "expected 23 color roles in MD_DARK")
        for ((role, color) in Tokens.MD_DARK.roles) {
            assertEquals(rn[role]?.first, color.raw, "MD_DARK.$role")
        }
        assertTrue(Tokens.MD_DARK.dark)
    }

    @Test
    fun `chart palettes match material theme ts`() {
        val (light, _) = rnChartPalette("MD_LIGHT")
        val (dark, _) = rnChartPalette("MD_DARK")
        assertEquals(light, Tokens.MD_LIGHT.chartPalette.map { it.raw })
        assertEquals(dark, Tokens.MD_DARK.chartPalette.map { it.raw })
        assertEquals(6, light.size)
        assertEquals(6, dark.size)
    }

    /**
     * A handful of tokens spelled out by hand, with their RN line, so the pin is
     * legible in a diff even if the parser above ever went wrong. Well above the
     * ten the scaffold requires.
     */
    @Test
    fun `sampled tokens equal the exact RN literal at the exact RN line`() {
        val samples: List<Triple<String, MdColor, Int>> = listOf(
            Triple("MD_LIGHT.surface", Tokens.MD_LIGHT.surface, 43),
            Triple("MD_LIGHT.surfaceContainerHigh", Tokens.MD_LIGHT.surfaceContainerHigh, 46),
            Triple("MD_LIGHT.onSurface", Tokens.MD_LIGHT.onSurface, 47),
            Triple("MD_LIGHT.outlineVariant", Tokens.MD_LIGHT.outlineVariant, 50),
            Triple("MD_LIGHT.primary", Tokens.MD_LIGHT.primary, 51),
            Triple("MD_LIGHT.onPrimaryContainer", Tokens.MD_LIGHT.onPrimaryContainer, 54),
            Triple("MD_LIGHT.error", Tokens.MD_LIGHT.error, 57),
            Triple("MD_LIGHT.success", Tokens.MD_LIGHT.success, 61),
            Triple("MD_LIGHT.onWarningContainer", Tokens.MD_LIGHT.onWarningContainer, 64),
            Triple("MD_LIGHT.ripple", Tokens.MD_LIGHT.ripple, 65),
            Triple("MD_DARK.surface", Tokens.MD_DARK.surface, 71),
            Triple("MD_DARK.onSurface", Tokens.MD_DARK.onSurface, 75),
            Triple("MD_DARK.outline", Tokens.MD_DARK.outline, 77),
            Triple("MD_DARK.primary", Tokens.MD_DARK.primary, 79),
            Triple("MD_DARK.onPrimary", Tokens.MD_DARK.onPrimary, 80),
            Triple("MD_DARK.secondaryContainer", Tokens.MD_DARK.secondaryContainer, 83),
            Triple("MD_DARK.errorContainer", Tokens.MD_DARK.errorContainer, 87),
            Triple("MD_DARK.successContainer", Tokens.MD_DARK.successContainer, 90),
            Triple("MD_DARK.warningContainer", Tokens.MD_DARK.warningContainer, 91),
            Triple("MD_DARK.ripple", Tokens.MD_DARK.ripple, 93),
        )
        assertTrue(samples.size >= 10)
        for ((label, color, line) in samples) {
            val rnLine = RepoSources.line("src/genos/ui/material/theme.ts", line)
            assertTrue(
                rnLine.contains("\"${color.raw}\""),
                "$label: theme.ts L$line is `${rnLine.trim()}`, expected it to carry \"${color.raw}\"",
            )
        }
    }

    /**
     * Every `// theme.ts LNN` citation inside `Tokens.kt` must point at the RN
     * line that actually declares that role — the citations are load-bearing
     * documentation, so they are tested like code.
     */
    @Test
    fun `every theme ts citation in Tokens kt points at the right line`() {
        val tokensKt = RepoSources.file("android/ui-core/src/main/kotlin/dev/appless/uicore/Tokens.kt")
            .readText(Charsets.UTF_8)
            .split("\n")
        val cite = Regex("""^\s*(\w+) = MdColor\("([^"]+)"\),\s*// theme\.ts L(\d+)$""")
        var checked = 0
        for (line in tokensKt) {
            val m = cite.find(line) ?: continue
            val (role, literal, cited) = m.destructured
            val rnLine = RepoSources.line("src/genos/ui/material/theme.ts", cited.toInt()).trim()
            assertEquals(
                "$role: \"$literal\",",
                rnLine,
                "citation `theme.ts L$cited` for $role does not match the RN source",
            )
            checked++
        }
        assertEquals(46, checked, "expected 23 cited roles x 2 themes")
    }

    @Test
    fun `every theme android ts citation in Tokens kt points at the right line`() {
        val tokensKt = RepoSources.file("android/ui-core/src/main/kotlin/dev/appless/uicore/Tokens.kt")
            .readText(Charsets.UTF_8)
            .split("\n")
        val cite = Regex("""^\s*(\w+) = (m\.\w+|dark),\s*// theme\.android\.ts L(\d+)$""")
        var checked = 0
        for (line in tokensKt) {
            val m = cite.find(line) ?: continue
            val (shellRole, expression, cited) = m.destructured
            val rnLine = RepoSources.line("src/genos/theme.android.ts", cited.toInt()).trim()
            // `dark` is written with ES shorthand in the RN source (`dark,`).
            val expected = if (shellRole == expression) "$shellRole," else "$shellRole: $expression,"
            assertEquals(expected, rnLine, "theme.android.ts L$cited")
            checked++
        }
        assertEquals(16, checked, "expected all 16 shell roles cited")
    }

    // ------------------------------------------------------------- projections

    @Test
    fun `the shell theme is the Material projection theme android ts declares`() {
        val light = ShellTheme.LIGHT
        assertEquals(Tokens.MD_LIGHT.surface, light.bg)
        assertEquals(Tokens.MD_LIGHT.surfaceContainer, light.group)
        assertEquals(Tokens.MD_LIGHT.surfaceContainerHigh, light.fill)
        assertEquals(Tokens.MD_LIGHT.surfaceContainerHigh, light.bubble)
        assertEquals(Tokens.MD_LIGHT.primary, light.tint)
        assertEquals(Tokens.MD_LIGHT.success, light.green)
        assertEquals(Tokens.MD_LIGHT.error, light.red)
        assertEquals(Tokens.MD_LIGHT.secondaryContainer, light.chromeBg)
        assertEquals(Tokens.MD_LIGHT.onSecondaryContainer, light.chromeInk)
        assertEquals(Tokens.MD_LIGHT.outlineVariant, light.chromeBorder)
        assertFalse(light.dark)
        assertTrue(ShellTheme.DARK.dark)
        assertEquals(Tokens.MD_DARK.surface, ShellTheme.DARK.bg)
    }

    @Test
    fun `the chart theme adapter reads the three roles shared charts wants`() {
        val chart = Tokens.chartTheme(dark = false)
        assertEquals(Tokens.MD_LIGHT.outlineVariant, chart.sep)
        assertEquals(Tokens.MD_LIGHT.onSurfaceVariant, chart.ink2)
        assertEquals(Tokens.MD_LIGHT.chartPalette, chart.chartPalette)
        assertEquals(Tokens.MD_DARK, Tokens.theme(dark = true))
    }

    // --------------------------------------------------------------- decoding

    @Test
    fun `every token literal decodes`() {
        val all = Tokens.MD_LIGHT.roles.values + Tokens.MD_DARK.roles.values +
            Tokens.MD_LIGHT.chartPalette + Tokens.MD_DARK.chartPalette
        for (color in all) {
            assertTrue(color.isParsed, "could not decode ${color.raw}")
        }
    }

    @Test
    fun `hex and rgba literals decode to the same channel model`() {
        assertEquals(Triple(0x4F, 0x51, 0xC0), Tokens.MD_LIGHT.primary.bytes)
        assertEquals("#4f51c0ff", Tokens.MD_LIGHT.primary.hex8)
        // `rgba(27,27,33,0.12)` — theme.ts L65.
        val ripple = Tokens.MD_LIGHT.ripple
        assertEquals(Triple(27, 27, 33), ripple.bytes)
        assertEquals(0.12, ripple.alpha, 1e-12)
        assertEquals("#1b1b211f", ripple.hex8)
        assertEquals(0x1F1B1B21.toInt(), ripple.argb)
        assertFalse(MdColor("not-a-color").isParsed)
    }

    // -------------------------------------------------- renderer metric parity

    @Test
    fun `text styles match the TEXT_STYLES table in material components tsx`() {
        assertEquals(
            listOf("small", "default", "large", "small-heavy", "heading"),
            MaterialMetrics.textStyles.keys.toList(),
        )
        assertEquals(12.5, MaterialMetrics.textStyles.getValue("small").fontSize)
        assertEquals(22.0, MaterialMetrics.textStyles.getValue("default").lineHeight)
        assertEquals("500", MaterialMetrics.textStyles.getValue("heading").fontWeight)
        assertEquals(-6.0, MaterialMetrics.textStyles.getValue("heading").marginBottom)
        // `TEXT_STYLES[key] ?? TEXT_STYLES.default` — components.tsx L97-98.
        assertEquals(MaterialMetrics.textStyles.getValue("default"), MaterialMetrics.textStyle(null))
        assertEquals(MaterialMetrics.textStyles.getValue("default"), MaterialMetrics.textStyle("bogus"))
        assertEquals(MaterialMetrics.textStyles.getValue("large"), MaterialMetrics.textStyle("large"))
    }

    @Test
    fun `metric literals are the ones inlined in the RN renderers`() {
        val components = RepoSources.text("src/genos/ui/material/components.tsx")
        val forms = RepoSources.text("src/genos/ui/material/forms.tsx")
        // HeroStat uses the M3 display-large scale.
        assertEquals(57.0, MaterialMetrics.HERO_VALUE_FONT_SIZE)
        assertEquals(64.0, MaterialMetrics.HERO_VALUE_LINE_HEIGHT)
        assertTrue(components.contains("fontSize: 57"))
        assertTrue(components.contains("lineHeight: 64"))
        // CardHeader title.
        assertTrue(components.contains("fontSize: 28"))
        // Outlined text fields.
        assertEquals(4.0, MaterialMetrics.FIELD_RADIUS)
        assertEquals(16.0, MaterialMetrics.FIELD_FONT_SIZE)
        assertTrue(forms.contains("borderRadius: 4"))
        assertTrue(forms.contains("borderWidth: focused ? 2 : 1"))
        assertTrue(forms.contains("paddingVertical: focused ? 13 : 14"))
        assertTrue(forms.contains("paddingHorizontal: focused ? 15 : 16"))
        // Full-height pill buttons.
        assertEquals(20.0, MaterialMetrics.BUTTON_RADIUS)
        assertTrue(forms.contains("borderRadius: 20"))
        assertTrue(forms.contains("minHeight: compact ? 32 : 40"))
    }

    @Test
    fun `select sizes and TextArea height match forms tsx`() {
        assertEquals(MaterialMetrics.SelectSize(10.0, 14.0), MaterialMetrics.selectSize("small"))
        assertEquals(MaterialMetrics.SelectSize(14.0, 16.0), MaterialMetrics.selectSize("medium"))
        assertEquals(MaterialMetrics.SelectSize(18.0, 18.0), MaterialMetrics.selectSize("large"))
        // `SELECT_SIZES[props.size ?? "medium"] ?? SELECT_SIZES.medium` — forms.tsx L114.
        assertEquals(MaterialMetrics.selectSize("medium"), MaterialMetrics.selectSize(null))
        assertEquals(MaterialMetrics.selectSize("medium"), MaterialMetrics.selectSize("gigantic"))
        // `minHeight: 28 + rows * 20`, rows defaulting to 4 — forms.tsx L64, L67.
        assertEquals(108.0, MaterialMetrics.textAreaMinHeight(null))
        assertEquals(48.0, MaterialMetrics.textAreaMinHeight(1))
        assertEquals(228.0, MaterialMetrics.textAreaMinHeight(10))
    }

    @Test
    fun `compact buttons are exactly the two small sizes`() {
        assertTrue(MaterialMetrics.isCompactButton("extra-small"))
        assertTrue(MaterialMetrics.isCompactButton("small"))
        assertFalse(MaterialMetrics.isCompactButton("medium"))
        assertFalse(MaterialMetrics.isCompactButton(null))
    }

    @Test
    fun `callout icons are the CALLOUT_ICON table and all resolve`() {
        assertEquals(
            listOf("neutral", "info", "success", "warning", "danger"),
            MaterialMetrics.calloutIcons.keys.toList(),
        )
        for ((variant, icon) in MaterialMetrics.calloutIcons) {
            assertFalse(IconMap.resolve(icon).isFallback, "callout $variant -> $icon must resolve")
        }
        assertEquals("check_circle", IconMap.resolve(MaterialMetrics.calloutIcons.getValue("success")).symbolName)
    }
}
