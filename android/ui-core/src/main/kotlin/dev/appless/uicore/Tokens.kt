package dev.appless.uicore

import kotlin.math.roundToInt

/**
 * Kotlin port of `src/genos/ui/material/theme.ts` (the Material 3 tonal
 * palette) and `src/genos/theme.android.ts` (the shell-chrome projection of
 * it), plus the Material renderer metrics that live inline in
 * `src/genos/ui/material/components.tsx` and `src/genos/ui/material/forms.tsx`.
 *
 * Every color literal here is byte-identical to the RN source and cites the RN
 * line it was ported from, so drift is a one-line diff. `TokensTest` re-reads
 * the TypeScript on disk and pins a sample of them.
 *
 * NO Compose in this file — the Compose layer bridges [MdColor] to
 * `androidx.compose.ui.graphics.Color`.
 */

// MARK: - Color

/**
 * A design token color, carrying both the exact RN literal it was ported from
 * and its decoded sRGB components.
 *
 * RN colors arrive as either `#rrggbb` hex or `rgba(r,g,b,a)` (0-255 channels,
 * 0-1 alpha); both forms are preserved verbatim in [raw] so tests can compare
 * against the TypeScript source without re-encoding.
 */
public class MdColor(public val raw: String) {

    private val decoded: DoubleArray? = decode(raw)

    /** Red channel, 0..1 sRGB. */
    public val red: Double get() = decoded?.get(0) ?: 0.0

    /** Green channel, 0..1 sRGB. */
    public val green: Double get() = decoded?.get(1) ?: 0.0

    /** Blue channel, 0..1 sRGB. */
    public val blue: Double get() = decoded?.get(2) ?: 0.0

    /** Alpha, 0..1. */
    public val alpha: Double get() = decoded?.get(3) ?: 1.0

    /** `false` when [raw] could not be decoded (a porting mistake; asserted in tests). */
    public val isParsed: Boolean get() = decoded != null

    /** Channels as 0..255 bytes (rounded) — the form the RN hex literals use. */
    public val bytes: Triple<Int, Int, Int>
        get() = Triple(
            (red * 255).roundToInt(),
            (green * 255).roundToInt(),
            (blue * 255).roundToInt(),
        )

    /**
     * `#RRGGBBAA`, lower-cased — a normalized form for comparing an `rgba(...)`
     * token against a hex one.
     */
    public val hex8: String
        get() {
            val (r, g, b) = bytes
            return "#%02x%02x%02x%02x".format(r, g, b, (alpha * 255).roundToInt())
        }

    /** `0xAARRGGBB`, the packed form Compose's `Color(...)` takes. */
    public val argb: Int
        get() {
            val (r, g, b) = bytes
            return ((alpha * 255).roundToInt() shl 24) or (r shl 16) or (g shl 8) or b
        }

    override fun equals(other: Any?): Boolean = other is MdColor && other.raw == raw
    override fun hashCode(): Int = raw.hashCode()
    override fun toString(): String = raw

    private companion object {
        fun decode(s: String): DoubleArray? {
            val t = s.trim().lowercase()
            if (t.startsWith("#")) return decodeHex(t.substring(1))
            if (t.startsWith("rgba(") || t.startsWith("rgb(")) return decodeRgb(t)
            return null
        }

        fun nib(c: Char): Double? {
            val v = Character.digit(c, 16)
            return if (v < 0) null else v.toDouble()
        }

        fun decodeHex(body: String): DoubleArray? {
            val c = body.toCharArray()
            return when (c.size) {
                3, 4 -> {
                    val r = nib(c[0]) ?: return null
                    val g = nib(c[1]) ?: return null
                    val b = nib(c[2]) ?: return null
                    val a = if (c.size == 4) (nib(c[3]) ?: return null) else 15.0
                    doubleArrayOf(r / 15, g / 15, b / 15, a / 15)
                }
                6, 8 -> {
                    fun byte(i: Int): Double? {
                        val hi = nib(c[i]) ?: return null
                        val lo = nib(c[i + 1]) ?: return null
                        return (hi * 16 + lo) / 255
                    }
                    val r = byte(0) ?: return null
                    val g = byte(2) ?: return null
                    val b = byte(4) ?: return null
                    val a = if (c.size == 8) (byte(6) ?: return null) else 1.0
                    doubleArrayOf(r, g, b, a)
                }
                else -> null
            }
        }

        fun decodeRgb(t: String): DoubleArray? {
            val open = t.indexOf('(')
            val close = t.lastIndexOf(')')
            if (open < 0 || close < open) return null
            val parts = t.substring(open + 1, close).split(",").map { it.trim().toDoubleOrNull() }
            if (parts.size != 3 && parts.size != 4) return null
            val r = parts[0] ?: return null
            val g = parts[1] ?: return null
            val b = parts[2] ?: return null
            val a = if (parts.size == 4) (parts[3] ?: return null) else 1.0
            return doubleArrayOf(r / 255, g / 255, b / 255, a)
        }
    }
}

