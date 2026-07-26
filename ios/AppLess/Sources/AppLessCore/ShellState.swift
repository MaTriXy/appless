//
//  ShellState.swift
//  AppLessCore
//
//  The OS shell's navigation state - a byte-for-byte port of the state GenOS
//  itself owns in `src/genos/GenOS.tsx`:
//
//      sessions       appId → stack of screen ids (per-app, like iOS multitasking)
//      activeApp      the app whose top screen is on screen, or nil (home)
//      recentOrder    switcher order, most recently activated first
//      appMeta        appId → display name/emoji/tile (first write wins)
//      minimizedIds   apps the user sent home; ONLY these get a home-screen icon
//      switcherOpen   the app switcher overlay
//
//  Everything the shell *decides* lives here so a Linux test can pin it.
//  `GenOSCore.GenOSController` owns caching, prefetch, @OS parsing, deep-link
//  resolution and cancellation; this type never touches the screen store - the
//  caller resolves an id through the controller and hands it in.
//
//  NO SwiftUI in this file.
//

import Foundation
import GenOSCore

// MARK: - Value types

/// `AppMeta` in GenOS.tsx: how an app renders in the switcher and on the home
/// grid, remembered the first time the app is launched.
public struct AppMetaInfo: Sendable, Equatable {
    public var name: String
    public var emoji: String
    /// Gradient stops for the icon tile (`tile: [string, string]` in RN).
    public var tileStart: String
    public var tileEnd: String

    public init(name: String, emoji: String, tileStart: String, tileEnd: String) {
        self.name = name
        self.emoji = emoji
        self.tileStart = tileStart
        self.tileEnd = tileEnd
    }

    public init(app: AppDef) {
        self.init(
            name: app.name, emoji: app.emoji, tileStart: app.tileStart, tileEnd: app.tileEnd)
    }
}

/// `RunningApp` in Switcher.tsx - one live session, as the switcher and the
/// home grid see it.
public struct RunningAppInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let emoji: String
    public let tileStart: String
    public let tileEnd: String

    public init(id: String, name: String, emoji: String, tileStart: String, tileEnd: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.tileStart = tileStart
        self.tileEnd = tileEnd
    }
}

/// `NavDir` in GenOS.tsx - which transition the next screen mount plays.
public enum NavDirection: String, Sendable, Equatable {
    case launch
    case push
    case pop

    /// RN `ScreenTransition` durations, in seconds.
    /// (`kind === "launch" ? 380 : kind === "push" ? 300 : 260` ms).
    public var duration: Double {
        switch self {
        case .launch: return 0.380
        case .push: return 0.300
        case .pop: return 0.260
        }
    }
}

/// What the shell must do after an `@OS(...)` command has been applied to the
/// stack (GenOS.tsx `executedOsCommands` effect, second half).
public enum OSFollowUp: Sendable, Equatable {
    case none
    case home
    case switcher
    /// `@OS(open, "…")` - launch the named app (known app, else summon).
    case open(String)
}

/// The Android hardware-back mapping (GenOS.tsx `BackHandler` effect). iOS has
/// no hardware button, so the shell binds this to the edge-swipe gesture; the
/// decision table is the RN one.
public enum BackIntent: Sendable, Equatable {
    /// The switcher was open: close it, consume the event.
    case dismissSwitcher
    /// A minimize animation is running: swallow the event.
    case consumed
    case goBack
    case goHome
    /// Nothing to do - RN returns false and the OS takes over.
    case unhandled
}

// MARK: - Shell state

public struct ShellState: Sendable, Equatable {

    /// appId → stack of screen ids.
    public private(set) var sessions: [String: [String]] = [:]
    public private(set) var activeApp: String?
    public private(set) var recentOrder: [String] = []
    public private(set) var appMeta: [String: AppMetaInfo] = [:]
    /// Apps the user has sent home - only these show as icons on the home
    /// screen (a backgrounded app is added here by ``activate(_:)`` too).
    public private(set) var minimizedIds: [String] = []
    public var switcherOpen: Bool = false
    /// Which transition the next screen mount plays.
    public private(set) var navDirection: NavDirection = .launch
    /// Screen ids whose `@OS(...)` command has already run - the RN
    /// `executedOsCommands` ref. A screen's command must fire exactly once.
    private var executedOSCommands: Set<String> = []

