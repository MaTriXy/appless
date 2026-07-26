//
//  ShellChrome.swift
//  AppLessCore
//
//  Every number, color, string and curve the OS shell draws with, lifted out
//  of the SwiftUI views so a Linux test can pin it against `src/genos`.
//
//  The rule this file exists for (README.md, "The Linux/macOS split"): a value
//  is never DECIDED inside `AppLessUI`. The shell views bridge these tokens to
//  SwiftUI; they do not invent any of them.
//
//  Sources:
//    src/genos/GenOS.tsx              chrome buttons, hint, pill, toast, error
//                                     state, skeleton, screen padding, the
//                                     launch/push/pop and minimize transitions
//    src/genos/shell/HomeScreen.tsx   wordmark block, tiles, suggestions, ask bar
//    src/genos/shell/Switcher.tsx     switcher backdrop, cards, previews
//    src/genos/shell/KeyGate.tsx      BYOK gate
//
//  NO SwiftUI in this file.
//

import Foundation
import GenOSCore

// MARK: - Easing

/// A cubic-bezier timing curve, spelled the way RN's `Easing.bezier` takes it.
public struct ShellEasing: Sendable, Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

// MARK: - Transitions

/// The start of a screen transition: the animation always ENDS at
/// `(opacity 1, translate 0, scale 1)`, so only the start state varies
/// (GenOS.tsx `ScreenTransition`, L86-127).
public struct ScreenTransitionGeometry: Sendable, Equatable {
    /// Seconds (RN ms / 1000).
    public let duration: Double
    public let startOpacity: Double
    public let startTranslateX: Double
    public let startTranslateY: Double
    public let startScale: Double

    public init(
        duration: Double,
        startOpacity: Double,
        startTranslateX: Double = 0,
        startTranslateY: Double = 0,
        startScale: Double = 1
    ) {
        self.duration = duration
        self.startOpacity = startOpacity
        self.startTranslateX = startTranslateX
        self.startTranslateY = startTranslateY
        self.startScale = startScale
    }

    public func opacity(at progress: Double) -> Double {
        ShellChrome.lerp(startOpacity, 1, progress)
    }
    public func translateX(at progress: Double) -> Double {
        ShellChrome.lerp(startTranslateX, 0, progress)
    }
    public func translateY(at progress: Double) -> Double {
        ShellChrome.lerp(startTranslateY, 0, progress)
    }
    public func scale(at progress: Double) -> Double {
        ShellChrome.lerp(startScale, 1, progress)
    }
}

// MARK: - Chrome buttons

/// The single top-left chrome button. RN swaps its icon and its action on
/// stack depth: deeper than the root pops, the root minimizes
/// (GenOS.tsx L655-687).
public enum ChromeLeadingButton: Sendable, Equatable {
    case back
    case home

    /// The Lucide name, translated by `IconMap.chromeIcons`.
    public var iconName: String {
        switch self {
        case .back: return "chevron-left"
        case .home: return "house"
        }
    }

    /// RN `accessibilityLabel`.
    public var accessibilityLabel: String {
        switch self {
        case .back: return "Back"
        case .home: return "Home"
        }
    }

    public var symbol: IconResolution { IconMap.resolve(iconName) }
}

// MARK: - Shell chrome tokens

public enum ShellChrome {

    /// RN `Easing.bezier(0.22, 1, 0.32, 1)` - every shell transition uses it.
    public static let standardEasing = ShellEasing(0.22, 1, 0.32, 1)

    /// Linear interpolation, the RN `Animated.interpolate` default for a
    /// two-stop `inputRange` of `[0, 1]`. Progress is clamped, as RN clamps by
    /// default (`extrapolate: "extend"` is never used by the shell).
    public static func lerp(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return from + (to - from) * p
    }

    /// Piecewise interpolation over an arbitrary `inputRange`/`outputRange`
    /// pair (RN `Animated.Value.interpolate`); used by the minimize opacity
    /// ramp, whose input range has three stops.
    public static func interpolate(_ progress: Double, inputRange: [Double], outputRange: [Double])
        -> Double
    {
        guard inputRange.count == outputRange.count, inputRange.count >= 2 else { return progress }
        let p = min(max(progress, inputRange[0]), inputRange[inputRange.count - 1])
        for index in 0..<(inputRange.count - 1) where p <= inputRange[index + 1] {
            let span = inputRange[index + 1] - inputRange[index]
            let t = span == 0 ? 0 : (p - inputRange[index]) / span
            return outputRange[index] + (outputRange[index + 1] - outputRange[index]) * t
        }
        return outputRange[outputRange.count - 1]
    }

