package dev.appless.app.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.theme.LocalShellTheme
import dev.appless.app.theme.toColor
import dev.appless.genoscore.KeyStatus

/**
 * First-launch BYOK gate — `src/genos/shell/KeyGate.tsx`.
 *
 * applessOS generates every screen on the USER'S OWN Cerebras key, entered once
 * and stored on-device (here: `EncryptedSharedPreferences` under an Android
 * Keystore master key). Shown until a key exists; it comes BACK when the API
 * rejects a stored key, which is why it renders on both
 * [KeyStatus.MISSING] and [KeyStatus.REJECTED].
 */
@Composable
internal fun KeyGate(
    status: KeyStatus,
    onSubmit: (String) -> Unit,
    onGetKey: () -> Unit,
) {
    val t = LocalShellTheme.current
    var value by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    // `value.trim().length >= 10` — KeyGate.tsx L22.
    val valid = value.trim().length >= 10

    fun save() {
        if (!valid || saving) return
        saving = true
        onSubmit(value)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(t.bg.toColor())
            // Swallow taps so the screen underneath is unreachable while gated.
            .clickable(enabled = false) {}
            .padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
    ) {
        Text(
            text = "AppLess",
            color = t.ink.toColor(),
            fontSize = 30.sp,
            fontWeight = FontWeight.ExtraBold,
            letterSpacing = (-0.5).sp,
        )
        Text(
            text = "Every screen is generated the moment you ask - on your own Cerebras " +
                "API key. It is stored only on this device.",
            color = t.ink2.toColor(),
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 320.dp),
        )

        if (status == KeyStatus.REJECTED) {
            Text(
                text = "Cerebras rejected the saved key - paste a valid one.",
                color = t.red.toColor(),
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
            )
        }

        BasicTextField(
            value = value,
            onValueChange = { value = it },
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 360.dp)
                .border(1.dp, t.sep.toColor(), RoundedCornerShape(12.dp))
                .background(t.group.toColor(), RoundedCornerShape(12.dp))
                .padding(vertical = 12.dp, horizontal = 14.dp),
            textStyle = TextStyle(color = t.ink.toColor(), fontSize = 14.sp),
            cursorBrush = SolidColor(ACCENT),
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Go,
            ),
            keyboardActions = KeyboardActions(onGo = { save() }),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        Text("csk-…", color = t.ink3.toColor(), fontSize = 14.sp)
                    }
                    inner()
                }
            },
        )

        Box(
            Modifier
                .clip(RoundedCornerShape(22.dp))
                .background(
                    if (!valid || saving) ACCENT.copy(alpha = 0.4f) else ACCENT,
                )
                .clickable(enabled = valid && !saving) { save() }
                .padding(vertical = 12.dp, horizontal = 36.dp),
        ) {
            Text(
                text = if (saving) "Starting…" else "Start",
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        Text(
            text = "Get a free key at cloud.cerebras.ai",
            color = t.tint.toColor(),
            fontSize = 13.sp,
            modifier = Modifier.clickable(onClick = onGetKey),
        )
    }
}
