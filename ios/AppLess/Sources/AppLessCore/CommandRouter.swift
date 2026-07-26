//
//  CommandRouter.swift
//  AppLessCore
//
//  The two routing decisions the shell makes, lifted out of the view so Linux
//  can test them:
//
//  - ``ShellRouter/route(_:activeApp:topScreenId:apps:)`` - GenOS.tsx
//    `routeCommand`, the ask bar and the suggestion chips. OS intents
//    (back/home/close/switcher/open <app>) drive the shell directly;
//    everything else generates a screen.
//  - ``ShellRouter/decide(event:activeApp:topScreenId:generating:)`` -
//    GenOS.tsx `handleAction`, every tap inside a rendered screen.
//
//  Both are pure: they read state and return an intent. Applying the intent
//  (which touches `GenOSController` and the screen store) is the shell's job.
//
//  NO SwiftUI in this file.
//

import Foundation
import GenOSCore

// MARK: - Typed command

/// What a typed/tapped command resolves to (GenOS.tsx `routeCommand`).
public enum ShellCommand: Sendable, Equatable {
    /// Empty transcript - RN returns without doing anything.
    case none
    case back
    case home
    /// "close this app" ENDS the session, unlike Home which minimizes it.
    case closeActiveApp
    case openSwitcher
    /// A known app from the catalog: open or resume it.
    case launch(AppDef)
    /// Generate a child screen of the current top screen. Carries the ORIGINAL
    /// text (not the lower-cased, punctuation-stripped form).
    case resolveAction(String)
    /// Nothing is open and no app matched: summon a brand-new app.
    case summon(AppDef)
}

// MARK: - Tap decision

/// What a tap inside a rendered screen resolves to (GenOS.tsx `handleAction`).
public enum ShellActionDecision: Sendable, Equatable {
    case toast(String)
    /// `genos://open?app=…&request=…`
    case deepLink(appId: String, request: String)
    case back
    case home
    /// Any non-`genos://` url: hand to the system browser.
    case openExternalURL(String)
    /// Generate a child screen from this message (plus the event's formState).
    case resolveAction(String)
    /// The parent screen is still streaming - toast instead of generating a
    /// child from truncated context.
    case stillMaterializing
    /// Nothing to do (no message, no active app, unparseable genos:// url).
    case ignore
}

// MARK: - Router

public enum ShellRouter {

    /// RN `showToast(params.text || "Done ✓")` default.
    public static let defaultToastText = "Done ✓"
    /// RN's "the parent is still streaming" toast.
    public static let stillMaterializingToast = "Still materializing - try again in a second"
    /// RN truncates a summoned app's display name at 24 UTF-16 units.
    public static let summonNameLimit = 24

    // MARK: routeCommand

    /// GenOS.tsx `routeCommand`.
    ///
    /// - Parameters:
    ///   - transcript: the raw typed/spoken text.
    ///   - activeApp: the app currently on screen, or nil at home.
    ///   - topScreenId: the top screen of that app, or nil.
    ///   - apps: the catalog to match "open <app>" against.
    public static func route(
        _ transcript: String,
        activeApp: String?,
        topScreenId: String?,
        apps: [AppDef] = Apps.all
    ) -> ShellCommand {
        let text = shellTrim(transcript)
        if text.isEmpty { return .none }

        // RN: text.toLowerCase().replace(/[.!?,]+$/g, "").trim()
        let lower = shellTrim(
            ShellRegex.replacingAll("[.!?,]+\\z", in: text.lowercased(), with: ""))

        if ShellRegex.test("\\A(go |navigate |take me )?back\\z", lower)
            || lower == "previous screen"
        {
            return .back
        }
        if ShellRegex.test("\\A(go |take me |go to )?home( screen)?\\z", lower) {
            return .home
        }
        if ShellRegex.test("\\Aclose( this| the)? app\\z", lower) {
            return .closeActiveApp
        }
        if ShellRegex.test("\\A(open |show )?(the )?(app )?(switcher|recent apps)\\z", lower) {
            return .openSwitcher
        }

        // "open/launch/switch to <app>" jumps to a known app from anywhere;
        // a bare app name only launches from the home screen (inside an app it
        // is a request for a screen, not a navigation).
        let openMatch = ShellRegex.first(
            "\\A(?:open|launch|switch to|go to)\(ShellRegex.jsWS)+(\(ShellRegex.jsDot)+)\\z", lower)
        let haystack = (openMatch.flatMap { $0.count > 1 ? $0[1] : nil }) ?? lower
        if let known = apps.first(where: { shellContains(haystack, $0.name.lowercased()) }),
            openMatch != nil || activeApp == nil
        {
            return .launch(known)
        }

        if activeApp != nil, topScreenId != nil {
            return .resolveAction(text)
        }

        var app = Apps.summonApp(
            shellUTF16Count(text) > summonNameLimit
                ? "\(shellSlice(text, upTo: summonNameLimit))…" : text)
        // RN overrides the summon template for a free-text command: the app is
        // named after the truncated text, but the REQUEST carries all of it.
        app.request =
            "Open the perfect app screen for this request: \"\(text)\". Invent a polished, realistic screen that fulfils it."
        return .summon(app)
    }

