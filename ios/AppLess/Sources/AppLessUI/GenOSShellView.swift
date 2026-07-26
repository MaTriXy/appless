//
//  GenOSShellView.swift
//  AppLessUI
//
//  The OS shell itself - the SwiftUI port of `src/genos/GenOS.tsx`.
//
//  Layer order, bottom to top (RN's absolute-position stack):
//
//      home screen           always mounted, visible when nothing is open
//      screen layer          the active app's top screen, transitioned in and
//                            minimized out toward the home icon grid
//      chrome                back/home (top-left), switcher (top-right)
//      gesture hint          once, for 6s
//      generating pill       while the top screen streams
//      toast                 2.8s
//      switcher              full-screen overlay
//      key gate              first launch / rejected key
//
//  Every decision behind these layers lives in `AppLessCore`
//  (`ShellState`, `ShellRouter`, `ShellChrome`) or `GenOSCore`.
//

#if canImport(SwiftUI)

import AppLessCore
import GenOSCore
import SwiftUI

public struct GenOSShellView: View {

    @ObservedObject private var model: GenOSShellModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    public init(model: GenOSShellModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    private var theme: CdsTheme { CdsTheme.resolve(isDark: colorScheme == .dark) }

    public var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let size = proxy.size

            ZStack {
                HomeScreenView(
                    apps: model.homeApps,
                    covered: model.activeApp != nil,
                    topInset: insets.top,
                    bottomInset: insets.bottom,
                    onCommand: { model.routeCommand($0) },
                    onResume: { model.activate($0) },
                    onClose: { model.closeSession($0) })

                screenLayer(size: size, insets: insets)

                if ShellLayers.showsChrome(
                    hasActiveApp: model.activeApp != nil, switcherOpen: model.switcherOpen)
                {
                    chromeLayer(insets: insets)
                    hintLayer(insets: insets)
                }

                if ShellLayers.showsGeneratingPill(
                    hasActiveApp: model.activeApp != nil, generating: model.isGenerating)
                {
                    pillLayer(insets: insets)
                }

                toastLayer(insets: insets, width: size.width)

                if ShellLayers.showsSwitcher(switcherOpen: model.switcherOpen) {
                    SwitcherView(
                        apps: model.runningApps,
                        theme: theme,
                        topScreen: { appId in
                            model.shell.topScreenId(of: appId).flatMap { model.screen($0) }
                        },
                        root: { model.root(of: $0) },
                        onResume: { model.activate($0) },
                        onClose: { model.closeSession($0) },
                        onDismiss: { model.setSwitcherOpen(false) })
                }

                if ShellChrome.KeyGate.isPresented(model.keyStatus) {
                    KeyGateView(
                        status: model.keyStatus,
                        theme: theme,
                        onSubmit: { model.submitKey($0) })
                }
            }
            .frame(width: size.width, height: size.height)
            .background(Color(theme.bg))
        }
        .ignoresSafeArea()
        .cdsTheme(colorScheme: colorScheme)
        .onAppear { model.openExternalURL = { url in openURL(url) } }
        .task { await model.start() }
    }

    // MARK: - Screen layer

    @ViewBuilder
    private func screenLayer(size: CGSize, insets: EdgeInsets) -> some View {
        if let topId = model.topScreenId, let screen = model.screen(topId) {
            ScreenTransitionContainer(direction: model.shell.navDirection) {
                ScreenHostView(
                    screen: screen,
                    root: model.root(of: topId),
                    theme: theme,
                    topInset: insets.top,
                    bottomInset: insets.bottom,
                    actions: GenosActionDispatcher { event in
                        Task { @MainActor in model.handleAction(event) }
                    },
                    onRetry: { model.retryTopScreen() })
            }
            // A new top screen remounts the container, replaying the
            // transition - RN's `key={topId}`.
            .id(topId)
            // …and the whole layer shrinks toward the home grid on Home.
            .scaleEffect(ShellChrome.Minimize.scale(at: model.minimizeProgress))
            .offset(
                y: ShellChrome.Minimize.translateY(
                    at: model.minimizeProgress,
                    windowHeight: Double(size.height),
                    topInset: Double(insets.top))
            )
            .opacity(ShellChrome.Minimize.opacity(at: model.minimizeProgress))
            .allowsHitTesting(!model.minimizing)
            // iOS has no hardware back key, so RN's `BackHandler` table is
            // bound to the left-edge swipe instead. Simultaneous, so a
            // horizontal drag inside the screen still scrolls it.
            .simultaneousGesture(
                DragGesture(minimumDistance: ShellChrome.BackGesture.edgeWidth)
                    .onEnded { value in
                        guard
                            ShellChrome.BackGesture.isBackSwipe(
                                startX: Double(value.startLocation.x),
                                translationX: Double(value.translation.width),
                                translationY: Double(value.translation.height))
                        else { return }
                        model.handleBackGesture()
                    }
            )
        }
    }

    // MARK: - Chrome

    private func chromeLayer(insets: EdgeInsets) -> some View {
        ZStack {
            LeadingChromeButton(
                theme: theme,
                stackDepth: model.stack.count,
                action: {
                    switch ShellActivity.leadingIntent(stackDepth: model.stack.count) {
                    case .back: model.goBack()
                    case .home: model.goHome()
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, ShellChrome.Chrome.insetHorizontal)

            SwitcherChromeButton(theme: theme, action: { model.setSwitcherOpen(true) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, ShellChrome.Chrome.insetHorizontal)
        }
        .padding(.top, insets.top + CGFloat(ShellChrome.Chrome.insetTop))
    }

    /// The hint sits inside the chrome layer, so `showsChrome` is already
    /// true here; `showsGestureHint` re-states the full guard so the rule is
    /// pinned in one place.
    @ViewBuilder
    private func hintLayer(insets: EdgeInsets) -> some View {
        if ShellLayers.showsGestureHint(
            hasActiveApp: model.activeApp != nil,
            switcherOpen: model.switcherOpen,
            hintArmed: model.showsGestureHint)
        {
            GestureHintView(onDismiss: { model.dismissGestureHint() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, insets.bottom + CGFloat(ShellChrome.Hint.bottomInset))
        }
    }

    private func pillLayer(insets: EdgeInsets) -> some View {
        GeneratingPillView(searching: model.isSearching)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, insets.bottom + CGFloat(ShellChrome.Pill.bottomInset))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func toastLayer(insets: EdgeInsets, width: CGFloat) -> some View {
        if let toast = model.toast {
            ToastView(text: toast.text, maxWidth: width * CGFloat(ShellChrome.Toast.maxWidthFraction))
                .id(toast.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, insets.top + CGFloat(ShellChrome.Toast.topInset))
                .allowsHitTesting(false)
        }
    }
}

#endif
