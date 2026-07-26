package dev.appless.uicore

/**
 * Port of `spec/icon-map.md` — Lucide (and Phosphor, for the home shell) icon
 * names to **Material Symbols**.
 *
 * The model emits Lucide kebab-case names as plain strings in three prop slots
 * (`ListItem.leading` string variant, `Toggle.icon`, `StatTiles.items[].icon`);
 * AppLess itself emits a fixed set of chrome names. Unknown names MUST degrade
 * to a neutral placeholder dot — never crash, never hide the row
 * (spec/icon-map.md §1).
 *
 * The tables below are transcribed from the spec's markdown tables (Material
 * Symbol column — the SF Symbols column is the iOS port's);
 * `IconMapTest` re-parses `spec/icon-map.md` and fails if any row is missing or
 * mismatched.
 *
 * NO Compose in this file — the Compose layer turns a [IconResolution.Symbol]
 * into a Material Symbols glyph and a [IconResolution.PlaceholderDot] into a
 * tinted 8dp dot.
 */
public sealed interface IconResolution {
    /** Draw the Material Symbols glyph named [name] (rounded/filled per §0). */
    public data class Symbol(val name: String) : IconResolution

    /**
     * Unknown name: draw the neutral placeholder dot (spec/icon-map.md §1) — an
     * 8x8 view, corner radius 4, filled with the caller-passed tint at opacity
     * 0.6. No error, no fallback glyph, no text.
     */
    public data object PlaceholderDot : IconResolution

    /** The Material Symbols name, or `null` for the dot fallback. */
    public val symbolName: String?
        get() = (this as? Symbol)?.name

    public val isFallback: Boolean
        get() = this === PlaceholderDot
}

public object IconMap {

    // ---------------------------------------------------------------- resolve

    /**
     * Resolve a model- or shell-emitted Lucide name to a Material Symbol.
     *
     * Name normalization mirrors `kebabToPascal` in `ui/icons.tsx` L10-15 as far
     * as it is observable: trim, then treat `-`, `_` and space as the same
     * separator, so `credit_card` and `credit card` resolve like `credit-card`.
     * Matching is case-insensitive.
     *
     * Native ports are NOT required to ship the full Lucide catalogue
     * (spec/icon-map.md §3): anything outside the tables degrades to
     * [IconResolution.PlaceholderDot].
     */
    public fun resolve(name: String): IconResolution {
        val symbol = lucideToMaterial[normalize(name)] ?: return IconResolution.PlaceholderDot
        return IconResolution.Symbol(symbol)
    }

    /**
     * Resolve a Phosphor name used by the home shell (`shell/HomeScreen.tsx`).
     * Phosphor names are PascalCase and are a different icon family from the
     * model-facing Lucide set (spec/icon-map.md §5).
     */
    public fun resolvePhosphor(name: String): IconResolution {
        val symbol = phosphorToMaterial[name.trim()] ?: return IconResolution.PlaceholderDot
        return IconResolution.Symbol(symbol)
    }

    /** `"Credit-Card"`, `"credit_card"`, `" credit card "` -> `"credit-card"`. */
    public fun normalize(name: String): String =
        name.trim()
            .lowercase()
            .split('-', '_', ' ')
            .filter { it.isNotEmpty() }
            .joinToString("-")

    // ----------------------------------------------------------------- tables

    /**
     * Every Lucide name the spec maps: §2 (73 model-facing names the system
     * prompt promises) + §3 (5 `ICON_TINT` extras) + §4 (10 app-internal chrome
     * names) = 88.
     */
    public val lucideToMaterial: Map<String, String> by lazy {
        LinkedHashMap<String, String>().apply {
            putAll(promptVocabulary)
            for ((k, v) in tintExtras) putIfAbsent(k, v)
            for ((k, v) in chromeIcons) putIfAbsent(k, v)
        }
    }