// MARK: - Theme

/**
 * Port of the `MdTheme` interface (`material/theme.ts` L18-40). Field order and
 * doc comments mirror the RN source exactly.
 */
public data class MdTheme(
    /** Screen background. */
    val surface: MdColor,
    /** Card / grouped container surfaces, low -> high emphasis. */
    val surfaceContainerLow: MdColor,
    val surfaceContainer: MdColor,
    val surfaceContainerHigh: MdColor,
    val onSurface: MdColor,
    val onSurfaceVariant: MdColor,
    val outline: MdColor,
    val outlineVariant: MdColor,
    val primary: MdColor,
    val onPrimary: MdColor,
    val primaryContainer: MdColor,
    val onPrimaryContainer: MdColor,
    val secondaryContainer: MdColor,
    val onSecondaryContainer: MdColor,
    val error: MdColor,
    val onError: MdColor,
    val errorContainer: MdColor,
    val onErrorContainer: MdColor,
    /** Semantic accents used by stats/callouts (not core M3 roles). */
    val success: MdColor,
    val successContainer: MdColor,
    val warningContainer: MdColor,
    val onWarningContainer: MdColor,
    /** Pressed-state ripple color. */
    val ripple: MdColor,
    val chartPalette: List<MdColor>,
    val dark: Boolean,
) {
    /** Every color role, keyed by its RN property name — what `TokensTest` walks. */
    public val roles: Map<String, MdColor>
        get() = linkedMapOf(
            "surface" to surface,
            "surfaceContainerLow" to surfaceContainerLow,
            "surfaceContainer" to surfaceContainer,
            "surfaceContainerHigh" to surfaceContainerHigh,
            "onSurface" to onSurface,
            "onSurfaceVariant" to onSurfaceVariant,
            "outline" to outline,
            "outlineVariant" to outlineVariant,
            "primary" to primary,
            "onPrimary" to onPrimary,
            "primaryContainer" to primaryContainer,
            "onPrimaryContainer" to onPrimaryContainer,
            "secondaryContainer" to secondaryContainer,
            "onSecondaryContainer" to onSecondaryContainer,
            "error" to error,
            "onError" to onError,
            "errorContainer" to errorContainer,
            "onErrorContainer" to onErrorContainer,
            "success" to success,
            "successContainer" to successContainer,
            "warningContainer" to warningContainer,
            "onWarningContainer" to onWarningContainer,
            "ripple" to ripple,
        )
}

/**
 * Material 3 design tokens — static tonal palette seeded from the applessOS
 * brand indigo (`#5e5ce6`). Hand-derived M3 tonal values; no runtime HCT math
 * and no dynamic color, matching the RN source (`material/theme.ts` L1-5).
 */
public object Tokens {