    public init() {}

    // MARK: Derived

    /// The active app's stack (empty at home).
    public var stack: [String] {
        guard let activeApp else { return [] }
        return sessions[activeApp] ?? []
    }

    /// The screen currently on top, or nil at home.
    public var topScreenId: String? { stack.last }

    /// The top screen of any app - the switcher's `topScreenId(appId)`.
    public func topScreenId(of appId: String) -> String? { sessions[appId]?.last }

    public func stack(of appId: String) -> [String] { sessions[appId] ?? [] }

    /// RN `runningApps`: every app with a non-empty session, in recency order.
    public var runningApps: [RunningAppInfo] {
        recentOrder
            .filter { !(sessions[$0] ?? []).isEmpty }
            .map { id in
                let meta = appMeta[id]
                return RunningAppInfo(
                    id: id,
                    name: meta?.name ?? shellCapitalize(id),
                    emoji: meta?.emoji ?? "✨",
                    tileStart: meta?.tileStart ?? Apps.defaultTileStart,
                    tileEnd: meta?.tileEnd ?? Apps.defaultTileEnd
                )
            }
    }

    /// RN `homeApps`: the running apps the user has minimized.
    public var homeApps: [RunningAppInfo] {
        runningApps.filter { minimizedIds.contains($0.id) }
    }

    /// RN `!sessions[app.id]?.length` - whether `launch` must open a screen.
    public func needsLaunchScreen(_ appId: String) -> Bool {
        (sessions[appId] ?? []).isEmpty
    }

    // MARK: Meta

    /// RN `rememberMeta`: the FIRST name/emoji/tile an app is launched with
    /// wins; later launches never overwrite it (that is what lets a summoned
    /// app keep the title it adopted from its own first screen).
    public mutating func rememberMeta(_ appId: String, _ meta: AppMetaInfo) {
        if appMeta[appId] == nil { appMeta[appId] = meta }
    }

    /// The meta a `genos://open` deep link records for its target - RN
    /// `deepLink`: a known app's own name/emoji/tile, else the capitalized
    /// RAW appId (not the lower-cased key), "✨" and the default tile.
    public static func deepLinkMeta(appId: String, apps: [AppDef] = Apps.all) -> AppMetaInfo {
        let known = apps.first { $0.id == appId.lowercased() }
        return AppMetaInfo(
            name: known?.name ?? shellCapitalize(appId),
            emoji: known?.emoji ?? "✨",
            tileStart: known?.tileStart ?? Apps.defaultTileStart,
            tileEnd: known?.tileEnd ?? Apps.defaultTileEnd
        )
    }

    // MARK: Navigation

    /// RN `activate`: resuming always replays the launch transition, and
    /// switching away from a live session BACKGROUNDS it - it must stay
    /// reachable from the home grid, not just from the switcher.
    public mutating func activate(_ appId: String) {
        navDirection = .launch
        if let prev = activeApp, prev != appId, !minimizedIds.contains(prev) {
            minimizedIds.append(prev)
        }
        activeApp = appId
        switcherOpen = false
        recentOrder = [appId] + recentOrder.filter { $0 != appId }
    }

    /// RN `pushScreen`: idempotent. A duplicate dispatch of the same resolved
    /// screen (double action events, a re-entered effect) must NOT create a
    /// second identical frame.
    ///
    /// `navDirection` is set even when the push is a no-op, exactly as RN sets
    /// `navAnim` outside the state updater - with the stack unchanged the
    /// screen never remounts, so nothing animates either way.
    @discardableResult
    public mutating func pushScreen(appId: String, screenId: String) -> Bool {
        navDirection = .push
        var st = sessions[appId] ?? []
        if st.last == screenId { return false }
        st.append(screenId)
        sessions[appId] = st
        return true
    }

    /// RN `launch`: remember the meta, seed the stack when the app has no
    /// session yet, then activate. The caller opens the screen through
    /// `GenOSController.openApp` (which touches the store) and passes the id;
    /// pass `nil` when ``needsLaunchScreen(_:)`` was false.
    public mutating func launch(app: AppDef, screenId: String?) {
        navDirection = .launch
        rememberMeta(app.id, AppMetaInfo(app: app))
        // The RN updater re-checks the guard, so a session created between the
        // check and the commit is never clobbered.
        if let screenId, (sessions[app.id] ?? []).isEmpty {
            sessions[app.id] = [screenId]
        }
        activate(app.id)
    }

