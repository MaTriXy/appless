package dev.appless.app.compose

import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropObject
import dev.appless.openuilang.PropValue
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The renderers whose whole output is GEOMETRY.
 *
 * `PhotoGrid` and `ImageBlock` draw nothing but images, and Robolectric never
 * completes a network image load — so the semantics tree is empty for both and
 * every text-based assertion is blind to them. What IS observable off-device is
 * the layout the flex rules produce, and that is where the port could actually
 * be wrong (`flexBasis: "31%"` + `flexGrow: 1` -> `FlowRow(maxItemsInEachRow =
 * 3)`; `flexBasis: "45%"` -> 2; `aspectRatio: 16/9` on the hero).
 *
 * Uses [NodeHost] so several payloads can be measured against each other inside
 * one composition — a ratio is a far stronger assertion than any single
 * absolute height.
 */
@RunWith(RobolectricTestRunner::class)
class RendererLayoutTest {

    @get:Rule
    val compose = createComposeRule()

    private val host by lazy { NodeHost(compose) }

    private fun rootHeight(): Dp = compose.onRoot().getUnclippedBoundsInRoot().height

    private fun photoGrid(count: Int, withSrc: Int = count): ElementNode {
        val entries = (1..count).map { i ->
            if (i <= withSrc) {
                PropValue.Obj(
                    PropObject(listOf("src" to PropValue.Str("/api/img?q=a&seed=$i&w=200&h=200"))),
                )
            } else {
                // `.filter((im) => im?.src)` — components.tsx L484.
                PropValue.Obj(PropObject(listOf("alt" to PropValue.Str("no src"))))
            }
        }
        return ElementNode("PhotoGrid", props = mapOf("images" to PropValue.Arr(entries)))
    }

    /**
     * Three images occupy ONE row of square cells; six occupy TWO.
     *
     * So the six-image grid is roughly twice as tall. A port that dropped
     * `maxItemsInEachRow = 3` (letting `FlowRow` fit as many as the width
     * allows) would make both grids one row tall and the ratio would collapse
     * to 1.
     */
    @Test
    fun photoGrid_lays_out_three_cells_per_row() {
        host.show(photoGrid(3))
        val oneRow = rootHeight()
        host.show(photoGrid(6))
        val twoRows = rootHeight()

        assertTrue("a three-image grid must have a height: $oneRow", oneRow > 0.dp)
        assertTrue(
            "six images must wrap to a second row: one row = $oneRow, six = $twoRows",
            twoRows > oneRow * 1.8f && twoRows < oneRow * 2.2f,
        )
    }

    /**
     * Entries with no `src` are DROPPED, not laid out as blank cells.
     *
     * Four entries of which three have a src therefore occupy exactly the same
     * height as three entries — one row. If the filter were missing, the fourth
     * would wrap onto a second row and double the height.
     */
    @Test
    fun photoGrid_entries_without_a_src_take_up_no_space() {
        host.show(photoGrid(3))
        val threeReal = rootHeight()
        host.show(photoGrid(4, withSrc = 3))
        val threeRealOneEmpty = rootHeight()

        assertTrue(
            "an entry with no src must not occupy a cell: $threeReal vs $threeRealOneEmpty",
            threeRealOneEmpty == threeReal,
        )
    }

    /**
     * `StatTiles` is two per row (`flexBasis: "45%"`, `components.tsx` L388-441),
     * so four tiles are twice as tall as two.
     */
    @Test
    fun statTiles_lay_out_two_per_row() {
        fun tiles(count: Int) = ElementNode(
            "StatTiles",
            props = mapOf(
                "items" to PropValue.Arr(
                    (1..count).map {
                        PropValue.Obj(
                            PropObject(
                                listOf(
                                    "label" to PropValue.Str("L$it"),
                                    "value" to PropValue.Str("$it"),
                                ),
                            ),
                        )
                    },
                ),
            ),
        )

        host.show(tiles(2))
        val oneRow = rootHeight()
        host.show(tiles(4))
        val twoRows = rootHeight()

        assertTrue("two tiles must fit one row: $oneRow", oneRow > 0.dp)
        assertTrue(
            "four tiles must wrap to two rows: $oneRow vs $twoRows",
            twoRows > oneRow * 1.8f && twoRows < oneRow * 2.3f,
        )
    }

    /**
     * `ImageBlock` is a 16:9 hero (`components.tsx` L444-478), so its height is
     * fixed by the width whether or not the photo ever loads.
     */
    @Test
    fun imageBlock_holds_a_sixteen_by_nine_box_even_with_no_loaded_image() {
        host.show(
            ElementNode(
                "ImageBlock",
                props = mapOf("src" to PropValue.Str("/api/img?q=a&seed=1&w=800&h=440")),
            ),
        )
        val bounds = compose.onRoot().getUnclippedBoundsInRoot()
        val ratio = bounds.width.value / bounds.height.value
        assertTrue("expected ~16:9, got ${bounds.width} x ${bounds.height}", ratio in 1.7f..1.8f)
    }
}