    /** `MD_LIGHT` — `src/genos/ui/material/theme.ts` L42-68. */
    public val MD_LIGHT: MdTheme = MdTheme(
        surface = MdColor("#FBF8FF"),                 // theme.ts L43
        surfaceContainerLow = MdColor("#F5F2FC"),     // theme.ts L44
        surfaceContainer = MdColor("#EFECF8"),        // theme.ts L45
        surfaceContainerHigh = MdColor("#E9E7F2"),    // theme.ts L46
        onSurface = MdColor("#1B1B21"),               // theme.ts L47
        onSurfaceVariant = MdColor("#46464F"),        // theme.ts L48
        outline = MdColor("#777680"),                 // theme.ts L49
        outlineVariant = MdColor("#C7C5D0"),          // theme.ts L50
        primary = MdColor("#4F51C0"),                 // theme.ts L51
        onPrimary = MdColor("#FFFFFF"),               // theme.ts L52
        primaryContainer = MdColor("#E1E0FF"),        // theme.ts L53
        onPrimaryContainer = MdColor("#08006C"),      // theme.ts L54
        secondaryContainer = MdColor("#E2E0F9"),      // theme.ts L55
        onSecondaryContainer = MdColor("#1A1A2C"),    // theme.ts L56
        error = MdColor("#BA1A1A"),                   // theme.ts L57
        onError = MdColor("#FFFFFF"),                 // theme.ts L58
        errorContainer = MdColor("#FFDAD6"),          // theme.ts L59
        onErrorContainer = MdColor("#410002"),        // theme.ts L60
        success = MdColor("#146C2E"),                 // theme.ts L61
        successContainer = MdColor("#C6EFC9"),        // theme.ts L62
        warningContainer = MdColor("#FFEFC9"),        // theme.ts L63
        onWarningContainer = MdColor("#4E3D00"),      // theme.ts L64
        ripple = MdColor("rgba(27,27,33,0.12)"),      // theme.ts L65
        chartPalette = listOf(                        // theme.ts L66
            MdColor("#4F51C0"),
            MdColor("#B02F6E"),
            MdColor("#146C2E"),
            MdColor("#8A4F00"),
            MdColor("#00696E"),
            MdColor("#7D4E9E"),
        ),
        dark = false,                                 // theme.ts L67
    )

    /** `MD_DARK` — `src/genos/ui/material/theme.ts` L70-96. */
    public val MD_DARK: MdTheme = MdTheme(
        surface = MdColor("#131318"),                 // theme.ts L71
        surfaceContainerLow = MdColor("#1B1B21"),     // theme.ts L72
        surfaceContainer = MdColor("#1F1F25"),        // theme.ts L73
        surfaceContainerHigh = MdColor("#2A292F"),    // theme.ts L74
        onSurface = MdColor("#E4E1E9"),               // theme.ts L75
        onSurfaceVariant = MdColor("#C7C5D0"),        // theme.ts L76
        outline = MdColor("#918F9A"),                 // theme.ts L77
        outlineVariant = MdColor("#46464F"),          // theme.ts L78
        primary = MdColor("#C0C1FF"),                 // theme.ts L79
        onPrimary = MdColor("#1D1D93"),               // theme.ts L80
        primaryContainer = MdColor("#3739A9"),        // theme.ts L81
        onPrimaryContainer = MdColor("#E1E0FF"),      // theme.ts L82
        secondaryContainer = MdColor("#434258"),      // theme.ts L83
        onSecondaryContainer = MdColor("#E2E0F9"),    // theme.ts L84
        error = MdColor("#FFB4AB"),                   // theme.ts L85
        onError = MdColor("#690005"),                 // theme.ts L86
        errorContainer = MdColor("#93000A"),          // theme.ts L87
        onErrorContainer = MdColor("#FFDAD6"),        // theme.ts L88
        success = MdColor("#8BD592"),                 // theme.ts L89
        successContainer = MdColor("#0F5223"),        // theme.ts L90
        warningContainer = MdColor("#5D4A00"),        // theme.ts L91
        onWarningContainer = MdColor("#FFE9A6"),      // theme.ts L92
        ripple = MdColor("rgba(228,225,233,0.12)"),   // theme.ts L93
        chartPalette = listOf(                        // theme.ts L94
            MdColor("#C0C1FF"),
            MdColor("#FFAFD0"),
            MdColor("#8BD592"),
            MdColor("#F5BD6F"),
            MdColor("#4DD9E2"),
            MdColor("#D6BAF4"),
        ),
        dark = true,                                  // theme.ts L95
    )

    /** `useMd()` — `material/theme.ts` L98-100. */
    public fun theme(dark: Boolean): MdTheme = if (dark) MD_DARK else MD_LIGHT

    /** `useMdChartTheme()` — `material/theme.ts` L103-106. */
    public fun chartTheme(dark: Boolean): ChartTheme {
        val t = theme(dark)
        return ChartTheme(sep = t.outlineVariant, ink2 = t.onSurfaceVariant, chartPalette = t.chartPalette)
    }
}

/** The three roles the shared chart geometry reads — `ui/shared/charts.tsx` `ChartTheme`. */
public data class ChartTheme(
    val sep: MdColor,
    val ink2: MdColor,
    val chartPalette: List<MdColor>,
)

