package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import dev.appless.app.icons.LucideIcon
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.LocalFormName
import dev.appless.app.render.LocalFormStore
import dev.appless.app.render.LocalTriggerAction
import dev.appless.app.render.RenderNode
import dev.appless.app.render.actionPlan
import dev.appless.app.render.get
import dev.appless.app.render.isTruthy
import dev.appless.app.render.items
import dev.appless.app.render.intOrNull
import dev.appless.app.render.numberOrNull
import dev.appless.app.render.reactText
import dev.appless.app.render.stringOrNull
import dev.appless.app.render.truthyItems
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropValue
import dev.appless.uicore.FormValue
import dev.appless.uicore.InputBehavior
import dev.appless.uicore.MaterialMetrics
import dev.appless.uicore.readSelectItems
import kotlin.math.roundToInt

/**
 * Material 3 form renderers — `src/genos/ui/material/forms.tsx`.
 *
 * The state model is `ui-core`'s `FormStateModel` (wrapped by `FormStore`), so
 * ordering, the `{value, componentType}` wrapper and the submitted payload
 * shape are the tested ones; this file owns only the M3 chrome.
 */

// ------------------------------------------------------------- field plumbing

/**
 * `useFieldState(name, componentType, seedValue)` — `ui/shared/forms.ts`.
 *
 * The seed is applied ONCE and only while the field is unset, so a re-parse
 * mid-stream (the model is still emitting the screen) cannot overwrite what the
 * user has typed.
 */
@Composable
private fun rememberField(
    name: String,
    componentType: String,
    seed: PropValue?,
): FieldHandle {
    val store = LocalFormStore.current
    val formName = LocalFormName.current
    val seeded = FormValue.seed(seed)
    LaunchedEffect(formName, name, componentType, seeded) {
        if (seeded != null) store.seedDefault(formName, name, componentType, seeded)
    }
    return FieldHandle(
        value = store.value(formName, name),
        set = { store.set(formName, name, componentType, it) },
    )
}

private class FieldHandle(val value: FormValue?, val set: (FormValue) -> Unit)

/**
 * `useOutlinedStyle(focused)` — `forms.tsx` L24-35.
 *
 * A focused field grows its border from 1 to 2 and sheds 1 of padding on each
 * axis so the text does not shift.
 */
@Composable
private fun outlinedFieldModifier(focused: Boolean): Modifier {
    val t = LocalMdTheme.current
    return Modifier
        .fillMaxWidth()
        .border(
            width = if (focused) {
                MaterialMetrics.FIELD_BORDER_WIDTH_FOCUSED.dp
            } else {
                MaterialMetrics.FIELD_BORDER_WIDTH_RESTING.dp
            },
            color = if (focused) t.primary.toColor() else t.outline.toColor(),
            shape = RoundedCornerShape(MaterialMetrics.FIELD_RADIUS.dp),
        )
        .padding(
            vertical = if (focused) {
                MaterialMetrics.FIELD_PADDING_VERTICAL_FOCUSED.dp
            } else {
                MaterialMetrics.FIELD_PADDING_VERTICAL_RESTING.dp
            },
            horizontal = if (focused) {
                MaterialMetrics.FIELD_PADDING_HORIZONTAL_FOCUSED.dp
            } else {
                MaterialMetrics.FIELD_PADDING_HORIZONTAL_RESTING.dp
            },
        )
}

/** `textInputBehaviorProps(type)` — `shared/forms.ts` L44-52, via `ui-core`. */
private fun keyboardOptions(type: String?): KeyboardOptions = KeyboardOptions(
    keyboardType = when (InputBehavior.keyboardType(type)) {
        "email-address" -> KeyboardType.Email
        "numeric" -> KeyboardType.Number
        "url" -> KeyboardType.Uri
        else -> KeyboardType.Text
    },
    capitalization = if (InputBehavior.autoCapitalize(type) == "none") {
        KeyboardCapitalization.None
    } else {
        KeyboardCapitalization.Sentences
    },
)

