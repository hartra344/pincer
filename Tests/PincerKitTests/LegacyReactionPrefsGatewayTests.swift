import Foundation
import Synchronization
import Testing
@testable import PincerKit

private actor FirstFitGate {
    private let entryProbe = Mutex(false)
    private let release = Gate()
    private var calls = 0

    nonisolated var hasEntered: Bool { self.entryProbe.withLock { $0 } }
    func open() async { await self.release.open() }

    func fit(_ entries: [String: String], preserving key: String?) async -> [String: String]? {
        self.calls += 1
        if self.calls == 1 {
            self.entryProbe.withLock { $0 = true }
            await self.release.wait()
        }
        return await Task.detached(priority: .utility) {
            LegacyReactionPrefs.fitting(entries, preserving: key)
        }.value
    }
}

@MainActor
@Suite("Legacy reaction preference sync", .serialized)
struct LegacyReactionPrefsGatewayTests {
    private func encodedSize(_ entries: [String: String]) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries).count
    }

    @Test func nativeGatewayFallbackCapsWireMapAndRetainsMigrationSource() async throws {
        let fake = try FakePrefsGateway()
        fake.advertisedMethods += ["session.reactions.set", "session.reactions.list"]
        let sessionKey = "agent:main:main"
        let legacy = Dictionary(uniqueKeysWithValues: (0..<140).map { index in
            (Reactions.prefEntryKey(sessionKey: sessionKey, messageId: String(format: "legacy-%03d", index)), "👍")
        })
        fake.seed(Reactions.prefKey, legacy)

        let h = try await PrefsHarness(sharing: fake)
        defer {
            ReactionStore(gatewayId: h.profile.id.uuidString, defaults: h.scratch.defaults).removeAll()
            h.finish()
            fake.stop()
        }

        #expect(h.store.advertisedNativeSessionReactions)
        #expect(h.store.reactions == legacy, "first sync keeps the full local source for native migration")
        let initiallyFitted = try #require(fake.map(Reactions.prefKey))
        #expect(try self.encodedSize(initiallyFitted) <= LegacyReactionPrefs.syncedByteBudget)

        // Simulate a native request failure after the Gateway advertised support. The fallback
        // users.prefs write must fit while local-only migration entries stay available.
        h.store.sessionReactionsOff = true
        let currentId = "latest-gesture"
        let currentKey = Reactions.prefEntryKey(sessionKey: sessionKey, messageId: currentId)
        h.store.setReactions(["🧭"], sessionKey: sessionKey, messageId: currentId)
        let written = await eventually(timeout: .seconds(10)) {
            fake.map(Reactions.prefKey)?[currentKey] == "🧭"
                && h.store.pendingPrefChanges[Reactions.prefKey] == nil
        }
        #expect(written, "the protected current reaction reaches the bounded wire map")
        let remote = try #require(fake.map(Reactions.prefKey))
        #expect(try self.encodedSize(remote) <= LegacyReactionPrefs.syncedByteBudget)

        let localOnlyKey = Reactions.prefEntryKey(sessionKey: sessionKey, messageId: "legacy-000")
        #expect(remote[localOnlyKey] == nil && h.store.reactions[localOnlyKey] == "👍",
                "wire pruning does not replace the local native-migration source")
        await h.store.pull(h.store.syncedMap(Reactions.prefKey))
        #expect(h.store.reactions[localOnlyKey] == "👍", "a prefs pull preserves local-only migration entries")

        h.store.setReactions([], sessionKey: sessionKey, messageId: "legacy-000")
        #expect(h.store.reactions[localOnlyKey] == nil, "successful migration deletion removes the local source entry")
        let removed = await eventually(timeout: .seconds(10)) {
            h.store.pendingPrefChanges[Reactions.prefKey] == nil
                && fake.map(Reactions.prefKey)?[localOnlyKey] == nil
        }
        #expect(removed)
    }

    @Test func staleReactionFitDoesNotSendAfterReconnect() async throws {
        let fake = try FakePrefsGateway()
        let h = try await PrefsHarness(sharing: fake)
        defer {
            h.finish()
            fake.stop()
        }

        let sessionKey = "agent:main:main"
        let legacy = Dictionary(uniqueKeysWithValues: (0..<140).map { index in
            (Reactions.prefEntryKey(sessionKey: sessionKey, messageId: String(format: "stale-%03d", index)), "👍")
        })
        fake.seed(Reactions.prefKey, legacy)
        let map = h.store.syncedMap(Reactions.prefKey)
        let oldEpoch = h.store.connectionEpoch
        h.store.defaults.set(false, forKey: map.syncedDefaultsKey)

        let gate = FirstFitGate()
        h.store.legacyReactionPrefsFitter = { entries, key in
            await gate.fit(entries, preserving: key)
        }
        let stalePullFinished = Mutex(false)
        let stalePull = Task {
            defer { stalePullFinished.withLock { $0 = true } }
            await h.store.pullMaps([map], epoch: oldEpoch)
        }
        let entered = await eventually(timeout: .seconds(15)) { gate.hasEntered }
        #expect(entered, "the old pull reaches the held reaction fitter")
        guard entered else {
            // Always open the fitter gate before cancellation, in case the RPC reaches it just after
            // the timeout. The Gateway request itself has a 15-second timeout, so settling is bounded.
            await gate.open()
            stalePull.cancel()
            let settled = await eventually(timeout: .seconds(15)) { stalePullFinished.withLock { $0 } }
            #expect(settled, "the timed-out old pull settles after its fitter gate is released")
            return
        }

        // Reconnect while the old pull is suspended in its detached-fit seam. The new epoch
        // completes the same bounded pull; resuming the old fit must not issue another write.
        h.store.stop()
        h.store.start()
        let reconnectedAndSynced = await eventually(timeout: .seconds(15)) {
            h.store.state.isConnected
                && h.store.connectionEpoch > oldEpoch
                && h.store.defaults.bool(forKey: map.syncedDefaultsKey)
        }
        #expect(reconnectedAndSynced, "the new connection epoch finishes its reaction sync")
        let setsAfterReconnect = fake.sets.count

        await gate.open()
        _ = await stalePull.value
        await h.settle()
        #expect(fake.sets.count == setsAfterReconnect,
                "a fit from the prior connection epoch must not send a users.prefs.set")
    }
}
