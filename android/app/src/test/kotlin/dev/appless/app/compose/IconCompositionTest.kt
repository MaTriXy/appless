package dev.appless.app.compose

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import dev.appless.app.icons.LucideIcon
import dev.appless.app.icons.PhosphorIcon
import dev.appless.uicore.IconMap
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The icon bridge, EXECUTED.
 *
 * `MaterialSymbolsTest` proves the name -> `ImageVector` map is total over
 * `spec/icon-map.md`. It cannot prove the vectors compose: `Icons.Rounded.X` is
 * a lazily built `ImageVector`, and building one runs a path parser. A name
 * whose vector throws on first build would pass that test and draw nothing on a
 * phone.
 *
 * So this suite composes every icon in the spec and measures what came out.
 * The measurement is the assertion: a RESOLVED icon lays out at the requested
 * size, while an unknown name falls back to the placeholder dot, which
 * `spec/icon-map.md` §1 fixes at 8x8 (`IconMap.PLACEHOLDER_DOT_SIZE`). The two
 * are therefore distinguishable without a screenshot.
 */
@RunWith(RobolectricTestRunner::class)
class IconCompositionTest {

    @get:Rule
    val compose = createComposeRule()

    private companion object {
        /** Deliberately neither 8dp (the dot) nor the 17dp default. */
        val REQUESTED = 24.dp
        val TAG = "icon-under-test"
    }

    private var name by mutableStateOf("")
    private var phosphor by mutableStateOf(false)

    private fun start() {
        compose.setThemedContent {
            // The icon itself publishes no semantics (every renderer passes
            // `contentDescription = null`, matching the RN source), so it is
            // wrapped in a tagged box that takes its size.
            Box(Modifier.testTag(TAG)) {
                if (phosphor) {
                    PhosphorIcon(name = name, tint = Color.Black, size = REQUESTED)
                } else {
                    LucideIcon(name = name, tint = Color.Black, size = REQUESTED)
                }
            }
        }
    }

    private fun show(icon: String, isPhosphor: Boolean = false) {
        name = icon
        phosphor = isPhosphor
        compose.waitForIdle()
    }

    /**
     * All 88 Lucide names the spec maps compose to a real glyph at the
     * requested size — not to the 8dp fallback dot.
     */
    @Test
    fun every_lucide_name_in_the_spec_composes_to_a_real_glyph() {
        start()
        val fallbacks = mutableListOf<String>()
        val threw = mutableListOf<String>()
        for (lucide in IconMap.lucideToMaterial.keys) {
            try {
                show(lucide)
                compose.onNodeWithTag(TAG).assertWidthIsEqualTo(REQUESTED)
                compose.onNodeWithTag(TAG).assertHeightIsEqualTo(REQUESTED)
            } catch (e: AssertionError) {
                fallbacks += "$lucide (${IconMap.lucideToMaterial[lucide]})"
            } catch (t: Throwable) {
                threw += "$lucide: ${t::class.java.name}: ${t.message}"
            }
        }
        assertEquals("icons that threw while composing:\n${threw.joinToString("\n")}", 0, threw.size)
        assertEquals(
            "spec icons that fell back to the placeholder dot:\n${fallbacks.joinToString("\n")}",
            0,
            fallbacks.size,
        )
        assertEquals(88, IconMap.lucideToMaterial.size)
    }

    /** The home shell's Phosphor names, same treatment (`spec/icon-map.md` §5). */
    @Test
    fun every_phosphor_name_in_the_spec_composes_to_a_real_glyph() {
        start()
        val bad = mutableListOf<String>()
        for (phosphorName in IconMap.phosphorToMaterial.keys) {
            try {
                show(phosphorName, isPhosphor = true)
                compose.onNodeWithTag(TAG).assertWidthIsEqualTo(REQUESTED)
            } catch (t: Throwable) {
                bad += "$phosphorName: ${t.message}"
            }
        }
        assertEquals("Phosphor icons that did not compose:\n${bad.joinToString("\n")}", 0, bad.size)
    }

    /**
     * An unknown name draws the neutral placeholder dot at exactly 8x8
     * (`spec/icon-map.md` §1) — never an error, never a fallback glyph, never
     * text.
     *
     * This is the assertion that gives the two above their teeth: it proves the
     * size check really does distinguish "resolved" from "fell back".
     */
    @Test
    fun an_unknown_name_draws_the_eight_dp_placeholder_dot() {
        start()
        show("definitely-not-an-icon")
        val dot = IconMap.PLACEHOLDER_DOT_SIZE.toFloat().dp
        compose.onNodeWithTag(TAG).assertWidthIsEqualTo(dot)
        compose.onNodeWithTag(TAG).assertHeightIsEqualTo(dot)
    }

    /** An EMPTY name renders nothing at all — `if (name.isNullOrEmpty()) return`. */
    @Test
    fun an_empty_name_renders_nothing_not_even_the_dot() {
        start()
        show("")
        compose.onNodeWithTag(TAG).assertWidthIsEqualTo(0.dp)
    }

    /**
     * `kebabToPascal` normalization survives into the composition: four
     * spellings of the same icon all lay out as the resolved glyph.
     */
    @Test
    fun name_normalization_survives_into_the_composition() {
        start()
        for (spelling in listOf("credit-card", "credit_card", "Credit-Card", " credit card ")) {
            show(spelling)
            compose.onNodeWithTag(TAG).assertWidthIsEqualTo(REQUESTED)
        }
    }
}
