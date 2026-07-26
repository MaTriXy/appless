package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.icons.LucideIcon
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.LocalTriggerAction
import dev.appless.app.render.RenderNode
import dev.appless.app.render.childrenSlot
import dev.appless.app.render.field
import dev.appless.app.render.get
import dev.appless.app.render.reactText
import dev.appless.app.render.stringOrNull
import dev.appless.app.render.truthyItems
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.GenosActions
import dev.appless.uicore.MaterialMetrics

/**
 * Chips + tabs — `src/genos/ui/material/components.tsx` L555-663.
 */

/**
 * `Chips` — `components.tsx` L556-604: M3 filter chips.
 *
 * Chips are NOT actions. Selecting one regenerates the whole screen through
 * the filter message `ui-core` owns ([GenosActions.chipsMessage]) — and
 * re-tapping the already-selected chip does nothing at all (`if (selected)
 * return`, L568), so a filter is never re-requested.
 */
internal object ChipsRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val trigger = LocalTriggerAction.current
        var active by remember { mutableIntStateOf(0) }
        val labels = node["labels"].truthyItems()

        Row(
            modifier = Modifier
                .bleedHorizontal(16.dp)
                .horizontalScroll(rememberScrollState())
                .padding(vertical = 2.dp, horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.CHIP_ROW_GAP.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            labels.forEachIndexed { index, labelValue ->
                val selected = index == active
                val label = labelValue.reactText()
                Row(
                    modifier = Modifier
                        .height(MaterialMetrics.CHIP_HEIGHT.dp)
                        .clip(RoundedCornerShape(MaterialMetrics.CHIP_RADIUS.dp))
                        .background(
                            if (selected) t.secondaryContainer.toColor() else Color.Transparent,
                        )
                        .then(
                            // Selected chips shed the outline — L586-587.
                            if (selected) {
                                Modifier
                            } else {
                                Modifier.border(
                                    MaterialMetrics.CHIP_BORDER_WIDTH_UNSELECTED.dp,
                                    t.outline.toColor(),
                                    RoundedCornerShape(MaterialMetrics.CHIP_RADIUS.dp),
                                )
                            }
                        )
                        .clickable {
                            if (selected) return@clickable
                            active = index
                            // Neither a form name nor an action plan: the label
                            // itself becomes the request (`triggerAction(msg,
                            // undefined, undefined)`, L571-575).
                            trigger(GenosActions.chipsMessage(label), null, null)
                        }
                        .padding(
                            horizontal = if (selected) {
                                MaterialMetrics.CHIP_PADDING_HORIZONTAL_SELECTED.dp
                            } else {
                                MaterialMetrics.CHIP_PADDING_HORIZONTAL_UNSELECTED.dp
                            },
                        ),
                    horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.CHIP_ICON_GAP.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (selected) {
                        LucideIcon(
                            name = "check",
                            tint = t.onSecondaryContainer.toColor(),
                            size = 15.dp,
                        )
                    }
                    Text(
                        text = label,
                        color = if (selected) {
                            t.onSecondaryContainer.toColor()
                        } else {
                            t.onSurfaceVariant.toColor()
                        },
                        fontSize = MaterialMetrics.CHIP_FONT_SIZE.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }
    }
}

/**
 * `Tabs` — `components.tsx` L606-663.
 *
 * Switching tabs is purely local — nothing is dispatched. The visible tab is
 * `items[min(active, max(items.length - 1, 0))]`, so a screen that re-parses
 * with FEWER tabs mid-stream clamps onto the last one instead of blanking.
 */
internal object TabsRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        var active by remember { mutableIntStateOf(0) }
        val items = node["items"].truthyItems()
        val current = items.getOrNull(
            minOf(active, maxOf(items.size - 1, 0)),
        )

        Column {
            Row(
                Modifier
                    .fillMaxWidth()
                    .drawBottomHairline(t.outlineVariant.toColor()),
            ) {
                items.forEachIndexed { index, item ->
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .clickable { active = index }
                            .padding(
                                top = MaterialMetrics.TAB_PADDING_TOP.dp,
                                start = 4.dp,
                                end = 4.dp,
                            ),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(
                            // `it.props?.label ?? \`Tab ${i + 1}\`` — L645.
                            text = item.field("label").stringOrNull() ?: "Tab ${index + 1}",
                            color = if (index == active) {
                                t.primary.toColor()
                            } else {
                                t.onSurfaceVariant.toColor()
                            },
                            fontSize = MaterialMetrics.TAB_FONT_SIZE.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Box(
                            Modifier
                                .padding(
                                    top = MaterialMetrics.TAB_INDICATOR_MARGIN_TOP.dp,
                                    start = MaterialMetrics.TAB_INDICATOR_MARGIN_HORIZONTAL.dp,
                                    end = MaterialMetrics.TAB_INDICATOR_MARGIN_HORIZONTAL.dp,
                                )
                                .fillMaxWidth()
                                .height(MaterialMetrics.TAB_INDICATOR_HEIGHT.dp)
                                .background(
                                    color = if (index == active) {
                                        t.primary.toColor()
                                    } else {
                                        Color.Transparent
                                    },
                                    shape = RoundedCornerShape(
                                        topStart = 3.dp,
                                        topEnd = 3.dp,
                                    ),
                                ),
                        )
                    }
                }
            }
            Column(
                modifier = Modifier.padding(top = MaterialMetrics.TAB_CONTENT_MARGIN_TOP.dp),
                verticalArrangement = Arrangement.spacedBy(MaterialMetrics.TAB_CONTENT_GAP.dp),
            ) {
                if (current != null) RenderNode(current.childrenSlot())
            }
        }
    }
}