    /// The transition a screen mount plays, per `NavDirection`
    /// (GenOS.tsx L91 durations, L97-118 styles).
    public static func transition(_ direction: NavDirection) -> ScreenTransitionGeometry {
        switch direction {
        case .launch:
            // opacity 0→1, translateY 34→0, scale 0.88→1 over 380ms.
            return ScreenTransitionGeometry(
                duration: direction.duration,
                startOpacity: 0,
                startTranslateY: 34,
                startScale: 0.88)
        case .push:
            // opacity 0→1, translateX 56→0 over 300ms.
            return ScreenTransitionGeometry(
                duration: direction.duration,
                startOpacity: 0,
                startTranslateX: 56)
        case .pop:
            // opacity 0.35→1, translateX -44→0 over 260ms.
            return ScreenTransitionGeometry(
                duration: direction.duration,
                startOpacity: 0.35,
                startTranslateX: -44)
        }
    }

    // MARK: Minimize-to-icon

    /// The Home gesture: the open screen shrinks toward the home icon grid
    /// (GenOS.tsx L323-346 + L571-596).
    public enum Minimize {
        /// `Animated.timing(..., duration: 360)`, in seconds.
        public static let duration: Double = 0.360
        /// `scale: [1, 0.08]`.
        public static let endScale: Double = 0.08
        /// The icon grid's offset from the top of the home screen (wordmark
        /// block + margins). RN keeps this in sync with `HomeScreen` by hand.
        public static let iconGridOffset: Double = 230

        /// `translateY: [0, -max(0, winH / 2 - (insets.top + 230))]` - clamped
        /// at 0 so a short or landscape window never animates DOWNWARD.
        public static func endTranslateY(windowHeight: Double, topInset: Double) -> Double {
            -max(0, windowHeight / 2 - (topInset + iconGridOffset))
        }

        public static func translateY(
            at progress: Double, windowHeight: Double, topInset: Double
        ) -> Double {
            lerp(0, endTranslateY(windowHeight: windowHeight, topInset: topInset), progress)
        }

        public static func scale(at progress: Double) -> Double {
            lerp(1, endScale, progress)
        }

        /// `opacity: interpolate([0, 0.8, 1] → [1, 0.85, 0])` - the screen
        /// holds most of its opacity until the very end of the shrink.
        public static func opacity(at progress: Double) -> Double {
            interpolate(progress, inputRange: [0, 0.8, 1], outputRange: [1, 0.85, 0])
        }
    }

    // MARK: Top-left / top-right buttons

    public enum Chrome {
        /// `top: insets.top + 6`, `left/right: 12`.
        public static let insetTop: Double = 6
        public static let insetHorizontal: Double = 12
        public static let buttonSize: Double = 34
        public static let buttonRadius: Double = 17
        public static let borderWidth: Double = 1
        public static let iconSize: Double = 18
        /// RN `strokeWidth={2.4}` (SF Symbols express this as weight - see
        /// README "Known differences" #17).
        public static let iconStrokeWidth: Double = 2.4
        public static let pressedScale: Double = 0.9
        public static let shadowColor = CdsColor("#000000")
        public static let shadowOpacity: Double = 0.07
        public static let shadowRadius: Double = 3
        public static let shadowOffsetY: Double = 1
        /// The switcher button's accessibility label.
        public static let switcherAccessibilityLabel = "App switcher"
        /// `AppsIcon` has no faithful SF Symbol; the shell redraws the two
        /// overlapping rounded squares (`ui/icons.tsx`, spec/icon-map.md §4).
        public static let appsIconSquare: Double = 12
        public static let appsIconRadius: Double = 3.4
        public static let appsIconOffset: Double = 4.5
        public static let appsIconStroke: Double = 1.8
    }

    /// Which button the top-left slot shows: RN `stack.length > 1 ? back : home`.
    public static func leadingButton(stackDepth: Int) -> ChromeLeadingButton {
        stackDepth > 1 ? .back : .home
    }

    // MARK: One-time gesture hint

    public enum Hint {
        /// `setTimeout(() => setShowHint(false), 6000)`.
        public static let visibleSeconds: Double = 6
        /// `bottom: insets.bottom + 46`.
        public static let bottomInset: Double = 46
        public static let paddingVertical: Double = 9
        public static let paddingHorizontal: Double = 16
        public static let radius: Double = 16
        public static let lineGap: Double = 3
        public static let fontSize: Double = 11.5
        public static let background = CdsColor("rgba(20,20,24,0.88)")
        public static let ink = CdsColor("rgba(255,255,255,0.92)")
        /// The two lines, verbatim.
        public static let lines = ["‹ top-left: back / home", "top-right ⧉ : recent apps"]
    }

