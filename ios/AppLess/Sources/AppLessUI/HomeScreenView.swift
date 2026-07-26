//
//  HomeScreenView.swift
//  AppLessUI
//
//  The AppLess home: wordmark, the minimized threads as icons, three rotating
//  suggestion lines, and one "ask for anything" pill. Port of
//  `src/genos/shell/HomeScreen.tsx`.
//
//  It stays mounted UNDER an open app (RN keeps it behind the screen layer and
//  memoizes it), which is why the suggestion rotation pauses while `covered`.
//

#if canImport(SwiftUI)

import AppLessCore
import GenOSCore
import SwiftUI

public struct HomeScreenView: View {

    /// Minimized threads, in recency order.
    public let apps: [RunningAppInfo]
    /// True while an app screen is rendered over the home screen.
    public let covered: Bool
    public let topInset: CGFloat
    public let bottomInset: CGFloat
    public let onCommand: (String) -> Void
    public let onResume: (String) -> Void
    public let onClose: (String) -> Void

    @State private var ask: String = ""
    /// The app whose long-press close badge is showing.
    @State private var editingId: String?
    @State private var rotation = SuggestionRotation()

    public init(
        apps: [RunningAppInfo],
        covered: Bool,
        topInset: CGFloat,
        bottomInset: CGFloat,
        onCommand: @escaping (String) -> Void,
        onResume: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void
    ) {
        self.apps = apps
        self.covered = covered
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.onCommand = onCommand
        self.onResume = onResume
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                bottomBlock
            }
            .padding(.top, topInset + CGFloat(ShellChrome.Home.paddingTop))
            .padding(.bottom, bottomInset + CGFloat(ShellChrome.Home.paddingBottom))
        }
        .clipped()
        // Every 4s one suggestion row is swapped; paused under an app screen.
        .task(id: covered) {
            guard !covered else { return }
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: nanoseconds(SuggestionRotation.intervalSeconds))
                if Task.isCancelled { return }
                rotation.advance()
            }
        }
    }

    // MARK: Backdrop

    /// RN uses `assets/home-bg.jpg` behind a 22% black scrim. The package
    /// ships no bitmap, so the wallpaper is the gradient in
    /// `ShellChrome.Home.backdropStops` (see README, known differences).
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: ShellChrome.Home.backdropStops.map { Color($0) },
                startPoint: .top,
                endPoint: .bottom)
            Color(ShellChrome.Home.scrim)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            WordmarkView()
            Text(ShellChrome.Home.taglineText)
                .font(.system(size: ShellChrome.Home.taglineFontSize, weight: .regular))
                .tracking(ShellChrome.Home.taglineLetterSpacing)
                .lineSpacing(
                    max(0, ShellChrome.Home.taglineLineHeight - ShellChrome.Home.taglineFontSize))
                .foregroundStyle(Color(ShellChrome.Home.taglineInk))
                .multilineTextAlignment(.center)
                .padding(.top, ShellChrome.Home.taglineTopMargin)

            if !apps.isEmpty {
                iconGrid
                    .padding(.top, ShellChrome.Home.gridTopMargin)
            }
        }
        .padding(.top, ShellChrome.Home.headerPaddingTop)
        .frame(maxWidth: .infinity)
    }

    private var iconGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: ShellChrome.Home.tileCellWidth),
                        spacing: ShellChrome.Home.gridGap)
                ],
                spacing: ShellChrome.Home.gridGap
            ) {
                ForEach(apps) { app in
                    AppIconView(
                        app: app,
                        editing: editingId == app.id,
                        onPress: {
                            switch HomePresentation.tileTap(isEditing: editingId != nil) {
                            case .dismissEditing: editingId = nil
                            case .resume: onResume(app.id)
                            }
                        },
                        onLongPress: { editingId = app.id },
                        onClose: {
                            onClose(app.id)
                            editingId = nil
                        })
                }
            }
            .padding(.horizontal, ShellChrome.Home.gridPaddingHorizontal)
        }
        .frame(maxHeight: ShellChrome.Home.gridMaxHeight)
    }

    // MARK: Suggestions + ask bar

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: ShellChrome.Home.suggestionBlockGap) {
            let visible = rotation.visible()
            VStack(alignment: .leading, spacing: ShellChrome.Home.suggestionRowGap) {
                ForEach(visible.indices, id: \.self) { index in
                    SuggestionRowView(
                        suggestion: visible[index],
                        covered: covered,
                        onTap: { onCommand(visible[index].command) })
                    // Identity is the ROW, not the suggestion: the row stays
                    // mounted and types the new label in (RN `key={i}`).
                    .id(index)
                }
            }
            .padding(.vertical, ShellChrome.Home.suggestionRowPaddingVertical)
            .padding(.leading, ShellChrome.Home.suggestionRowPaddingLeading)

            askBar
        }
        .padding(.horizontal, ShellChrome.Home.suggestionBlockPaddingHorizontal)
    }

    private var askBar: some View {
        let sendable = ShellChrome.Home.hasSendableText(ask)
        return ZStack(alignment: .trailing) {
            askField(sendable: sendable)
            if sendable {
                Button(action: { submit() }) {
                    Circle()
                        .fill(Color(ShellChrome.Home.sendButtonBackground))
                        .frame(
                            width: ShellChrome.Home.sendButtonSize,
                            height: ShellChrome.Home.sendButtonSize)
                        .overlay {
                            PhosphorIcon(
                                ShellChrome.Home.sendIconPhosphor,
                                size: ShellChrome.Home.sendButtonGlyphSize,
                                tint: Color(ShellChrome.Home.sendButtonInk),
                                weight: .bold)
                        }
                }
                .buttonStyle(SendPressStyle())
                .accessibilityLabel(Text(ShellChrome.Home.sendAccessibilityLabel))
                .padding(.trailing, ShellChrome.Home.sendButtonTrailing)
            }
        }
    }

    private func askField(sendable: Bool) -> some View {
        TextField("", text: $ask)
            .textFieldStyle(.plain)
            .font(.system(size: ShellChrome.Home.askFontSize))
            .foregroundStyle(Color(ShellChrome.Home.askInk))
            .tint(Color(ShellChrome.Home.askInk))
            .autocorrectionDisabled(true)
            .onSubmit { submit() }
            .modifier(AskFieldPlatformModifier())
            .padding(.vertical, ShellChrome.Home.askPaddingVertical)
            .padding(.leading, ShellChrome.Home.askPaddingLeading)
            .padding(
                .trailing,
                sendable
                    ? ShellChrome.Home.askPaddingTrailingWithSend
                    : ShellChrome.Home.askPaddingTrailing
            )
            // SwiftUI has no placeholder color before iOS 17 (README known
            // difference #8): draw it behind the field instead.
            .background(alignment: .leading) {
                if ask.isEmpty {
                    Text(ShellChrome.Home.askPlaceholder)
                        .font(.system(size: ShellChrome.Home.askFontSize))
                        .foregroundStyle(Color(ShellChrome.Home.askPlaceholderInk))
                        .padding(.leading, ShellChrome.Home.askPaddingLeading)
                        .allowsHitTesting(false)
                }
            }
            .appLessGlass(cornerRadius: ShellChrome.Home.askRadius)
    }

    @MainActor
    private func submit() {
        guard let text = ShellChrome.Home.submission(ask) else { return }
        onCommand(text)
        ask = ""
    }
}

