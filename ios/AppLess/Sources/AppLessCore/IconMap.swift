//
//  IconMap.swift
//  AppLessCore
//
//  Port of `spec/icon-map.md` - Lucide (and Phosphor, for the home shell) icon
//  names to SF Symbols.
//
//  The model emits Lucide kebab-case names as plain strings in three prop slots
//  (`ListItem.leading` string variant, `Toggle.icon`, `StatTiles.items[].icon`);
//  AppLess itself emits a fixed set of chrome names. Unknown names MUST degrade
//  to a neutral placeholder dot - never crash, never hide the row
//  (spec/icon-map.md §1).
//
//  The tables below are transcribed from the spec's markdown tables;
//  `IconMapTests` re-parses `spec/icon-map.md` on Linux and fails if any row is
//  missing or mismatched.
//
//  NO SwiftUI in this file - `AppLessUI` turns a `.symbol` into
//  `Image(systemName:)` and a `.placeholderDot` into a tinted 8pt dot.
//

import Foundation

/// How an icon name resolved.
public enum IconResolution: Sendable, Equatable {
    /// Draw `Image(systemName: name)`.
    case symbol(String)
    /// Unknown name: draw the neutral placeholder dot (spec/icon-map.md §1) -
    /// an 8x8 view, corner radius 4, filled with the caller-passed tint at
    /// opacity 0.6. No error, no fallback glyph, no text.
    case placeholderDot

    /// The SF Symbol name, or `nil` for the dot fallback.
    public var symbolName: String? {
        if case .symbol(let name) = self { return name }
        return nil
    }

    public var isFallback: Bool { self == .placeholderDot }
}

public enum IconMap {

    // MARK: - Resolution

    /// Resolve a model- or shell-emitted Lucide name to an SF Symbol.
    ///
    /// Name normalization mirrors `kebabToPascal` in `ui/icons.tsx` L10-15 as
    /// far as it is observable: trim, then treat `-`, `_` and space as the same
    /// separator, so `credit_card` and `credit card` resolve like `credit-card`.
    /// Matching is case-insensitive.
    ///
    /// Native ports are NOT required to ship the full Lucide catalogue
    /// (spec/icon-map.md §3): anything outside the tables degrades to
    /// ``IconResolution/placeholderDot``.
    public static func resolve(_ name: String) -> IconResolution {
        guard let symbol = lucideToSFSymbol[normalize(name)] else { return .placeholderDot }
        return .symbol(symbol)
    }

    /// Resolve a Phosphor name used by the home shell (`shell/HomeScreen.tsx`).
    /// Phosphor names are PascalCase and are a different icon family from the
    /// model-facing Lucide set (spec/icon-map.md §5).
    public static func resolvePhosphor(_ name: String) -> IconResolution {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let symbol = phosphorToSFSymbol[key] else { return .placeholderDot }
        return .symbol(symbol)
    }

