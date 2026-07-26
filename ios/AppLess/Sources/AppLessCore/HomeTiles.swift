//
//  HomeTiles.swift
//  AppLessCore
//
//  The home screen's icon + label decisions (HomeScreen.tsx): which glyph a
//  minimized thread gets, and the one-word label under it.
//
//  RN picks a Phosphor icon; the names are kept as the Phosphor PascalCase
//  keys so `IconMap.phosphorToSFSymbol` (spec/icon-map.md §5) does the
//  SF Symbol translation - the choice and the mapping stay separately
//  testable, and the mapping is already pinned against the spec.
//
//  NO SwiftUI in this file.
//

import Foundation

public enum HomeTiles {

    /// RN `Sparkle` - the fallback for a summoned thread nothing matched.
    public static let fallbackIcon = "Sparkle"

    /// `TILE_ICONS` - app emoji → filled Phosphor icon.
    public static let iconsByEmoji: [String: String] = [
        "💬": "ChatCircle",
        "🍜": "BowlFood",
        "💪": "Barbell",
        "💳": "CreditCard",
        "✈️": "AirplaneTilt",
        "📅": "CalendarBlank",
        "🎵": "MusicNote",
        "🌅": "SunHorizon",
        "☕": "Coffee",
        "⛅": "CloudSun",
        "📝": "NotePencil",
        "🗺️": "MapTrifold",
        "⚙️": "GearSix",
        "🏃": "PersonSimpleRun",
    ]

    /// `SUGGESTION_ICONS` - suggestion label → Phosphor icon.
    public static let iconsBySuggestionLabel: [String: String] = [
        "Order dinner": "BowlFood",
        "My spending": "CreditCard",
        "Text Maya": "ChatCircle",
        "Weekend in Goa": "AirplaneTilt",
        "My day": "CalendarBlank",
        "Play something": "MusicNote",
        "Weather": "CloudSun",
        "My workouts": "PersonSimpleRun",
        "Coffee nearby": "Coffee",
        "New note": "NotePencil",
    ]

    /// `KEYWORD_ICONS`, IN ORDER - first match wins, so the table's order is
    /// part of the behavior (e.g. "coffee" beats "order").
    public static let keywordIcons: [(pattern: String, icon: String)] = [
        ("coffee|cafe|chai|tea", "Coffee"),
        ("dinner|food|eat|restaurant|lunch|breakfast|pizza|meal|order|recipe", "BowlFood"),
        ("trip|travel|flight|weekend|vacation|hotel|itinerary|visit", "AirplaneTilt"),
        ("weather|forecast|rain|sunny|temperature", "CloudSun"),
        ("music|song|playlist|radio|dj", "MusicNote"),
        ("workout|gym|fitness|exercise|yoga|steps", "Barbell"),
        ("note|list|todo|grocery|checklist", "NotePencil"),
        ("spend|bank|money|pay|budget|finance|invest|wallet", "CreditCard"),
        ("day|calendar|schedule|meeting|event|remind", "CalendarBlank"),
        ("text|message|chat|call", "ChatCircle"),
        ("map|nearby|direction|route|place", "MapTrifold"),
        ("photo|image|picture|camera", "Camera"),
        ("shop|buy|cart|store|deal", "ShoppingCart"),
        ("health|heart|sleep|meditat|wellness", "Heartbeat"),
        ("game|play", "GameController"),
        ("book|read|novel", "Book"),
        ("car|ride|taxi|uber|drive", "Car"),
        ("news|world|translate", "Globe"),
        ("setting|config", "GearSix"),
    ]

    /// The `i`-flag keyword patterns, spelled as case variants (ICU folding
    /// would also match U+212A/U+017F, which JS's `i` does not).
    private static let compiledKeywordIcons: [(pattern: String, icon: String)] =
        keywordIcons.map { entry in
            (
                entry.pattern.split(separator: "|")
                    .map { ShellRegex.caseInsensitive(String($0)) }
                    .joined(separator: "|"),
                entry.icon
            )
        }

    /// RN `tileIconFor`: the emoji table first, then the keyword table against
    /// "<name> <id with dashes as spaces>", then Sparkle.
    public static func icon(name: String, emoji: String, appId: String) -> String {
        if let byEmoji = iconsByEmoji[emoji] { return byEmoji }
        let haystack = "\(name) \(ShellRegex.replacingAll("-", in: appId, with: " "))"
        for entry in compiledKeywordIcons where ShellRegex.test(entry.pattern, haystack) {
            return entry.icon
        }
        return fallbackIcon
    }

    public static func icon(for app: RunningAppInfo) -> String {
        icon(name: app.name, emoji: app.emoji, appId: app.id)
    }

    /// The SF Symbol a tile draws, via spec/icon-map.md §5.
    public static func symbol(for app: RunningAppInfo) -> IconResolution {
        IconMap.resolvePhosphor(icon(for: app))
    }

    /// RN `oneWordName`: drop leading filler words and keep the first
    /// meaningful one - "Trip Planner" → "Trip", "My Day" → "Day".
    ///
    /// RN: name.trim().split(/\s+/) then filter(!/^(my|the|a|an|your|our|new)$/i).
    public static func oneWordName(_ name: String) -> String {
        // RN splits on /\s+/ after trimming; do the same over the full JS
        // whitespace set rather than the space character alone.
        let parts = splitOnJSWhitespace(shellTrim(name))
        let filler = "\\A(" + ["my", "the", "a", "an", "your", "our", "new"]
            .map(ShellRegex.caseInsensitive).joined(separator: "|") + ")\\z"
        let meaningful = parts.filter { !ShellRegex.test(filler, $0) }
        return meaningful.first ?? parts.first ?? name
    }

    /// JS `s.split(/\s+/)` for an already-trimmed string.
    private static func splitOnJSWhitespace(_ s: String) -> [String] {
        guard !s.isEmpty else { return [""] }
        var parts: [String] = []
        var current = ""
        var inRun = false
        for scalar in s.unicodeScalars {
            if isShellWhitespace(scalar) {
                if !inRun {
                    parts.append(current)
                    current = ""
                    inRun = true
                }
            } else {
                current.unicodeScalars.append(scalar)
                inRun = false
            }
        }
        parts.append(current)
        return parts
    }

    /// ECMAScript StrWhiteSpace membership (the `\s` set).
    private static func isShellWhitespace(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{2028}", "\u{2029}", "\u{FEFF}":
            return true
        default:
            return c.properties.generalCategory == .spaceSeparator
        }
    }
}