    // MARK: "materializing…" pill

    public enum Pill {
        /// `bottom: insets.bottom + 34`.
        public static let bottomInset: Double = 34
        public static let gap: Double = 7
        public static let paddingVertical: Double = 5
        public static let paddingHorizontal: Double = 14
        public static let radius: Double = 14
        public static let background = CdsColor("rgba(94,92,230,0.92)")
        public static let ink = CdsColor("#ffffff")
        public static let fontSize: Double = 11.5
        public static let letterSpacing: Double = 0.4
        public static let shadowColor = CdsColor("#5e5ce6")
        public static let shadowOpacity: Double = 0.45
        public static let shadowRadius: Double = 9
        public static let shadowOffsetY: Double = 6
        /// `PulsingDot`: 7pt dot, opacity+scale 1 ⇄ 0.35, 450ms each way.
        public static let dotSize: Double = 7
        public static let dotRadius: Double = 4
        public static let dotMinOpacity: Double = 0.35
        public static let dotPulseSeconds: Double = 0.450
    }

    /// The pill's label: the model is running `web_search` before it composes
    /// (`top?.searching ? "searching the web…" : "materializing…"`).
    public static func generatingLabel(searching: Bool) -> String {
        searching ? "searching the web…" : "materializing…"
    }

    // MARK: Toast

    public enum Toast {
        /// `setTimeout(() => setToast(null), 2800)` - the same constant
        /// `GenOSConstants.toastMs` already pins for the runtime.
        public static let visibleSeconds: Double = GenOSConstants.toastMs / 1000
        /// `top: insets.top + 12`.
        public static let topInset: Double = 12
        /// `maxWidth: "78%"`.
        public static let maxWidthFraction: Double = 0.78
        public static let paddingVertical: Double = 10
        public static let paddingHorizontal: Double = 18
        public static let radius: Double = 20
        public static let background = CdsColor("rgba(20,20,24,0.92)")
        public static let ink = CdsColor("#ffffff")
        public static let fontSize: Double = 13
        public static let shadowColor = CdsColor("#000000")
        public static let shadowOpacity: Double = 0.45
        public static let shadowRadius: Double = 16
        public static let shadowOffsetY: Double = 12
    }

    // MARK: The screen host

    public enum ScreenHost {
        /// `paddingTop: insets.top + 54`.
        public static let contentTopInset: Double = 54
        public static let contentHorizontal: Double = 14
        /// `paddingBottom: 44 + insets.bottom`.
        public static let contentBottomInset: Double = 44
        /// The page gradient behind a screen: light mode fades white into the
        /// theme background over the first 35%, dark mode is flat.
        public static let gradientLightStart = CdsColor("#ffffff")
        public static let gradientMidpoint: Double = 0.35

        /// Error state (`top.status === "error"`).
        public static let errorFallbackMessage = "Generation failed"
        public static let errorGap: Double = 14
        public static let errorPadding: Double = 24
        public static let errorFontSize: Double = 13
        public static let errorInkOpacity: Double = 0.75
        public static let retryLabel = "Retry"
        public static let retryPaddingVertical: Double = 8
        public static let retryPaddingHorizontal: Double = 22
        public static let retryRadius: Double = 18
        public static let retryBackground = CdsColor("#5e5ce6")
        public static let retryInk = CdsColor("#ffffff")
        public static let retryFontSize: Double = 14
    }

    /// The three pulsing placeholder blocks shown until the first token of a
    /// screen arrives (GenOS.tsx `Skeleton`, L155-185).
    public enum Skeleton {
        public struct Block: Sendable, Equatable {
            public let height: Double
            /// Fraction of the available width (RN `"55%"` / `"100%"`).
            public let widthFraction: Double
            public let radius: Double
        }

        public static let blocks: [Block] = [
            Block(height: 30, widthFraction: 0.55, radius: 12),
            Block(height: 150, widthFraction: 1.0, radius: 16),
            Block(height: 188, widthFraction: 1.0, radius: 14),
        ]
        public static let gap: Double = 14
        public static let paddingTop: Double = 6
        public static let paddingHorizontal: Double = 2
        public static let fill = CdsColor("rgba(127,127,140,0.22)")
        public static let minOpacity: Double = 0.4
        public static let pulseSeconds: Double = 0.550
    }

    // MARK: Home screen

