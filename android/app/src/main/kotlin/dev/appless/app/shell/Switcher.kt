package dev.appless.app.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.render.ActionDispatcher
import dev.appless.app.render.FormStore
import dev.appless.app.render.ScreenView
import dev.appless.app.theme.LocalShellTheme
import dev.appless.app.theme.toColor
import dev.appless.genoscore.Screen
import dev.appless.openuilang.LibrarySchema

/**
 * iOS-style app switcher with LIVE miniature previews — `shell/Switcher.tsx`.
 *
 * The previews are not screenshots: each card renders the session's top screen
 * through the same renderer set at full phone size and scales it down 2x, which
 * is why a card of an app that is still streaming keeps filling in.
 */
@Composable
internal fun Switcher(
    apps: List<RunningApp>,
    screenFor: (String) -> Screen?,
    schema: LibrarySchema,
    onResume: (String) -> Unit,
    onClose: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val t = LocalShellTheme.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xE00C0C12)) // rgba(12,12,18,0.88) — Switcher.tsx L46
            .clickable(onClick = onDismiss),
        contentAlignment = Alignment.Center,
    ) {
        if (apps.isEmpty()) {
            Text(
                text = "No open apps",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )
            return@Box
        }
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 28.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for (app in apps) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SwitcherCardHeader(app, onClose = { onClose(app.id) })
                    Box(
                        Modifier
                            .size(CARD_W, CARD_H)
                            .clip(RoundedCornerShape(24.dp))
                            .background(t.bg.toColor())
                            .clickable { onResume(app.id) },
                    ) {
                        val screen = screenFor(app.id)
                        val content = screen?.content
                        if (!content.isNullOrEmpty()) {
                            SwitcherPreview(content, schema)
                        } else {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text(app.emoji, fontSize = 64.sp, color = Color.White.copy(alpha = 0.5f))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SwitcherCardHeader(app: RunningApp, onClose: () -> Unit) {
    Row(
        modifier = Modifier.width(CARD_W),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(
                    // The app's tile gradient, corner to corner — Switcher.tsx L69-72.
                    Brush.linearGradient(
                        listOf(parseHex(app.tileStart), parseHex(app.tileEnd)),
                    )
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(app.emoji, fontSize = 12.sp)
        }
        Text(
            text = app.name,
            color = Color.White,
            fontSize = 12.5.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Box(
            Modifier
                .size(20.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.25f))
                .clickable(onClick = onClose),
            contentAlignment = Alignment.Center,
        ) {
            Text("✕", color = Color.White, fontSize = 10.sp)
        }
    }
}

/**
 * The miniature: lay the screen out at FULL phone size, then scale by 0.5 —
 * `Switcher.tsx` L110-131. Laying out at card size instead would reflow the
 * screen (text wrapping differently), which is exactly what a preview must not
 * do.
 */
@Composable
private fun SwitcherPreview(content: String, schema: LibrarySchema) {
    val formStore = remember { FormStore() }
    // A preview is inert: taps inside it must resume the app, never dispatch.
    val dispatcher = remember { ActionDispatcher(formStore) {} }
    Box(
        Modifier
            .layout { measurable, constraints ->
                val placeable = measurable.measure(
                    constraints.copy(
                        minWidth = 0,
                        minHeight = 0,
                        maxWidth = (constraints.maxWidth * 2),
                        maxHeight = (constraints.maxHeight * 2),
                    )
                )
                layout(constraints.maxWidth, constraints.maxHeight) { placeable.place(0, 0) }
            }
            .scale(PREVIEW_SCALE)
            .padding(10.dp),
    ) {
        ScreenView(
            content = content,
            isStreaming = false,
            schema = schema,
            formStore = formStore,
            dispatcher = dispatcher,
        )
    }
}

/** Card geometry — `Switcher.tsx` L16-20. */
private val CARD_W = 188.dp
private val CARD_H = 400.dp
private const val PREVIEW_SCALE = 0.5f

/** `#rrggbb` -> Color, for the tile gradient stops carried as raw RN literals. */
private fun parseHex(raw: String): Color {
    val body = raw.removePrefix("#")
    val value = body.toLongOrNull(16) ?: return Color.Transparent
    return when (body.length) {
        6 -> Color(0xFF000000L or value)
        8 -> Color(value)
        else -> Color.Transparent
    }
}
