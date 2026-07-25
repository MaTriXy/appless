//
//  Tokens.swift
//  AppLessCore
//
//  Swift port of `src/genos/ui/cupertino/theme.ts` (the RN port of
//  cupertino.css / genos.css custom properties) plus the Cupertino renderer
//  metrics that live inline in `src/genos/ui/cupertino/components.tsx` and
//  `forms.tsx`.
//
//  Every color literal here is byte-identical to the RN source; the RN line is
//  cited next to each token so drift is a one-line diff. `TokensTests` pins a
//  sample of them.
//
//  NO SwiftUI in this file - `AppLessUI` bridges `CdsColor` to `Color`.
//

import Foundation

// MARK: - Color

/// A design token color, carrying both the exact RN literal it was ported from
/// and its decoded sRGB components.
///
/// RN colors arrive as either `#rrggbb` hex or `rgba(r,g,b,a)` (0-255 channels,
/// 0-1 alpha) - both forms are preserved verbatim in ``raw`` so tests can
/// compare against the TypeScript source without re-encoding.
public struct CdsColor: Sendable, Equatable, Hashable {
    /// The literal exactly as written in `cupertino/theme.ts`.
    public let raw: String
    /// Red channel, 0...1 sRGB.
    public let red: Double
    /// Green channel, 0...1 sRGB.
    public let green: Double
    /// Blue channel, 0...1 sRGB.
    public let blue: Double
    /// Alpha, 0...1.
    public let alpha: Double
    /// `false` when ``raw`` could not be decoded (a porting mistake; asserted in tests).
    public let isParsed: Bool

    public init(_ raw: String) {
        self.raw = raw
        if let c = CdsColor.decode(raw) {
            (red, green, blue, alpha, isParsed) = (c.r, c.g, c.b, c.a, true)
        } else {
            (red, green, blue, alpha, isParsed) = (0, 0, 0, 1, false)
        }
    }

    /// Channels as 0...255 bytes (rounded), the form the RN literals use.
    public var bytes: (red: Int, green: Int, blue: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// `#RRGGBBAA`, lower-cased - a normalized form for comparing an
    /// `rgba(...)` token against a hex one.
    public var hex8: String {
        let b = bytes
        return String(format: "#%02x%02x%02x%02x", b.red, b.green, b.blue, Int((alpha * 255).rounded()))
    }

    // MARK: Decoding

    private static func decode(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") { return decodeHex(String(t.dropFirst())) }
        if t.hasPrefix("rgba(") || t.hasPrefix("rgb(") { return decodeRGB(t) }
        return nil
    }

    private static func decodeHex(_ body: String) -> (Double, Double, Double, Double)? {
        let chars = Array(body)
        func nib(_ c: Character) -> Double? { c.hexDigitValue.map(Double.init) }
        switch chars.count {
        case 3, 4:
            guard let r = nib(chars[0]), let g = nib(chars[1]), let b = nib(chars[2]) else { return nil }
            let a = chars.count == 4 ? nib(chars[3]) : 15
            guard let a else { return nil }
            return (r / 15, g / 15, b / 15, a / 15)
        case 6, 8:
            func byte(_ i: Int) -> Double? {
                guard let hi = nib(chars[i]), let lo = nib(chars[i + 1]) else { return nil }
                return (hi * 16 + lo) / 255
            }
            guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
            let a = chars.count == 8 ? byte(6) : 1
            guard let a else { return nil }
            return (r, g, b, a)
        default:
            return nil
        }
    }

    private static func decodeRGB(_ t: String) -> (Double, Double, Double, Double)? {
        guard let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")") else { return nil }
        let parts = t[t.index(after: open)..<close]
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let r = parts[0], let g = parts[1], let b = parts[2] else { return nil }
        let a: Double
        if parts.count == 4 {
            guard let parsed = parts[3] else { return nil }
            a = parsed
        } else {
            a = 1
        }
        return (r / 255, g / 255, b / 255, a)
    }
}

// MARK: - Theme