    public enum Home {
        /// `paddingTop: topInset + 40`, `paddingBottom: 46`.
        public static let paddingTop: Double = 40
        public static let paddingBottom: Double = 46
        /// The wallpaper scrim that keeps the white type legible.
        public static let scrim = CdsColor("rgba(0,0,0,0.22)")
        /// RN uses `assets/home-bg.jpg`; the package ships no bitmap, so the
        /// backdrop is this gradient unless the host app supplies the asset
        /// (see README "Known differences"). Sampled from the shipped
        /// wallpaper's corners.
        public static let backdropStops: [CdsColor] = [
            CdsColor("#2b2350"),
            CdsColor("#5e4a8f"),
            CdsColor("#c98f7a"),
        ]

        public static let headerPaddingTop: Double = 28
        public static let wordmarkWidth: Double = 170
        public static let wordmarkHeight: Double = 44
        public static let taglineText = "Just ask."
        public static let taglineTopMargin: Double = 4
        public static let taglineFontSize: Double = 24
        public static let taglineLineHeight: Double = 30
        public static let taglineLetterSpacing: Double = -0.5
        public static let taglineInk = CdsColor("rgba(255,255,255,0.5)")

        /// The minimized-app grid.
        public static let gridTopMargin: Double = 100
        public static let gridMaxHeight: Double = 216
        public static let gridGap: Double = 18
        public static let gridPaddingHorizontal: Double = 24
        public static let tileCellWidth: Double = 64
        public static let tileSize: Double = 54
        public static let tileRadius: Double = 13
        public static let tileGlyphSize: Double = 26
        /// `<TileIcon color="#fff" weight="fill" />`.
        public static let tileGlyphInk = CdsColor("#ffffff")
        public static let tilePressedScale: Double = 0.92
        public static let tileLabelTopMargin: Double = 5
        public static let tileLabelMaxWidth: Double = 62
        public static let tileLabelFontSize: Double = 11
        public static let tileLabelInk = CdsColor("rgba(255,255,255,0.9)")
        public static let tileLabelShadow = CdsColor("rgba(0,0,0,0.35)")
        public static let tileLabelShadowRadius: Double = 6
        /// The long-press close badge.
        public static let closeBadgeSize: Double = 20
        public static let closeBadgeOffset: Double = -7
        public static let closeBadgeBackground = CdsColor("rgba(28,28,30,0.92)")
        public static let closeBadgeGlyph = "✕"
        public static let closeBadgeFontSize: Double = 11
        /// RN `accessibilityLabel={`Close ${app.name}`}` - shared with the
        /// switcher's close button.
        public static func closeAccessibilityLabel(_ appName: String) -> String {
            "Close \(appName)"
        }

        /// The frosted surface behind the tiles and the ask bar (`GLASS`).
        public static let glassFill = CdsColor("rgba(255,255,255,0.2)")
        public static let glassBorder = CdsColor("rgba(255,255,255,0.25)")
        public static let glassBorderWidth: Double = 1
        public static let glassShadow = CdsColor("#000000")
        public static let glassShadowOpacity: Double = 0.08
        public static let glassShadowRadius: Double = 4
        public static let glassShadowOffsetY: Double = 2

        /// The suggestion block.
        public static let suggestionBlockGap: Double = 12
        public static let suggestionBlockPaddingHorizontal: Double = 18
        public static let suggestionRowGap: Double = 22
        public static let suggestionRowPaddingVertical: Double = 10
        public static let suggestionRowPaddingLeading: Double = 10
        public static let suggestionIconGap: Double = 10
        public static let suggestionIconSize: Double = 18
        public static let suggestionFontSize: Double = 15
        public static let suggestionInk = CdsColor("rgba(255,255,255,0.85)")
        public static let suggestionPressedOpacity: Double = 0.6
        /// The label swap: fade out over 280ms, then type in at 45ms/char.
        public static let suggestionFadeSeconds: Double = 0.280
        public static let suggestionTypeSeconds: Double = 0.045

        /// The ask bar.
        public static let askPlaceholder = "Ask for anything…"
        public static let askPlaceholderInk = CdsColor("rgba(255,255,255,0.75)")
        public static let askInk = CdsColor("#ffffff")
        public static let askFontSize: Double = 14
        public static let askRadius: Double = 22
        public static let askPaddingVertical: Double = 11
        public static let askPaddingLeading: Double = 18
        /// `paddingRight: ask.trim() ? 48 : 18` - room for the send button.
        public static let askPaddingTrailing: Double = 18
        public static let askPaddingTrailingWithSend: Double = 48
        public static let sendButtonSize: Double = 32
        public static let sendButtonTrailing: Double = 5
        public static let sendButtonBackground = CdsColor("#ffffff")
        public static let sendButtonInk = CdsColor("#1c1c1e")
        public static let sendButtonGlyphSize: Double = 16
        public static let sendButtonPressedScale: Double = 0.88
        public static let sendAccessibilityLabel = "Send"
        /// Phosphor `ArrowUp`, resolved through spec/icon-map.md §5.
        public static let sendIconPhosphor = "ArrowUp"

