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

        // onTermination hops back to the MainActor - poll briefly.
        for _ in 0..<100 {
            if store.listenerCount == 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(store.listenerCount == 0)
    }
}
