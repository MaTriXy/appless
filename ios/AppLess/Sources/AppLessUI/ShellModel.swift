//
//  ShellModel.swift
//  AppLessUI
//
//  The observable object the shell views render: it owns nothing it can
//  decide itself.
//
//    - navigation state          → `AppLessCore.ShellState`
//    - typed / tapped routing    → `AppLessCore.ShellRouter`
//    - chrome copy and geometry  → `AppLessCore.ShellChrome`
//    - screens, caching, prefetch, @OS parsing, cancellation
//                                → `GenOSCore.GenOSController` / `ScreenStore`
//    - openui-lang → element tree → `OpenUILang.StreamingParser`
//
//  What lives HERE is only what React kept in `GenOS.tsx` outside of state:
//  the effects. Store subscription, the minimize animation and its
//  re-entrancy guard, the toast and hint timers, and the one-shot @OS
//  execution pass.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import GenOSCore
import OpenUILang
import SwiftUI

/// A toast with an identity, so a re-shown toast animates in again
/// (RN `{ text, key: Date.now() }`).
public struct ShellToast: Identifiable, Equatable {
    public let id: Int
    public let text: String
}

@MainActor
public final class GenOSShellModel: ObservableObject {

    // MARK: Collaborators

    public let controller: GenOSController
    public let keyStore: KeyStore
    private let schema: LibrarySchema
    private let apps: [AppDef]

    // MARK: Published state

    /// The whole OS navigation state (sessions, activeApp, recents, meta,
    /// minimized set, switcher, nav direction).
    @Published public private(set) var shell = ShellState()
    /// Bumped on every screen-store notification - the SwiftUI equivalent of
    /// `useSyncExternalStore(screenStore.subscribe, screenStore.getVersion)`.
    @Published public private(set) var storeVersion = 0
    @Published public private(set) var keyStatus: KeyStatus
    @Published public private(set) var toast: ShellToast?
    /// The one-time gesture hint (6s, first app opened).
    @Published public private(set) var showsGestureHint = false
    /// True while the minimize-into-icon animation plays.
    @Published public private(set) var minimizing = false
    /// 0 → 1 while minimizing; the screen layer reads it through
    /// `ShellChrome.Minimize`.
    @Published public private(set) var minimizeProgress: Double = 0
    /// Parsed element trees, keyed by screen id (top screens only).
    @Published public private(set) var trees: [String: ParseResult] = [:]

    /// Where an external (non-`genos://`) url goes. The view installs
    /// SwiftUI's `openURL` here; nothing else in the model knows about it.
    public var openExternalURL: ((URL) -> Void)?

    // MARK: Private

    private var parsers: [String: StreamingParser] = [:]
    private var parsedText: [String: String] = [:]
    private var toastCounter = 0
    private var toastTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var hintArmed = false
    /// Identifies the in-flight minimize, so a superseded one never commits.
    private var minimizeToken = UUID()
    private var keyUnsubscribe: (@MainActor () -> Void)?
    /// Last `(id, status)` reported to the controller, so prefetch is only
    /// re-armed on a real change (RN's `[topId, top?.status]` effect deps).
    private var reportedActiveScreen: String??
    private var reportedActiveStatus: ScreenStatus?

    public init(
        controller: GenOSController,
        keyStore: KeyStore,
        schema: LibrarySchema,
        apps: [AppDef] = Apps.all
    ) {
        self.controller = controller
        self.keyStore = keyStore
        self.schema = schema
        self.apps = apps
        self.keyStatus = keyStore.status
    }

    // MARK: - Lifecycle

    /// Drive the model for as long as the shell is on screen: hydrate the
    /// stored API key, then pump the screen store's change feed.
    public func start() async {
        if keyUnsubscribe == nil {
            keyUnsubscribe = keyStore.subscribe { [weak self] in
                guard let self else { return }
                self.keyStatus = self.keyStore.status
            }
        }
        await keyStore.hydrate()
        keyStatus = keyStore.status
        onStoreChanged()
        for await _ in controller.store.updates {
            onStoreChanged()
        }
    }

    /// One screen-store notification: refresh trees, run any pending `@OS`
    /// command exactly once, adopt a summoned app's title, and tell the
    /// controller which screen is visible (which is what arms prefetch).
    private func onStoreChanged() {
        storeVersion &+= 1
        refreshTrees()
        executePendingOSCommand()
        adoptSummonedTitle()
        reportActiveScreen()
    }

    // MARK: - Derived reads

    public var activeApp: String? { shell.activeApp }
    public var stack: [String] { shell.stack }
    public var topScreenId: String? { shell.topScreenId }
    public var topScreen: Screen? { shell.topScreenId.flatMap { controller.store.get($0) } }

    public func screen(_ id: String) -> Screen? { controller.store.get(id) }

    /// The resolved root element of a screen, once any content has arrived.
    public func root(of id: String) -> ElementNode? { trees[id]?.root }

    /// RN `generating`: the top screen is pending or streaming.
    public var isGenerating: Bool {
        guard let status = topScreen?.status else { return false }
        return status == .pending || status == .streaming
    }