    /**
     * spec/icon-map.md §2 — "the prompt's reliable names", 73. Native renderers
     * MUST resolve all of them. Rows the spec marks `⚠` have no exact Material
     * counterpart (only `notebook` on the Material side); revisit in Phase 3/6.
     */
    public val promptVocabulary: Map<String, String> = linkedMapOf(
        "wifi" to "wifi",
        "bluetooth" to "bluetooth",
        "signal" to "signal_cellular_alt",
        "moon" to "dark_mode",
        "sun" to "light_mode",
        "sun-dim" to "brightness_low",
        "battery-full" to "battery_full",
        "hard-drive" to "hard_drive",
        "bell" to "notifications",
        "lock" to "lock",
        "shield-check" to "verified_user",
        "map-pin" to "location_on",
        "navigation" to "navigation",
        "plane" to "flight",
        "train" to "train",
        "bus" to "directions_bus",
        "car" to "directions_car",
        "utensils" to "restaurant",
        "coffee" to "local_cafe",
        "pizza" to "local_pizza",
        "wine" to "wine_bar",
        "cake" to "cake",
        "dumbbell" to "fitness_center",
        "heart-pulse" to "monitor_heart",
        "flame" to "local_fire_department",
        "footprints" to "footprint",
        "credit-card" to "credit_card",
        "banknote" to "payments",
        "piggy-bank" to "savings",
        "wallet" to "wallet",
        "receipt" to "receipt_long",
        "trending-up" to "trending_up",
        "trending-down" to "trending_down",
        "arrow-up-right" to "north_east",
        "arrow-down-right" to "south_east",
        "calendar" to "calendar_today",
        "clock" to "schedule",
        "alarm-clock" to "alarm",
        "music" to "music_note",
        "headphones" to "headphones",
        "mic" to "mic",
        "play" to "play_arrow",
        "camera" to "photo_camera",
        "image" to "image",
        "film" to "movie",
        "message-circle" to "chat_bubble",
        "phone" to "call",
        "mail" to "mail",
        "send" to "send",
        "user" to "person",
        "users" to "group",
        "home" to "home",
        "building" to "apartment",
        "star" to "star",
        "gift" to "redeem",
        "search" to "search",
        "settings" to "settings",
        "zap" to "bolt",
        "cloud" to "cloud",
        "cloud-rain" to "rainy",
        "snowflake" to "ac_unit",
        "wind" to "air",
        "droplets" to "water_drop",
        "thermometer" to "device_thermostat",
        "umbrella" to "umbrella",
        "leaf" to "eco",
        "package" to "package_2",
        "shopping-bag" to "shopping_bag",
        "shopping-cart" to "shopping_cart",
        "truck" to "local_shipping",
        "book" to "menu_book",
        "pen" to "edit",
        "notebook" to "auto_stories", // ⚠ nearest match (spec §2)
    )

    /**
     * spec/icon-map.md §3 — additional names the RN app special-cases in
     * `ICON_TINT`; not promised by the prompt but plausible model output.
     */
    public val tintExtras: Map<String, String> = linkedMapOf(
        "battery" to "battery_std",
        "battery-charging" to "battery_charging_full",
        "bell-ring" to "notifications_active",
        "heart" to "favorite",
        "volume-2" to "volume_up",
    )

    /**
     * spec/icon-map.md §4 — hard-coded chrome & renderer icons, emitted by
     * AppLess code and never by the model.
     */
    public val chromeIcons: Map<String, String> = linkedMapOf(
        "chevron-left" to "arrow_back_ios_new",
        "house" to "home",
        "chevron-right" to "chevron_right",
        "chevron-down" to "expand_more",
        "chevrons-up-down" to "unfold_more",
        "check" to "check",
        "info" to "info",
        "circle-check" to "check_circle",
        "triangle-alert" to "warning",
        "octagon-alert" to "report",
    )

    /**
     * spec/icon-map.md §5 — home-shell tile & suggestion icons (Phosphor,
     * filled weight), keyed by Phosphor PascalCase name.
     */
    public val phosphorToMaterial: Map<String, String> = linkedMapOf(
        "ChatCircle" to "chat_bubble",
        "BowlFood" to "ramen_dining",
        "Barbell" to "fitness_center",
        "CreditCard" to "credit_card",
        "AirplaneTilt" to "flight_takeoff",
        "CalendarBlank" to "calendar_today",
        "MusicNote" to "music_note",
        "SunHorizon" to "wb_twilight",
        "Coffee" to "local_cafe",
        "CloudSun" to "partly_cloudy_day",
        "NotePencil" to "edit_note",
        "MapTrifold" to "map",
        "GearSix" to "settings",
        "PersonSimpleRun" to "directions_run",
        "Camera" to "photo_camera",
        "ShoppingCart" to "shopping_cart",
        "Heartbeat" to "monitor_heart",
        "GameController" to "sports_esports",
        "Book" to "menu_book",
        "Car" to "directions_car",
        "Globe" to "public",
        "Sparkle" to "auto_awesome",
        "ArrowUp" to "arrow_upward",
    )

    /**
     * The app-switcher glyph has no faithful Material equivalent: the RN app
     * draws two overlapping rounded squares (`AppsIcon`, `ui/icons.tsx`).
     * spec/icon-map.md §4 suggests this symbol; redraw the shape for exact
     * parity when the shell chrome is built.
     */
    public const val APPS_ICON_SYMBOL_SUGGESTION: String = "select_window"

