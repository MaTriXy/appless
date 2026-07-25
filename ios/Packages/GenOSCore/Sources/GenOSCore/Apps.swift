import Foundation

/// App catalog (src/genos/apps.ts).
public struct AppDef: Sendable, Equatable {
    public var id: String
    public var name: String
    public var emoji: String
    /// Gradient stops for the icon tile.
    public var tileStart: String
    public var tileEnd: String
    /// The request sent to the model to open the app's home screen.
    public var request: String

    public init(id: String, name: String, emoji: String, tileStart: String, tileEnd: String, request: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.tileStart = tileStart
        self.tileEnd = tileEnd
        self.request = request
    }
}

public struct Suggestion: Sendable, Equatable {
    public var emoji: String
    public var label: String
    public var command: String

    public init(emoji: String, label: String, command: String) {
        self.emoji = emoji
        self.label = label
        self.command = command
    }
}

public enum Apps {
    public static let defaultTileStart = "#5e5ce6"
    public static let defaultTileEnd = "#bf5af2"

    /// The 12 built-in apps (verbatim from src/genos/apps.ts).
    public static let all: [AppDef] = [
        AppDef(
            id: "messages", name: "Messages", emoji: "💬",
            tileStart: "#34c759", tileEnd: "#28a745",
            request: "Open the \"Messages\" app home screen: an inbox list of 7 conversations with contact names, last message snippets, timestamps, and a compose button."
        ),
        AppDef(
            id: "food", name: "Food", emoji: "🍜",
            tileStart: "#ff9f0a", tileEnd: "#ff6b22",
            request: "Open the \"Food\" delivery app home screen: hero image, cuisine filter chips, and a list of popular restaurants with ratings, delivery times, and thumbnail images."
        ),
        AppDef(
            id: "fitness", name: "Fitness", emoji: "💪",
            tileStart: "#ff375f", tileEnd: "#c2185b",
            request: "Open the \"Fitness\" app home screen: today's activity stats, a weekly workout bar chart, and a list of recent workouts with durations and calories."
        ),
        AppDef(
            id: "banking", name: "Banking", emoji: "💳",
            tileStart: "#30d158", tileEnd: "#0a84ff",
            request: "Open the \"Banking\" app home screen: current balance, a monthly spending line chart, spending category chips, and a list of recent transactions with merchants and amounts."
        ),
        AppDef(
            id: "flights", name: "Flights", emoji: "✈️",
            tileStart: "#0a84ff", tileEnd: "#5e5ce6",
            request: "Open the \"Flights\" app home screen: an upcoming flight status card with route and gate, plus a list of cheap weekend destinations with prices and thumbnail images."
        ),
        AppDef(
            id: "calendar", name: "Calendar", emoji: "📅",
            tileStart: "#ff453a", tileEnd: "#ff9f0a",
            request: "Open the \"Calendar\" app home screen: today's date header and a list of 6 events for today with times, titles, locations, and a new-event button."
        ),
        AppDef(
            id: "music", name: "Music", emoji: "🎵",
            tileStart: "#bf5af2", tileEnd: "#ff375f",
            request: "Open the \"Music\" app home screen: a now-playing section with album art image, playback buttons, and a list of playlists and recently played albums with cover images."
        ),
        AppDef(
            id: "photos", name: "Photos", emoji: "🌅",
            tileStart: "#64d2ff", tileEnd: "#5e5ce6",
            request: "Open the \"Photos\" app home screen: a memories highlight image, an image gallery of 6 recent photos, and a tappable albums list (Summer, Food, Friends...) with photo counts."
        ),
        AppDef(
            id: "weather", name: "Weather", emoji: "⛅",
            tileStart: "#5ac8fa", tileEnd: "#007aff",
            request: "Open the \"Weather\" app home screen: current conditions for Bengaluru with a big temperature, an hourly temperature area chart, and a 5-day forecast list."
        ),
        AppDef(
            id: "notes", name: "Notes", emoji: "📝",
            tileStart: "#ffd60a", tileEnd: "#ff9f0a",
            request: "Open the \"Notes\" app home screen: a search field, pinned note callout, and a list of 6 notes with titles, snippets, and edited timestamps, plus a new-note button."
        ),
        AppDef(
            id: "maps", name: "Maps", emoji: "🗺️",
            tileStart: "#32d74b", tileEnd: "#0a84ff",
            request: "Open the \"Maps\" app home screen: a search field, a MapView of the Bengaluru city center, and a nearby places list with categories, distances, and ratings."
        ),
        AppDef(
            id: "settings", name: "Settings", emoji: "⚙️",
            tileStart: "#8e8e93", tileEnd: "#48484a",
            request: "Open the \"Settings\" app home screen: a profile row, then settings rows for Wi-Fi, Display, Sound, Battery, and Privacy with current-state subtitles."
        ),
    ]

    /// Rotating suggestion chips phrased as spoken commands (apps.ts).
    public static let suggestions: [Suggestion] = [
        Suggestion(emoji: "🍜", label: "Order dinner", command: "order some dinner from a great place nearby"),
        Suggestion(emoji: "💳", label: "My spending", command: "show my spending this month"),
        Suggestion(emoji: "💬", label: "Text Maya", command: "text Maya that I'm running 15 minutes late"),
        Suggestion(emoji: "✈️", label: "Weekend in Goa", command: "plan a weekend trip to Goa"),
        Suggestion(emoji: "📅", label: "My day", command: "what does my day look like"),
        Suggestion(emoji: "🎵", label: "Play something", command: "play something upbeat"),
        Suggestion(emoji: "⛅", label: "Weather", command: "what's the weather this week"),
        Suggestion(emoji: "🏃", label: "My workouts", command: "show my workouts this week"),
        Suggestion(emoji: "🗺️", label: "Coffee nearby", command: "find a good coffee shop near me"),
        Suggestion(emoji: "📝", label: "New note", command: "start a note for my grocery list"),
    ]

    /// Free-text request → summoned app: id "summon-<slug>" (lower-case,
    /// non-alphanumeric runs → "-", boundary dashes KEPT per the RN regex),
    /// emoji "✨", default tile, request template.
    public static func summonApp(_ name: String) -> AppDef {
        let slug = JSRegex.replacingAll("[^a-z0-9]+", in: name.lowercased(), with: "-")
        return AppDef(
            id: "summon-\(slug)",
            name: name,
            emoji: "✨",
            tileStart: defaultTileStart,
            tileEnd: defaultTileEnd,
            request: "Open an app called \"\(name)\". Invent a plausible, polished home screen for it with realistic content and tappable rows or buttons for its main features."
        )
    }

    public static func find(id: String) -> AppDef? {
        all.first { $0.id == id }
    }
}
