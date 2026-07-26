import Foundation
import GenOSCore
import Testing

@testable import AppLessCore

/// `ShellState` against `src/genos/GenOS.tsx` - the shell owns navigation, so
/// every rule in these tests is one the RN component enforces in state.
@Suite struct ShellStateTests {

    private func meta(_ name: String, emoji: String = "✨") -> AppMetaInfo {
        AppMetaInfo(name: name, emoji: emoji, tileStart: "#000000", tileEnd: "#ffffff")
    }

    private var messages: AppDef { Apps.find(id: "messages")! }
    private var music: AppDef { Apps.find(id: "music")! }

    // MARK: launch / activate

    @Test func launchSeedsTheStackAndActivates() {
        var s = ShellState()
        #expect(s.needsLaunchScreen(messages.id))
        s.launch(app: messages, screenId: "screen-1")

        #expect(s.activeApp == "messages")
        #expect(s.stack == ["screen-1"])
        #expect(s.topScreenId == "screen-1")
        #expect(s.recentOrder == ["messages"])
        #expect(s.appMeta["messages"]?.name == "Messages")
        #expect(s.navDirection == .launch)
        // Launching does not minimize anything: the home grid is still empty.
        #expect(s.minimizedIds.isEmpty)
        #expect(!s.needsLaunchScreen("messages"))
    }