/// Keyboard traits that only exist on iOS.
struct AskFieldPlatformModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .submitLabel(.go)
                .textInputAutocapitalization(.never)
        #else
            content
        #endif
    }
}

/// RN `transform: [{ scale: pressed ? 0.88 : 1 }]`.
struct SendPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? ShellChrome.Home.sendButtonPressedScale : 1)
            .contentShape(Circle())
    }
}

// MARK: - Suggestion row

/// One suggestion line. When its suggestion changes the old label fades out
/// and the new one types itself in, character by character. While `covered`
/// the label swaps without animating - there is nothing to see under an app.
struct SuggestionRowView: View {
    let suggestion: Suggestion
    let covered: Bool
    let onTap: () -> Void

    @State private var shown: String = ""
    @State private var fade: Double = 1
    @State private var mounted = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: ShellChrome.Home.suggestionIconGap) {
                PhosphorIcon(
                    HomeTiles.iconsBySuggestionLabel[suggestion.label] ?? HomeTiles.fallbackIcon,
                    size: ShellChrome.Home.suggestionIconSize,
                    tint: Color(ShellChrome.Home.suggestionInk),
                    weight: .regular)
                Text(shown)
                    .font(.system(size: ShellChrome.Home.suggestionFontSize, weight: .regular))
                    .foregroundStyle(Color(ShellChrome.Home.suggestionInk))
            }
            .opacity(fade)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SuggestionPressStyle())
        .task(id: suggestion.label) {
            await swap(to: suggestion.label)
        }
    }

    /// RN `SuggestionRow`'s effect: first mount (and every swap while covered)
    /// shows the label immediately; otherwise fade out for 280ms, then type in
    /// at 45ms per character.
    @MainActor
    private func swap(to label: String) async {
        let isFirstAppearance = !mounted
        mounted = true
        guard HomePresentation.animatesSwap(covered: covered, isFirstAppearance: isFirstAppearance)
        else {
            shown = label
            return
        }
        withAnimation(.linear(duration: ShellChrome.Home.suggestionFadeSeconds)) { fade = 0 }
        try? await Task.sleep(nanoseconds: nanoseconds(ShellChrome.Home.suggestionFadeSeconds))
        if Task.isCancelled { return }
        shown = ""
        fade = 1
        for frame in HomePresentation.typingFrames(for: label) {
            try? await Task.sleep(nanoseconds: nanoseconds(ShellChrome.Home.suggestionTypeSeconds))
            if Task.isCancelled { return }
            shown = frame
        }
    }
}

