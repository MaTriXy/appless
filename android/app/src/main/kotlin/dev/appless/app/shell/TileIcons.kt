package dev.appless.app.shell

/**
 * Home-screen tile iconography — `src/genos/shell/HomeScreen.tsx` L122-190.
 *
 * RN imports Phosphor components directly; the port keeps the same tables but
 * resolves through PHOSPHOR NAMES, which `ui-core`'s `IconMap.resolvePhosphor`
 * maps to Material Symbols (spec/icon-map.md §5). Pure strings in, pure strings
 * out — so the matching order, which is what actually decides the icon, is
 * testable.
 */
public object TileIcons {

    /** `SUGGESTION_ICONS` — `HomeScreen.tsx` L42-53, keyed by suggestion label. */
    public val suggestionIcons: Map<String, String> = linkedMapOf(
        "Order dinner" to "BowlFood",
        "My spending" to "CreditCard",
        "Text Maya" to "ChatCircle",
        "Weekend in Goa" to "AirplaneTilt",
        "My day" to "CalendarBlank",
        "Play something" to "MusicNote",
        "Weather" to "CloudSun",
        "My workouts" to "PersonSimpleRun",
        "Coffee nearby" to "Coffee",
        "New note" to "NotePencil",
    )

    /** `TILE_ICONS` — `HomeScreen.tsx` L123-138, keyed by the app's emoji. */
    public val tileIconsByEmoji: Map<String, String> = linkedMapOf(
        "💬" to "ChatCircle",
        "🍜" to "BowlFood",
        "💪" to "Barbell",
        "💳" to "CreditCard",
        "✈️" to "AirplaneTilt",
        "📅" to "CalendarBlank",
        "🎵" to "MusicNote",
        "🌅" to "SunHorizon",
        "☕" to "Coffee",
        "⛅" to "CloudSun",
        "📝" to "NotePencil",
        "🗺️" to "MapTrifold",
        "⚙️" to "GearSix",
        "🏃" to "PersonSimpleRun",
    )

    /** The fallback for anything unmatched — `Sparkle`, L188. */
    public const val FALLBACK: String = "Sparkle"

    /**
     * `KEYWORD_ICONS` — `HomeScreen.tsx` L145-165.
     *
     * ORDER MATTERS and is preserved verbatim: the first pattern that matches
     * wins, so "coffee trip" is a Coffee tile, not an Airplane one.
     */
    private val keywordIcons: List<Pair<Regex, String>> = listOf(
        Regex("coffee|cafe|chai|tea", RegexOption.IGNORE_CASE) to "Coffee",
        Regex(
            "dinner|food|eat|restaurant|lunch|breakfast|pizza|meal|order|recipe",
            RegexOption.IGNORE_CASE,
        ) to "BowlFood",
        Regex(
            "trip|travel|flight|weekend|vacation|hotel|itinerary|visit",
            RegexOption.IGNORE_CASE,
        ) to "AirplaneTilt",
        Regex("weather|forecast|rain|sunny|temperature", RegexOption.IGNORE_CASE) to "CloudSun",
        Regex("music|song|playlist|radio|dj", RegexOption.IGNORE_CASE) to "MusicNote",
        Regex("workout|gym|fitness|exercise|yoga|steps", RegexOption.IGNORE_CASE) to "Barbell",
        Regex("note|list|todo|grocery|checklist", RegexOption.IGNORE_CASE) to "NotePencil",
        Regex(
            "spend|bank|money|pay|budget|finance|invest|wallet",
            RegexOption.IGNORE_CASE,
        ) to "CreditCard",
        Regex(
            "day|calendar|schedule|meeting|event|remind",
            RegexOption.IGNORE_CASE,
        ) to "CalendarBlank",
        Regex("text|message|chat|call", RegexOption.IGNORE_CASE) to "ChatCircle",
        Regex("map|nearby|direction|route|place", RegexOption.IGNORE_CASE) to "MapTrifold",
        Regex("photo|image|picture|camera", RegexOption.IGNORE_CASE) to "Camera",
        Regex("shop|buy|cart|store|deal", RegexOption.IGNORE_CASE) to "ShoppingCart",
        Regex("health|heart|sleep|meditat|wellness", RegexOption.IGNORE_CASE) to "Heartbeat",
        Regex("game|play", RegexOption.IGNORE_CASE) to "GameController",
        Regex("book|read|novel", RegexOption.IGNORE_CASE) to "Book",
        Regex("car|ride|taxi|uber|drive", RegexOption.IGNORE_CASE) to "Car",
        Regex("news|world|translate", RegexOption.IGNORE_CASE) to "Globe",
        Regex("setting|config", RegexOption.IGNORE_CASE) to "GearSix",
    )

    /**
     * `tileIconFor(app)` — `HomeScreen.tsx` L181-189.
     *
     * Emoji first (a built-in app always hits), then keywords matched against
     * the display name PLUS the id with dashes turned back into spaces (a
     * summoned app's id is a slug of the original typed query).
     */
    public fun tileIcon(name: String, id: String, emoji: String): String {
        tileIconsByEmoji[emoji]?.let { return it }
        val haystack = "$name ${id.replace("-", " ")}"
        for ((pattern, icon) in keywordIcons) {
            if (pattern.containsMatchIn(haystack)) return icon
        }
        return FALLBACK
    }

    /** `SUGGESTION_ICONS[s.label] ?? Sparkle` — L117. */
    public fun suggestionIcon(label: String): String = suggestionIcons[label] ?: FALLBACK

    /**
     * `oneWordName(name)` — `HomeScreen.tsx` L171-176: drop leading filler
     * words and keep the first meaningful one ("Trip Planner" -> "Trip",
     * "My Day" -> "Day").
     */
    public fun oneWordName(name: String): String {
        val words = name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val meaningful = words.filterNot { FILLER.matches(it) }
        return meaningful.firstOrNull() ?: words.firstOrNull() ?: name
    }

    /** `/^(my|the|a|an|your|our|new)$/i` — L174. */
    private val FILLER = Regex("(my|the|a|an|your|our|new)", RegexOption.IGNORE_CASE)
}
