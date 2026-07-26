package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.icons.LucideIcon
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.RenderNode
import dev.appless.app.render.get
import dev.appless.app.render.isTruthy
import dev.appless.app.render.reactText
import dev.appless.app.render.stringOrNull
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.MaterialMetrics

/**
 * Structure + text renderers — `src/genos/ui/material/components.tsx` L52-155.
 */

/** `Card` — `components.tsx` L53-55. The contract root. */
internal object CardRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        Column(
            modifier = Modifier.padding(bottom = MaterialMetrics.CARD_PADDING_BOTTOM.dp),
            verticalArrangement = Arrangement.spacedBy(MaterialMetrics.CARD_GAP.dp),
        ) {
            RenderNode(node.children)
        }
    }
}

/** `CardHeader` — `components.tsx` L58-77: M3 headline with a primary overline. */
internal object CardHeaderRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        Column(
            Modifier.padding(
                top = MaterialMetrics.CARD_HEADER_PADDING_TOP.dp,
                start = MaterialMetrics.CARD_HEADER_PADDING_HORIZONTAL.dp,
                end = MaterialMetrics.CARD_HEADER_PADDING_HORIZONTAL.dp,
            )
        ) {
            val subtitle = node["subtitle"]
            if (subtitle.isTruthy()) {
                Text(
                    text = subtitle.reactText(),
                    color = t.primary.toColor(),
                    fontSize = MaterialMetrics.CARD_HEADER_OVERLINE_FONT_SIZE.sp,
                    fontWeight = FontWeight.Medium,
                    letterSpacing = MaterialMetrics.CARD_HEADER_OVERLINE_LETTER_SPACING.sp,
                    modifier = Modifier.padding(
                        bottom = MaterialMetrics.CARD_HEADER_OVERLINE_MARGIN_BOTTOM.dp,
                    ),
                )
            }
            Text(
                text = node["title"].reactText(),
                color = t.onSurface.toColor(),
                fontSize = MaterialMetrics.CARD_HEADER_TITLE_FONT_SIZE.sp,
                lineHeight = MaterialMetrics.CARD_HEADER_TITLE_LINE_HEIGHT.sp,
                fontWeight = FontWeight.Normal,
            )
        }
    }
}

/**
 * `TextContent` — `components.tsx` L95-110.
 *
 * `small` is the only style that drops to the secondary ink role, and the
 * comparison is against the RAW prop (`key === "small"`), not the resolved
 * style — an unknown style falls back to `default` metrics but keeps primary
 * ink.
 */
internal object TextContentRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val rawStyle = node["style"].stringOrNull()
        val style = materialTextStyle(rawStyle)
        val negative = if (style.marginBottom < 0) (-style.marginBottom).dp else 0.dp
        Text(
            text = node["text"].reactText(),
            color = if (rawStyle == "small") t.onSurfaceVariant.toColor() else t.onSurface.toColor(),
            fontSize = style.fontSize.sp,
            lineHeight = style.lineHeight.sp,
            fontWeight = if (style.fontWeight == "500") FontWeight.Medium else FontWeight.Normal,
            modifier = Modifier
                .padding(horizontal = 4.dp)
                .then(if (negative > 0.dp) Modifier.negativeBottomMargin(negative) else Modifier),
        )
    }
}

/** `TextCallout` — `components.tsx` L119-155. */
internal object TextCalloutRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val variant = node["variant"].stringOrNull() ?: "neutral"

        // `components.tsx` L121-131. The two `success` foregrounds are literals
        // in the RN source (they are not M3 roles), so they are transcribed
        // here with their line rather than invented.
        val background: Color
        val foreground: Color
        when (variant) {
            "info" -> {
                background = t.secondaryContainer.toColor()
                foreground = t.onSecondaryContainer.toColor()
            }
            "success" -> {
                background = t.successContainer.toColor()
                foreground = if (t.dark) Color(0xFFC6EFC9) else Color(0xFF0A3D18) // L124
            }
            "warning" -> {
                background = t.warningContainer.toColor()
                foreground = t.onWarningContainer.toColor()
            }
            "danger" -> {
                background = t.errorContainer.toColor()
                foreground = t.onErrorContainer.toColor()
            }
            else -> {
                background = t.surfaceContainerHigh.toColor()
                foreground = t.onSurface.toColor()
            }
        }

        Row(
            modifier = Modifier
                .background(background, RoundedCornerShape(MaterialMetrics.CALLOUT_RADIUS.dp))
                .padding(
                    PaddingValues(
                        vertical = MaterialMetrics.CALLOUT_PADDING_VERTICAL.dp,
                        horizontal = MaterialMetrics.CALLOUT_PADDING_HORIZONTAL.dp,
                    )
                ),
            horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.CALLOUT_GAP.dp),
            verticalAlignment = Alignment.Top,
        ) {
            LucideIcon(
                name = MaterialMetrics.calloutIcons[variant],
                tint = foreground,
                size = 20.dp,
                modifier = Modifier.padding(top = 1.dp), // L139 marginTop: 1
            )
            Column(Modifier.weight(1f)) {
                Text(
                    text = node["title"].reactText(),
                    color = foreground,
                    fontSize = MaterialMetrics.CALLOUT_TITLE_FONT_SIZE.sp,
                    lineHeight = MaterialMetrics.CALLOUT_TITLE_LINE_HEIGHT.sp,
                    fontWeight = FontWeight.Medium,
                )
                val description = node["description"]
                if (description.isTruthy()) {
                    Text(
                        text = description.reactText(),
                        color = foreground.copy(
                            alpha = MaterialMetrics.CALLOUT_BODY_OPACITY.toFloat(),
                        ),
                        fontSize = MaterialMetrics.CALLOUT_BODY_FONT_SIZE.sp,
                        lineHeight = MaterialMetrics.CALLOUT_BODY_LINE_HEIGHT.sp,
                        modifier = Modifier.padding(top = 2.dp), // L147 marginTop: 2
                    )
                }
            }
        }
    }
}
