//
//  SwitcherView.swift
//  AppLessUI
//
//  The iOS-style app switcher with live miniature previews of every running
//  session. Port of `src/genos/shell/Switcher.tsx`.
//
//  The miniatures are the REAL renderer output at full phone size, scaled down
//  2× and non-interactive - the same trick the RN version uses, which is why a
//  streaming screen keeps painting inside its card.
//

#if canImport(SwiftUI)

import AppLessCore
import GenOSCore
import OpenUILang
import SwiftUI

struct SwitcherView: View {
    let apps: [RunningAppInfo]
    let theme: CdsTheme
    /// The top screen of a session, or nil when it has none.
    let topScreen: (String) -> Screen?
    /// The resolved tree for a screen id, when one has parsed.
    let root: (String) -> ElementNode?
    let onResume: (String) -> Void
    let onClose: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color(ShellChrome.Switcher.backdrop)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if apps.isEmpty {
                Text(ShellChrome.Switcher.emptyText)
                    .font(.system(size: ShellChrome.Switcher.emptyFontSize))
                    .foregroundStyle(Color(ShellChrome.Switcher.emptyInk))
                    .multilineTextAlignment(.center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: ShellChrome.Switcher.cardGap) {
                        ForEach(apps) { app in
                            card(for: app)
                        }
                    }
                    .padding(.horizontal, ShellChrome.Switcher.contentPaddingHorizontal)
                }
            }
        }
    }

    private func card(for app: RunningAppInfo) -> some View {
        VStack(alignment: .leading, spacing: ShellChrome.Switcher.headerRowGap) {
            header(for: app)
            preview(for: app)
        }
    }

    private func header(for app: RunningAppInfo) -> some View {
        HStack(spacing: ShellChrome.Switcher.headerGap) {
            LinearGradient(
                colors: [Color(CdsColor(app.tileStart)), Color(CdsColor(app.tileEnd))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: ShellChrome.Switcher.tileSize, height: ShellChrome.Switcher.tileSize)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ShellChrome.Switcher.tileRadius, style: .continuous)
            )
            .overlay {
                Text(app.emoji)
                    .font(.system(size: ShellChrome.Switcher.tileEmojiSize))
            }

            Text(app.name)
                .font(.system(size: ShellChrome.Switcher.nameFontSize, weight: .semibold))
                .foregroundStyle(Color(ShellChrome.Switcher.ink))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onClose(app.id)
            } label: {
                Circle()
                    .fill(Color(ShellChrome.Switcher.closeButtonFill))
                    .frame(
                        width: ShellChrome.Switcher.closeButtonSize,
                        height: ShellChrome.Switcher.closeButtonSize
                    )
                    .overlay {
                        Text(ShellChrome.Switcher.closeGlyph)
                            .font(.system(size: ShellChrome.Switcher.closeFontSize))
                            .foregroundStyle(Color(ShellChrome.Switcher.ink))
                    }
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text(ShellChrome.Home.closeAccessibilityLabel(app.name)))
        }
        .frame(width: ShellChrome.Switcher.cardWidth)
    }

    private func preview(for app: RunningAppInfo) -> some View {
        Button {
            onResume(app.id)
        } label: {
            ZStack {
                Color(theme.bg)
                previewContent(for: app)
            }
            .frame(
                width: ShellChrome.Switcher.cardWidth,
                height: ShellChrome.Switcher.cardHeight
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ShellChrome.Switcher.cardRadius, style: .continuous))
        }
        .buttonStyle(PlainPressStyle())
    }

    @ViewBuilder
    private func previewContent(for app: RunningAppInfo) -> some View {
        let screen = topScreen(app.id)
        if let screen, !screen.content.isEmpty, let element = root(screen.id) {
            GenosScreenView(root: element)
                .padding(ShellChrome.Switcher.previewPadding)
                .frame(
                    width: ShellChrome.Switcher.previewWidth,
                    height: ShellChrome.Switcher.previewHeight,
                    alignment: .top
                )
                .background(Color(theme.bg))
                .scaleEffect(ShellChrome.Switcher.previewScale, anchor: .topLeading)
                .frame(
                    width: ShellChrome.Switcher.cardWidth,
                    height: ShellChrome.Switcher.cardHeight,
                    alignment: .topLeading
                )
                .allowsHitTesting(false)
                .clipped()
        } else {
            Text(app.emoji)
                .font(.system(size: ShellChrome.Switcher.fallbackEmojiSize))
                .opacity(ShellChrome.Switcher.fallbackEmojiOpacity)
        }
    }
}

#endif