// MARK: - Shell chrome projection

/**
 * `toShellTheme` — `src/genos/theme.android.ts` L13-35.
 *
 * The OS chrome (back pill, apps button, toast, error screen, switcher) is
 * written against the Cupertino `CdsTheme` shape; Android maps Material roles
 * onto it so the chrome matches the Material renderer set with no shell-code
 * changes.
 */
public data class ShellTheme(
    val bg: MdColor,
    val group: MdColor,
    val ink: MdColor,
    val ink2: MdColor,
    val ink3: MdColor,
    val sep: MdColor,
    val fill: MdColor,
    val tint: MdColor,
    val green: MdColor,
    val red: MdColor,
    val bubble: MdColor,
    val chromeBg: MdColor,
    val chromeInk: MdColor,
    val chromeBorder: MdColor,
    val chartPalette: List<MdColor>,
    val dark: Boolean,
) {
    public companion object {
        /** `toShellTheme(dark)` — `theme.android.ts` L13-35. */
        public fun of(dark: Boolean): ShellTheme {
            val m = Tokens.theme(dark)
            return ShellTheme(
                bg = m.surface,                           // theme.android.ts L15
                group = m.surfaceContainer,               // theme.android.ts L16
                ink = m.onSurface,                        // theme.android.ts L17
                ink2 = m.onSurfaceVariant,                // theme.android.ts L18
                ink3 = m.outline,                         // theme.android.ts L19
                sep = m.outlineVariant,                   // theme.android.ts L20
                fill = m.surfaceContainerHigh,            // theme.android.ts L21
                tint = m.primary,                         // theme.android.ts L22
                green = m.success,                        // theme.android.ts L23
                red = m.error,                            // theme.android.ts L24
                bubble = m.surfaceContainerHigh,          // theme.android.ts L25
                chromeBg = m.secondaryContainer,          // theme.android.ts L26
                chromeInk = m.onSecondaryContainer,       // theme.android.ts L27
                chromeBorder = m.outlineVariant,          // theme.android.ts L28
                chartPalette = m.chartPalette,            // theme.android.ts L29
                dark = dark,                              // theme.android.ts L30
            )
        }

        /** `SHELL_LIGHT` — `theme.android.ts` L38. */
        public val LIGHT: ShellTheme = of(false)

        /** `SHELL_DARK` — `theme.android.ts` L39. */
        public val DARK: ShellTheme = of(true)
    }
}

// MARK: - Renderer metrics

/**
 * The spacing, radii and type scale the Material renderers inline in
 * `src/genos/ui/material/components.tsx` and `.../forms.tsx`.
 *
 * These are not in `theme.ts` — they are literals inside the renderer bodies —
 * so they are transcribed here with their RN line so the Compose layer never
 * re-invents a number.
 */
public object MaterialMetrics {

    /** One entry of the `TEXT_STYLES` table (`components.tsx` L82-93). */
    public data class TextStyle(
        val fontSize: Double,
        val lineHeight: Double,
        /** RN `fontWeight`, `null` when the style does not set one. */
        val fontWeight: String? = null,
        val marginBottom: Double = 0.0,
    )

    /** `TEXT_STYLES` — `components.tsx` L82-93. Keys are `TextContent.style`. */
    public val textStyles: Map<String, TextStyle> = linkedMapOf(
        "small" to TextStyle(12.5, 18.0),                                  // components.tsx L83
        "default" to TextStyle(15.0, 22.0),                                // components.tsx L84
        "large" to TextStyle(17.0, 24.0),                                  // components.tsx L85
        "small-heavy" to TextStyle(13.0, 19.0, "500"),                     // components.tsx L86
        "heading" to TextStyle(20.0, 26.0, "500", marginBottom = -6.0),    // components.tsx L87-92
    )

    /**
     * `TEXT_STYLES[props.style ?? "default"] ?? TEXT_STYLES.default` —
     * `components.tsx` L97-98: an unknown style falls back to `default`.
     */
    public fun textStyle(style: String?): TextStyle =
        textStyles[style ?: "default"] ?: textStyles.getValue("default")