/// Port of the `CdsTheme` interface (`cupertino/theme.ts` L7-29). Field order
/// and doc comments mirror the RN source exactly.
public struct CdsTheme: Sendable, Equatable {
    /// Screen background behind grouped content.
    public let bg: CdsColor
    /// Grouped-list / card surface.
    public let group: CdsColor
    public let ink: CdsColor
    public let ink2: CdsColor
    public let ink3: CdsColor
    public let sep: CdsColor
    public let fill: CdsColor
    public let tint: CdsColor
    public let green: CdsColor
    public let red: CdsColor
    public let bubble: CdsColor
    /// Shell chrome (back pill, latency chip).
    public let chromeBg: CdsColor
    public let chromeInk: CdsColor
    /// Hairline stroke around chrome buttons - must read on chromeBg in both modes.
    public let chromeBorder: CdsColor
    /// Categorical chart palette - validated against light/dark surfaces.
    public let chartPalette: [CdsColor]
    public let dark: Bool

    /// Every scalar color token, keyed by its RN field name - used by the
    /// parity tests and by any tooling that diffs the port against theme.ts.
    public var colorsByName: [String: CdsColor] {
        [
            "bg": bg, "group": group, "ink": ink, "ink2": ink2, "ink3": ink3,
            "sep": sep, "fill": fill, "tint": tint, "green": green, "red": red,
            "bubble": bubble, "chromeBg": chromeBg, "chromeInk": chromeInk,
            "chromeBorder": chromeBorder,
        ]
    }

    /// The 14 scalar token names in RN declaration order (`theme.ts` L9-25).
    public static let colorTokenNames = [
        "bg", "group", "ink", "ink2", "ink3", "sep", "fill", "tint",
        "green", "red", "bubble", "chromeBg", "chromeInk", "chromeBorder",
    ]
}

extension CdsTheme {
    /// `CDS_LIGHT` - `cupertino/theme.ts` L31-48.
    public static let light = CdsTheme(
        bg: CdsColor("#f2f2f7"),                     // theme.ts L32
        group: CdsColor("#ffffff"),                  // theme.ts L33
        ink: CdsColor("#101013"),                    // theme.ts L34
        ink2: CdsColor("rgba(60,60,67,0.6)"),        // theme.ts L35
        ink3: CdsColor("rgba(60,60,67,0.3)"),        // theme.ts L36
        sep: CdsColor("rgba(60,60,67,0.15)"),        // theme.ts L37
        fill: CdsColor("rgba(120,120,128,0.14)"),    // theme.ts L38
        tint: CdsColor("#007aff"),                   // theme.ts L39
        green: CdsColor("#34c759"),                  // theme.ts L40
        red: CdsColor("#ff3b30"),                    // theme.ts L41
        bubble: CdsColor("#e9e9eb"),                 // theme.ts L42
        chromeBg: CdsColor("rgba(255,255,255,0.9)"), // theme.ts L43
        chromeInk: CdsColor("#1c1c1e"),              // theme.ts L44
        chromeBorder: CdsColor("rgba(0,0,0,0.08)"),  // theme.ts L45
        chartPalette: [                              // theme.ts L46
            CdsColor("#0A84FF"), CdsColor("#C2410C"), CdsColor("#15803D"),
            CdsColor("#BF5AF2"), CdsColor("#FF375F"), CdsColor("#0891B2"),
        ],
        dark: false                                  // theme.ts L47
    )