    /**
     * Placeholder-dot geometry, `ui/icons.tsx` `LucideIcon` fallback branch —
     * an 8x8 view, `borderRadius 4`, tint at `opacity 0.6`.
     */
    public const val PLACEHOLDER_DOT_SIZE: Double = 8.0
    public const val PLACEHOLDER_DOT_RADIUS: Double = 4.0
    public const val PLACEHOLDER_DOT_OPACITY: Double = 0.6

    /** Default icon size / stroke width the RN renderer uses — `ui/icons.tsx` L74-76. */
    public const val DEFAULT_ICON_SIZE: Double = 17.0
    public const val DEFAULT_STROKE_WIDTH: Double = 2.0

    // --------------------------------------------------------- badge tinting

    /** `BADGE_COLORS`, in order — `ui/icons.tsx` L19-29, spec/icon-map.md §1. */
    public val badgeColors: List<MdColor> = listOf(
        MdColor("#0a84ff"), // blue    — icons.tsx L20
        MdColor("#34c759"), // green   — icons.tsx L21
        MdColor("#ff9f0a"), // orange  — icons.tsx L22
        MdColor("#af52de"), // purple  — icons.tsx L23
        MdColor("#ff3b30"), // red     — icons.tsx L24
        MdColor("#5ac8fa"), // cyan    — icons.tsx L25
        MdColor("#5e5ce6"), // indigo  — icons.tsx L26
        MdColor("#ff2d55"), // pink    — icons.tsx L27
        MdColor("#30b0c7"), // teal    — icons.tsx L28
    )

    /** `ICON_TINT` — hand-picked tints, `ui/icons.tsx` L31-63. */
    public val iconTintTable: Map<String, String> = linkedMapOf(
        "wifi" to "#0a84ff",
        "bluetooth" to "#0a84ff",
        "plane" to "#ff9f0a",
        "battery-full" to "#34c759",
        "battery" to "#34c759",
        "battery-charging" to "#34c759",
        "moon" to "#5e5ce6",
        "bell" to "#ff3b30",
        "bell-ring" to "#ff3b30",
        "heart" to "#ff2d55",
        "heart-pulse" to "#ff2d55",
        "flame" to "#ff9f0a",
        "credit-card" to "#34c759",
        "wallet" to "#34c759",
        "map-pin" to "#ff3b30",
        "music" to "#ff2d55",
        "camera" to "#8e8e93",
        "settings" to "#8e8e93",
        "lock" to "#8e8e93",
        "shield-check" to "#34c759",
        "sun" to "#ff9f0a",
        "cloud-rain" to "#5ac8fa",
        "cloud" to "#5ac8fa",
        "droplets" to "#5ac8fa",
        "wind" to "#30b0c7",
        "message-circle" to "#34c759",
        "phone" to "#34c759",
        "mail" to "#0a84ff",
        "calendar" to "#ff3b30",
        "clock" to "#ff9f0a",
        "alarm-clock" to "#ff9f0a",
        "volume-2" to "#ff2d55",
    )

    /**
     * The raw 32-bit signed hash `iconTint` computes — `ui/icons.tsx` L68-69,
     * spec/icon-map.md §1 ("must be ported byte-exact").
     *
     * `h = (h * 31 + key.charCodeAt(i)) | 0` with 32-bit signed overflow
     * semantics over the LOWER-CASED name. JS does not kebab-normalize here, so
     * this takes the raw name; `charCodeAt` is a UTF-16 code unit, which is
     * exactly what Kotlin's `Char` is, so iterating the `String` is faithful
     * (including surrogate pairs, which contribute two units).
     */
    public fun tintHash(name: String): Int {
        var h = 0
        for (c in name.lowercase()) h = h * 31 + c.code // Int is 32-bit two's complement == `| 0`
        return h
    }

    /**
     * Port of `iconTint(name)` — `ui/icons.tsx` L65-71.
     *
     * Lower-case the name; if it is in [iconTintTable] use that color,
     * otherwise pick `BADGE_COLORS[abs(h) % 9]`.
     *
     * Note: JS `Math.abs(-2147483648)` is `2147483648` (a Double), so the
     * magnitude is taken in 64 bits rather than overflowing back to
     * `Int.MIN_VALUE`.
     */
    public fun iconTint(name: String): MdColor {
        val key = name.lowercase()
        iconTintTable[key]?.let { return MdColor(it) }
        val index = (Math.abs(tintHash(key).toLong()) % badgeColors.size).toInt()
        return badgeColors[index]
    }
}