        /// `ask.trim()` decides both the send button and the trailing padding.
        public static func hasSendableText(_ raw: String) -> Bool {
            !shellTrim(raw).isEmpty
        }

        /// What the ask bar submits: the trimmed text, or nil when blank.
        public static func submission(_ raw: String) -> String? {
            let text = shellTrim(raw)
            return text.isEmpty ? nil : text
        }
    }

    // MARK: Switcher

    public enum Switcher {
        public static let backdrop = CdsColor("rgba(12,12,18,0.88)")
        public static let cardWidth: Double = 188
        public static let cardHeight: Double = 400
        /// Miniatures render at full phone size, scaled down 2×.
        public static let previewScale: Double = 0.5
        public static var previewWidth: Double { cardWidth / previewScale }
        public static var previewHeight: Double { cardHeight / previewScale }
        public static let previewPadding: Double = 10
        public static let cardRadius: Double = 24
        public static let cardGap: Double = 16
        public static let contentPaddingHorizontal: Double = 28
        public static let headerGap: Double = 7
        public static let headerRowGap: Double = 8
        public static let tileSize: Double = 22
        public static let tileRadius: Double = 6
        public static let tileEmojiSize: Double = 12
        public static let nameFontSize: Double = 12.5
        public static let closeButtonSize: Double = 20
        public static let closeButtonFill = CdsColor("rgba(255,255,255,0.25)")
        public static let closeGlyph = "✕"
        public static let closeFontSize: Double = 10
        public static let ink = CdsColor("#ffffff")
        public static let emptyText = "No open apps"
        public static let emptyInk = CdsColor("rgba(255,255,255,0.7)")
        public static let emptyFontSize: Double = 14
        /// The emoji shown when a session has produced no content yet.
        public static let fallbackEmojiSize: Double = 64
        public static let fallbackEmojiOpacity: Double = 0.5
    }

    // MARK: BYOK key gate

    public enum KeyGate {
        public static let title = "AppLess"
        public static let blurb =
            "Every screen is generated the moment you ask - on your own Cerebras API key. It is stored only on this device."
        public static let rejectedNotice = "Cerebras rejected the saved key - paste a valid one."
        public static let placeholder = "csk-…"
        public static let startLabel = "Start"
        public static let savingLabel = "Starting…"
        public static let signupLabel = "Get a free key at cloud.cerebras.ai"
        public static let signupURL = "https://cloud.cerebras.ai"
        public static let accent = CdsColor("#5e5ce6")
        public static let padding: Double = 28
        public static let gap: Double = 14
        public static let titleFontSize: Double = 30
        public static let titleLetterSpacing: Double = -0.5
        public static let blurbFontSize: Double = 14
        public static let blurbMaxWidth: Double = 320
        public static let noticeFontSize: Double = 13
        public static let fieldMaxWidth: Double = 360
        public static let fieldRadius: Double = 12
        public static let fieldPaddingVertical: Double = 12
        public static let fieldPaddingHorizontal: Double = 14
        public static let fieldFontSize: Double = 14
        public static let buttonPaddingVertical: Double = 12
        public static let buttonPaddingHorizontal: Double = 36
        public static let buttonRadius: Double = 22
        public static let buttonFontSize: Double = 15
        public static let disabledOpacity: Double = 0.4
        public static let pressedOpacity: Double = 0.8
        public static let linkFontSize: Double = 13
        /// RN `const valid = value.trim().length >= 10`.
        public static let minimumKeyLength = 10

        /// Whether the Start button is enabled for this field value.
        public static func isSubmittable(_ raw: String) -> Bool {
            shellUTF16Count(shellTrim(raw)) >= minimumKeyLength
        }

        /// The gate is up while the key is missing or was rejected
        /// (`keyStatus === "missing" || keyStatus === "rejected"`); `loading`
        /// and `present` keep it down.
        public static func isPresented(_ status: KeyStatus) -> Bool {
            status == .missing || status == .rejected
        }

        public static func showsRejectedNotice(_ status: KeyStatus) -> Bool {
            status == .rejected
        }

        public static func buttonLabel(saving: Bool) -> String {
            saving ? savingLabel : startLabel
        }
    }
}