    /// `CDS_DARK` - `cupertino/theme.ts` L50-67.
    public static let dark = CdsTheme(
        bg: CdsColor("#000000"),                      // theme.ts L51
        group: CdsColor("#1c1c1e"),                   // theme.ts L52
        ink: CdsColor("#f5f5f7"),                     // theme.ts L53
        ink2: CdsColor("rgba(235,235,245,0.62)"),     // theme.ts L54
        ink3: CdsColor("rgba(235,235,245,0.3)"),      // theme.ts L55
        sep: CdsColor("rgba(84,84,88,0.55)"),         // theme.ts L56
        fill: CdsColor("rgba(120,120,128,0.22)"),     // theme.ts L57
        tint: CdsColor("#0a84ff"),                    // theme.ts L58
        green: CdsColor("#34c759"),                   // theme.ts L59
        red: CdsColor("#ff3b30"),                     // theme.ts L60
        bubble: CdsColor("#26262a"),                  // theme.ts L61
        chromeBg: CdsColor("rgba(58,58,66,0.92)"),    // theme.ts L62
        chromeInk: CdsColor("#ffffff"),               // theme.ts L63
        chromeBorder: CdsColor("rgba(255,255,255,0.16)"), // theme.ts L64
        chartPalette: [                               // theme.ts L65
            CdsColor("#3B82F6"), CdsColor("#D97706"), CdsColor("#16A34A"),
            CdsColor("#A855F7"), CdsColor("#F43F5E"), CdsColor("#0284C7"),
        ],
        dark: true                                    // theme.ts L66
    )

    /// Port of `useCds()` (`cupertino/theme.ts` L69-71):
    /// `useColorScheme() === "dark" ? CDS_DARK : CDS_LIGHT`.
    ///
    /// The RN hook reads the OS color scheme; on the Swift side the caller
    /// supplies it (SwiftUI passes `\.colorScheme == .dark`), keeping this
    /// function platform-independent and unit-testable on Linux.
    public static func resolve(isDark: Bool) -> CdsTheme { isDark ? .dark : .light }
}

// MARK: - Metrics

/// Geometry and typography constants for the Cupertino design system.
///
/// `cupertino/theme.ts` only carries colors; radii, spacing and type scale live
/// inline in the renderers, so they are collected here with their source lines
/// and are identical in light and dark (the RN styles never branch on `dark`).
public enum CdsMetrics {

    // MARK: Radii

    public enum Radius {
        /// Segmented-control pill inside Tabs. components.tsx L649.
        public static let segment: Double = 8
        /// Icon badge in a ListItem row (29x29). components.tsx L41.
        public static let iconBadge: Double = 7
        /// Leading image thumbnail in a ListItem (42x42). components.tsx L194.
        public static let thumbnail: Double = 9
        /// Tabs segmented-control track. components.tsx L637.
        public static let segmentTrack: Double = 10
        /// Input / TextArea field. forms.tsx L33.
        public static let field: Double = 12
        /// Toggle knob (24x24). components.tsx L269.
        public static let toggleKnob: Double = 12
        /// Grouped surface: ListBlock, KVList, StatTiles tile, TextCallout,
        /// Select sheet, Button. components.tsx L147/L314/L332/L425, forms.tsx L138/L254.
        public static let group: Double = 14
        /// TextCallout leading icon disc (28x28). components.tsx L155.
        public static let calloutIcon: Double = 14
        /// Toggle track (47x28). components.tsx L259.
        public static let toggleTrack: Double = 15
        /// ImageBlock / PhotoGrid. components.tsx L468, L516.
        public static let media: Double = 16
        /// Chip pill. components.tsx L602.
        public static let chip: Double = 17
        /// Chat bubble. components.tsx L555 (tail corner is 6).
        public static let bubble: Double = 18
        /// Chat-bubble tail corner. components.tsx L557-558.
        public static let bubbleTail: Double = 6
    }

    // MARK: Spacing

