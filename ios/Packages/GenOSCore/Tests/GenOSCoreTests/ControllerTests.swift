import Foundation
import Testing
@testable import GenOSCore

// src/genos/store.ts controller: caches, retry, staleness, superseded streams.
@MainActor
@Suite struct ControllerCacheTests {
    @Test func openAppLaunchesPendingScreenAndStartsStream() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        let screen = h.store.get(id)
        #expect(screen?.appId == "weather")
        #expect(screen?.appName == "Weather")
        #expect(screen?.request == sampleApp.request)
        #expect(screen?.status == .pending)
        #expect(screen?.speculative == false)
        #expect(screen?.content == "")
        #expect(h.streamer.count == 1)
        #expect(h.streamer.last?.messages.last?.content == sampleApp.request)
    }

    @Test func openAppReusesDoneHomeScreenWithoutRegenerating() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let again = h.controller.openApp(sampleApp)
        #expect(again == id)
        #expect(h.streamer.count == 1)
    }

    @Test func openAppReusesInFlightScreenUntilStale() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.clock.advance(by: 29_999)
        #expect(h.controller.openApp(sampleApp) == id)
        #expect(h.streamer.count == 1)
    }

    @Test func openAppStuckPastStaleMsRetriesInPlace() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta("partial")
        h.clock.advance(by: 30_001)
        let again = h.controller.openApp(sampleApp)
        #expect(again == id)
        // Same id, but a fresh generation was started.
        #expect(h.streamer.count == 2)
        #expect(h.store.get(id)?.status == .pending)
        #expect(h.store.get(id)?.content == "")
    }

    @Test func openAppErroredScreenRetriesInPlace() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onError(StreamError("boom"))
        #expect(h.store.get(id)?.status == .error)
        let again = h.controller.openApp(sampleApp)
        #expect(again == id)
        #expect(h.streamer.count == 2)
        #expect(h.store.get(id)?.error == nil)
    }

    @Test func deepLinkCachesByLowercasedAppIdAndRequest() {
        let h = ControllerHarness(apps: [sampleApp])
        let id = h.controller.openDeepLink(appId: "Weather", request: "show goa")
        h.finishLast(content: "root = Card()")
        // Known app resolves catalog name; repeated link reuses the screen.
        #expect(h.store.get(id)?.appId == "weather")
        #expect(h.store.get(id)?.appName == "Weather")
        #expect(h.controller.openDeepLink(appId: "weather", request: "show goa") == id)
        #expect(h.streamer.count == 1)
    }

    @Test func deepLinkUnknownAppGetsCapitalizedFallbackName() {
        let h = ControllerHarness(apps: [sampleApp])
        let id = h.controller.openDeepLink(appId: "stocks", request: "show AAPL")
        #expect(h.store.get(id)?.appId == "stocks")
        #expect(h.store.get(id)?.appName == "Stocks")
    }

    /// FINDING 4: RN's `appId.charAt(0).toUpperCase()` takes one UTF-16 CODE
    /// UNIT, so an astral first character (a lone high surrogate) has no case
    /// mapping and comes back unchanged. Swift's grapheme-level
    /// `prefix(1).uppercased()` uppercased it instead ("𐐨eseret" → "𐐀eseret").
    /// The port now matches RN and Kotlin.
    @Test func deepLinkFallbackNameLeavesAnAstralFirstCharacterAlone() {
        let h = ControllerHarness(apps: [sampleApp])
        // node: "\u{10428}eseret".charAt(0).toUpperCase() + "\u{10428}eseret".slice(1)
        //       === "\u{10428}eseret"
        let id = h.controller.openDeepLink(appId: "\u{10428}eseret", request: "show")
        #expect(h.store.get(id)?.appName == "\u{10428}eseret")
        // The appId itself is lowercased as before (no case mapping either).
        #expect(h.store.get(id)?.appId == "\u{10428}eseret")
        // The BMP path the fix must not break, including a combining mark.
        let bmp = h.controller.openDeepLink(appId: "e\u{301}cho", request: "show")
        #expect(h.store.get(bmp)?.appName == "E\u{301}cho")
    }

    @Test func resolveActionLaunchesChildInheritingParentIdentity() {
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let childId = h.controller.resolveAction(parentId: parentId, message: "show hourly")
        let child = h.store.get(childId)
        #expect(child?.appId == "weather")
        #expect(child?.appName == "Weather")
        #expect(child?.parentId == parentId)
        #expect(child?.request == "show hourly")
        #expect(child?.speculative == false)
    }

    @Test func resolveActionWithoutParentFallsBackToUnknownApp() {
        let h = ControllerHarness()
        let id = h.controller.resolveAction(parentId: "missing", message: "hello")
        #expect(h.store.get(id)?.appId == "unknown")
        #expect(h.store.get(id)?.appName == "App")
    }

    @Test func resolveActionCacheHitReturnsSameScreenWithoutNewStream() {
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let childId = h.controller.resolveAction(parentId: parentId, message: "details")
        h.finishLast(content: "root = Detail()")
        let again = h.controller.resolveAction(parentId: parentId, message: "details")
        #expect(again == childId)
        #expect(h.streamer.count == 2)
    }

    @Test func formSubmissionBypassesCacheBothWays() {
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")

        // Cached plain action exists...
        let plain = h.controller.resolveAction(parentId: parentId, message: "book table")
        h.finishLast(content: "root = Booked()")

        // ...but a form submission must never read it,
        let form1 = h.controller.resolveAction(
            parentId: parentId,
            message: "book table",
            formState: [("guests", .number(4))]
        )
        #expect(form1 != plain)
        // ...and must never write it: a second identical submission is fresh too.
        let form2 = h.controller.resolveAction(
            parentId: parentId,
            message: "book table",
            formState: [("guests", .number(4))]
        )
        #expect(form2 != form1)
        // The plain cache entry is untouched.
        #expect(h.controller.resolveAction(parentId: parentId, message: "book table") == plain)
    }

    @Test func formSubmissionAppendsJsonToRequest() {
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let id = h.controller.resolveAction(
            parentId: parentId,
            message: "book table",
            formState: [("guests", .number(4))]
        )
        #expect(h.store.get(id)?.request == "book table\n\nSubmitted form values: {\"guests\":4}")
    }

    @Test func formSubmissionJsonPreservesInsertionOrder() {
        // RN JSON.stringify(formState) emits keys in insertion order - the
        // ordered formState API must not re-sort them.
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let id = h.controller.resolveAction(
            parentId: parentId,
            message: "submit",
            formState: [("zeta", .string("z")), ("alpha", .number(1)), ("mid", .bool(true))]
        )
        #expect(
            h.store.get(id)?.request
                == "submit\n\nSubmitted form values: {\"zeta\":\"z\",\"alpha\":1,\"mid\":true}"
        )
    }

    /// FINDING 1 where it actually bites: real form state is THREE levels deep
    /// (`{formName: {fieldName: {value, componentType}}}`), and the request
    /// string built here is what the MODEL reads. Nested keys used to be
    /// alphabetized.
    @Test func formSubmissionJsonPreservesInsertionOrderAtEveryDepth() {
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let id = h.controller.resolveAction(
            parentId: parentId,
            message: "sign up",
            formState: [
                ("signup", .object([
                    "email": .object([
                        "value": .string("a@b.c"),
                        "componentType": .string("TextField"),
                    ]),
                    "age": .object([
                        "value": .number(30),
                        "componentType": .string("Slider"),
                    ]),
                ])),
            ]
        )
        // node: "sign up\n\nSubmitted form values: " + JSON.stringify(formState)
        #expect(
            h.store.get(id)?.request == "sign up\n\nSubmitted form values: "
                + #"{"signup":{"email":{"value":"a@b.c","componentType":"TextField"},"age":{"value":30,"componentType":"Slider"}}}"#
        )
    }

    @Test func emptyFormStateBehavesLikePlainAction() {
        let h = ControllerHarness()
        let parentId = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = Card()")
        let a = h.controller.resolveAction(parentId: parentId, message: "go", formState: [])
        h.finishLast(content: "root = X()")
        let b = h.controller.resolveAction(parentId: parentId, message: "go")
        #expect(a == b)
        #expect(h.store.get(a)?.request == "go")
    }

    @Test func retryScreenResetsAllGenerationState() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta("junk")
        h.streamer.last?.handlers.onError(StreamError("boom"))
        h.clock.advance(by: 500)

        h.controller.retryScreen(id)
        let s = h.store.get(id)
        #expect(s?.content == "")
        #expect(s?.status == .pending)
        #expect(s?.error == nil)
        #expect(s?.genMs == nil)
        #expect(s?.prefetched == nil)
        #expect(s?.truncated == nil)
        #expect(s?.speculative == false)
        #expect(s?.searching == false)
        #expect(s?.startedAt == 500)
        #expect(h.streamer.count == 2)
    }

    @Test func supersededStreamCallbacksAreIgnored() throws {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        let old = try #require(h.streamer.last)
        h.controller.retryScreen(id)
        let fresh = try #require(h.streamer.last)

        // The replaced stream keeps chattering - none of it may land.
        old.handlers.onDelta("stale delta")
        #expect(h.store.get(id)?.content == "")
        old.handlers.onDone(StreamEndInfo(truncated: true, dropped: false))
        #expect(h.store.get(id)?.status == .pending)
        #expect(h.store.get(id)?.truncated == nil)
        old.handlers.onError(StreamError("stale error"))
        #expect(h.store.get(id)?.error == nil)
        #expect(old.handlers.onToolRound?([]) == .abort)

        // The fresh stream still works.
        fresh.handlers.onDelta("live")
        #expect(h.store.get(id)?.content == "live")
        fresh.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(h.store.get(id)?.status == .done)
    }

    @Test func zombieCallbacksFromCancellationIgnoringStreamerAreSuppressed() throws {
        // retryScreen cancels the old token, but FakeStreamer never observes
        // cancellation - it models RN's worst case, an aborted fetch that
        // keeps delivering callbacks. Every zombie callback must be
        // suppressed, and the old onDone in particular must not evict the
        // NEW token from inflight (the stale() guard fences removeValue).
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        let old = try #require(h.streamer.last)
        old.handlers.onDelta("first half")
        h.controller.retryScreen(id)
        let fresh = try #require(h.streamer.last)
        #expect(old.token.isCancelled)
        #expect(!fresh.token.isCancelled)

        // The cancelled stream fires all three callbacks anyway - none land.
        old.handlers.onDelta("zombie delta")
        old.handlers.onDone(StreamEndInfo(truncated: true, dropped: false))
        old.handlers.onError(StreamError("zombie error"))
        let s = h.store.get(id)
        #expect(s?.content == "")
        #expect(s?.status == .pending)
        #expect(s?.error == nil)
        #expect(s?.truncated == nil)
        #expect(s?.genMs == nil)

        // The new token survived the zombie onDone (still inflight), so the
        // new stream's delta and onDone land normally.
        h.clock.advance(by: 250)
        fresh.handlers.onDelta("live content")
        #expect(h.store.get(id)?.content == "live content")
        fresh.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(h.store.get(id)?.status == .done)
        #expect(h.store.get(id)?.genMs == 250)
    }

    @Test func retryAbortsThePreviousInflightStream() throws {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        let old = try #require(h.streamer.last)
        h.controller.retryScreen(id)
        #expect(old.token.isCancelled)
        #expect(try #require(h.streamer.last).token.isCancelled == false)
    }

    @Test func synchronouslyFiringStreamerIsNotDroppedAsStale() {
        // RN sets inflight BEFORE streamScreen; a ScreenStreaming impl that
        // fires handlers synchronously inside stream() must land its deltas.
        let clock = ManualClock()
        let store = ScreenStore(clock: clock)
        let streamer = SyncFiringStreamer()
        let controller = GenOSController(store: store, streamer: streamer, clock: clock, apps: [])
        let id = controller.openApp(sampleApp)
        #expect(store.get(id)?.content == "sync delta")
        #expect(store.get(id)?.status == .done)
    }
}