    // Card / CardHeader
    /** `Card` children gap and bottom padding — `components.tsx` L54. */
    public const val CARD_GAP: Double = 16.0
    public const val CARD_PADDING_BOTTOM: Double = 8.0
    /** `CardHeader` block padding — `components.tsx` L61. */
    public const val CARD_HEADER_PADDING_TOP: Double = 4.0
    public const val CARD_HEADER_PADDING_HORIZONTAL: Double = 4.0
    /** `CardHeader` subtitle (the M3 overline) — `components.tsx` L65-68. */
    public const val CARD_HEADER_OVERLINE_FONT_SIZE: Double = 12.0
    public const val CARD_HEADER_OVERLINE_LETTER_SPACING: Double = 0.5
    public const val CARD_HEADER_OVERLINE_MARGIN_BOTTOM: Double = 2.0
    /** `CardHeader` title — `components.tsx` L75. */
    public const val CARD_HEADER_TITLE_FONT_SIZE: Double = 28.0
    public const val CARD_HEADER_TITLE_LINE_HEIGHT: Double = 36.0

    // TextCallout
    /** `components.tsx` L136-152. */
    public const val CALLOUT_GAP: Double = 12.0
    public const val CALLOUT_PADDING_VERTICAL: Double = 14.0
    public const val CALLOUT_PADDING_HORIZONTAL: Double = 16.0
    public const val CALLOUT_RADIUS: Double = 12.0
    public const val CALLOUT_TITLE_FONT_SIZE: Double = 14.0
    public const val CALLOUT_TITLE_LINE_HEIGHT: Double = 20.0
    public const val CALLOUT_BODY_FONT_SIZE: Double = 13.0
    public const val CALLOUT_BODY_LINE_HEIGHT: Double = 18.0
    public const val CALLOUT_BODY_OPACITY: Double = 0.85

    /** `CALLOUT_ICON` — `components.tsx` L111-117; the Lucide names §4 maps. */
    public val calloutIcons: Map<String, String> = linkedMapOf(
        "neutral" to "info",                // components.tsx L112
        "info" to "info",                   // components.tsx L113
        "success" to "circle-check",        // components.tsx L114
        "warning" to "triangle-alert",      // components.tsx L115
        "danger" to "octagon-alert",        // components.tsx L116
    )

    // ListItem / Toggle rows
    /** `components.tsx` L174-176 (ListItem) and L234-236 (Toggle). */
    public const val ROW_GAP: Double = 16.0
    public const val ROW_PADDING_VERTICAL: Double = 10.0
    public const val ROW_PADDING_HORIZONTAL: Double = 16.0
    /** ListItem leading avatar — `components.tsx` L186. */
    public const val ROW_AVATAR_SIZE: Double = 48.0
    public const val ROW_AVATAR_RADIUS: Double = 24.0
    /** Bubbles avatar — `components.tsx` L39-41. */
    public const val BUBBLE_AVATAR_SIZE: Double = 40.0
    public const val BUBBLE_AVATAR_RADIUS: Double = 20.0
    /** Row title / subtitle — `components.tsx` L192, L199. */
    public const val ROW_TITLE_FONT_SIZE: Double = 16.0
    public const val ROW_TITLE_LINE_HEIGHT: Double = 24.0
    public const val ROW_SUBTITLE_FONT_SIZE: Double = 13.5
    public const val ROW_SUBTITLE_LINE_HEIGHT: Double = 19.0

    // ListBlock / KVList
    /** ListBlock header — `components.tsx` L272-275. */
    public const val BLOCK_HEADER_FONT_SIZE: Double = 14.0
    public const val BLOCK_HEADER_MARGIN_BOTTOM: Double = 8.0
    public const val BLOCK_HEADER_MARGIN_LEFT: Double = 16.0
    /** Container radius — `components.tsx` L293, L315. */
    public const val BLOCK_RADIUS: Double = 12.0
    public const val LIST_BLOCK_PADDING_VERTICAL: Double = 4.0
    public const val KV_LIST_PADDING_VERTICAL: Double = 6.0
    /** KVList row — `components.tsx` L327-337. */
    public const val KV_ROW_GAP: Double = 16.0
    public const val KV_ROW_PADDING_VERTICAL: Double = 9.0
    public const val KV_ROW_PADDING_HORIZONTAL: Double = 16.0
    public const val KV_ROW_FONT_SIZE: Double = 14.0