    public enum Spacing {
        /// Gap between the Card's children. components.tsx L56.
        public static let cardGap: Double = 15
        /// Card bottom padding. components.tsx L56.
        public static let cardPaddingBottom: Double = 8
        /// CardHeader padding: top / bottom / horizontal. components.tsx L63.
        public static let headerPaddingTop: Double = 18
        public static let headerPaddingBottom: Double = 14
        public static let headerPaddingHorizontal: Double = 2
        /// TextCallout padding + icon gap. components.tsx L143-146.
        public static let calloutGap: Double = 11
        public static let calloutPaddingVertical: Double = 12
        public static let calloutPaddingHorizontal: Double = 14
        /// StatTiles tile padding. components.tsx L426-427.
        public static let tilePaddingVertical: Double = 11
        public static let tilePaddingHorizontal: Double = 13
        /// Input / TextArea padding. forms.tsx L34-35.
        public static let fieldPaddingVertical: Double = 12
        public static let fieldPaddingHorizontal: Double = 14
        /// Button padding: regular / compact vertical, horizontal. forms.tsx L255-256.
        public static let buttonPaddingVertical: Double = 13
        public static let buttonPaddingVerticalCompact: Double = 9
        public static let buttonPaddingHorizontal: Double = 18
        /// Chat bubble padding. components.tsx L553-554.
        public static let bubblePaddingVertical: Double = 8
        public static let bubblePaddingHorizontal: Double = 13
        /// Chip padding. components.tsx L600-601.
        public static let chipPaddingVertical: Double = 7
        public static let chipPaddingHorizontal: Double = 14
        /// PhotoGrid inter-tile gap. components.tsx L514.
        public static let photoGridGap: Double = 2.5
    }

    // MARK: Sizes

    public enum Size {
        /// ListItem icon badge. components.tsx L38-39.
        public static let iconBadge: Double = 29
        /// Glyph inside the icon badge, and its stroke width. components.tsx L46.
        public static let iconBadgeGlyph: Double = 15
        public static let iconBadgeStrokeWidth: Double = 2.2
        /// ListItem leading thumbnail. components.tsx L194.
        public static let thumbnail: Double = 42
        /// TextCallout icon disc. components.tsx L153-154.
        public static let calloutIcon: Double = 28
        /// Toggle track and knob. components.tsx L257-258, L266-267.
        public static let toggleTrackWidth: Double = 47
        public static let toggleTrackHeight: Double = 28
        public static let toggleKnob: Double = 24
        /// `LucideIcon` default size / stroke width. icons.tsx L74-77.
        public static let iconDefault: Double = 17
        public static let iconStrokeWidthDefault: Double = 2
        /// Unknown-icon placeholder dot. spec/icon-map.md §1, icons.tsx.
        public static let placeholderDot: Double = 8
        public static let placeholderDotRadius: Double = 4
        public static let placeholderDotOpacity: Double = 0.6
        /// ImageBlock aspect ratio. components.tsx L470.
        public static let imageBlockAspectRatio: Double = 16.0 / 9.0
    }

    // MARK: Typography

    /// A font weight as RN spells it ("300".."700"), with the SwiftUI/UIKit
    /// numeric equivalent so `AppLessUI` never re-derives the mapping.
    public enum FontWeight: String, Sendable, CaseIterable {
        case light = "300"
        case regular = "400"
        case medium = "500"
        case semibold = "600"
        case bold = "700"

        public var numericValue: Int { Int(rawValue)! }
    }

    /// One text style: size, line height, weight, tracking.
    public struct TextStyle: Sendable, Equatable {
        public let fontSize: Double
        public let lineHeight: Double?
        public let fontWeight: FontWeight
        public let letterSpacing: Double

        public init(
            fontSize: Double,
            lineHeight: Double? = nil,
            fontWeight: FontWeight = .regular,
            letterSpacing: Double = 0
        ) {
            self.fontSize = fontSize
            self.lineHeight = lineHeight
            self.fontWeight = fontWeight
            self.letterSpacing = letterSpacing
        }
    }

