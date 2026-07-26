package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.icons.LucideIcon
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.RenderNode
import dev.appless.app.render.actionPlan
import dev.appless.app.render.field
import dev.appless.app.render.get
import dev.appless.app.render.isTruthy
import dev.appless.app.render.reactText
import dev.appless.app.render.stringOrNull
import dev.appless.app.render.truthyItems
import dev.appless.app.render.useTap
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.MaterialMetrics

/**
 * List renderers — `src/genos/ui/material/components.tsx` L157-347.
 */

/** `GroupHeader` — `components.tsx` L258-271: the primary-tinted block header. */
@Composable
private fun GroupHeader(text: String) {
    val t = LocalMdTheme.current
    Text(
        text = text,
        color = t.primary.toColor(),
        fontSize = MaterialMetrics.BLOCK_HEADER_FONT_SIZE.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(
            bottom = MaterialMetrics.BLOCK_HEADER_MARGIN_BOTTOM.dp,
            start = MaterialMetrics.BLOCK_HEADER_MARGIN_LEFT.dp,
        ),
    )
}

/**
 * `ListItem` — `components.tsx` L158-217.
 *
 * The row is pressable ONLY when it carries an action: `useTap` returns
 * undefined without one and RN passes `disabled={!onTap}`, so an actionless row
 * is inert and shows no affordance. The chevron follows the same gate.
 */
internal object ListItemRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val onTap = useTap(node["title"].stringOrNull(), node["action"].actionPlan())
        val leading = node["leading"]

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (onTap != null) Modifier.clickable(onClick = onTap) else Modifier)
                .defaultMinSize(minHeight = 56.dp)
                .padding(
                    vertical = MaterialMetrics.ROW_PADDING_VERTICAL.dp,
                    horizontal = MaterialMetrics.ROW_PADDING_HORIZONTAL.dp,
                ),
            horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.ROW_GAP.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // `typeof leading === "string" && leading` first, then the
            // `{src}` object form — `components.tsx` L179-190.
            val leadingName = leading.stringOrNull()
            val leadingSrc = leading.field("src").stringOrNull()
            when {
                !leadingName.isNullOrEmpty() -> TonalIcon(leadingName)
                leadingSrc != null -> SemanticImg(
                    src = leadingSrc,
                    modifier = Modifier
                        .size(MaterialMetrics.ROW_AVATAR_SIZE.dp)
                        .clip(CircleShape),
                )
                else -> Unit
            }

            Column(Modifier.weight(1f)) {
                Text(
                    text = node["title"].reactText(),
                    color = t.onSurface.toColor(),
                    fontSize = MaterialMetrics.ROW_TITLE_FONT_SIZE.sp,
                    lineHeight = MaterialMetrics.ROW_TITLE_LINE_HEIGHT.sp,
                    fontWeight = FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val subtitle = node["subtitle"]
                if (subtitle.isTruthy()) {
                    Text(
                        text = subtitle.reactText(),
                        color = t.onSurfaceVariant.toColor(),
                        fontSize = MaterialMetrics.ROW_SUBTITLE_FONT_SIZE.sp,
                        lineHeight = MaterialMetrics.ROW_SUBTITLE_LINE_HEIGHT.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            val trailing = node["trailing"]
            if (trailing.isTruthy()) {
                Text(
                    text = trailing.reactText(),
                    color = t.onSurfaceVariant.toColor(),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    style = TabularNums,
                )
            }
            if (onTap != null) {
                // Navigational affordance for an actionable row. RN's Material
                // set leaves this to the ripple (its Cupertino sibling draws
                // the chevron); the gate — "only with an action" — is identical.
                LucideIcon(
                    name = "chevron-right",
                    tint = t.outline.toColor(),
                    size = 18.dp,
                )
            }
        }
    }
}

/**
 * `Toggle` — `components.tsx` L219-256.
 *
 * The switch flips LOCALLY and dispatches nothing: `override` shadows
 * `props.on` for the life of the composition, so the model is never asked to
 * re-render a screen because a switch moved.
 */
internal object ToggleRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        var override by remember { mutableStateOf<Boolean?>(null) }
        val on = override ?: node["on"].isTruthy()

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(role = Role.Switch) { override = !on }
                .defaultMinSize(minHeight = 56.dp)
                .padding(
                    vertical = MaterialMetrics.ROW_PADDING_VERTICAL.dp,
                    horizontal = MaterialMetrics.ROW_PADDING_HORIZONTAL.dp,
                ),
            horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.ROW_GAP.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val icon = node["icon"]
            if (icon.isTruthy()) TonalIcon(icon.reactText())

            Column(Modifier.weight(1f)) {
                Text(
                    text = node["title"].reactText(),
                    color = t.onSurface.toColor(),
                    fontSize = MaterialMetrics.ROW_TITLE_FONT_SIZE.sp,
                    lineHeight = MaterialMetrics.ROW_TITLE_LINE_HEIGHT.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val subtitle = node["subtitle"]
                if (subtitle.isTruthy()) {
                    Text(
                        text = subtitle.reactText(),
                        color = t.onSurfaceVariant.toColor(),
                        fontSize = MaterialMetrics.ROW_SUBTITLE_FONT_SIZE.sp,
                        lineHeight = MaterialMetrics.ROW_SUBTITLE_LINE_HEIGHT.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            Switch(
                checked = on,
                onCheckedChange = { override = it },
                colors = SwitchDefaults.colors(
                    checkedTrackColor = t.primary.toColor(),           // L251
                    uncheckedTrackColor = t.surfaceContainerHigh.toColor(),
                    checkedThumbColor = t.onPrimary.toColor(),         // L252
                    uncheckedThumbColor = t.outline.toColor(),
                    checkedBorderColor = t.primary.toColor(),
                    uncheckedBorderColor = t.outline.toColor(),
                ),
            )
        }
    }
}

/** `ListBlock` — `components.tsx` L273-300: rounded surfaceContainer group. */
internal object ListBlockRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        Column {
            val header = node["header"]
            if (header.isTruthy()) GroupHeader(header.reactText())
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(MaterialMetrics.BLOCK_RADIUS.dp))
                    .background(t.surfaceContainer.toColor())
                    .padding(vertical = MaterialMetrics.LIST_BLOCK_PADDING_VERTICAL.dp),
            ) {
                for (item in node["items"].truthyItems()) RenderNode(item)
            }
        }
    }
}