/** The bare outlined text field shared by Input / TextArea / DatePicker. */
@Composable
private fun OutlinedField(
    field: FieldHandle,
    onValueChange: (String) -> Unit,
    placeholder: String?,
    keyboard: KeyboardOptions = KeyboardOptions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    singleLine: Boolean = true,
    extraModifier: Modifier = Modifier,
) {
    val t = LocalMdTheme.current
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    // `typeof field.value === "string" ? field.value : ""` — forms.tsx L45.
    val text = field.value?.textValue ?: ""

    BasicTextField(
        value = text,
        onValueChange = onValueChange,
        modifier = outlinedFieldModifier(focused).then(extraModifier),
        textStyle = TextStyle(
            color = t.onSurface.toColor(),
            fontSize = MaterialMetrics.FIELD_FONT_SIZE.sp,
        ),
        cursorBrush = SolidColor(t.primary.toColor()),
        keyboardOptions = keyboard,
        visualTransformation = visualTransformation,
        singleLine = singleLine,
        interactionSource = interaction,
        decorationBox = { inner ->
            Box(contentAlignment = if (singleLine) Alignment.CenterStart else Alignment.TopStart) {
                if (text.isEmpty() && !placeholder.isNullOrEmpty()) {
                    Text(
                        text = placeholder,
                        color = t.onSurfaceVariant.toColor(),
                        fontSize = MaterialMetrics.FIELD_FONT_SIZE.sp,
                    )
                }
                inner()
            }
        },
    )
}

// ------------------------------------------------------------------- renderers

/** `Input` — `forms.tsx` L37-56. */
internal object InputRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val name = node["name"].reactText()
        val field = rememberField(name, "Input", node["value"])
        val type = node["type"].stringOrNull()
        OutlinedField(
            field = field,
            onValueChange = { field.set(FormValue.Str(it)) },
            placeholder = node["placeholder"].stringOrNull(),
            keyboard = keyboardOptions(type),
            visualTransformation = if (InputBehavior.isSecure(type)) {
                PasswordVisualTransformation()
            } else {
                VisualTransformation.None
            },
        )
    }
}

/** `TextArea` — `forms.tsx` L58-79: `minHeight: 28 + rows * 20`, rows default 4. */
internal object TextAreaRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val name = node["name"].reactText()
        val field = rememberField(name, "TextArea", node["value"])
        OutlinedField(
            field = field,
            onValueChange = { field.set(FormValue.Str(it)) },
            placeholder = node["placeholder"].stringOrNull(),
            singleLine = false,
            extraModifier = Modifier.defaultMinSize(
                minHeight = MaterialMetrics.textAreaMinHeight(node["rows"].intOrNull()).dp,
            ),
        )
    }
}

/**
 * `DatePicker` — `forms.tsx` L81-99.
 *
 * RN renders a plain text field with an ISO placeholder rather than a calendar
 * sheet; the port keeps that (a native date dialog would submit a different
 * string shape than the model was told to expect).
 */
internal object DatePickerRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val name = node["name"].reactText()
        val field = rememberField(name, "DatePicker", node["value"])
        OutlinedField(
            field = field,
            onValueChange = { field.set(FormValue.Str(it)) },
            placeholder = if (node["mode"].stringOrNull() == "range") {
                "YYYY-MM-DD → YYYY-MM-DD"
            } else {
                "YYYY-MM-DD"
            },
        )
    }
}

