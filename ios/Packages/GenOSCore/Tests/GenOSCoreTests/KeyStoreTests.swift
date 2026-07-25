import Foundation
import Testing
@testable import GenOSCore

// src/config.ts KeyStore
@MainActor
@Suite struct KeyStoreTests {
    @Test func envKeyWinsImmediatelyWithoutHydration() async {
        let store = MemorySecureStore()
        await store.seed(KeyStore.storageKey, "persisted-key")
        let ks = KeyStore(envKey: "  env-key  ", store: store)
        #expect(ks.status == .present)
        #expect(ks.get() == "env-key")
        await ks.hydrate()
        // Env key never overwritten by the persisted value.
        #expect(ks.get() == "env-key")
    }

    @Test func hydrationFindsPersistedKey() async {
        let store = MemorySecureStore()
        await store.seed(KeyStore.storageKey, "  stored-key \n")
        let ks = KeyStore(envKey: nil, store: store)
        #expect(ks.status == .loading)
        #expect(ks.get() == nil)
        await ks.hydrate()
        #expect(ks.status == .present)
        #expect(ks.get() == "stored-key")
    }

    @Test func hydrationWithNothingStoredIsMissing() async {
        let ks = KeyStore(envKey: nil, store: MemorySecureStore())
        await ks.hydrate()
        #expect(ks.status == .missing)
        #expect(ks.get() == nil)
    }

    @Test func setTrimsPersistsAndNotifies() async {
        let store = MemorySecureStore()
        let ks = KeyStore(envKey: nil, store: store)
        await ks.hydrate()

        var notifications = 0
        let unsubscribe = ks.subscribe { notifications += 1 }
        ks.set("  fresh-key ")
        #expect(ks.status == .present)
        #expect(ks.get() == "fresh-key")
        #expect(notifications == 1)
        // Persistence is best-effort background work - poll for it.
        for _ in 0..<50 {
            if await store.stored(KeyStore.storageKey) != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await store.stored(KeyStore.storageKey) == "fresh-key")
        unsubscribe()
    }

    @Test func markRejectedDropsKeyAndClearsPersistence() async {
        let store = MemorySecureStore()
        await store.seed(KeyStore.storageKey, "bad-key")
        let ks = KeyStore(envKey: nil, store: store)
        await ks.hydrate()
        #expect(ks.get() == "bad-key")

        ks.markRejected("bad-key")
        #expect(ks.status == .rejected)
        #expect(ks.get() == nil)
        for _ in 0..<50 {
            if await store.stored(KeyStore.storageKey) == nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await store.stored(KeyStore.storageKey) == nil)
    }

    @Test func markRejectedIsNoOpForStaleKey() async {
        // A stale in-flight stream must not wipe a newly entered valid key.
        let store = MemorySecureStore()
        let ks = KeyStore(envKey: nil, store: store)
        await ks.hydrate()
        ks.set("new-key")

        ks.markRejected("old-key")
        #expect(ks.status == .present)
        #expect(ks.get() == "new-key")
    }

    @Test func whitespaceOnlyKeyStoresEmptyAndStatusPresent() async {
        // RN parity (config.ts): set('  ') stores '' and setStatus("present")
        // runs UNCONDITIONALLY - the gate shows present even though the key
        // is unusable; the stream client rejects it locally (falsy check).
        let store = MemorySecureStore()
        let ks = KeyStore(envKey: nil, store: store)
        await ks.hydrate()

        ks.set("   ")
        #expect(ks.status == .present)
        #expect(ks.get() == "")
        // The empty trimmed value is persisted, like RN's persistedWrite("").
        for _ in 0..<50 {
            if await store.stored(KeyStore.storageKey) != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await store.stored(KeyStore.storageKey) == "")
    }

    @Test func setTrimsExactEcmaScriptWhitespaceSet() async {
        // JS key.trim() strips U+FEFF and NBSP; Foundation's
        // .whitespacesAndNewlines would leave the BOM in place.
        let ks = KeyStore(envKey: nil, store: MemorySecureStore())
        await ks.hydrate()
        ks.set("\u{FEFF} real-key \u{00A0}")
        #expect(ks.get() == "real-key")
    }

    @Test func keyEnteredWhileHydrationInFlightWins() async {
        let store = MemorySecureStore()
        await store.seed(KeyStore.storageKey, "persisted-old")
        await store.gate()

        let ks = KeyStore(envKey: nil, store: store)
        let hydration = Task { await ks.hydrate() }
        // Give hydration a chance to start and block on the gated read.
        await Task.yield()

        ks.set("typed-while-loading")
        #expect(ks.status == .present)

        await store.releaseReads()
        await hydration.value

        // The late-arriving persisted key must not overwrite the typed one.
        #expect(ks.get() == "typed-while-loading")
        #expect(ks.status == .present)
    }
}