    @Test func relaunchingALiveAppKeepsItsStack() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-2")
        // RN: `if (!sessions[app.id]?.length)` - no new screen is opened.
        #expect(!s.needsLaunchScreen("messages"))
        s.launch(app: messages, screenId: nil)
        #expect(s.stack == ["screen-1", "screen-2"])
    }

    @Test func activatingAnotherAppBackgroundsThePreviousOne() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.launch(app: music, screenId: "screen-2")

        // Switching away from a live session must leave it reachable from the
        // home grid, not only from the switcher.
        #expect(s.minimizedIds == ["messages"])
        #expect(s.activeApp == "music")
        #expect(s.recentOrder == ["music", "messages"])
        #expect(s.homeApps.map(\.id) == ["messages"])
        #expect(s.runningApps.map(\.id) == ["music", "messages"])
    }

    @Test func activatingTheSameAppDoesNotBackgroundIt() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.activate("messages")
        #expect(s.minimizedIds.isEmpty)
        #expect(s.recentOrder == ["messages"])
    }

    @Test func activateAlwaysReplaysTheLaunchTransitionAndClosesTheSwitcher() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-2")
        #expect(s.navDirection == .push)
        s.switcherOpen = true
        s.activate("messages")
        #expect(s.navDirection == .launch)
        #expect(!s.switcherOpen)
    }

    // MARK: pushScreen idempotence

    @Test func pushingTheSameResolvedScreenTwiceDoesNotDoublePush() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        let pushed = s.pushScreen(appId: "messages", screenId: "screen-2")
        let duplicate = s.pushScreen(appId: "messages", screenId: "screen-2")
        #expect(pushed)
        #expect(!duplicate)
        #expect(s.stack == ["screen-1", "screen-2"])
    }

    @Test func pushingAScreenThatIsNotOnTopStillPushes() {
        // Only the TOP frame is deduped - navigating back to a screen the user
        // already visited is a genuine new frame.
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-2")
        s.pushScreen(appId: "messages", screenId: "screen-1")
        #expect(s.stack == ["screen-1", "screen-2", "screen-1"])
    }

    // MARK: back / home / close

    @Test func goBackPopsButNeverEmptiesTheStack() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-2")

        s.goBack()
        #expect(s.stack == ["screen-1"])
        #expect(s.navDirection == .pop)

        s.goBack()
        #expect(s.stack == ["screen-1"])
    }

    @Test func goBackAtHomeDoesNothing() {
        var s = ShellState()
        s.goBack()
        #expect(s.activeApp == nil)
        #expect(s.sessions.isEmpty)
    }

    @Test func minimizeCommitsTheAppIntoTheHomeGrid() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.commitMinimize(appId: "messages")

        #expect(s.activeApp == nil)
        #expect(s.minimizedIds == ["messages"])
        #expect(s.stack.isEmpty)
        // The session survives - the icon resumes it.
        #expect(s.sessions["messages"] == ["screen-1"])
        #expect(s.homeApps.map(\.id) == ["messages"])
    }

    @Test func minimizeOnlyDismissesTheAppItStartedWith() {
        // RN: setActiveApp((cur) => (cur === appId ? null : cur)) - the user
        // activated something else while the animation ran.
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.launch(app: music, screenId: "screen-2")
        s.commitMinimize(appId: "messages")

        #expect(s.activeApp == "music")
        #expect(s.minimizedIds == ["messages"])
    }

    @Test func minimizingTwiceDoesNotDuplicateTheIcon() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.commitMinimize(appId: "messages")
        s.activate("messages")
        s.commitMinimize(appId: "messages")
        #expect(s.minimizedIds == ["messages"])
    }

    @Test func closeSessionEndsTheThreadEverywhere() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.commitMinimize(appId: "messages")
        s.launch(app: music, screenId: "screen-2")
        s.closeSession("messages")

        #expect(s.sessions["messages"] == nil)
        #expect(s.recentOrder == ["music"])
        #expect(s.minimizedIds.isEmpty)
        #expect(s.activeApp == "music")
        #expect(s.runningApps.map(\.id) == ["music"])
        // RN keeps appMeta - a relaunch reuses the remembered name.
        #expect(s.appMeta["messages"] != nil)
    }

    @Test func closingTheActiveSessionReturnsHome() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.closeSession("messages")
        #expect(s.activeApp == nil)
    }

    // MARK: meta

    @Test func rememberMetaKeepsTheFirstValue() {
        var s = ShellState()
        s.rememberMeta("summon-x", meta("Raw typed text"))
        s.rememberMeta("summon-x", meta("Something else"))
        #expect(s.appMeta["summon-x"]?.name == "Raw typed text")
    }

    @Test func runningAppsFallBackToACapitalizedIdAndTheDefaultTile() {
        var s = ShellState()
        s.pushScreen(appId: "mystery", screenId: "screen-1")
        s.activate("mystery")
        let app = s.runningApps.first
        #expect(app?.name == "Mystery")
        #expect(app?.emoji == "✨")
        #expect(app?.tileStart == Apps.defaultTileStart)
        #expect(app?.tileEnd == Apps.defaultTileEnd)
    }

    @Test func deepLinkMetaUsesTheKnownAppElseTheCapitalizedRawId() {
        let known = ShellState.deepLinkMeta(appId: "MUSIC")
        #expect(known.name == "Music")
        #expect(known.emoji == "🎵")

        let unknown = ShellState.deepLinkMeta(appId: "wardrobe")
        #expect(unknown.name == "Wardrobe")
        #expect(unknown.emoji == "✨")
        #expect(unknown.tileStart == Apps.defaultTileStart)
    }

    @Test func openDeepLinkPushesUnderTheLowerCasedId() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.openDeepLink(
            appId: "MUSIC", meta: ShellState.deepLinkMeta(appId: "MUSIC"), screenId: "screen-9")
        #expect(s.activeApp == "music")
        #expect(s.sessions["music"] == ["screen-9"])
        #expect(s.sessions["MUSIC"] == nil)
        #expect(s.minimizedIds == ["messages"])
    }

    // MARK: @OS commands

    @Test func osCommandScreenIsRemovedFromTheStack() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-2")

        let follow = s.applyOSCommand(OSCommand(cmd: .home), screenId: "screen-2")
        #expect(follow == .home)
        #expect(s.stack == ["screen-1"])
        #expect(s.navDirection == .pop)
    }

    @Test func osBackPopsOneMoreFrame() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-2")
        s.pushScreen(appId: "messages", screenId: "screen-cmd")

        let follow = s.applyOSCommand(OSCommand(cmd: .back), screenId: "screen-cmd")
        #expect(follow == .none)
        #expect(s.stack == ["screen-1"])
    }

    @Test func osBackWithOnlyTheRootLeftDoesNotEmptyTheStack() {
        // An active app with zero screens renders nothing and traps the user.
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-cmd")

        _ = s.applyOSCommand(OSCommand(cmd: .back), screenId: "screen-cmd")
        #expect(s.stack == ["screen-1"])
        #expect(s.activeApp == "messages")
    }

    @Test func osSwitcherOpensTheOverlay() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-cmd")
        let follow = s.applyOSCommand(OSCommand(cmd: .switcher), screenId: "screen-cmd")
        #expect(follow == .switcher)
        #expect(s.switcherOpen)
        #expect(s.stack == ["screen-1"])
    }

    @Test func osOpenCarriesItsArgumentAndAnArglessOpenIsInert() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        s.pushScreen(appId: "messages", screenId: "screen-cmd")
        let opened = s.applyOSCommand(OSCommand(cmd: .open, arg: "Music"), screenId: "screen-cmd")
        #expect(opened == .open("Music"))

        s.pushScreen(appId: "messages", screenId: "screen-cmd2")
        let nilArg = s.applyOSCommand(OSCommand(cmd: .open, arg: nil), screenId: "screen-cmd2")
        let emptyArg = s.applyOSCommand(OSCommand(cmd: .open, arg: ""), screenId: "screen-cmd3")
        #expect(nilArg == .none)
        #expect(emptyArg == .none)
    }

    @Test func osCommandsAreExecutedExactlyOncePerScreen() {
        var s = ShellState()
        let first = s.shouldExecuteOSCommand(screenId: "screen-cmd")
        let second = s.shouldExecuteOSCommand(screenId: "screen-cmd")
        let other = s.shouldExecuteOSCommand(screenId: "screen-other")
        #expect(first)
        #expect(!second)
        #expect(other)
    }

    @Test func osCommandAtHomeIsInert() {
        var s = ShellState()
        #expect(s.applyOSCommand(OSCommand(cmd: .home), screenId: "screen-1") == .none)
    }

    // MARK: summoned-app rename

    @Test func summonedAppAdoptsItsFirstScreensCardHeader() {
        var s = ShellState()
        var app = Apps.summonApp("plan a weekend trip")
        app.request = "…"
        s.launch(app: app, screenId: "screen-1")

        let adopted = s.adoptSummonedTitle(
            appId: app.id, content: "Card(CardHeader(\"Trip Planner\", \"3 days\"))")
        #expect(adopted == "Trip Planner")
        #expect(s.appMeta[app.id]?.name == "Trip Planner")
    }

    @Test func renameIsGatedOnStackDepthOne() {
        var s = ShellState()
        let app = Apps.summonApp("weekend")
        s.launch(app: app, screenId: "screen-1")
        s.pushScreen(appId: app.id, screenId: "screen-2")

        #expect(s.adoptSummonedTitle(appId: app.id, content: "Card(CardHeader(\"Child\"))") == nil)
        #expect(s.appMeta[app.id]?.name == "weekend")
    }

    @Test func renameOnlyAppliesToSummonedApps() {
        var s = ShellState()
        s.launch(app: messages, screenId: "screen-1")
        #expect(s.adoptSummonedTitle(appId: "messages", content: "Card(CardHeader(\"Inbox\"))") == nil)
        #expect(s.appMeta["messages"]?.name == "Messages")
    }

    @Test func renameIsIdempotent() {
        var s = ShellState()
        let app = Apps.summonApp("x")
        s.launch(app: app, screenId: "screen-1")
        #expect(s.adoptSummonedTitle(appId: app.id, content: "Card(CardHeader(\"Xylo\"))") == "Xylo")
        #expect(s.adoptSummonedTitle(appId: app.id, content: "Card(CardHeader(\"Xylo\"))") == nil)
    }

    // MARK: hardware back

    @Test func hardwareBackMirrorsTheShellGesture() {
        var s = ShellState()
        #expect(s.hardwareBackIntent(minimizing: false) == .unhandled)

        s.launch(app: messages, screenId: "screen-1")
        #expect(s.hardwareBackIntent(minimizing: false) == .goHome)

        s.pushScreen(appId: "messages", screenId: "screen-2")
        #expect(s.hardwareBackIntent(minimizing: false) == .goBack)

        #expect(s.hardwareBackIntent(minimizing: true) == .consumed)

        s.switcherOpen = true
        // The switcher wins over everything, even a running minimize.
        #expect(s.hardwareBackIntent(minimizing: true) == .dismissSwitcher)
    }

    // MARK: transitions

    @Test func transitionDurationsMatchTheRNCurves() {
        #expect(NavDirection.launch.duration == 0.380)
        #expect(NavDirection.push.duration == 0.300)
        #expect(NavDirection.pop.duration == 0.260)
    }
}