    /// RN `top?.searching` - the model is running `web_search`.
    public var isSearching: Bool { topScreen?.searching == true }

    public var switcherOpen: Bool { shell.switcherOpen }
    public var runningApps: [RunningAppInfo] { shell.runningApps }
    public var homeApps: [RunningAppInfo] { shell.homeApps }

    public func setSwitcherOpen(_ open: Bool) {
        guard shell.switcherOpen != open else { return }
        shell.switcherOpen = open
    }

    // MARK: - Navigation

    /// Open (or resume) an app. The screen is opened through the controller -
    /// which touches the store - BEFORE the state mutation, exactly as RN
    /// keeps `openApp` out of its `setState` updater.
    public func launch(_ app: AppDef) {
        let screenId = shell.needsLaunchScreen(app.id) ? controller.openApp(app) : nil
        mutate { $0.launch(app: app, screenId: screenId) }
    }

    /// Resume a backgrounded session from the home grid or the switcher.
    public func activate(_ appId: String) {
        mutate { $0.activate(appId) }
    }

    /// Home: the screen shrinks into its home-screen icon.
    ///
    /// Re-entrant calls during the animation are ignored, and the completion
    /// only commits for the app it started with - a resume mid-flight leaves
    /// the new app on screen (`ShellState.commitMinimize` re-checks that).
    public func goHome() {
        setSwitcherOpen(false)
        guard let appId = shell.activeApp, !minimizing else { return }
        minimizing = true
        let token = UUID()
        minimizeToken = token
        withAnimation(.shellStandard(duration: ShellChrome.Minimize.duration)) {
            minimizeProgress = 1
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds(ShellChrome.Minimize.duration))
            guard let self, self.minimizeToken == token else { return }
            self.minimizing = false
            self.mutate { $0.commitMinimize(appId: appId) }
            self.minimizeProgress = 0
        }
    }

    public func goBack() {
        guard shell.activeApp != nil, !minimizing else { return }
        mutate { $0.goBack() }
    }

    public func closeSession(_ appId: String) {
        mutate { $0.closeSession(appId) }
    }

    /// `genos://open?app=…&request=…` - jump into another app at a screen.
    public func openDeepLink(appId: String, request: String) {
        let screenId = controller.openDeepLink(appId: appId, request: request)
        let meta = ShellState.deepLinkMeta(appId: appId, apps: apps)
        mutate { $0.openDeepLink(appId: appId, meta: meta, screenId: screenId) }
    }

    /// The iOS analog of RN's Android hardware-back handler: the shell binds
    /// this to the interactive back gesture.
    public func handleBackGesture() {
        switch shell.hardwareBackIntent(minimizing: minimizing) {
        case .dismissSwitcher: setSwitcherOpen(false)
        case .consumed: break
        case .goBack: goBack()
        case .goHome: goHome()
        case .unhandled: break
        }
    }

    public func retryTopScreen() {
        guard let id = shell.topScreenId else { return }
        controller.retryScreen(id)
    }

    // MARK: - Command routing

    /// The ask bar and the suggestion chips (`routeCommand`).
    public func routeCommand(_ transcript: String) {
        switch ShellRouter.route(
            transcript, activeApp: shell.activeApp, topScreenId: shell.topScreenId, apps: apps)
        {
        case .none:
            break
        case .back:
            goBack()
        case .home:
            goHome()
        case .closeActiveApp:
            if let appId = shell.activeApp { closeSession(appId) }
        case .openSwitcher:
            setSwitcherOpen(true)
        case .launch(let app), .summon(let app):
            launch(app)
        case .resolveAction(let text):
            generateChild(message: text, formState: nil)
        }
    }

    /// Every tap inside a rendered screen (`handleAction`).
    public func handleAction(_ event: ActionEvent) {
        switch ShellRouter.decide(
            event: event,
            activeApp: shell.activeApp,
            topScreenId: shell.topScreenId,
            generating: isGenerating)
        {
        case .toast(let text):
            showToast(text)
        case .deepLink(let appId, let request):
            openDeepLink(appId: appId, request: request)
        case .back:
            goBack()
        case .home:
            goHome()
        case .openExternalURL(let raw):
            if let url = URL(string: raw) { openExternalURL?(url) }
        case .resolveAction(let message):
            generateChild(message: message, formState: event.formState.pairs)
        case .stillMaterializing:
            showToast(ShellRouter.stillMaterializingToast)
        case .ignore:
            break
        }
    }

    /// Resolve a request against the top screen and push the result.
    private func generateChild(message: String, formState: [(String, GenosJSONValue)]?) {
        guard let appId = shell.activeApp, let topId = shell.topScreenId else { return }
        let screenId = controller.resolveAction(
            parentId: topId, message: message, formState: formState)
        mutate { $0.pushScreen(appId: appId, screenId: screenId) }
    }

    // MARK: - Toast

    public func showToast(_ text: String) {
        toastTask?.cancel()
        toastCounter &+= 1
        toast = ShellToast(id: toastCounter, text: text)
        let token = toastCounter
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds(ShellChrome.Toast.visibleSeconds))
            guard let self, !Task.isCancelled, self.toast?.id == token else { return }
            self.toast = nil
        }
    }

    // MARK: - Key gate

    public func submitKey(_ raw: String) {
        keyStore.set(raw)
        keyStatus = keyStore.status
    }

    // MARK: - Effects

    /// Every state mutation runs through here so the hint effect sees the
    /// activeApp transition, exactly like RN's `useEffect([activeApp])`.
    private func mutate(_ body: (inout ShellState) -> Void) {
        let before = shell.activeApp
        body(&shell)
        syncGestureHint(previousActiveApp: before)
    }

    /// RN's one-time hint: armed the first time an app opens, hidden after 6s
    /// - and hidden immediately if the user leaves that app sooner (the RN
    /// cleanup, which also prevents a second arming).
    private func syncGestureHint(previousActiveApp: String?) {
        guard shell.activeApp != previousActiveApp else { return }
        hintTask?.cancel()
        if showsGestureHint { showsGestureHint = false }
        guard shell.activeApp != nil, !hintArmed else { return }
        hintArmed = true
        showsGestureHint = true
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds(ShellChrome.Hint.visibleSeconds))
            guard let self, !Task.isCancelled else { return }
            self.showsGestureHint = false
        }
    }

    public func dismissGestureHint() {
        hintTask?.cancel()
        showsGestureHint = false
    }

    /// The model answered with `@OS(...)` instead of a screen: drop the
    /// command screen and apply the navigation, once per screen.
    private func executePendingOSCommand() {
        guard let topId = shell.topScreenId, shell.activeApp != nil,
            let command = controller.store.get(topId)?.osCommand
        else { return }
        guard shell.shouldExecuteOSCommand(screenId: topId) else { return }

        let followUp = mutateReturning { $0.applyOSCommand(command, screenId: topId) }
        switch followUp {
        case .none, .switcher:
            break
        case .home:
            goHome()
        case .open(let argument):
            let target = argument.lowercased()
            let known = apps.first { $0.id == target || $0.name.lowercased() == target }
            launch(known ?? Apps.summonApp(argument))
        }
    }

    /// `mutate` for a mutation that returns something.
    private func mutateReturning<T>(_ body: (inout ShellState) -> T) -> T {
        let before = shell.activeApp
        let result = body(&shell)
        syncGestureHint(previousActiveApp: before)
        return result
    }

    /// A summoned app adopts the title of its first screen's `CardHeader`.
    private func adoptSummonedTitle() {
        guard let appId = shell.activeApp, let topId = shell.topScreenId,
            let content = controller.store.get(topId)?.content, !content.isEmpty
        else { return }
        shell.adoptSummonedTitle(appId: appId, content: content)
    }

    /// RN `setActiveScreen(topId)` - only the visible screen prefetches.
    private func reportActiveScreen() {
        let id = shell.topScreenId
        let status = id.flatMap { controller.store.get($0)?.status }
        if let reported = reportedActiveScreen, reported == id, reportedActiveStatus == status {
            return
        }
        reportedActiveScreen = .some(id)
        reportedActiveStatus = status
        controller.setActiveScreen(id)
    }

    // MARK: - Parsing

    /// Keep an element tree for every screen that can be ON SCREEN: the
    /// active app's top screen, plus every session's top screen (the switcher
    /// renders live miniatures of those).
    private func refreshTrees() {
        var wanted: Set<String> = []
        if let topId = shell.topScreenId { wanted.insert(topId) }
        for app in shell.runningApps {
            if let id = shell.topScreenId(of: app.id) { wanted.insert(id) }
        }

        for id in wanted { refreshTree(id) }

        // Drop everything else, so a long session does not accumulate parsers.
        if trees.keys.contains(where: { !wanted.contains($0) }) {
            trees = trees.filter { wanted.contains($0.key) }
        }
        parsers = parsers.filter { wanted.contains($0.key) }
        parsedText = parsedText.filter { wanted.contains($0.key) }
    }

    private func refreshTree(_ id: String) {
        guard let screen = controller.store.get(id) else { return }
        // `cleanLang` strips the model's code fences before parsing, exactly
        // as the RN `<Renderer response={cleanLang(top.content)} />` does.
        let text = Lang.cleanLang(screen.content)
        guard parsedText[id] != text else { return }
        parsedText[id] = text
        guard !text.isEmpty else {
            trees[id] = nil
            return
        }
        let parser: StreamingParser
        if let existing = parsers[id] {
            parser = existing
        } else {
            parser = StreamingParser(schema: schema)
            parsers[id] = parser
        }
        trees[id] = parser.set(text)
    }
}

// MARK: - Timing helpers

/// Seconds → nanoseconds for `Task.sleep`.
func nanoseconds(_ seconds: Double) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
}

extension Animation {
    /// The shell's one curve: RN `Easing.bezier(0.22, 1, 0.32, 1)`.
    static func shellStandard(duration: Double) -> Animation {
        .timingCurve(
            ShellChrome.standardEasing.x1,
            ShellChrome.standardEasing.y1,
            ShellChrome.standardEasing.x2,
            ShellChrome.standardEasing.y2,
            duration: duration)
    }
}

#endif
