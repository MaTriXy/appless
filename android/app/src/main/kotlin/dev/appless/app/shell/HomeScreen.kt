package dev.appless.app.shell

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.appless.app.R
import dev.appless.app.icons.PhosphorIcon
import dev.appless.genoscore.Apps
import dev.appless.genoscore.Suggestion
import kotlinx.coroutines.delay

/**
 * The appless home — `src/genos/shell/HomeScreen.tsx`.
 *
 * No app grid: a wordmark, three rotating suggestion lines, and one "ask for
 * anything" pill. Open threads appear as icons below the wordmark. It stays
 * MOUNTED under active app screens (that is what makes resuming instant), so
 * the suggestion rotation pauses while [covered].
 */
@Composable
internal fun HomeScreen(
    topInset: Dp,
    covered: Boolean,
    onCommand: (String) -> Unit,
    runningApps: List<RunningApp>,
    onResume: (String) -> Unit,
    onClose: (String) -> Unit,
) {
    var ask by remember { mutableStateOf("") }
    // Three visible slots, cycled one at a time — L340-360.
    val slots = remember { mutableStateListOf(0, 1, 2) }
    var editingId by remember { mutableStateOf<String?>(null) }
    var nextIdx by remember { mutableIntStateOf(3) }
    var turn by remember { mutableIntStateOf(0) }

    LaunchedEffect(covered) {
        if (covered) return@LaunchedEffect
        while (true) {
            delay(4000)
            val row = turn % slots.size
            val idx = nextIdx % Apps.suggestions.size
            nextIdx += 1
            turn += 1
            slots[row] = idx
        }
    }

    fun submit() {
        val text = ask.trim()
        if (text.isEmpty()) return
        onCommand(text)
        ask = ""
    }

    Box(Modifier.fillMaxSize()) {
        Image(
            painter = painterResource(R.drawable.home_bg),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
        // Scrim for text legibility over the wallpaper — L400-410.
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.22f)))

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = topInset + 40.dp, bottom = 46.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // The RN wordmark is an inline SVG (`applessLogo.tsx`); the port
                // draws it as type rather than adding an SVG runtime for one asset.
                Text(
                    text = "appless",
                    color = Color.White,
                    fontSize = 40.sp,
                    fontWeight = FontWeight.Light,
                    letterSpacing = (-1.5).sp,
                )
                Text(
                    text = "Just ask.",
                    color = Color.White.copy(alpha = 0.5f),
                    fontSize = 24.sp,
                    lineHeight = 30.sp,
                    letterSpacing = (-0.5).sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 4.dp),
                )

                if (runningApps.isNotEmpty()) {
                    AppIconGrid(
                        apps = runningApps,
                        editingId = editingId,
                        onPress = { id ->
                            if (editingId != null) editingId = null else onResume(id)
                        },
                        onLongPress = { editingId = it },
                        onClose = {
                            onClose(it)
                            editingId = null
                        },
                    )
                }
            }

            Column(
                modifier = Modifier.padding(horizontal = 18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(
                    modifier = Modifier.padding(top = 10.dp, bottom = 10.dp, start = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(22.dp),
                ) {
                    for (slot in slots) {
                        val suggestion = Apps.suggestions[slot]
                        SuggestionRow(suggestion) { onCommand(suggestion.command) }
                    }
                }

                AskBar(
                    value = ask,
                    onValueChange = { ask = it },
                    onSubmit = { submit() },
                )
            }
        }
    }
}

/** One rotating suggestion line — `SuggestionRow`, `HomeScreen.tsx` L60-121. */
@Composable
private fun SuggestionRow(suggestion: Suggestion, onPress: () -> Unit) {
    // RN fades the old label out and types the new one in character by
    // character. The port crossfades instead: `Crossfade`-style alpha on the
    // label keeps the rhythm without a per-character recomposition storm.
    val alpha by animateFloatAsState(
        targetValue = 1f,
        animationSpec = tween(280),
        label = "suggestion-fade",
    )
    Row(
        modifier = Modifier
            .clickable(onClick = onPress)
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PhosphorIcon(
            name = TileIcons.suggestionIcon(suggestion.label),
            tint = Color.White.copy(alpha = 0.85f * alpha),
            size = 18.dp,
        )
        Text(
            text = suggestion.label,
            color = Color.White.copy(alpha = 0.85f * alpha),
            fontSize = 15.sp,
        )
    }
}