/// RN `opacity: pressed ? 0.6 : 1`.
struct SuggestionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? ShellChrome.Home.suggestionPressedOpacity : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - App icon

/// An iOS-style icon for a minimized thread: it pops in on mount, long-press
/// reveals the close badge, and tapping the badge ends the session.
struct AppIconView: View {
    let app: RunningAppInfo
    let editing: Bool
    let onPress: () -> Void
    let onLongPress: () -> Void
    let onClose: () -> Void

    @State private var popped = false

    var body: some View {
        VStack(spacing: 0) {
            tile
                .scaleEffect(popped ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { popped = true }
                }
            Text(HomeTiles.oneWordName(app.name))
                .font(.system(size: ShellChrome.Home.tileLabelFontSize, weight: .medium))
                .foregroundStyle(Color(ShellChrome.Home.tileLabelInk))
                .lineLimit(1)
                .frame(maxWidth: ShellChrome.Home.tileLabelMaxWidth)
                .shadow(
                    color: Color(ShellChrome.Home.tileLabelShadow),
                    radius: ShellChrome.Home.tileLabelShadowRadius)
                .padding(.top, ShellChrome.Home.tileLabelTopMargin)
        }
        .frame(width: ShellChrome.Home.tileCellWidth)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPress)
        .onLongPressGesture(perform: onLongPress)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: ShellChrome.Home.tileRadius, style: .continuous)
            .fill(Color(ShellChrome.Home.glassFill))
            .frame(width: ShellChrome.Home.tileSize, height: ShellChrome.Home.tileSize)
            .overlay(
                RoundedRectangle(cornerRadius: ShellChrome.Home.tileRadius, style: .continuous)
                    .stroke(
                        Color(ShellChrome.Home.glassBorder),
                        lineWidth: ShellChrome.Home.glassBorderWidth)
            )
            .overlay {
                PhosphorIcon(
                    HomeTiles.icon(for: app),
                    size: ShellChrome.Home.tileGlyphSize,
                    tint: Color(ShellChrome.Home.tileGlyphInk),
                    weight: .semibold)
            }
            .shadow(
                color: Color(ShellChrome.Home.glassShadow)
                    .opacity(ShellChrome.Home.glassShadowOpacity),
                radius: ShellChrome.Home.glassShadowRadius,
                x: 0,
                y: ShellChrome.Home.glassShadowOffsetY)
            .overlay(alignment: .topLeading) {
                if editing {
                    closeBadge
                        .offset(
                            x: ShellChrome.Home.closeBadgeOffset,
                            y: ShellChrome.Home.closeBadgeOffset)
                }
            }
    }

    private var closeBadge: some View {
        Button(action: onClose) {
            Circle()
                .fill(Color(ShellChrome.Home.closeBadgeBackground))
                .frame(
                    width: ShellChrome.Home.closeBadgeSize,
                    height: ShellChrome.Home.closeBadgeSize)
                .overlay {
                    Text(ShellChrome.Home.closeBadgeGlyph)
                        .font(.system(size: ShellChrome.Home.closeBadgeFontSize, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .buttonStyle(PlainPressStyle())
        .accessibilityLabel(Text(ShellChrome.Home.closeAccessibilityLabel(app.name)))
    }
}

#endif
