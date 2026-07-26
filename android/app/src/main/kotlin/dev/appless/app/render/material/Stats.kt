package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.icons.LucideIcon
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.field
import dev.appless.app.render.get
import dev.appless.app.render.isTruthy
import dev.appless.app.render.reactText
import dev.appless.app.render.stringOrNull
import dev.appless.app.render.truthyItems
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.genoscore.jsTrim
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.MaterialMetrics

/**
 * Stat renderers — `src/genos/ui/material/components.tsx` L349-441.
 */

/** `HeroStat` — `components.tsx` L350-386: M3 display-large centred stat. */
internal object HeroStatRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    top = MaterialMetrics.HERO_PADDING_TOP.dp,
                    bottom = MaterialMetrics.HERO_PADDING_BOTTOM.dp,
                ),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val label = node["label"]
            if (label.isTruthy()) {
                Text(
                    text = label.reactText(),
                    color = t.onSurfaceVariant.toColor(),
                    fontSize = MaterialMetrics.HERO_LABEL_FONT_SIZE.sp,
                    fontWeight = FontWeight.Medium,
                    letterSpacing = MaterialMetrics.HERO_LABEL_LETTER_SPACING.sp,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
            Text(
                text = node["value"].reactText(),
                color = t.onSurface.toColor(),
                fontSize = MaterialMetrics.HERO_VALUE_FONT_SIZE.sp,
                lineHeight = MaterialMetrics.HERO_VALUE_LINE_HEIGHT.sp,
                fontWeight = FontWeight.Normal,
                style = TabularNums,
            )
            val sublabel = node["sublabel"]
            if (sublabel.isTruthy()) {
                Text(
                    text = sublabel.reactText(),
                    color = t.onSurfaceVariant.toColor(),
                    fontSize = MaterialMetrics.HERO_SUBLABEL_FONT_SIZE.sp,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

/**
 * `StatTiles` — `components.tsx` L388-441.
 *
 * RN lays these out with `flexBasis: "45%"` + `flexGrow: 1` and a 10 gap, i.e.
 * two per row with a lone last tile stretching full width — which is exactly
 * `FlowRow(maxItemsInEachRow = 2)` with an equal weight per tile.
 */
internal object StatTilesRenderer : ComposeRenderer {
    @OptIn(ExperimentalLayoutApi::class)
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val items = node["items"].truthyItems()
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.TILE_GRID_GAP.dp),
            verticalArrangement = Arrangement.spacedBy(MaterialMetrics.TILE_GRID_GAP.dp),
            maxItemsInEachRow = 2,
        ) {
            for (item in items) {
                // `it.delta?.trim().startsWith(...)` — L396-400. A signed delta
                // colors itself; anything else stays in the secondary ink role.
                val delta = item.field("delta").stringOrNull()
                val trimmedDelta = delta?.let { jsTrim(it) }
                val deltaColor = when {
                    trimmedDelta?.startsWith("-") == true -> t.error.toColor()
                    trimmedDelta?.startsWith("+") == true -> t.success.toColor()
                    else -> t.onSurfaceVariant.toColor()
                }
                Column(
                    Modifier
                        .weight(1f)
                        .background(
                            t.surfaceContainer.toColor(),
                            RoundedCornerShape(MaterialMetrics.TILE_RADIUS.dp),
                        )
                        .padding(
                            vertical = MaterialMetrics.TILE_PADDING_VERTICAL.dp,
                            horizontal = MaterialMetrics.TILE_PADDING_HORIZONTAL.dp,
                        ),
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.TILE_ICON_GAP.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val icon = item.field("icon")
                        if (icon.isTruthy()) {
                            LucideIcon(
                                name = icon.reactText(),
                                tint = t.onSurfaceVariant.toColor(),
                                size = 14.dp,
                            )
                        }
                        Text(
                            text = item.field("label").reactText(),
                            color = t.onSurfaceVariant.toColor(),
                            fontSize = MaterialMetrics.TILE_LABEL_FONT_SIZE.sp,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                    Row(
                        modifier = Modifier.padding(top = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = item.field("value").reactText(),
                            color = t.onSurface.toColor(),
                            fontSize = MaterialMetrics.TILE_VALUE_FONT_SIZE.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            style = TabularNums,
                            modifier = Modifier.alignByBaseline(),
                        )
                        if (item.field("delta").isTruthy()) {
                            Text(
                                text = item.field("delta").reactText(),
                                color = deltaColor,
                                fontSize = MaterialMetrics.TILE_DELTA_FONT_SIZE.sp,
                                fontWeight = FontWeight.Medium,
                                modifier = Modifier.alignByBaseline(),
                            )
                        }
                    }
                }
            }
        }
    }
}
