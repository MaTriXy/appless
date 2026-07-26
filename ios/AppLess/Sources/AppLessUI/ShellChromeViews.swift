//
//  ShellChromeViews.swift
//  AppLessUI
//
//  The floating OS chrome drawn over a generated screen: the two round
//  buttons, the one-time gesture hint, the "materializing…" pill and the
//  toast - plus the two small pieces of iconography the shell owns (the
//  Phosphor glyph bridge and the hand-drawn app-switcher square).
//
//  Every number, color and string comes from `AppLessCore.ShellChrome`.
//

#if canImport(SwiftUI)

import AppLessCore
import SwiftUI

// MARK: - Icons

/// A Phosphor icon name (`HomeTiles`, spec/icon-map.md §5) as an SF Symbol,
/// with the same neutral-dot degradation `LucideIcon` uses.
public struct PhosphorIcon: View {
    public let name: String
    public let size: CGFloat
    public let tint: Color
    public let weight: Font.Weight

    public init(_ name: String, size: CGFloat, tint: Color, weight: Font.Weight = .semibold) {
        self.name = name
        self.size = size
        self.tint = tint
        self.weight = weight
    }

    public var body: some View {
        switch IconMap.resolvePhosphor(name) {
        case .symbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
        case .placeholderDot:
            RoundedRectangle(cornerRadius: CdsMetrics.Size.placeholderDotRadius, style: .continuous)
                .fill(tint)
                .opacity(CdsMetrics.Size.placeholderDotOpacity)
                .frame(
                    width: CdsMetrics.Size.placeholderDot,
                    height: CdsMetrics.Size.placeholderDot)
        }
    }
}

/// The app-switcher glyph: two overlapping rounded squares.
///
/// SF Symbols has no faithful equivalent (spec/icon-map.md §4 suggests
/// `square.on.square`, which sits differently), so the shell redraws the RN
/// `AppsIcon` shape.
struct AppsIcon: View {
    let tint: Color
    var side: CGFloat = ShellChrome.Chrome.appsIconSquare

    var body: some View {
        let radius = ShellChrome.Chrome.appsIconRadius
        let offset = ShellChrome.Chrome.appsIconOffset
        let stroke = ShellChrome.Chrome.appsIconStroke
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(tint, lineWidth: stroke)
                .frame(width: side, height: side)
                .offset(x: offset / 2, y: -offset / 2)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(tint, lineWidth: stroke)
                .frame(width: side, height: side)
                .offset(x: -offset / 2, y: offset / 2)
        }
        .frame(width: side + offset, height: side + offset)
    }
}

// MARK: - Round chrome buttons

/// The 34pt circular chrome button (`GenOS.tsx` L655-724).
struct ChromeButton<Glyph: View>: View {
    let theme: CdsTheme
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(theme.chromeBg))
                .frame(
                    width: ShellChrome.Chrome.buttonSize,
                    height: ShellChrome.Chrome.buttonSize)
                .overlay(
                    Circle().stroke(
                        Color(theme.chromeBorder),
                        lineWidth: ShellChrome.Chrome.borderWidth)
                )
                .overlay { glyph() }
                .shadow(
                    color: Color(ShellChrome.Chrome.shadowColor)
                        .opacity(ShellChrome.Chrome.shadowOpacity),
                    radius: ShellChrome.Chrome.shadowRadius,
                    x: 0,
                    y: ShellChrome.Chrome.shadowOffsetY)
        }
        .buttonStyle(ChromePressStyle())
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// RN `transform: [{ scale: pressed ? 0.9 : 1 }]`.
struct ChromePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? ShellChrome.Chrome.pressedScale : 1)
            .contentShape(Circle())
    }
}

/// Top-left: back while the stack is deeper than its root, home at the root.
struct LeadingChromeButton: View {
    let theme: CdsTheme
    let stackDepth: Int
    let action: () -> Void

    var body: some View {
        let button = ShellChrome.leadingButton(stackDepth: stackDepth)
        ChromeButton(theme: theme, accessibilityLabel: button.accessibilityLabel, action: action) {
            LucideIcon(
                button.iconName,
                size: ShellChrome.Chrome.iconSize,
                tint: Color(theme.chromeInk))
        }
    }
}