// src/genos/store.ts onDone/onError/onToolRound wiring.
@MainActor
@Suite struct ControllerLifecycleTests {
    @Test func doneSetsGenMsTruncatedAndStatus() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.clock.advance(by: 1234)
        h.streamer.last?.handlers.onDelta("root = Card()")
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: true, dropped: false))
        let s = h.store.get(id)
        #expect(s?.status == .done)
        #expect(s?.genMs == 1234)
        #expect(s?.truncated == true)
        #expect(s?.osCommand == nil)
        #expect(s?.searching == false)
    }

    @Test func droppedStreamSurfacesRetryableError() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta("partial screen that looks fine")
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: true))
        let s = h.store.get(id)
        #expect(s?.status == .error)
        #expect(s?.error == "The connection dropped mid-screen - retry")
        #expect(s?.searching == false)
    }

    @Test func streamErrorPatchesScreenToError() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onError(StreamError("boom"))
        #expect(h.store.get(id)?.status == .error)
        #expect(h.store.get(id)?.error == "boom")
    }

    /// FINDING 6: RN patches `err.message`. `String(describing:)` leaked the
    /// Swift type/case spelling into `Screen.error`, which the user reads and
    /// which Kotlin spelled differently again.
    @Test func nonStreamErrorDegradesToBareMessage() {
        struct Carrier: LocalizedError {
            var errorDescription: String? { "network unreachable" }
        }
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onError(Carrier())
        #expect(h.store.get(id)?.status == .error)
        #expect(h.store.get(id)?.error == "network unreachable")
        // No type decoration of any kind reached the screen.
        #expect(h.store.get(id)?.error?.contains("Carrier") == false)
    }

    /// FINDING 5: `genMs` uses JS `Math.round`, whose ties go toward
    /// +INFINITY. `.rounded()` broke the tie away from zero, and `Int(_:)`
    /// TRAPPED on NaN / out-of-Int64 elapsed times. The same cases are pinned
    /// in the Kotlin suite so the two ports cannot drift apart.
    @Test func genMsUsesJsMathRoundAndClamps() {
        // node: Math.round(1234.5) === 1235 (a positive tie rounds up).
        let up = ControllerHarness()
        let upId = up.controller.openApp(sampleApp)
        up.clock.advance(by: 1234.5)
        up.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(up.store.get(upId)?.genMs == 1235)

        // node: Math.round(-0.5) === -0 and Math.round(-2.5) === -2. Swift's
        // .rounded() would have answered -1 and -3 for a clock that went
        // backwards (NTP step, monotonic-source swap).
        for (elapsed, expected) in [(-0.5, 0), (-2.5, -2), (-1.5, -1)] as [(Double, Int)] {
            let h = ControllerHarness()
            let id = h.controller.openApp(sampleApp)
            h.clock.advance(by: elapsed)
            h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
            #expect(h.store.get(id)?.genMs == expected, "elapsed \(elapsed)")
        }

        // Out of Int range: clamped, NOT a trap. Int(1e30) used to crash the
        // process here.
        let huge = ControllerHarness()
        let hugeId = huge.controller.openApp(sampleApp)
        huge.clock.advance(by: 1e30)
        huge.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(huge.store.get(hugeId)?.genMs == Int.max)
    }

    @Test func osCommandParsedOnDone() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.streamer.last?.handlers.onDelta("@OS(open, \"music\")")
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(h.store.get(id)?.osCommand == OSCommand(cmd: .open, arg: "music"))
        // OS-command screens never trigger prefetch.
        #expect(h.streamer.count == 1)
    }

    @Test func nonSpeculativeToolRoundResetsScreenToSearching() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta("half a screen")
        let decision = h.streamer.last?.handlers.onToolRound?([ToolRoundCall(name: "web_search", args: [:])])
        #expect(decision == .proceed)
        let s = h.store.get(id)
        #expect(s?.content == "")
        #expect(s?.status == .pending)
        #expect(s?.searching == true)
    }
}

