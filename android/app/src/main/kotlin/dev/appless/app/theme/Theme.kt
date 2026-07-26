package dev.appless.app.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import dev.appless.uicore.MdColor
import dev.appless.uicore.MdTheme
import dev.appless.uicore.ShellTheme
import dev.appless.uicore.Tokens

/**
 * The Compose bridge for `ui-core`'s design tokens.
 *
 * `ui-core` is deliberately Compose-free — it carries the RN color literals and
 * the metrics, verified headlessly against the TypeScript. This file is the
 * ONLY place those turn into `androidx.compose.ui.graphics.Color`, so there is
 * exactly one conversion to audit.
 */

/** `MdColor.argb` is already `0xAARRGGBB`, the packed form `Color(...)` takes. */
public fun MdColor.toColor(): Color = Color(argb)

/**
 * `useMd()` — `src/genos/ui/material/theme.ts` L98-100.
 *
 * A static local: the theme only changes when the system flips light/dark, and
 * every renderer reads it, so invalidating the whole tree is the cheap option.
 */
public val LocalMdTheme: ProvidableCompositionLocal<MdTheme> =
    staticCompositionLocalOf { Tokens.MD_LIGHT }

/** `useCds()` on Android — the shell-chrome projection (`theme.android.ts`). */
public val LocalShellTheme: ProvidableCompositionLocal<ShellTheme> =
    staticCompositionLocalOf { ShellTheme.LIGHT }

/**
 * Projects the ported Material 3 roles onto Compose's `ColorScheme` so stock
 * M3 components (TextField, Switch, Slider, Surface) pick up the SAME palette
 * the hand-written renderers use.
 *
 * Roles `ui-core` does not carry (`secondary`, `tertiary`, `inverse*`, the
 * `surfaceContainer*` tiers M3 1.3 added) are filled from the nearest ported
 * role rather than invented, so nothing on screen can show a color that is not
 * in `material/theme.ts`.
 */
private fun colorScheme(t: MdTheme) = if (t.dark) {
    darkColorScheme(
        primary = t.primary.toColor(),
        onPrimary = t.onPrimary.toColor(),
        primaryContainer = t.primaryContainer.toColor(),
        onPrimaryContainer = t.onPrimaryContainer.toColor(),
        secondary = t.onSecondaryContainer.toColor(),
        onSecondary = t.secondaryContainer.toColor(),
        secondaryContainer = t.secondaryContainer.toColor(),
        onSecondaryContainer = t.onSecondaryContainer.toColor(),
        tertiary = t.primary.toColor(),
        onTertiary = t.onPrimary.toColor(),
        background = t.surface.toColor(),
        onBackground = t.onSurface.toColor(),
        surface = t.surface.toColor(),
        onSurface = t.onSurface.toColor(),
        surfaceVariant = t.surfaceContainer.toColor(),
        onSurfaceVariant = t.onSurfaceVariant.toColor(),
        surfaceContainerLowest = t.surface.toColor(),
        surfaceContainerLow = t.surfaceContainerLow.toColor(),
        surfaceContainer = t.surfaceContainer.toColor(),
        surfaceContainerHigh = t.surfaceContainerHigh.toColor(),
        surfaceContainerHighest = t.surfaceContainerHigh.toColor(),
        outline = t.outline.toColor(),
        outlineVariant = t.outlineVariant.toColor(),
        error = t.error.toColor(),
        onError = t.onError.toColor(),
        errorContainer = t.errorContainer.toColor(),
        onErrorContainer = t.onErrorContainer.toColor(),
    )
} else {
    lightColorScheme(
        primary = t.primary.toColor(),
        onPrimary = t.onPrimary.toColor(),
        primaryContainer = t.primaryContainer.toColor(),
        onPrimaryContainer = t.onPrimaryContainer.toColor(),
        secondary = t.onSecondaryContainer.toColor(),
        onSecondary = t.secondaryContainer.toColor(),
        secondaryContainer = t.secondaryContainer.toColor(),
        onSecondaryContainer = t.onSecondaryContainer.toColor(),
        tertiary = t.primary.toColor(),
        onTertiary = t.onPrimary.toColor(),
        background = t.surface.toColor(),
        onBackground = t.onSurface.toColor(),
        surface = t.surface.toColor(),
        onSurface = t.onSurface.toColor(),
        surfaceVariant = t.surfaceContainer.toColor(),
        onSurfaceVariant = t.onSurfaceVariant.toColor(),
        surfaceContainerLowest = t.surface.toColor(),
        surfaceContainerLow = t.surfaceContainerLow.toColor(),
        surfaceContainer = t.surfaceContainer.toColor(),
        surfaceContainerHigh = t.surfaceContainerHigh.toColor(),
        surfaceContainerHighest = t.surfaceContainerHigh.toColor(),
        outline = t.outline.toColor(),
        outlineVariant = t.outlineVariant.toColor(),
        error = t.error.toColor(),
        onError = t.onError.toColor(),
        errorContainer = t.errorContainer.toColor(),
        onErrorContainer = t.onErrorContainer.toColor(),
    )
}

@Composable
public fun AppLessTheme(
    dark: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val md = Tokens.theme(dark)
    CompositionLocalProvider(
        LocalMdTheme provides md,
        LocalShellTheme provides ShellTheme.of(dark),
    ) {
        MaterialTheme(colorScheme = colorScheme(md), content = content)
    }
}