    // HeroStat
    /** `components.tsx` L356-382. */
    public const val HERO_PADDING_TOP: Double = 8.0
    public const val HERO_PADDING_BOTTOM: Double = 2.0
    public const val HERO_LABEL_FONT_SIZE: Double = 12.0
    public const val HERO_LABEL_LETTER_SPACING: Double = 0.5
    /** M3 display-large — `components.tsx` L372-374. */
    public const val HERO_VALUE_FONT_SIZE: Double = 57.0
    public const val HERO_VALUE_LINE_HEIGHT: Double = 64.0
    public const val HERO_SUBLABEL_FONT_SIZE: Double = 14.0

    // StatTiles
    /** `components.tsx` L394-434. */
    public const val TILE_GRID_GAP: Double = 10.0
    public const val TILE_RADIUS: Double = 12.0
    public const val TILE_PADDING_VERTICAL: Double = 12.0
    public const val TILE_PADDING_HORIZONTAL: Double = 14.0
    public const val TILE_ICON_GAP: Double = 6.0
    public const val TILE_LABEL_FONT_SIZE: Double = 12.0
    public const val TILE_VALUE_FONT_SIZE: Double = 22.0
    public const val TILE_DELTA_FONT_SIZE: Double = 12.0

    // ImageBlock / PhotoGrid
    /** `components.tsx` L452, L467-472. */
    public const val IMAGE_RADIUS: Double = 16.0
    public const val IMAGE_CAPTION_PADDING_TOP: Double = 28.0
    public const val IMAGE_CAPTION_PADDING_HORIZONTAL: Double = 16.0
    public const val IMAGE_CAPTION_PADDING_BOTTOM: Double = 12.0
    public const val IMAGE_CAPTION_FONT_SIZE: Double = 15.0
    /** `components.tsx` L487-488. */
    public const val PHOTO_GRID_GAP: Double = 3.0
    public const val PHOTO_GRID_RADIUS: Double = 16.0

    // Bubbles
    /** `components.tsx` L505-537. */
    public const val BUBBLE_GAP: Double = 4.0
    public const val BUBBLE_PADDING_VERTICAL: Double = 9.0
    public const val BUBBLE_PADDING_HORIZONTAL: Double = 14.0
    public const val BUBBLE_RADIUS: Double = 18.0
    public const val BUBBLE_FONT_SIZE: Double = 14.5
    public const val BUBBLE_LINE_HEIGHT: Double = 20.0
    public const val BUBBLE_AUTHOR_FONT_SIZE: Double = 11.0

    // Chips
    /** `components.tsx` L560-598 — M3 filter chips. */
    public const val CHIP_ROW_GAP: Double = 8.0
    public const val CHIP_HEIGHT: Double = 32.0
    public const val CHIP_RADIUS: Double = 8.0
    public const val CHIP_ICON_GAP: Double = 6.0
    public const val CHIP_FONT_SIZE: Double = 14.0
    /** Selected chips lose their 1px outline and pad 12 instead of 14 — L585-588. */
    public const val CHIP_PADDING_HORIZONTAL_SELECTED: Double = 12.0
    public const val CHIP_PADDING_HORIZONTAL_UNSELECTED: Double = 14.0
    public const val CHIP_BORDER_WIDTH_UNSELECTED: Double = 1.0

    // Tabs
    /** `components.tsx` L632-658. */
    public const val TAB_PADDING_TOP: Double = 10.0
    public const val TAB_FONT_SIZE: Double = 14.0
    public const val TAB_INDICATOR_HEIGHT: Double = 3.0
    public const val TAB_INDICATOR_MARGIN_TOP: Double = 9.0
    public const val TAB_INDICATOR_MARGIN_HORIZONTAL: Double = 18.0
    public const val TAB_CONTENT_MARGIN_TOP: Double = 14.0
    public const val TAB_CONTENT_GAP: Double = 16.0

