package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import dev.appless.app.icons.LucideIcon
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.uicore.MaterialMetrics

/**
 * Shared bits the Material renderers use, ported from the helpers that live
 * inline in `src/genos/ui/material/components.tsx`.
 */

/**
 * `fontVariant: ["tabular-nums"]` — the RN style every numeric field in the
 * Material set carries so digits do not jitter as a screen streams in.
 */
internal val TabularNums: TextStyle = TextStyle(fontFeatureSettings = "tnum")

/**
 * RN's negative `marginBottom` (the `large-heavy` text style pulls the next
 * element up by 6).
 *
 * Compose forbids negative padding, so the child under-reports its height by
 * `amount`, which is what a negative bottom margin does inside a gapped column.
 */
internal fun Modifier.negativeBottomMargin(amount: Dp): Modifier = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    val height = (placeable.height - amount.roundToPx()).coerceAtLeast(0)
    layout(placeable.width, height) { placeable.place(0, 0) }
}

/**
 * `TonalIcon` — `components.tsx` L34-49: a 40dp secondary-container disc with a
 * 19dp icon in the on-secondary-container role. Used as `ListItem.leading`
 * (string form) and `Toggle.icon`.
 */
@Composable
internal fun TonalIcon(name: String) {
    val t = LocalMdTheme.current
    Box(
        Modifier
            .size(40.dp)
            .background(t.secondaryContainer.toColor(), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        LucideIcon(name = name, tint = t.onSecondaryContainer.toColor(), size = 19.dp)
    }
}

/**
 * `TEXT_STYLES` lookup with the one key-name fix the port needs.
 *
 * `ui-core`'s [MaterialMetrics.textStyles] calls the M3 title row `"heading"`;
 * the CONTRACT (and `components.tsx` L87) spells the same style
 * `"large-heavy"`. Aliasing here keeps the ported metrics authoritative
 * instead of re-typing 20/26/500/-6 locally.
 */
internal fun materialTextStyle(rawStyle: String?): MaterialMetrics.TextStyle =
    MaterialMetrics.textStyle(if (rawStyle == "large-heavy") "heading" else rawStyle)

/**
 * RN's negative horizontal `margin` (the chip strip bleeds past the screen
 * padding: `marginHorizontal: -16`, `components.tsx` L563).
 *
 * The child is measured `amount` wider on BOTH sides and then placed shifted
 * left, so it paints edge-to-edge while the parent's layout is unchanged.
 */
internal fun Modifier.bleedHorizontal(amount: Dp): Modifier = layout { measurable, constraints ->
    val extra = amount.roundToPx() * 2
    val widened = constraints.copy(
        minWidth = (constraints.minWidth + extra).coerceAtLeast(0),
        maxWidth = if (constraints.maxWidth == Int.MAX_VALUE) {
            Int.MAX_VALUE
        } else {
            constraints.maxWidth + extra
        },
    )
    val placeable = measurable.measure(widened)
    layout((placeable.width - extra).coerceAtLeast(0), placeable.height) {
        placeable.place(-amount.roundToPx(), 0)
    }
}

/**
 * RN's `borderBottomWidth: 1` — a hairline under the composable.
 *
 * Drawn rather than laid out (a `border` modifier would ring all four sides and
 * shift the content) and snapped to one physical pixel, which is what a 1dp RN
 * border resolves to on a phone.
 */
internal fun Modifier.drawBottomHairline(color: Color): Modifier = drawBehind {
    val stroke = 1.dp.toPx()
    drawLine(
        color = color,
        start = Offset(0f, size.height - stroke / 2),
        end = Offset(size.width, size.height - stroke / 2),
        strokeWidth = stroke,
    )
}

/**
 * `Double.dp` / `Double.sp`.
 *
 * Every metric in `ui-core` is a `Double` because it was transcribed from a
 * TypeScript number; Compose only defines `.dp`/`.sp` on `Int` and `Float`.
 * Converting at the call site (`X.toFloat().dp`) 200 times would bury the
 * ported constants in noise, so the conversion lives here — in the renderers'
 * own package, where it is visible without an import.
 */
internal inline val Double.dp: Dp get() = toFloat().dp

internal inline val Double.sp: TextUnit get() = toFloat().sp