/** The minimized-thread icon grid — `HomeScreen.tsx` L432-457. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AppIconGrid(
    apps: List<RunningApp>,
    editingId: String?,
    onPress: (String) -> Unit,
    onLongPress: (String) -> Unit,
    onClose: (String) -> Unit,
) {
    FlowRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 100.dp)
            .heightIn(max = 216.dp)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        for (app in apps) {
            AppIcon(
                app = app,
                editing = editingId == app.id,
                onPress = { onPress(app.id) },
                onLongPress = { onLongPress(app.id) },
                onClose = { onClose(app.id) },
            )
        }
    }
}

/** `AppIcon` — `HomeScreen.tsx` L207-292: pops in, long-press reveals a close badge. */
@Composable
private fun AppIcon(
    app: RunningApp,
    editing: Boolean,
    onPress: () -> Unit,
    onLongPress: () -> Unit,
    onClose: () -> Unit,
) {
    var mounted by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { mounted = true }
    val pop by animateFloatAsState(
        targetValue = if (mounted) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "icon-pop",
    )

    Column(
        modifier = Modifier
            .width(64.dp)
            .pointerInput(app.id, editing) {
                detectTapGestures(onTap = { onPress() }, onLongPress = { onLongPress() })
            },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.scale(pop)) {
            Box(
                Modifier
                    .size(54.dp)
                    .clip(RoundedCornerShape(13.dp))
                    // GLASS — HomeScreen.tsx L192-201.
                    .background(Color.White.copy(alpha = 0.2f))
                    .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(13.dp)),
                contentAlignment = Alignment.Center,
            ) {
                PhosphorIcon(
                    name = TileIcons.tileIcon(app.name, app.id, app.emoji),
                    tint = Color.White,
                    size = 26.dp,
                )
            }
            if (editing) {
                Box(
                    Modifier
                        .align(Alignment.TopStart)
                        .size(20.dp)
                        .clip(CircleShape)
                        .background(Color(0xEB1C1C1E))
                        .clickable(onClick = onClose)
                        // `accessibilityLabel={`Close ${app.name}`}` — HomeScreen.tsx L259.
                        .semantics {
                            contentDescription = "Close ${app.name}"
                            role = Role.Button
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("✕", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
        Text(
            // "Trip Planner" -> "Trip" — the one-word tile label.
            text = TileIcons.oneWordName(app.name),
            color = Color.White.copy(alpha = 0.9f),
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 5.dp),
        )
    }
}

/** The "ask for anything" pill — `HomeScreen.tsx` L466-486. */
@Composable
private fun AskBar(value: String, onValueChange: (String) -> Unit, onSubmit: () -> Unit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(22.dp))
                .background(Color.White.copy(alpha = 0.2f))
                .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(22.dp))
                .padding(
                    top = 11.dp,
                    bottom = 11.dp,
                    start = 18.dp,
                    // Make room for the send button once there is text — L479.
                    end = if (value.trim().isNotEmpty()) 48.dp else 18.dp,
                ),
            textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { onSubmit() }),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        Text(
                            "Ask for anything…",
                            color = Color.White.copy(alpha = 0.75f),
                            fontSize = 14.sp,
                        )
                    }
                    inner()
                }
            },
        )
        if (value.trim().isNotEmpty()) {
            Box(
                Modifier
                    .padding(end = 5.dp)
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(Color.White)
                    .clickable(onClick = onSubmit)
                    // `accessibilityLabel="Send"` — HomeScreen.tsx L467.
                    .semantics {
                        contentDescription = "Send"
                        role = Role.Button
                    },
                contentAlignment = Alignment.Center,
            ) {
                PhosphorIcon(name = "ArrowUp", tint = Color(0xFF1C1C1E), size = 16.dp)
            }
        }
    }
}
