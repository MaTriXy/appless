import Foundation
import Testing
@testable import GenOSCore

// src/genos/apps.ts
@Suite struct AppsCatalogTests {
    @Test func twelveBuiltInAppsWithStableIds() {
        #expect(Apps.all.count == 12)
        #expect(Apps.all.map(\.id) == [
            "messages", "food", "fitness", "banking", "flights", "calendar",
            "music", "photos", "weather", "notes", "maps", "settings",
        ])
    }

    @Test func messagesAppRequestVerbatim() {
        let messages = Apps.all.first
        #expect(messages?.name == "Messages")
        #expect(messages?.emoji == "💬")
        #expect(messages?.tileStart == "#34c759")
        #expect(messages?.tileEnd == "#28a745")
        #expect(
            messages?.request
                == "Open the \"Messages\" app home screen: an inbox list of 7 conversations with contact names, last message snippets, timestamps, and a compose button."
        )
    }

    @Test func tenSuggestionChipsPhrasedAsCommands() {
        #expect(Apps.suggestions.count == 10)
        #expect(
            Apps.suggestions.first
                == Suggestion(emoji: "🍜", label: "Order dinner", command: "order some dinner from a great place nearby")
        )
    }
}

@Suite struct SummonAppTests {
    @Test func slugLowercasesAndCollapsesNonAlphanumericRuns() {
        let app = Apps.summonApp("My  Cool App")
        #expect(app.id == "summon-my-cool-app")
        #expect(app.name == "My  Cool App")
        #expect(app.emoji == "✨")
        #expect(app.tileStart == "#5e5ce6")
        #expect(app.tileEnd == "#bf5af2")
    }

    @Test func slugKeepsBoundaryDashesFromTrailingPunctuation() {
        // replace(/[^a-z0-9]+/g, "-") does not trim: "!Hi!" → "-hi-".
        #expect(Apps.summonApp("!Hi!").id == "summon--hi-")
        #expect(Apps.summonApp("Café Räder").id == "summon-caf-r-der")
    }

    @Test func requestTemplateVerbatim() {
        #expect(
            Apps.summonApp("Plant Care").request
                == "Open an app called \"Plant Care\". Invent a plausible, polished home screen for it with realistic content and tappable rows or buttons for its main features."
        )
    }
}

// src/genos/telemetry.ts
@Suite struct TelemetryTests {
    @Test func optOutAcceptsOneAndTrueCaseInsensitive() {
        #expect(Telemetry.optedOut(env: ["POSTHOG_DISABLED": "1"]))
        #expect(Telemetry.optedOut(env: ["POSTHOG_DISABLED": "true"]))
        #expect(Telemetry.optedOut(env: ["POSTHOG_DISABLED": "TRUE"]))
        #expect(Telemetry.optedOut(env: ["DO_NOT_TRACK": "1"]))
        #expect(!Telemetry.optedOut(env: ["POSTHOG_DISABLED": "0"]))
        #expect(!Telemetry.optedOut(env: ["POSTHOG_DISABLED": "yes"]))
        #expect(!Telemetry.optedOut(env: [:]))
    }

    @Test func singleLaunchEventShape() {
        let event = Telemetry.launchEvent(distinctId: "anon-1", platform: "ios")
        #expect(event == TelemetryEvent(
            event: "appless_app_launched",
            distinctId: "anon-1",
            lib: "appless-native",
            platform: "ios"
        ))
        #expect(Telemetry.posthogHost == "https://us.i.posthog.com")
    }
}