/** `KVList` — `components.tsx` L302-347: label/value rows in a rounded group. */
internal object KVListRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        Column {
            val header = node["header"]
            if (header.isTruthy()) GroupHeader(header.reactText())
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(MaterialMetrics.BLOCK_RADIUS.dp))
                    .background(t.surfaceContainer.toColor())
                    .padding(vertical = MaterialMetrics.KV_LIST_PADDING_VERTICAL.dp),
            ) {
                for (row in node["rows"].truthyItems()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(
                                vertical = MaterialMetrics.KV_ROW_PADDING_VERTICAL.dp,
                                horizontal = MaterialMetrics.KV_ROW_PADDING_HORIZONTAL.dp,
                            ),
                        horizontalArrangement = Arrangement.spacedBy(
                            MaterialMetrics.KV_ROW_GAP.dp,
                            Alignment.Start,
                        ),
                    ) {
                        Text(
                            text = row.field("label").reactText(),
                            color = t.onSurfaceVariant.toColor(),
                            fontSize = MaterialMetrics.KV_ROW_FONT_SIZE.sp,
                            modifier = Modifier.alignByBaseline(),
                        )
                        Text(
                            text = row.field("value").reactText(),
                            color = t.onSurface.toColor(),
                            fontSize = MaterialMetrics.KV_ROW_FONT_SIZE.sp,
                            fontWeight = FontWeight.Medium,
                            textAlign = TextAlign.End,
                            style = TabularNums,
                            modifier = Modifier
                                .weight(1f)
                                .alignByBaseline(),
                        )
                    }
                }
            }
        }
    }
}