    /// `"Credit-Card"`, `"credit_card"`, `" credit card "` -> `"credit-card"`.
    public static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .joined(separator: "-")
    }

    // MARK: - Tables

    /// Every Lucide name the spec maps: §2 (73 model-facing names the system
    /// prompt promises) + §3 (5 `ICON_TINT` extras) + §4 (10 app-internal
    /// chrome names) = 88.
    public static let lucideToSFSymbol: [String: String] =
        promptVocabulary
            .merging(tintExtras) { current, _ in current }
            .merging(chromeIcons) { current, _ in current }

    /// spec/icon-map.md §2 - "the prompt's reliable names", 73. Native
    /// renderers MUST resolve all of them. Rows marked `nearest match` have no
    /// exact SF counterpart (spec's `⚠`); revisit in Phase 3/6.
    public static let promptVocabulary: [String: String] = [
        "wifi": "wifi",
        "bluetooth": "wave.3.right",  // nearest match (no exact SF counterpart)
        "signal": "cellularbars",
        "moon": "moon.fill",
        "sun": "sun.max.fill",
        "sun-dim": "sun.min.fill",
        "battery-full": "battery.100percent",
        "hard-drive": "internaldrive.fill",
        "bell": "bell.fill",
        "lock": "lock.fill",
        "shield-check": "checkmark.shield.fill",
        "map-pin": "mappin",
        "navigation": "location.north.fill",
        "plane": "airplane",
        "train": "tram.fill",
        "bus": "bus.fill",
        "car": "car.fill",
        "utensils": "fork.knife",
        "coffee": "cup.and.saucer.fill",
        "pizza": "takeoutbag.and.cup.and.straw.fill",  // nearest match (no exact SF counterpart)
        "wine": "wineglass.fill",
        "cake": "birthday.cake.fill",
        "dumbbell": "dumbbell.fill",
        "heart-pulse": "waveform.path.ecg",
        "flame": "flame.fill",
        "footprints": "shoeprints.fill",
        "credit-card": "creditcard.fill",
        "banknote": "banknote.fill",
        "piggy-bank": "banknote.fill",  // nearest match (no exact SF counterpart)
        "wallet": "wallet.pass.fill",
        "receipt": "receipt",
        "trending-up": "chart.line.uptrend.xyaxis",
        "trending-down": "chart.line.downtrend.xyaxis",
        "arrow-up-right": "arrow.up.right",
        "arrow-down-right": "arrow.down.right",
        "calendar": "calendar",
        "clock": "clock.fill",
        "alarm-clock": "alarm.fill",
        "music": "music.note",
        "headphones": "headphones",
        "mic": "mic.fill",
        "play": "play.fill",
        "camera": "camera.fill",
        "image": "photo.fill",
        "film": "film",
        "message-circle": "message.fill",
        "phone": "phone.fill",
        "mail": "envelope.fill",
        "send": "paperplane.fill",
        "user": "person.fill",
        "users": "person.2.fill",
        "home": "house.fill",
        "building": "building.2.fill",
        "star": "star.fill",
        "gift": "gift.fill",
        "search": "magnifyingglass",
        "settings": "gearshape.fill",
        "zap": "bolt.fill",
        "cloud": "cloud.fill",
        "cloud-rain": "cloud.rain.fill",
        "snowflake": "snowflake",
        "wind": "wind",
        "droplets": "drop.fill",
        "thermometer": "thermometer.medium",
        "umbrella": "umbrella.fill",
        "leaf": "leaf.fill",
        "package": "shippingbox.fill",
        "shopping-bag": "bag.fill",
        "shopping-cart": "cart.fill",
        "truck": "truck.box.fill",
        "book": "book.fill",
        "pen": "pencil",
        "notebook": "book.closed.fill",
    ]

    /// spec/icon-map.md §3 - additional names the RN app special-cases in
    /// `ICON_TINT`; not promised by the prompt but plausible model output.
    public static let tintExtras: [String: String] = [
        "battery": "battery.75percent",
        "battery-charging": "battery.100percent.bolt",
        "bell-ring": "bell.badge.fill",
        "heart": "heart.fill",
        "volume-2": "speaker.wave.2.fill",
    ]

    /// spec/icon-map.md §4 - hard-coded chrome & renderer icons, emitted by
    /// AppLess code and never by the model.
    public static let chromeIcons: [String: String] = [
        "chevron-left": "chevron.left",
        "house": "house.fill",
        "chevron-right": "chevron.right",
        "chevron-down": "chevron.down",
        "chevrons-up-down": "chevron.up.chevron.down",
        "check": "checkmark",
        "info": "info.circle.fill",
        "circle-check": "checkmark.circle.fill",
        "triangle-alert": "exclamationmark.triangle.fill",
        "octagon-alert": "exclamationmark.octagon.fill",
    ]

    /// spec/icon-map.md §5 - home-shell tile & suggestion icons (Phosphor,
    /// filled weight), keyed by Phosphor PascalCase name.
    public static let phosphorToSFSymbol: [String: String] = [
        "ChatCircle": "message.fill",
        "BowlFood": "fork.knife",  // nearest match (no exact SF counterpart)
        "Barbell": "dumbbell.fill",
        "CreditCard": "creditcard.fill",
        "AirplaneTilt": "airplane.departure",
        "CalendarBlank": "calendar",
        "MusicNote": "music.note",
        "SunHorizon": "sun.horizon.fill",
        "Coffee": "cup.and.saucer.fill",
        "CloudSun": "cloud.sun.fill",
        "NotePencil": "square.and.pencil",
        "MapTrifold": "map.fill",
        "GearSix": "gearshape.fill",
        "PersonSimpleRun": "figure.run",
        "Camera": "camera.fill",
        "ShoppingCart": "cart.fill",
        "Heartbeat": "waveform.path.ecg",
        "GameController": "gamecontroller.fill",
        "Book": "book.fill",
        "Car": "car.fill",
        "Globe": "globe",
        "Sparkle": "sparkles",
        "ArrowUp": "arrow.up",
    ]

    /// The app-switcher glyph has no faithful SF equivalent: the RN app draws
    /// two overlapping rounded squares (`AppsIcon`, `ui/icons.tsx`).
    /// spec/icon-map.md §4 suggests this symbol; redraw the shape for exact
    /// parity when the shell chrome is built.
    public static let appsIconSymbolSuggestion = "square.on.square"

    // MARK: - Badge tinting

    /// `BADGE_COLORS`, in order - `ui/icons.tsx` L19-29, spec/icon-map.md §1.
    public static let badgeColors: [CdsColor] = [
        CdsColor("#0a84ff"),  // blue
        CdsColor("#34c759"),  // green
        CdsColor("#ff9f0a"),  // orange
        CdsColor("#af52de"),  // purple
        CdsColor("#ff3b30"),  // red
        CdsColor("#5ac8fa"),  // cyan
        CdsColor("#5e5ce6"),  // indigo
        CdsColor("#ff2d55"),  // pink
        CdsColor("#30b0c7"),  // teal
    ]

    /// `ICON_TINT` - hand-picked tints, `ui/icons.tsx` L31-63.
    public static let iconTintTable: [String: String] = [
        "wifi": "#0a84ff",
        "bluetooth": "#0a84ff",
        "plane": "#ff9f0a",
        "battery-full": "#34c759",
        "battery": "#34c759",
        "battery-charging": "#34c759",
        "moon": "#5e5ce6",
        "bell": "#ff3b30",
        "bell-ring": "#ff3b30",
        "heart": "#ff2d55",
        "heart-pulse": "#ff2d55",
        "flame": "#ff9f0a",
        "credit-card": "#34c759",
        "wallet": "#34c759",
        "map-pin": "#ff3b30",
        "music": "#ff2d55",
        "camera": "#8e8e93",
        "settings": "#8e8e93",
        "lock": "#8e8e93",
        "shield-check": "#34c759",
        "sun": "#ff9f0a",
        "cloud-rain": "#5ac8fa",
        "cloud": "#5ac8fa",
        "droplets": "#5ac8fa",
        "wind": "#30b0c7",
        "message-circle": "#34c759",
        "phone": "#34c759",
        "mail": "#0a84ff",
        "calendar": "#ff3b30",
        "clock": "#ff9f0a",
        "alarm-clock": "#ff9f0a",
        "volume-2": "#ff2d55",
    ]

    /// Port of `iconTint(name)` - `ui/icons.tsx` L65-71, spec/icon-map.md §1
    /// ("must be ported byte-exact").
    ///
    /// Lower-case the name; if it is in ``iconTintTable`` use that color,
    /// otherwise hash `h = (h * 31 + charCodeAt(i)) | 0` with 32-bit signed
    /// overflow semantics over the lower-cased name and pick
    /// `BADGE_COLORS[abs(h) % 9]`.
    ///
    /// - Note: JS lower-cases but does NOT kebab-normalize here, so this takes
    ///   the raw name; `charCodeAt` is a UTF-16 code unit, so the hash iterates
    ///   `String.utf16` rather than `Character`s.
    public static func iconTint(_ name: String) -> CdsColor {
        let key = name.lowercased()
        if let hex = iconTintTable[key] { return CdsColor(hex) }
        var hash: Int32 = 0
        for unit in key.utf16 {
            hash = hash &* 31 &+ Int32(unit)  // `| 0` == wrap to 32-bit signed
        }
        // JS `Math.abs(-2147483648)` is 2147483648 (a Double), so widen to 64
        // bits before taking the magnitude instead of trapping on Int32.min.
        let index = Int(abs(Int64(hash))) % badgeColors.count
        return badgeColors[index]
    }
}
