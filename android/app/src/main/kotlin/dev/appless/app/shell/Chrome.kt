package dev.appless.app.shell

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.icons.AppsIcon
import dev.appless.app.icons.LucideIcon
import dev.appless.app.theme.LocalShellTheme
import dev.appless.app.theme.toColor

/**
 * The OS chrome that floats over a generated screen — `GenOS.tsx` L652-800:
 * the back/home pill, the switcher button, the one-time gesture hint, the
 * generating pill, the toast, and the streaming skeleton.
 *
 * All of it is drawn in the SHELL theme (`theme.android.ts`'s projection of the
 * Material roles), not in the renderers' theme, so the chrome stays visually
 * separate from whatever the model just generated.
 */

/** `accessibilityLabel="App switcher"` — `GenOS.tsx` L703. */
internal const val SWITCHER_LABEL: String = "App switcher"

/** `EASE` — `GenOS.tsx` L58: `Easing.bezier(0.22, 1, 0.32, 1)`. */
internal val EASE: Easing = CubicBezierEasing(0.22f, 1f, 0.32f, 1f)

/**
 * `Skeleton` — `GenOS.tsx` L153-181: three pulsing blocks shown until the
 * first content arrives.
 */
@Composable
internal fun Skeleton() {
    val transition = rememberInfiniteTransition(label = "skeleton")
    val alpha by transition.animateFloat(
        initialValue = 0.4f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(550), RepeatMode.Reverse),
        label = "skeleton-alpha",
    )
    val block = Color(0x387F7F8C) // rgba(127,127,140,0.22) — L166

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp, start = 2.dp, end = 2.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier
                .fillMaxWidth(0.55f)
                .height(30.dp)
                .alpha(alpha)
                .background(block, RoundedCornerShape(12.dp)),
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(150.dp)
                .alpha(alpha)
                .background(block, RoundedCornerShape(16.dp)),
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(188.dp)
                .alpha(alpha)
                .background(block, RoundedCornerShape(14.dp)),
        )
    }
}

/** `PulsingDot` — `GenOS.tsx` L128-151. */
@Composable
private fun PulsingDot() {
    val transition = rememberInfiniteTransition(label = "pulse")
    val value by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(450), RepeatMode.Reverse),
        label = "pulse-value",
    )
    Box(
        Modifier
            .size(7.dp)
            .scale(value)
            .alpha(value)
            .background(Color.White, CircleShape),
    )
}

/**
 * The generating pill — `GenOS.tsx` L744-772.
 *
 * Two labels: the model running `web_search` says so, so a long tool round
 * never looks like a hang.
 */
@Composable
internal fun GeneratingPill(searching: Boolean, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xEB5E5CE6)) // rgba(94,92,230,0.92) — L757
            .padding(vertical = 5.dp, horizontal = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PulsingDot()
        Text(
            text = if (searching) "searching the web…" else "materializing…",
            color = Color.White,
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.4.sp,
        )
    }
}

/** The toast — `GenOS.tsx` L774-799. */
@Composable
internal fun ShellToast(text: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth(0.78f)
            .clip(RoundedCornerShape(20.dp))
            .background(Color(0xEB141418)) // rgba(20,20,24,0.92) — L785
            .padding(vertical = 10.dp, horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * The one-time gesture hint — `GenOS.tsx` L723-742. Armed once per process on
 * the first app open, dismissed by tap or after 6 s.
 */
@Composable
internal fun GestureHint(onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xE0141418)) // rgba(20,20,24,0.88) — L735
            .clickable(onClick = onDismiss)
            .padding(vertical = 9.dp, horizontal = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            text = "‹ top-left: back / home",
            color = Color.White.copy(alpha = 0.92f),
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = "top-right ⧉ : recent apps",
            color = Color.White.copy(alpha = 0.92f),
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/**
 * The top-left chrome pill — `GenOS.tsx` L654-691.
 *
 * ONE button with two meanings, and the meaning is the stack depth: deeper than
 * the root it pops, at the root it minimizes the app into its icon.
 */
@Composable
internal fun BackOrHomePill(isBack: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val t = LocalShellTheme.current
    // `accessibilityLabel={stack.length > 1 ? "Back" : "Home"}` — GenOS.tsx L658.
    // The glyph inside is a Lucide icon with no description of its own (as in
    // RN), so without this the control is an unlabeled button to TalkBack and
    // unaddressable to any test.
    val label = if (isBack) "Back" else "Home"
    Box(
        modifier = modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(t.chromeBg.toColor())
            .border(1.dp, t.chromeBorder.toColor(), CircleShape)
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = label
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        LucideIcon(
            name = if (isBack) "chevron-left" else "house",
            tint = t.chromeInk.toColor(),
            size = 18.dp,
        )
    }
}

/** The top-right switcher button — `GenOS.tsx` L693-721. */
@Composable
internal fun SwitcherPill(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val t = LocalShellTheme.current
    Box(
        modifier = modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(t.chromeBg.toColor())
            .border(1.dp, t.chromeBorder.toColor(), CircleShape)
            .clickable(onClick = onClick)
            // `accessibilityLabel="App switcher"` — GenOS.tsx L703.
            .semantics {
                contentDescription = SWITCHER_LABEL
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        AppsIcon(color = t.chromeInk.toColor(), size = 18.dp)
    }
}

/** The error + retry screen — `GenOS.tsx` L603-627. */
@Composable
internal fun ErrorRetry(message: String, onRetry: () -> Unit) {
    val t = LocalShellTheme.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(
            text = message.ifEmpty { "Generation failed" },
            color = t.ink.toColor().copy(alpha = 0.75f),
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
        )
        Box(
            Modifier
                .clip(RoundedCornerShape(18.dp))
                .background(ACCENT)
                .clickable(onClick = onRetry)
                .padding(vertical = 8.dp, horizontal = 22.dp),
        ) {
            Text(text = "Retry", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** `ACCENT` — the applessOS brand indigo, `shell/KeyGate.tsx` L12. */
internal val ACCENT: Color = Color(0xFF5E5CE6)

/** Fixed chrome heights the screen's scroll padding has to clear. */
internal object ChromeMetrics {
    /** `paddingTop: insets.top + 54` — `GenOS.tsx` L630. */
    val contentTopPadding = 54.dp

    /** `paddingBottom: 44 + insets.bottom` — L632. */
    val contentBottomPadding = 44.dp

    /** `paddingHorizontal: 14` — L631. */
    val contentHorizontalPadding = 14.dp

    /** `top: insets.top + 6` for both chrome pills — L657, L697. */
    val pillTopInset = 6.dp

    /** The minimize target: 230 ≈ the home icon grid's offset — L566-570. */
    val minimizeTargetOffset = 230.dp
}