    public enum Typography {
        /// CardHeader subtitle (uppercased). components.tsx L67-71.
        public static let headerSubtitle = TextStyle(
            fontSize: 12, fontWeight: .semibold, letterSpacing: 0.6)
        /// CardHeader title. components.tsx L80-83.
        public static let headerTitle = TextStyle(
            fontSize: 56, lineHeight: 60, fontWeight: .light, letterSpacing: -1.5)
        /// HeroStat label (uppercased). components.tsx L375-378.
        public static let heroLabel = TextStyle(
            fontSize: 12, fontWeight: .semibold, letterSpacing: 1)
        /// HeroStat value. components.tsx L388-391.
        public static let heroValue = TextStyle(
            fontSize: 56, lineHeight: 60, fontWeight: .light, letterSpacing: -1.5)
        /// HeroStat caption. components.tsx L399.
        public static let heroCaption = TextStyle(fontSize: 14, fontWeight: .medium)
        /// Grouped-list section header. components.tsx L296-298.
        public static let groupHeader = TextStyle(
            fontSize: 12, fontWeight: .semibold, letterSpacing: 0.5)
        /// TextCallout title / body. components.tsx L165, L169.
        public static let calloutTitle = TextStyle(fontSize: 14, lineHeight: 19, fontWeight: .semibold)
        public static let calloutBody = TextStyle(fontSize: 13, lineHeight: 18)
        /// ListItem / Toggle title, subtitle, trailing value.
        /// components.tsx L200, L207, L214.
        public static let rowTitle = TextStyle(fontSize: 15, lineHeight: 20, fontWeight: .medium)
        public static let rowSubtitle = TextStyle(fontSize: 12.5, lineHeight: 17)
        public static let rowTrailing = TextStyle(fontSize: 14.5)
        /// KVList key / value. components.tsx L346, L350-351.
        public static let kvKey = TextStyle(fontSize: 14)
        public static let kvValue = TextStyle(fontSize: 14.5, fontWeight: .medium)
        /// StatTiles label / value / delta. components.tsx L434, L440-442, L450.
        public static let tileLabel = TextStyle(fontSize: 12, fontWeight: .semibold)
        public static let tileValue = TextStyle(fontSize: 21, fontWeight: .bold, letterSpacing: -0.4)
        public static let tileDelta = TextStyle(fontSize: 12, fontWeight: .semibold)
        /// ImageBlock caption. components.tsx L491-493.
        public static let imageCaption = TextStyle(fontSize: 15, fontWeight: .semibold, letterSpacing: -0.2)
        /// Bubbles author / body. components.tsx L542-543, L562.
        public static let bubbleAuthor = TextStyle(fontSize: 11, fontWeight: .medium)
        public static let bubbleBody = TextStyle(fontSize: 14.5, lineHeight: 20)
        /// Chip label. components.tsx L610-611.
        public static let chip = TextStyle(fontSize: 13, fontWeight: .semibold)
        /// Tabs segment label. components.tsx L664.
        public static let tab = TextStyle(fontSize: 13, fontWeight: .semibold)
        /// FormControl label / hint. forms.tsx L220, L225.
        public static let fieldLabel = TextStyle(fontSize: 13, fontWeight: .semibold)
        public static let fieldHint = TextStyle(fontSize: 12)
        /// Input / TextArea text. forms.tsx L36.
        public static let fieldText = TextStyle(fontSize: 15)
        /// Button label: regular / compact. forms.tsx L263.
        public static let button = TextStyle(fontSize: 15, fontWeight: .semibold)
        public static let buttonCompact = TextStyle(fontSize: 13.5, fontWeight: .semibold)

        /// `TEXT_STYLES` - the TextContent `style` prop table.
        /// components.tsx L93-103.
        public static let textContent: [String: TextStyle] = [
            "small": TextStyle(fontSize: 12.5, lineHeight: 18),
            "default": TextStyle(fontSize: 15, lineHeight: 22),
            "large": TextStyle(fontSize: 17, lineHeight: 24),
            "small-heavy": TextStyle(fontSize: 13, lineHeight: 19, fontWeight: .semibold),
            "large-heavy": TextStyle(fontSize: 20, lineHeight: 26, fontWeight: .bold, letterSpacing: -0.3),
        ]
        /// `large-heavy` also carries `marginBottom: -6`. components.tsx L103.
        public static let largeHeavyMarginBottom: Double = -6

        /// Unknown/missing `style` falls back to `default`. components.tsx L108.
        public static func textContentStyle(_ name: String?) -> TextStyle {
            textContent[name ?? "default"] ?? textContent["default"]!
        }

        /// `SELECT_SIZES` - the Select `size` prop table. forms.tsx L95-99.
        public static let selectSizes: [String: (paddingVertical: Double, fontSize: Double)] = [
            "small": (8, 13),
            "medium": (12, 15),
            "large": (15, 17),
        ]
    }
}