// Speculative prefetch (MAX_PREFETCH, tool refusal, regenerate-on-tap).
@MainActor
@Suite struct PrefetchTests {
    func doneContent(actions: [String]) -> String {
        actions.map { "b = Button(\"x\", @ToAssistant(\"\($0)\"))" }.joined(separator: "\n")
    }

    @Test func visibleDoneScreenPrefetchesUpToMaxPrefetchChildren() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        let actions = (1...8).map { "action \($0)" }
        h.streamer.last?.handlers.onDelta(doneContent(actions: actions))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))

        // 1 original + 6 speculative children (cap), not 8.
        #expect(h.streamer.count == 7)
        let children = h.store.all().filter { $0.parentId == id }
        #expect(children.count == 6)
        #expect(children.allSatisfy { $0.speculative })
        #expect(Set(children.map(\.request)) == Set((1...6).map { "action \($0)" }))
        #expect(children.allSatisfy { $0.appId == "weather" && $0.appName == "Weather" })
    }

    @Test func noPrefetchWhenScreenIsNotActive() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen("someone-else")
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["a"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(h.streamer.count == 1)
        #expect(h.store.all().filter { $0.parentId == id }.isEmpty)
    }

    @Test func becomingActiveWhileAlreadyDoneTriggersPrefetch() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["late action"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        #expect(h.streamer.count == 1)

        h.controller.setActiveScreen(id)
        #expect(h.streamer.count == 2)
        let child = h.store.all().first { $0.parentId == id }
        #expect(child?.request == "late action")
        #expect(child?.speculative == true)
    }

    @Test func prefetchSkipsActionsAlreadyInTheIndex() {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["dup", "fresh"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        let streams = h.streamer.count

        // Re-activating must not relaunch the same pairs.
        h.controller.setActiveScreen(nil)
        h.controller.setActiveScreen(id)
        #expect(h.streamer.count == streams)
    }

    @Test func speculativeStreamRefusesToolRound() throws {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["needs web"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))

        let spec = try #require(h.streamer.last)
        let decision = spec.handlers.onToolRound?([ToolRoundCall(name: "web_search", args: [:])])
        #expect(decision == .abort)
        // The refusal did not touch the screen (no searching flip).
        let childId = try #require(h.store.all().first { $0.parentId == id }).id
        #expect(h.store.get(childId)?.searching != true)
    }

    @Test func tappingErroredPrefetchRegeneratesNonSpeculative() throws {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["needs web"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))

        // The speculative stream errored with the sentinel (abort path).
        let spec = try #require(h.streamer.last)
        spec.handlers.onError(StreamError(GenOSConstants.needsLiveData))
        let childId = try #require(h.store.all().first { $0.parentId == id }).id
        #expect(h.store.get(childId)?.status == .error)
        #expect(h.store.get(childId)?.error == "needs live data")

        // Tap: same id, regenerated fresh, non-speculative → tools allowed.
        let resolved = h.controller.resolveAction(parentId: id, message: "needs web")
        #expect(resolved == childId)
        #expect(h.store.get(childId)?.status == .pending)
        #expect(h.store.get(childId)?.speculative == false)
        let retried = try #require(h.streamer.last)
        #expect(retried.handlers.onToolRound?([ToolRoundCall(name: "web_search", args: [:])]) == .proceed)
        #expect(h.store.get(childId)?.searching == true)
    }

    @Test func tappingCompletedPrefetchMarksPrefetched() throws {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["ready"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        h.finishLast(content: "root = Prefetched()")

        let childId = try #require(h.store.all().first { $0.parentId == id }).id
        let resolved = h.controller.resolveAction(parentId: id, message: "ready")
        #expect(resolved == childId)
        let child = h.store.get(childId)
        #expect(child?.speculative == false)
        #expect(child?.prefetched == true)
        // No regeneration for a completed prefetch.
        #expect(h.store.get(childId)?.content == "root = Prefetched()")
    }

    @Test func tappingStillStreamingPrefetchFlipsSpeculativeWithoutPrefetchedFlag() throws {
        let h = ControllerHarness()
        let id = h.controller.openApp(sampleApp)
        h.controller.setActiveScreen(id)
        h.streamer.last?.handlers.onDelta(doneContent(actions: ["slow"]))
        h.streamer.last?.handlers.onDone(StreamEndInfo(truncated: false, dropped: false))
        h.streamer.last?.handlers.onDelta("still going")

        let childId = try #require(h.store.all().first { $0.parentId == id }).id
        _ = h.controller.resolveAction(parentId: id, message: "slow")
        let child = h.store.get(childId)
        #expect(child?.speculative == false)
        // It was tapped mid-stream, not already fully generated.
        #expect(child?.prefetched == false)
    }
}