    /// `@OS(open, "<arg>")`: `APPS.find(a => a.id === target || a.name.toLowerCase()
    /// === target)`, falling back to a summoned app (`GenOS.tsx` L411-414).
    ///
    /// The comparison lowercases the ARGUMENT and the catalog NAME, but not
    /// the catalog id - ids are already lowercase, and matching them
    /// case-insensitively would be a change, not a port.
    public static func osOpenTarget(argument: String, apps: [AppDef] = Apps.all) -> AppDef {
        let target = argument.lowercased()
        let known = apps.first { $0.id == target || $0.name.lowercased() == target }
        return known ?? Apps.summonApp(argument)
    }

    // MARK: handleAction

    /// RN's navigation-shaped-request guard: "show me all my apps" must reach
    /// the OS, never the model, which happily generates a fake home screen.
    /// ("Settings home screen" is an app home - NOT OS home, hence `genos
    /// home` rather than a bare `home`.)
    ///
    /// RN: /genos\s*home|all (your |the )?apps|app (list|grid|drawer|launcher)|main menu/i
    static let osHomeRequestPattern: String = {
        let ci = ShellRegex.caseInsensitive
        return [
            ci("genos") + ShellRegex.jsWS + "*" + ci("home"),
            ci("all ") + "(" + ci("your ") + "|" + ci("the ") + ")?" + ci("apps"),
            ci("app ") + "(" + ci("list") + "|" + ci("grid") + "|" + ci("drawer") + "|"
                + ci("launcher") + ")",
            ci("main menu"),
        ].joined(separator: "|")
    }()

    /// RN: /^(go |return |navigate )?back( to( the)? previous( screen)?)?$/i
    static let backRequestPattern: String = {
        let ci = ShellRegex.caseInsensitive
        return "\\A(" + ci("go ") + "|" + ci("return ") + "|" + ci("navigate ") + ")?" + ci("back")
            + "(" + ci(" to") + "(" + ci(" the") + ")?" + ci(" previous") + "("
            + ci(" screen") + ")?)?\\z"
    }()

    /// True when a tapped message is really a request to go to the OS home.
    public static func isOSHomeRequest(_ message: String) -> Bool {
        ShellRegex.test(osHomeRequestPattern, message)
    }

    /// True when a tapped message is really a request to go back.
    public static func isBackRequest(_ message: String) -> Bool {
        ShellRegex.test(backRequestPattern, message)
    }

    /// GenOS.tsx `handleAction`.
    ///
    /// - Parameters:
    ///   - event: the dispatched `ActionEvent`.
    ///   - activeApp: the app currently on screen.
    ///   - topScreenId: the screen the tap came from.
    ///   - generating: the top screen is `pending`/`streaming`.
    public static func decide(
        event: ActionEvent,
        activeApp: String?,
        topScreenId: String?,
        generating: Bool
    ) -> ShellActionDecision {
        // 1. genos:// deep links are handled entirely by the shell.
        if let url = event.url, jsURLIsGenos(url) {
            guard let parsed = Lang.parseGenosUrl(url) else { return .ignore }
            switch parsed.cmd {
            case "toast":
                let text = parsed.params["text"] ?? ""
                return .toast(text.isEmpty ? defaultToastText : text)
            case "open":
                let app = parsed.params["app"] ?? ""
                let request = parsed.params["request"] ?? ""
                guard !app.isEmpty, !request.isEmpty else { return .ignore }
                return .deepLink(appId: app, request: request)
            case "back":
                return .back
            case "home":
                return .home
            default:
                return .ignore
            }
        }

        // 2. Any other url opens externally.
        if let url = event.url, !url.isEmpty {
            return .openExternalURL(url)
        }

        // 3. Otherwise it is a request for a screen.
        let message = shellTrim(event.humanFriendlyMessage)
        guard !message.isEmpty, topScreenId != nil, activeApp != nil else { return .ignore }

        // Never drop the tap silently while the parent streams: generating a
        // child from a partial parent gives the model truncated context, and a
        // dead button reads as "broken" on a slow connection.
        if generating { return .stillMaterializing }

        if isOSHomeRequest(message) { return .home }
        if isBackRequest(message) { return .back }
        return .resolveAction(message)
    }

    /// RN `url.startsWith("genos://")` - UTF-16-level (see `shellContains`).
    static func jsURLIsGenos(_ url: String) -> Bool {
        url.unicodeScalars.starts(with: "genos://".unicodeScalars)
    }
}
