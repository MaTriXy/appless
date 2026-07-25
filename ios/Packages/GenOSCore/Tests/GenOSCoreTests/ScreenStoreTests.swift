import Foundation
import Testing
@testable import GenOSCore

// src/genos/store.ts ScreenStore - 50ms flush coalescing.
@MainActor
@Suite struct ScreenStoreFlushTests {
    func makeStore() -> (ManualClock, ScreenStore, () -> Int) {
        let clock = ManualClock()
        let store = ScreenStore(clock: clock)
        let box = NotifyCounter()
        _ = store.subscribe { box.count += 1 }
        return (clock, store, { box.count })
    }

    final class NotifyCounter {
        var count = 0
    }

    func seed(_ store: ScreenStore, id: String = "s1") {
        store.upsert(Screen(id: id, appId: "a", appName: "A", request: "r"))
    }

    @Test func upsertNotifiesImmediately() {
        let (_, store, notifies) = makeStore()
        seed(store)
        #expect(notifies() == 1)
        #expect(store.version == 1)
    }

    @Test func appendsWithinWindowCoalesceToOneNotify() {
        let (clock, store, notifies) = makeStore()
        seed(store)
        let base = notifies()

        store.append("s1", delta: "a")
        store.append("s1", delta: "b")
        store.append("s1", delta: "c")
        // No notify until the flush window elapses.
        #expect(notifies() == base)
        clock.advance(by: 49)
        #expect(notifies() == base)
        clock.advance(by: 1)
        #expect(notifies() == base + 1)
        // Nothing else pending.
        clock.advance(by: 200)
        #expect(notifies() == base + 1)
    }

    @Test func appendContentIsSynchronousReadYourWrites() {
        let (_, store, _) = makeStore()
        seed(store)
        store.append("s1", delta: "hello ")
        store.append("s1", delta: "world")
        // get() sees the latest content before any flush happens.
        #expect(store.get("s1")?.content == "hello world")
    }

    @Test func appendFlipsStatusStreamingAndClearsSearching() {
        let (_, store, _) = makeStore()
        store.upsert(Screen(id: "s1", appId: "a", appName: "A", request: "r", status: .pending, searching: true))
        store.append("s1", delta: "x")
        #expect(store.get("s1")?.status == .streaming)
        #expect(store.get("s1")?.searching == false)
    }

    @Test func patchFlushesBufferedNotifyImmediately() {
        let (clock, store, notifies) = makeStore()
        seed(store)
        let base = notifies()

        store.append("s1", delta: "partial")
        #expect(notifies() == base)
        // Status change flushes the buffered streaming notify with it, now.
        store.patch("s1") { $0.status = .done }
        #expect(notifies() == base + 1)
        // The pending flush timer was cancelled - no second notify later.
        clock.advance(by: 100)
        #expect(notifies() == base + 1)
    }

    @Test func appendAfterFlushOpensANewWindow() {
        let (clock, store, notifies) = makeStore()
        seed(store)
        let base = notifies()

        store.append("s1", delta: "a")
        clock.advance(by: 50)
        #expect(notifies() == base + 1)
        store.append("s1", delta: "b")
        clock.advance(by: 50)
        #expect(notifies() == base + 2)
    }

    @Test func patchAndAppendOnMissingScreenAreNoOps() {
        let (clock, store, notifies) = makeStore()
        store.append("ghost", delta: "x")
        store.patch("ghost") { $0.status = .done }
        clock.advance(by: 100)
        #expect(notifies() == 0)
        #expect(store.get("ghost") == nil)
        #expect(store.all().isEmpty)
    }

    @Test func updatesFeedYieldsPerNotifyIncludingCoalescedFlush() async {
        let clock = ManualClock()
        let store = ScreenStore(clock: clock)
        var iterator = store.updates.makeAsyncIterator()

        // upsert notifies immediately - the yield is buffered for the reader.
        seed(store)
        #expect(await iterator.next() != nil)

        // Streaming appends coalesce to a single yield at the flush window.
        store.append("s1", delta: "a")
        store.append("s1", delta: "b")
        clock.advance(by: 50)
        #expect(await iterator.next() != nil)
        #expect(store.get("s1")?.content == "ab")
    }

    @Test func updatesFeedBuffersOnlyNewestTickForSlowConsumers() async {
        // bufferingPolicy .bufferingNewest(1): a burst of notifies while the
        // consumer isn't reading coalesces to ONE buffered tick, not a
        // backlog of stale wake-ups.
        let clock = ManualClock()
        let store = ScreenStore(clock: clock)
        let stream = store.updates

        // Three immediate notifies before anyone reads.
        seed(store)
        store.patch("s1") { $0.status = .streaming }
        store.patch("s1") { $0.status = .done }

        let counter = NotifyCounter()
        let consumer = Task { @MainActor in
            for await _ in stream { counter.count += 1 }
        }
        // Bounded polling is INHERENT here: the assertion is about an
        // independent consumer Task's progress through an AsyncStream, so
        // there is no seam to await - and the second sleep deliberately gives
        // wrongly-queued extra ticks time to arrive (proving they do not).
        for _ in 0..<100 {
            if counter.count >= 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(counter.count == 1)

        // A fresh notify still wakes the consumer - coalescing drops stale
        // ticks, not future ones.
        store.patch("s1") { $0.searching = true }
        for _ in 0..<100 {
            if counter.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(counter.count == 2)
        consumer.cancel()
    }

    @Test func updatesFeedTerminationUnsubscribes() async {
        let clock = ManualClock()
        let store = ScreenStore(clock: clock)
        #expect(store.listenerCount == 0)

        let stream = store.updates
        #expect(store.listenerCount == 1)

        let consumer = Task { @MainActor in
            for await _ in stream {}
        }
        await Task.yield()
        consumer.cancel()
        _ = await consumer.value

        // Bounded polling is INHERENT here: AsyncStream.onTermination fires on
        // the cancelling Task's context and hops back to the MainActor, so the
        // unsubscribe is observable only after an unspecified number of hops.
        for _ in 0..<100 {
            if store.listenerCount == 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(store.listenerCount == 0)
    }
}

// JS Set iteration parity: listeners.forEach fires in insertion order, and
// deleting a listener keeps the remaining order intact.
@MainActor
@Suite struct ScreenStoreListenerOrderTests {
    final class OrderLog {
        var events: [Int] = []
    }

    @Test func listenersNotifyInInsertionOrderAndSurviveRemoval() {
        let clock = ManualClock()
        let store = ScreenStore(clock: clock)
        let log = OrderLog()
        var unsubscribes: [@MainActor () -> Void] = []
        for i in 0..<5 {
            unsubscribes.append(store.subscribe { log.events.append(i) })
        }

        store.upsert(Screen(id: "s1", appId: "a", appName: "A", request: "r"))
        #expect(log.events == [0, 1, 2, 3, 4])

        // Removing a middle listener preserves the others' insertion order
        // (JS Set.delete does not reorder survivors).
        unsubscribes[2]()
        log.events = []
        store.patch("s1") { $0.status = .done }
        #expect(log.events == [0, 1, 3, 4])
    }
}
