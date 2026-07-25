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

    /// The 12 built-in apps. STUB: empty until implementation.
    public static let all: [AppDef] = []

    /// Rotating suggestion chips. STUB: empty until implementation.
    public static let suggestions: [Suggestion] = []

    /// Free-text request → summoned app: id "summon-<slug>" (lower-case,
    /// non-alphanumeric runs → "-"), emoji "✨", default tile, request template.
    public static func summonApp(_ name: String) -> AppDef {
        AppDef(id: "", name: "", emoji: "", tileStart: "", tileEnd: "", request: "") // STUB
    }

    public static func find(id: String) -> AppDef? {
        nil // STUB
    }
}
