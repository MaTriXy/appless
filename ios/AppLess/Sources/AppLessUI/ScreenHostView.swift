//
//  ScreenHostView.swift
//  AppLessUI
//
//  One generated screen, from the first frame to the last token:
//
//      pending, no content  → the pulsing skeleton
//      streaming / done     → `GenosScreenView` over the resolved tree
//      error                → the message plus Retry
//
//  Plus the direction-aware transition a screen mount plays (launch zooms up,
//  push slides in from the right, pop settles back from the left) - the
//  geometry and durations come from `AppLessCore.ShellChrome`.
//

#if canImport(SwiftUI)

import AppLessCore
import GenOSCore
import OpenUILang
import SwiftUI

// MARK: - Transition

/// Replays one nav transition when its content mounts. The shell keys this on
/// the top screen id (`ScreenTransition key={topId}` in RN), so a new screen
/// remounts it and the animation runs again.
struct ScreenTransitionContainer<Content: View>: View {
    let direction: NavDirection
    let content: () -> Content

    @State private var progress: Double = 0

    init(direction: NavDirection, @ViewBuilder content: @escaping () -> Content) {
        self.direction = direction
        self.content = content
    }

    var body: some View {
        let geometry = ShellChrome.transition(direction)
        content()
            .scaleEffect(geometry.scale(at: progress))
            .offset(
                x: geometry.translateX(at: progress),
                y: geometry.translateY(at: progress))
            .opacity(geometry.opacity(at: progress))
            .onAppear {
                withAnimation(.shellStandard(duration: geometry.duration)) { progress = 1 }
            }
    }
}

// MARK: - Screen host

struct ScreenHostView: View {
    let screen: Screen
    /// The resolved root element, or nil while nothing has parsed yet.
    let root: ElementNode?
    let theme: CdsTheme
    let topInset: CGFloat
    let bottomInset: CGFloat
    let actions: GenosActionDispatcher
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            pageGradient
            switch ScreenHostPresentation.state(
                isError: screen.status == .error, hasRoot: root != nil, error: screen.error)
            {
            case .error(let message):
                errorState(message: message)
            case .skeleton, .content:
                content
            }
        }
    }

    /// RN `LinearGradient(colors: t.dark ? [bg, bg] : ["#ffffff", bg],
    /// locations: [0, 0.35])`.
    private var pageGradient: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(
                    color: Color(
                        theme.dark ? theme.bg : ShellChrome.ScreenHost.gradientLightStart),
                    location: 0),
                Gradient.Stop(
                    color: Color(theme.bg),
                    location: ShellChrome.ScreenHost.gradientMidpoint),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var content: some View {
        ScrollView {
            Group {
                if let root {
                    GenosScreenView(root: root, actions: actions)
                } else {
                    SkeletonView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topInset + CGFloat(ShellChrome.ScreenHost.contentTopInset))
            .padding(.horizontal, ShellChrome.ScreenHost.contentHorizontal)
            .padding(.bottom, bottomInset + CGFloat(ShellChrome.ScreenHost.contentBottomInset))
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: ShellChrome.ScreenHost.errorGap) {
            Text(message)
                .font(.system(size: ShellChrome.ScreenHost.errorFontSize))
                .foregroundStyle(
                    Color(theme.ink).opacity(ShellChrome.ScreenHost.errorInkOpacity)
                )
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text(ShellChrome.ScreenHost.retryLabel)
                    .font(.system(size: ShellChrome.ScreenHost.retryFontSize, weight: .semibold))
                    .foregroundStyle(Color(ShellChrome.ScreenHost.retryInk))
                    .padding(.vertical, ShellChrome.ScreenHost.retryPaddingVertical)
                    .padding(.horizontal, ShellChrome.ScreenHost.retryPaddingHorizontal)
                    .background(
                        RoundedRectangle(
                            cornerRadius: ShellChrome.ScreenHost.retryRadius, style: .continuous
                        )
                        .fill(Color(ShellChrome.ScreenHost.retryBackground))
                    )
            }
            .buttonStyle(ButtonPressStyle())
        }
        .padding(ShellChrome.ScreenHost.errorPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Skeleton

/// The three pulsing placeholder blocks shown until the first token arrives.
struct SkeletonView: View {
    @State private var bright = false

    var body: some View {
        WidthReader { width in
            VStack(alignment: .leading, spacing: ShellChrome.Skeleton.gap) {
                ForEach(ShellChrome.Skeleton.blocks.indices, id: \.self) { index in
                    let block = ShellChrome.Skeleton.blocks[index]
                    RoundedRectangle(cornerRadius: block.radius, style: .continuous)
                        .fill(Color(ShellChrome.Skeleton.fill))
                        .frame(
                            width: width > 0 ? width * CGFloat(block.widthFraction) : nil,
                            height: block.height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(bright ? 1 : ShellChrome.Skeleton.minOpacity)
        }
        .padding(.top, ShellChrome.Skeleton.paddingTop)
        .padding(.horizontal, ShellChrome.Skeleton.paddingHorizontal)
        .onAppear {
            withAnimation(
                .easeInOut(duration: ShellChrome.Skeleton.pulseSeconds)
                    .repeatForever(autoreverses: true)
            ) {
                bright = true
            }
        }
    }
}

#endif
