import Foundation
import GenOSCore
import Testing

@testable import AppLessCore

/// `ShellRouter` against `GenOS.tsx` `routeCommand` and `handleAction`.
@Suite struct CommandRouterTests {

    private func route(
        _ text: String, activeApp: String? = nil, topScreenId: String? = nil
    ) -> ShellCommand {
        ShellRouter.route(text, activeApp: activeApp, topScreenId: topScreenId)
    }

    // MARK: - routeCommand: OS intents

    @Test func backPhrases() {
        for phrase in ["back", "go back", "navigate back", "take me back", "previous screen"] {
            #expect(route(phrase) == .back, "\(phrase) must route to back")
        }
    }

    @Test func trailingPunctuationAndCaseAreStripped() {
        #expect(route("  Go Back!!  ") == .back)
        #expect(route("HOME.") == .home)
        #expect(route("go back?") == .back)
        #expect(route("go back,") == .back)
    }

    @Test func homePhrases() {
        for phrase in ["home", "go home", "take me home", "go to home", "home screen",
                       "go to home screen"] {
            #expect(route(phrase) == .home, "\(phrase) must route to home")
        }
    }

    @Test func closeAppPhrases() {
        for phrase in ["close app", "close this app", "close the app"] {
            #expect(route(phrase, activeApp: "messages", topScreenId: "screen-1")
                == .closeActiveApp)
        }
    }

    @Test func switcherPhrases() {
        for phrase in ["switcher", "app switcher", "open switcher", "show the app switcher",
                       "recent apps", "open recent apps"] {
            #expect(route(phrase) == .openSwitcher, "\(phrase) must open the switcher")
        }
    }

    // MARK: - routeCommand: known apps

    @Test func openPrefixLaunchesAKnownAppFromInsideAnotherApp() {
        for phrase in ["open music", "launch music", "switch to music", "go to music"] {
            let decision = route(phrase, activeApp: "messages", topScreenId: "screen-1")
            guard case .launch(let app) = decision else {
                Issue.record("\(phrase) did not launch: \(decision)")
                continue
            }
            #expect(app.id == "music")
        }
    }

    @Test func aBareAppNameOnlyLaunchesFromHome() {
        // At home a bare name is a launch...
        guard case .launch(let app) = route("music") else {
            Issue.record("bare app name at home must launch")
            return
        }
        #expect(app.id == "music")

        // ...but inside an app it is a request for a screen.
        #expect(
            route("music", activeApp: "messages", topScreenId: "screen-1")
                == .resolveAction("music"))
    }

    @Test func theOpenTargetIsMatchedBySubstring() {
        guard case .launch(let app) = route("open the flights app", activeApp: "messages",
                                            topScreenId: "screen-1")
        else {
            Issue.record("substring match failed")
            return
        }
        #expect(app.id == "flights")
    }

    @Test func anUnknownOpenTargetFallsThroughToGeneration() {
        // "open my wardrobe" matches no catalog app: inside an app it becomes a
        // screen request, at home it summons.
        #expect(
            route("open my wardrobe", activeApp: "messages", topScreenId: "screen-1")
                == .resolveAction("open my wardrobe"))
        guard case .summon(let app) = route("open my wardrobe") else {
            Issue.record("unknown open target at home must summon")
            return
        }
        #expect(app.id == "summon-open-my-wardrobe")
    }

    // MARK: - routeCommand: generation

    @Test func emptyTranscriptDoesNothing() {
        #expect(route("") == .none)
        #expect(route("   \n ") == .none)
    }

    @Test func aRequestInsideAnAppResolvesAgainstTheTopScreen() {
        #expect(
            route("show me tomorrow", activeApp: "calendar", topScreenId: "screen-3")
                == .resolveAction("show me tomorrow"))
    }

    @Test func aRequestWithAnActiveAppButNoTopScreenSummons() {
        guard case .summon = route("do a thing", activeApp: "calendar", topScreenId: nil) else {
            Issue.record("no top screen must fall through to summon")
            return
        }
    }

    @Test func summonUsesTheExactRNRequestTemplate() {
        guard case .summon(let app) = route("find me a plumber") else {
            Issue.record("expected a summon")
            return
        }
        #expect(app.id == "summon-find-me-a-plumber")
        #expect(app.name == "find me a plumber")
        #expect(app.emoji == "✨")
        #expect(
            app.request
                == "Open the perfect app screen for this request: \"find me a plumber\". Invent a polished, realistic screen that fulfils it."
        )
    }

    @Test func aLongSummonNameIsTruncatedButTheRequestKeepsEverything() {
        let text = "plan an elaborate three week itinerary across southern italy"
        guard case .summon(let app) = route(text) else {
            Issue.record("expected a summon")
            return
        }
        #expect(app.name == "plan an elaborate three …")
        #expect(app.name.utf16.count == ShellRouter.summonNameLimit + 1)  // + the ellipsis
        // RN keeps the slug's boundary dashes (Apps.summonApp), so the
        // truncated tail's space + ellipsis collapse into one trailing dash.
        #expect(app.id == "summon-plan-an-elaborate-three-")
        #expect(shellContains(app.request, text))
    }

    @Test func aNameExactlyAtTheLimitIsNotTruncated() {
        let text = String(repeating: "a", count: 24)
        guard case .summon(let app) = route(text) else {
            Issue.record("expected a summon")
            return
        }
        #expect(app.name == text)
    }

    // MARK: - handleAction: genos:// links

    private func decide(
        url: String? = nil,
        message: String = "",
        activeApp: String? = "messages",
        topScreenId: String? = "screen-1",
        generating: Bool = false
    ) -> ShellActionDecision {
        var params: [String: GenosJSONValue] = [:]
        if let url { params["url"] = .string(url) }
        let event = ActionEvent(
            type: url == nil ? .continueConversation : .openURL,
            params: params,
            humanFriendlyMessage: message
        )
        return ShellRouter.decide(
            event: event, activeApp: activeApp, topScreenId: topScreenId, generating: generating)
    }

    @Test func toastLink() {
        #expect(decide(url: "genos://toast?text=Saved+%E2%9C%93") == .toast("Saved ✓"))
    }

    @Test func toastLinkFallsBackToTheDefaultText() {
        #expect(decide(url: "genos://toast") == .toast(ShellRouter.defaultToastText))
        #expect(decide(url: "genos://toast?text=") == .toast(ShellRouter.defaultToastText))
    }

    @Test func openLinkNeedsBothAppAndRequest() {
        #expect(
            decide(url: "genos://open?app=music&request=play%20jazz")
                == .deepLink(appId: "music", request: "play jazz"))
        #expect(decide(url: "genos://open?app=music") == .ignore)
        #expect(decide(url: "genos://open?request=play") == .ignore)
    }

    @Test func backAndHomeLinks() {
        #expect(decide(url: "genos://back") == .back)
        #expect(decide(url: "genos://home") == .home)
    }

    @Test func anUnknownGenosCommandIsIgnored() {
        #expect(decide(url: "genos://teleport?to=mars") == .ignore)
        // Unparseable: the scheme matched but the shape did not.
        #expect(decide(url: "genos://9?x=1") == .ignore)
    }

    @Test func aGenosLinkNeverFallsThroughToTheModel() {
        // Even with a message attached, the url wins and the tap stays local.
        #expect(decide(url: "genos://back", message: "show me more") == .back)
    }

    @Test func externalURLsOpenInTheBrowser() {
        #expect(
            decide(url: "https://cloud.cerebras.ai")
                == .openExternalURL("https://cloud.cerebras.ai"))
        #expect(decide(url: "mailto:a@b.c") == .openExternalURL("mailto:a@b.c"))
    }

    // MARK: - handleAction: generation

    @Test func aMessageBecomesAChildScreen() {
        #expect(decide(message: "  Show the receipt  ") == .resolveAction("Show the receipt"))
    }

    @Test func anEmptyMessageOrNoActiveAppIsIgnored() {
        #expect(decide(message: "   ") == .ignore)
        #expect(decide(message: "x", activeApp: nil) == .ignore)
        #expect(decide(message: "x", topScreenId: nil) == .ignore)
    }

    @Test func aTapWhileTheParentStreamsIsNeverDroppedSilently() {
        #expect(decide(message: "Show the receipt", generating: true) == .stillMaterializing)
        #expect(
            ShellRouter.stillMaterializingToast == "Still materializing - try again in a second")
    }

    @Test func theStreamingGuardRunsBeforeTheNavigationGuards() {
        // RN checks `generating` first, so even a navigation-shaped request
        // toasts while the parent streams.
        #expect(decide(message: "go back", generating: true) == .stillMaterializing)
    }

    // MARK: - handleAction: navigation-shaped requests

    @Test func navigationShapedRequestsGoToTheOSNotTheModel() {
        for message in [
            "genos home", "GenOS Home", "genoshome", "take me to all your apps", "all the apps",
            "all apps", "show the app list", "app grid", "app drawer", "app launcher",
            "open the main menu",
        ] {
            #expect(decide(message: message) == .home, "\(message) must go home")
        }
    }

    @Test func theAppsGuardIsLiteralAboutItsDeterminers() {
        // RN: /all (your |the )?apps/ - "all my apps" is NOT in the pattern, so
        // it reaches the model like any other request. Pinned so a "helpful"
        // widening of the guard is a deliberate change, not a silent one.
        #expect(decide(message: "all my apps") == .resolveAction("all my apps"))
    }

    @Test func anAppsOwnHomeScreenIsNotOSHome() {
        // "Settings home screen" is an app home - the model should render it.
        #expect(decide(message: "Settings home screen") == .resolveAction("Settings home screen"))
        #expect(decide(message: "Back to the inbox") == .resolveAction("Back to the inbox"))
    }

    @Test func backShapedRequestsPopInsteadOfGenerating() {
        for message in [
            "back", "Back", "go back", "return back", "navigate back",
            "back to previous", "back to the previous", "back to previous screen",
            "back to the previous screen",
        ] {
            #expect(decide(message: message) == .back, "\(message) must pop")
        }
    }

    @Test func backLikeMessagesThatAreNotNavigationStillGenerate() {
        #expect(decide(message: "back up my photos") == .resolveAction("back up my photos"))
        #expect(decide(message: "go back to Goa") == .resolveAction("go back to Goa"))
    }

    // MARK: - regex parity with the RN source

    /// The ported patterns are transcriptions; if GenOS.tsx changes one, this
    /// fails and forces the port to follow.
    @Test func rnSourceStillDeclaresThePortedRegexes() throws {
        let source = try Repo.text("src/genos/GenOS.tsx")

        let expected = [
            #"/^(go |navigate |take me )?back$/"#,
            #"/^(go |take me |go to )?home( screen)?$/"#,
            #"/^close( this| the)? app$/"#,
            #"/^(open |show )?(the )?(app )?(switcher|recent apps)$/"#,
            #"/^(?:open|launch|switch to|go to)\s+(.+)$/"#,
            #"/^(go |return |navigate )?back( to( the)? previous( screen)?)?$/i"#,
            #"app (list|grid|drawer|launcher)|main menu/i"#,
            #"lower === "previous screen""#,
            #"text.length > 24"#,
        ]
        for pattern in expected {
            #expect(source.contains(pattern), "GenOS.tsx no longer contains \(pattern)")
        }
    }
}