// buildMessages: CONTEXT_DEPTH ancestor replay with cleanLang.
@MainActor
@Suite struct BuildMessagesTests {
    @Test func replaysAtMostContextDepthAncestorsTextOnly() throws {
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        h.finishLast(content: "```openui\nroot = A()\n```")
        let b = h.controller.resolveAction(parentId: a, message: "to b")
        h.finishLast(content: "root = B()")
        let c = h.controller.resolveAction(parentId: b, message: "to c")
        h.finishLast(content: "root = C()")
        let d = h.controller.resolveAction(parentId: c, message: "to d")

        let messages = h.controller.buildMessages(for: try #require(h.store.get(d)))
        // Chain capped at CONTEXT_DEPTH=2 ancestors (b, c) + the new request.
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(messages[0].content == "to b")
        #expect(messages[1].content == "root = B()")
        #expect(messages[2].content == "to c")
        #expect(messages[3].content == "root = C()")
        #expect(messages[4].content == "to d")
    }

    @Test func ancestorContentIsCleanLangStripped() throws {
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        h.finishLast(content: "```openui-lang\nroot = Fenced()\n```")
        let b = h.controller.resolveAction(parentId: a, message: "next")

        let messages = h.controller.buildMessages(for: try #require(h.store.get(b)))
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(messages[1].content == "root = Fenced()")
    }

    @Test func contentlessAncestorReplaysUserTurnOnly() throws {
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        // Parent never produced content.
        let b = h.controller.resolveAction(parentId: a, message: "child")
        let messages = h.controller.buildMessages(for: try #require(h.store.get(b)))
        #expect(messages.map(\.role) == [.user, .user])
        #expect(messages[0].content == sampleApp.request)
        #expect(messages[1].content == "child")
    }

    @Test func erroredAncestorWithPartialContentReplaysThroughCleanLang() throws {
        // An errored ancestor that streamed some content before failing still
        // replays its partial program - RN's `if (s.content)` only checks
        // truthiness, never status - and it passes through cleanLang.
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta("```openui\nroot = Partial(")
        h.streamer.last?.handlers.onError(StreamError("boom"))
        #expect(h.store.get(a)?.status == .error)
        let b = h.controller.resolveAction(parentId: a, message: "child")

        let messages = h.controller.buildMessages(for: try #require(h.store.get(b)))
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(messages[0].content == sampleApp.request)
        #expect(messages[1].content == "root = Partial(")
        #expect(messages[2].content == "child")
    }

    @Test func erroredAncestorWithEmptyContentReplaysUserTurnOnly() throws {
        // RN `if (s.content)` - "" is falsy, so an ancestor that errored
        // before any delta contributes only its user request, no assistant
        // turn.
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onError(StreamError("boom"))
        #expect(h.store.get(a)?.status == .error)
        #expect(h.store.get(a)?.content == "")
        let b = h.controller.resolveAction(parentId: a, message: "child")

        let messages = h.controller.buildMessages(for: try #require(h.store.get(b)))
        #expect(messages.map(\.role) == [.user, .user])
        #expect(messages[0].content == sampleApp.request)
        #expect(messages[1].content == "child")
    }

    @Test func streamingAncestorReplaysItsPartialContent() throws {
        // A still-streaming ancestor replays whatever partial content it has
        // accumulated so far, cleanLang-stripped.
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        h.streamer.last?.handlers.onDelta("```openui-lang\nroot = Half(")
        #expect(h.store.get(a)?.status == .streaming)
        let b = h.controller.resolveAction(parentId: a, message: "onward")

        let messages = h.controller.buildMessages(for: try #require(h.store.get(b)))
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(messages[1].content == "root = Half(")
        #expect(messages[2].content == "onward")
    }

    @Test func chainCapsAtExactlyContextDepthAncestors() throws {
        // Five-deep chain: exactly CONTEXT_DEPTH=2 nearest ancestors replay;
        // the root and great-grandparent turns are absent entirely.
        #expect(GenOSConstants.contextDepth == 2)
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        h.finishLast(content: "root = A()")
        let b = h.controller.resolveAction(parentId: a, message: "to b")
        h.finishLast(content: "root = B()")
        let c = h.controller.resolveAction(parentId: b, message: "to c")
        h.finishLast(content: "root = C()")
        let d = h.controller.resolveAction(parentId: c, message: "to d")
        h.finishLast(content: "root = D()")
        let e = h.controller.resolveAction(parentId: d, message: "to e")

        let messages = h.controller.buildMessages(for: try #require(h.store.get(e)))
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(messages.map(\.content) == ["to c", "root = C()", "to d", "root = D()", "to e"])
        let replayed = messages.compactMap(\.content)
        #expect(!replayed.contains(sampleApp.request))
        #expect(!replayed.contains("root = A()"))
        #expect(!replayed.contains("to b"))
        #expect(!replayed.contains("root = B()"))
    }

    @Test func rootScreenIsJustItsOwnRequest() throws {
        let h = ControllerHarness()
        let a = h.controller.openApp(sampleApp)
        let messages = h.controller.buildMessages(for: try #require(h.store.get(a)))
        #expect(messages == [ChatMessage(role: .user, content: sampleApp.request)])
    }
}