/** `Select` — `forms.tsx` L109-181: outlined trigger + a modal option sheet. */
internal object SelectRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val name = node["name"].reactText()
        val field = rememberField(name, "Select", node["value"])
        var open by remember { mutableStateOf(false) }
        val size = MaterialMetrics.selectSize(node["size"].stringOrNull())
        val options = readSelectItems(node["items"])
        val currentValue = field.value?.textValue
        val selected = options.firstOrNull { it.value == currentValue }

        Row(
            modifier = outlinedFieldModifier(focused = false)
                .clickable { open = true },
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                // `selected?.label ?? props.placeholder ?? "Select…"` — L156.
                text = selected?.label
                    ?: node["placeholder"].stringOrNull()
                    ?: "Select…",
                color = if (selected != null) {
                    t.onSurface.toColor()
                } else {
                    t.onSurfaceVariant.toColor()
                },
                fontSize = size.fontSize.sp,
            )
            LucideIcon(name = "chevron-down", tint = t.onSurfaceVariant.toColor(), size = 18.dp)
        }

        if (open) {
            Dialog(onDismissRequest = { open = false }) {
                Column(
                    Modifier
                        .widthIn(max = 420.dp)
                        .clip(RoundedCornerShape(MaterialMetrics.SELECT_SHEET_RADIUS.dp))
                        .background(t.surfaceContainerHigh.toColor())
                        .padding(vertical = MaterialMetrics.SELECT_SHEET_PADDING_VERTICAL.dp),
                ) {
                    for (option in options) {
                        val isSelected = option.value == currentValue
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(
                                    if (isSelected) {
                                        t.secondaryContainer.toColor()
                                    } else {
                                        Color.Transparent
                                    },
                                )
                                .clickable {
                                    option.value?.let { field.set(FormValue.Str(it)) }
                                    open = false
                                }
                                .defaultMinSize(minHeight = MaterialMetrics.SELECT_OPTION_MIN_HEIGHT.dp)
                                .padding(
                                    horizontal = MaterialMetrics.SELECT_OPTION_PADDING_HORIZONTAL.dp,
                                ),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                // `it.label ?? it.value` — L175.
                                text = option.displayLabel ?: "",
                                color = t.onSurface.toColor(),
                                fontSize = MaterialMetrics.SELECT_OPTION_FONT_SIZE.sp,
                            )
                            if (isSelected) {
                                LucideIcon(
                                    name = "check",
                                    tint = t.primary.toColor(),
                                    size = 17.dp,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * `Slider` — `forms.tsx` L184-232.
 *
 * The default is SEEDED into form state (`props.value ?? props.defaultValue ??
 * [props.min]`), so an untouched slider still submits a value instead of going
 * missing from the payload — and the value is written as a one-element ARRAY,
 * react-lang's range-slider convention.
 */
internal object SliderRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val name = node["name"].reactText()
        val min = node["min"].numberOrNull() ?: 0.0
        val max = node["max"].numberOrNull() ?: 1.0
        val defaults = node["defaultValue"].items().mapNotNull { it.numberOrNull() }

        // `props.value ?? props.defaultValue ?? [props.min]` — L191-195.
        val seed: PropValue = node["value"]
            ?: node["defaultValue"]
            ?: PropValue.Arr(listOf(PropValue.Num(min)))
        val field = rememberField(name, "Slider", seed)

        // `Array.isArray(field.value) ? Number(field.value[0]) : (defaultValue?.[0] ?? min)`
        val current = field.value?.numbersValue?.firstOrNull()
            ?: defaults.firstOrNull()
            ?: min

        val discrete = node["variant"].stringOrNull() == "discrete"
        val step = node["step"].numberOrNull() ?: 1.0
        // Compose counts INTERMEDIATE stops; RN's `step` is the increment.
        val steps = if (discrete && step > 0 && max > min) {
            (((max - min) / step).roundToInt() - 1).coerceAtLeast(0)
        } else {
            0
        }

        Column(verticalArrangement = Arrangement.spacedBy(MaterialMetrics.SLIDER_GAP.dp)) {
            val label = node["label"]
            if (label.isTruthy()) {
                Text(
                    text = label.reactText(),
                    color = t.onSurfaceVariant.toColor(),
                    fontSize = MaterialMetrics.SLIDER_LABEL_FONT_SIZE.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.SLIDER_ROW_GAP.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Slider(
                    value = current.toFloat(),
                    onValueChange = { field.set(FormValue.Numbers(listOf(it.toDouble()))) },
                    valueRange = min.toFloat()..maxOf(max, min).toFloat(),
                    steps = steps,
                    colors = SliderDefaults.colors(
                        thumbColor = t.primary.toColor(),
                        activeTrackColor = t.primary.toColor(),
                        inactiveTrackColor = t.surfaceContainerHigh.toColor(),
                    ),
                    modifier = Modifier.weight(1f),
                )
                Text(
                    // `Math.round(current * 100) / 100` — L221.
                    text = formatSliderValue(current),
                    color = t.onSurfaceVariant.toColor(),
                    fontSize = MaterialMetrics.SLIDER_LABEL_FONT_SIZE.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.End,
                    style = TabularNums,
                    modifier = Modifier.widthIn(min = 36.dp),
                )
            }
        }
    }
}

/** `Math.round(v * 100) / 100`, printed the way JS prints a Number. */
private fun formatSliderValue(value: Double): String {
    val rounded = Math.round(value * 100.0) / 100.0
    return dev.appless.uicore.JsonWriter.number(rounded)
}

/** `FormControl` — `forms.tsx` L235-256. */
internal object FormControlRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        Column(verticalArrangement = Arrangement.spacedBy(MaterialMetrics.FORM_CONTROL_GAP.dp)) {
            Text(
                text = node["label"].reactText(),
                color = t.onSurfaceVariant.toColor(),
                fontSize = MaterialMetrics.FORM_CONTROL_LABEL_FONT_SIZE.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(
                    start = MaterialMetrics.FORM_CONTROL_LABEL_MARGIN_LEFT.dp,
                ),
            )
            RenderNode(node["input"])
            val hint = node["hint"]
            if (hint.isTruthy()) {
                Text(
                    text = hint.reactText(),
                    color = t.onSurfaceVariant.toColor(),
                    fontSize = MaterialMetrics.FORM_CONTROL_LABEL_FONT_SIZE.sp,
                    modifier = Modifier.padding(
                        start = MaterialMetrics.FORM_CONTROL_HINT_MARGIN_LEFT.dp,
                    ),
                )
            }
        }
    }
}

/**
 * `Button` — `forms.tsx` L260-309. M3 mapping: primary -> filled,
 * secondary -> tonal, tertiary -> text; `type: "destructive"` swaps in the
 * error roles.
 *
 * An action-less Button still dispatches: `triggerAction(label, formName,
 * undefined)` falls through to `ui-core`'s default `continue_conversation`
 * carrying the LABEL. This is also the only renderer that passes the enclosing
 * form's name, which is what makes a Form submit its own fields.
 */
internal object ButtonRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        val formName = LocalFormName.current
        val trigger = LocalTriggerAction.current

        val variant = node["variant"].stringOrNull() ?: "primary"
        val destructive = node["type"].stringOrNull() == "destructive"

        val background = when (variant) {
            "primary" -> if (destructive) t.error.toColor() else t.primary.toColor()
            "secondary" -> if (destructive) {
                t.errorContainer.toColor()
            } else {
                t.secondaryContainer.toColor()
            }
            else -> Color.Transparent
        }
        val foreground = when (variant) {
            "primary" -> if (destructive) t.onError.toColor() else t.onPrimary.toColor()
            "secondary" -> if (destructive) {
                t.onErrorContainer.toColor()
            } else {
                t.onSecondaryContainer.toColor()
            }
            else -> if (destructive) t.error.toColor() else t.primary.toColor()
        }
        val compact = MaterialMetrics.isCompactButton(node["size"].stringOrNull())
        // `props.label ?? ""` — the message an ACTION-LESS button sends.
        val label = node["label"].reactText()

        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(MaterialMetrics.BUTTON_RADIUS.dp))
                .background(background)
                .clickable { trigger(label, formName, node["action"].actionPlan()) }
                .defaultMinSize(
                    minHeight = if (compact) {
                        MaterialMetrics.BUTTON_COMPACT_MIN_HEIGHT.dp
                    } else {
                        MaterialMetrics.BUTTON_MIN_HEIGHT.dp
                    },
                )
                .padding(
                    vertical = if (compact) {
                        MaterialMetrics.BUTTON_COMPACT_PADDING_VERTICAL.dp
                    } else {
                        MaterialMetrics.BUTTON_PADDING_VERTICAL.dp
                    },
                    horizontal = if (compact) {
                        MaterialMetrics.BUTTON_COMPACT_PADDING_HORIZONTAL.dp
                    } else {
                        MaterialMetrics.BUTTON_PADDING_HORIZONTAL.dp
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = label,
                color = foreground,
                fontSize = MaterialMetrics.BUTTON_FONT_SIZE.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

/** `Buttons` — `forms.tsx` L311-322: a row of equal-width buttons, or a column. */
internal object ButtonsRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val column = node["direction"].stringOrNull() == "column"
        val buttons = node["buttons"].truthyItems()
        if (column) {
            Column(verticalArrangement = Arrangement.spacedBy(MaterialMetrics.BUTTONS_GAP.dp)) {
                for (button in buttons) RenderNode(button)
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.BUTTONS_GAP.dp)) {
                for (button in buttons) {
                    // `style={column ? undefined : { flex: 1 }}` — L317.
                    Box(Modifier.weight(1f)) { RenderNode(button) }
                }
            }
        }
    }
}

/**
 * `Form` — `forms.tsx` L324-333.
 *
 * The only thing this does beyond layout is scope its descendants' field names
 * to `props.name`, which is what makes two forms on one screen able to use the
 * same field name without colliding, and what decides which slice of state a
 * `Button` inside submits.
 */
internal object FormRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        CompositionLocalProvider(LocalFormName provides node["name"].stringOrNull()) {
            Column(verticalArrangement = Arrangement.spacedBy(MaterialMetrics.FORM_GAP.dp)) {
                for (field in node["fields"].truthyItems()) RenderNode(field)
                RenderNode(node["buttons"])
            }
        }
    }
}