/// Top-right: the app switcher.
struct SwitcherChromeButton: View {
    let theme: CdsTheme
    let action: () -> Void

    var body: some View {
        ChromeButton(
            theme: theme,
            accessibilityLabel: ShellChrome.Chrome.switcherAccessibilityLabel,
            action: action
        ) {
            AppsIcon(tint: Color(theme.chromeInk))
        }
    }
}

// MARK: - Gesture hint

/// The one-time "here is the chrome" hint, shown for 6s the first time an app
/// opens and dismissible by tapping it.
struct GestureHintView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: ShellChrome.Hint.lineGap) {
            ForEach(ShellChrome.Hint.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: ShellChrome.Hint.fontSize, weight: .semibold))
                    .foregroundStyle(Color(ShellChrome.Hint.ink))
            }
        }
        .padding(.vertical, ShellChrome.Hint.paddingVertical)
        .padding(.horizontal, ShellChrome.Hint.paddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: ShellChrome.Hint.radius, style: .continuous)
                .fill(Color(ShellChrome.Hint.background))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}

// MARK: - Generating pill

/// The pulsing "materializing…" / "searching the web…" pill.
struct GeneratingPillView: View {
    let searching: Bool
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: ShellChrome.Pill.gap) {
            Circle()
                .fill(Color(ShellChrome.Pill.ink))
                .frame(width: ShellChrome.Pill.dotSize, height: ShellChrome.Pill.dotSize)
                .opacity(dimmed ? ShellChrome.Pill.dotMinOpacity : 1)
                .scaleEffect(dimmed ? ShellChrome.Pill.dotMinOpacity : 1)
            Text(ShellChrome.generatingLabel(searching: searching))
                .font(.system(size: ShellChrome.Pill.fontSize, weight: .semibold))
                .tracking(ShellChrome.Pill.letterSpacing)
                .foregroundStyle(Color(ShellChrome.Pill.ink))
        }
        .padding(.vertical, ShellChrome.Pill.paddingVertical)
        .padding(.horizontal, ShellChrome.Pill.paddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: ShellChrome.Pill.radius, style: .continuous)
                .fill(Color(ShellChrome.Pill.background))
        )
        .shadow(
            color: Color(ShellChrome.Pill.shadowColor).opacity(ShellChrome.Pill.shadowOpacity),
            radius: ShellChrome.Pill.shadowRadius,
            x: 0,
            y: ShellChrome.Pill.shadowOffsetY)
        .onAppear {
            withAnimation(
                .easeInOut(duration: ShellChrome.Pill.dotPulseSeconds)
                    .repeatForever(autoreverses: true)
            ) {
                dimmed = true
            }
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: ShellChrome.Toast.fontSize, weight: .semibold))
            .foregroundStyle(Color(ShellChrome.Toast.ink))
            .multilineTextAlignment(.center)
            .padding(.vertical, ShellChrome.Toast.paddingVertical)
            .padding(.horizontal, ShellChrome.Toast.paddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: ShellChrome.Toast.radius, style: .continuous)
                    .fill(Color(ShellChrome.Toast.background))
            )
            .shadow(
                color: Color(ShellChrome.Toast.shadowColor)
                    .opacity(ShellChrome.Toast.shadowOpacity),
                radius: ShellChrome.Toast.shadowRadius,
                x: 0,
                y: ShellChrome.Toast.shadowOffsetY)
            .frame(maxWidth: maxWidth)
    }
}

// MARK: - Frosted glass

extension View {
    /// The `GLASS` surface the home tiles and the ask bar sit on.
    func appLessGlass(cornerRadius: Double) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(ShellChrome.Home.glassFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    Color(ShellChrome.Home.glassBorder),
                    lineWidth: ShellChrome.Home.glassBorderWidth)
        )
        .shadow(
            color: Color(ShellChrome.Home.glassShadow)
                .opacity(ShellChrome.Home.glassShadowOpacity),
            radius: ShellChrome.Home.glassShadowRadius,
            x: 0,
            y: ShellChrome.Home.glassShadowOffsetY)
    }
}

#endif