    /// RN `deepLink`: remember meta for the LOWER-CASED id, push, activate.
    public mutating func openDeepLink(appId: String, meta: AppMetaInfo, screenId: String) {
        let key = appId.lowercased()
        rememberMeta(key, meta)
        pushScreen(appId: key, screenId: screenId)
        activate(key)
    }

    /// RN `goBack`: pop one frame, never below the root.
    public mutating func goBack() {
        guard let activeApp else { return }
        navDirection = .pop
        var st = sessions[activeApp] ?? []
        guard st.count > 1 else { return }
        st.removeLast()
        sessions[activeApp] = st
    }

    /// The commit half of RN `goHome`: the app joins the minimized set and is
    /// dismissed. The animation and its re-entrancy guard live in the view;
    /// this only runs when the animation FINISHED, and only dismisses if the
    /// user did not activate something else mid-flight.
    public mutating func commitMinimize(appId: String) {
        if !minimizedIds.contains(appId) { minimizedIds.append(appId) }
        if activeApp == appId { activeApp = nil }
    }

    /// RN `closeSession`: end the thread. Unlike Home, this drops the stack -
    /// the app disappears from the switcher AND the home grid. `appMeta` is
    /// deliberately kept, as in RN.
    public mutating func closeSession(_ appId: String) {
        sessions.removeValue(forKey: appId)
        recentOrder.removeAll { $0 == appId }
        minimizedIds.removeAll { $0 == appId }
        if activeApp == appId { activeApp = nil }
    }

    // MARK: @OS commands

    /// RN `executedOsCommands.has/add`: true the first time a screen's command
    /// is seen, false forever after.
    public mutating func shouldExecuteOSCommand(screenId: String) -> Bool {
        executedOSCommands.insert(screenId).inserted
    }

    /// Apply an `@OS(...)` command to the active app's stack and report the
    /// follow-up navigation (GenOS.tsx `executedOsCommands` effect).
    ///
    /// The pending command screen is removed from the stack first - it holds
    /// the model's navigation reply, not a screen. `@OS(back)` then pops one
    /// MORE frame, but only while more than one is left: an active app with an
    /// empty stack renders nothing and traps the user.
    public mutating func applyOSCommand(_ command: OSCommand, screenId: String) -> OSFollowUp {
        guard let activeApp else { return .none }
        navDirection = .pop
        var st = (sessions[activeApp] ?? []).filter { $0 != screenId }
        if command.cmd == .back, st.count > 1 { st.removeLast() }
        sessions[activeApp] = st

        switch command.cmd {
        case .back:
            return .none
        case .home:
            return .home
        case .switcher:
            switcherOpen = true
            return .switcher
        case .open:
            guard let arg = command.arg, !arg.isEmpty else { return .none }
            return .open(arg)
        }
    }

    // MARK: Summoned-app rename

    /// RN's rename effect: a summoned app starts life named after the raw
    /// typed command and adopts the title the model gave its FIRST screen.
    /// Gated by `GenOSCore.Lang.summonedAppTitle` on the `summon-` prefix and
    /// stack depth 1, so pushed child screens never rename the app again.
    ///
    /// Returns the adopted title, or nil when the gate rejects or the name is
    /// already correct.
    @discardableResult
    public mutating func adoptSummonedTitle(appId: String, content: String) -> String? {
        guard
            let title = Lang.summonedAppTitle(
                appId: appId, stackDepth: (sessions[appId] ?? []).count, content: content)
        else { return nil }
        guard var meta = appMeta[appId], meta.name != title else { return nil }
        meta.name = title
        appMeta[appId] = meta
        return title
    }

    // MARK: Hardware / edge-swipe back

    /// RN `BackHandler` decision table.
    public func hardwareBackIntent(minimizing: Bool) -> BackIntent {
        if switcherOpen { return .dismissSwitcher }
        if minimizing { return .consumed }
        guard let activeApp else { return .unhandled }
        return (sessions[activeApp] ?? []).count > 1 ? .goBack : .goHome
    }
}
