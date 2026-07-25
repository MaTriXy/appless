//
//  Theme+SwiftUI.swift
//  AppLessUI
//
//  Bridges the platform-independent tokens in `AppLessCore` to SwiftUI types.
//  Nothing here decides a token VALUE - values live in `AppLessCore/Tokens.swift`
//  so Linux CI can pin them against the RN theme.
//

#if canImport(SwiftUI)

import AppLessCore
import SwiftUI

extension Color {
    /// A `CdsColor` as a SwiftUI color, in the sRGB space RN uses.
    public init(_ token: CdsColor) {
        self.init(
            .sRGB,
            red: token.red,
            green: token.green,
            blue: token.blue,
            opacity: token.alpha
        )
    }
}

extension Font.Weight {
    /// The RN numeric weight (`"300"`..`"700"`) as a SwiftUI weight.
    public init(_ weight: CdsMetrics.FontWeight) {
        switch weight {
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        }
    }
}

extension CdsMetrics.TextStyle {
    /// System font at this style's size and weight.
    public var font: Font {
        .system(size: fontSize, weight: Font.Weight(fontWeight))
    }

    /// Extra leading to add so the rendered line box matches RN's absolute
    /// `lineHeight`. SwiftUI's `lineSpacing` is the GAP between lines, not the
    /// line box, so subtract the font size.
    public var lineSpacing: CGFloat {
        guard let lineHeight else { return 0 }
        return max(0, lineHeight - fontSize)
    }
}

extension View {
    /// Apply a Cupertino text style (font, tracking, leading) in one call.
    public func cdsTextStyle(_ style: CdsMetrics.TextStyle) -> some View {
        self.font(style.font)
            .tracking(style.letterSpacing)
            .lineSpacing(style.lineSpacing)
    }
}

/// The active `CdsTheme`, resolved from the environment color scheme exactly
/// like `useCds()` does from `useColorScheme()`.
public struct CdsThemeKey: EnvironmentKey {
    public static let defaultValue: CdsTheme = .light
}

extension EnvironmentValues {
    public var cds: CdsTheme {
        get { self[CdsThemeKey.self] }
        set { self[CdsThemeKey.self] = newValue }
    }
}

extension View {
    /// Install the theme matching `colorScheme` into the environment.
    /// Port of `useCds()` - `cupertino/theme.ts` L69-71.
    public func cdsTheme(colorScheme: ColorScheme) -> some View {
        environment(\.cds, CdsTheme.resolve(isDark: colorScheme == .dark))
    }
}

#endif