    // Outlined text fields (Input / TextArea / DatePicker / Select)
    /** `useOutlinedStyle` — `forms.tsx` L24-35. */
    public const val FIELD_RADIUS: Double = 4.0
    public const val FIELD_FONT_SIZE: Double = 16.0
    public const val FIELD_BORDER_WIDTH_FOCUSED: Double = 2.0
    public const val FIELD_BORDER_WIDTH_RESTING: Double = 1.0
    /** Focused fields shed 1pt of padding to absorb the thicker border — L30-31. */
    public const val FIELD_PADDING_VERTICAL_FOCUSED: Double = 13.0
    public const val FIELD_PADDING_VERTICAL_RESTING: Double = 14.0
    public const val FIELD_PADDING_HORIZONTAL_FOCUSED: Double = 15.0
    public const val FIELD_PADDING_HORIZONTAL_RESTING: Double = 16.0

    /** `TextArea` height: `28 + rows * 20`, `rows` defaulting to 4 — `forms.tsx` L64, L67. */
    public const val TEXT_AREA_DEFAULT_ROWS: Int = 4
    public fun textAreaMinHeight(rows: Int?): Double = 28.0 + (rows ?: TEXT_AREA_DEFAULT_ROWS) * 20.0

    /** One `SELECT_SIZES` row — `forms.tsx` L103-107. */
    public data class SelectSize(val paddingVertical: Double, val fontSize: Double)

    /** `SELECT_SIZES` — `forms.tsx` L103-107. */
    public val selectSizes: Map<String, SelectSize> = linkedMapOf(
        "small" to SelectSize(10.0, 14.0),    // forms.tsx L104
        "medium" to SelectSize(14.0, 16.0),   // forms.tsx L105
        "large" to SelectSize(18.0, 18.0),    // forms.tsx L106
    )

    /** `SELECT_SIZES[props.size ?? "medium"] ?? SELECT_SIZES.medium` — `forms.tsx` L114. */
    public fun selectSize(size: String?): SelectSize =
        selectSizes[size ?: "medium"] ?: selectSizes.getValue("medium")

    /** Select popup sheet — `forms.tsx` L143-175. */
    public const val SELECT_SHEET_PADDING: Double = 36.0
    public const val SELECT_SHEET_RADIUS: Double = 12.0
    public const val SELECT_SHEET_PADDING_VERTICAL: Double = 8.0
    public const val SELECT_OPTION_MIN_HEIGHT: Double = 48.0
    public const val SELECT_OPTION_PADDING_HORIZONTAL: Double = 16.0
    public const val SELECT_OPTION_FONT_SIZE: Double = 15.0

    // Slider / FormControl / Buttons / Form
    /** `forms.tsx` L203-227. */
    public const val SLIDER_GAP: Double = 2.0
    public const val SLIDER_ROW_GAP: Double = 10.0
    public const val SLIDER_TRACK_HEIGHT: Double = 36.0
    public const val SLIDER_LABEL_FONT_SIZE: Double = 13.0
    /** `forms.tsx` L243-249. */
    public const val FORM_CONTROL_GAP: Double = 6.0
    public const val FORM_CONTROL_LABEL_FONT_SIZE: Double = 12.0
    public const val FORM_CONTROL_LABEL_MARGIN_LEFT: Double = 4.0
    public const val FORM_CONTROL_HINT_MARGIN_LEFT: Double = 16.0
    /** M3 full-height pill button — `forms.tsx` L289-305. */
    public const val BUTTON_RADIUS: Double = 20.0
    public const val BUTTON_FONT_SIZE: Double = 14.0
    public const val BUTTON_MIN_HEIGHT: Double = 40.0
    public const val BUTTON_PADDING_VERTICAL: Double = 10.0
    public const val BUTTON_PADDING_HORIZONTAL: Double = 24.0
    /** `size` of `extra-small` / `small` is compact — `forms.tsx` L287, L296-298. */
    public const val BUTTON_COMPACT_MIN_HEIGHT: Double = 32.0
    public const val BUTTON_COMPACT_PADDING_VERTICAL: Double = 6.0
    public const val BUTTON_COMPACT_PADDING_HORIZONTAL: Double = 16.0
    public const val BUTTON_PRESSED_OPACITY: Double = 0.9
    /** `forms.tsx` L314 and L326. */
    public const val BUTTONS_GAP: Double = 10.0
    public const val FORM_GAP: Double = 14.0

    /** `props.size === "extra-small" || props.size === "small"` — `forms.tsx` L287. */
    public fun isCompactButton(size: String?): Boolean = size == "extra-small" || size == "small"

    /** `MapView` corner radius the Material design system passes to the shared renderer. */
    public const val MAP_RADIUS: Double = 16.0
}
