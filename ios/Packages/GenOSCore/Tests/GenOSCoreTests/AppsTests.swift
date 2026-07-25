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

    @Test func launchRequestMatchesTelemetryTsExactly() {
        // telemetry.ts: POST {POSTHOG_HOST}/i/v0/e/ with the api_key constant
        // and {api_key, event, distinct_id, properties:{$lib, platform}} in
        // JSON.stringify insertion order.
        let req = Telemetry.launchRequest(distinctId: "anon-1-ab", platform: "ios")
        #expect(req.url == "https://us.i.posthog.com/i/v0/e/")
        #expect(req.method == "POST")
        #expect(req.headers == ["Content-Type": "application/json"])
        #expect(
            req.body.flatMap { String(data: $0, encoding: .utf8) }
                == "{\"api_key\":\"phc_3OLW53x09ZTVZSV6BEpj5uycj3ooqR6KOemOjx04e3D\","
                + "\"event\":\"appless_app_launched\","
                + "\"distinct_id\":\"anon-1-ab\","
                + "\"properties\":{\"$lib\":\"appless-native\",\"platform\":\"ios\"}}"
        )
    }

    @Test func fallbackIdMatchesJsAnonShape() {
        // `anon-${Date.now()}-${Math.random().toString(36).slice(2)}`.
        #expect(Telemetry.fallbackId(nowMs: 1_753_395_000_000, random: 0.5) == "anon-1753395000000-i")
        // (0).toString(36).slice(2) === "".
        #expect(Telemetry.fallbackId(nowMs: 7, random: 0) == "anon-7-")
        let id = Telemetry.fallbackId(nowMs: 1_753_395_000_123, random: 0.123456789)
        #expect(JSRegex.test("\\Aanon-[0-9]+-[0-9a-z]*\\z", id))
    }

    @Test func deviceIdPersistedOnceAndReused() async {
        let store = MemorySecureStore()
        let first = await Telemetry.deviceId(store: store, newId: { "fresh-id" })
        #expect(first == "fresh-id")
        // The persist is fire-and-forget (RN doesn't await setItemAsync) -
        // poll briefly for the detached write to land.
        var persisted: String?
        for _ in 0..<100 {
            persisted = await store.stored(Telemetry.idStorageKey)
            if persisted != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(persisted == "fresh-id")
        // A later call must reuse the persisted id, not mint a new one.
        let second = await Telemetry.deviceId(store: store, newId: { "other-id" })
        #expect(second == "fresh-id")
    }

    @Test func hungStoreWriteDoesNotDelayLaunchEvent() async {
        // RN fires SecureStore.setItemAsync().catch() WITHOUT awaiting - a
        // store whose write never completes must not block initTelemetry.
        let store = MemorySecureStore()
        await store.gateWrites()
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 200))
        await Telemetry.initTelemetry(
            env: [:],
            platform: "ios",
            store: store,
            http: http,
            newId: { "anon-hung-1" }
        )
        // initTelemetry returned and sent the event while the write is
        // still hung.
        let requests = await http.requests()
        #expect(requests.count == 1)
        #expect((await http.requestBodies()).first?["distinct_id"]?.stringValue == "anon-hung-1")
        #expect(await store.stored(Telemetry.idStorageKey) == nil)
        // Unblock the abandoned write so its continuation isn't leaked.
        await store.releaseWrites()
    }

    @Test func base36FractionDigitsPinnedDeviationFromJs() {
        // KNOWN DEVIATION (documented on base36FractionDigits): JS emits
        // shortest-round-trip digits - node: (0.1).toString(36) ===
        // "0.3lllllllllm", i.e. slice(2) === "3lllllllllm" - while the Swift
        // greedy expansion of the same double runs to 16 digits. Pinned here
        // so any drift is deliberate. Only the opaque fallback id embeds
        // this; both shapes satisfy the [0-9a-z]* id alphabet.
        #expect(Telemetry.base36FractionDigits(0.1) == "3llllllllllqsn8t")
        #expect(Telemetry.base36FractionDigits(0.1) != "3lllllllllm")
        // Exactly-representable fractions agree with JS.
        #expect(Telemetry.base36FractionDigits(0.5) == "i")
        #expect(JSRegex.test("\\A[0-9a-z]*\\z", Telemetry.base36FractionDigits(0.1)))
    }

    @Test func initTelemetrySendsOneEventThroughTheSeam() async {
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 200))
        await Telemetry.initTelemetry(
            env: [:],
            platform: "ios",
            store: MemorySecureStore(),
            http: http,
            newId: { "anon-1-x" }
        )
        let requests = await http.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.url == "https://us.i.posthog.com/i/v0/e/")
        let body = (await http.requestBodies()).first
        #expect(body?["distinct_id"]?.stringValue == "anon-1-x")
        #expect(body?["properties"]?["$lib"]?.stringValue == "appless-native")
        #expect(body?["properties"]?["platform"]?.stringValue == "ios")
    }

    @Test func initTelemetryOptedOutSendsNothing() async {
        let http = ScriptedHTTP()
        await Telemetry.initTelemetry(
            env: ["DO_NOT_TRACK": "1"],
            platform: "ios",
            store: MemorySecureStore(),
            http: http,
            newId: { "anon-1-x" }
        )
        #expect(await http.requests().isEmpty)
    }
}
