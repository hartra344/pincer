import Foundation
import Testing
@testable import PincerKit

@Suite struct ReactionStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ReactionStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func roundTripsAndWritesOnlyChangedBuckets() {
        let (defaults, suite) = self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReactionStore(gatewayId: "g1", defaults: defaults)
        var map = ["s1|m1": "👍", "s2|m1": "🎉"]
        store.apply(old: [:], new: map)
        #expect(store.load() == map)

        let b1 = "pincer.reactions.g1.s." + ReactionStore.bucketName(forEntry: "s1|m1")
        let b2 = "pincer.reactions.g1.s." + ReactionStore.bucketName(forEntry: "s2|m1")
        #expect(b1 != b2)
        // Poison s2's bucket: an apply touching only s1 must not rewrite it.
        defaults.set(["sentinel": "x"], forKey: b2)
        let old = map
        map["s1|m2"] = "👀"
        store.apply(old: old, new: map)
        #expect(defaults.dictionary(forKey: b2) as? [String: String] == ["sentinel": "x"])
        #expect((defaults.dictionary(forKey: b1) as? [String: String])?.count == 2)
    }

    @Test func removingLastEntryDropsBucketAndIndex() {
        let (defaults, suite) = self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReactionStore(gatewayId: "g1", defaults: defaults)
        store.apply(old: [:], new: ["s1|m1": "👍"])
        store.apply(old: ["s1|m1": "👍"], new: [:])
        #expect(store.load().isEmpty)
        #expect(defaults.object(forKey: store.indexKey) == nil)
    }

    @Test func migratesLegacyMapOnce() {
        let (defaults, suite) = self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ["s1|m1": "👍 🎉", "s2|m9": "✅", "agent:main:main|m3": "👀"]
        defaults.set(legacy, forKey: "pincer.reactions.g1")
        let store = ReactionStore(gatewayId: "g1", defaults: defaults)
        #expect(store.load() == legacy)
        #expect(defaults.object(forKey: "pincer.reactions.g1") == nil)
        store.migrateIfNeeded()
        #expect(store.load() == legacy)
    }

    @Test func interruptedMigrationLosesNothing() {
        let (defaults, suite) = self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ["s1|m1": "👍", "s2|m1": "🎉"]
        defaults.set(legacy, forKey: "pincer.reactions.g1")
        // A crash after one bucket was written, before the index and the legacy removal.
        defaults.set(["s1|m1": "👍"], forKey: "pincer.reactions.g1.s." + ReactionStore.bucketName(forEntry: "s1|m1"))
        let store = ReactionStore(gatewayId: "g1", defaults: defaults)
        #expect(store.load() == legacy)
        #expect(defaults.object(forKey: "pincer.reactions.g1") == nil)
    }

    @Test func removeAllClearsOneGatewayOnly() {
        let (defaults, suite) = self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ReactionStore(gatewayId: "g1", defaults: defaults)
        let b = ReactionStore(gatewayId: "g2", defaults: defaults)
        a.apply(old: [:], new: ["s1|m1": "👍"])
        b.apply(old: [:], new: ["s1|m1": "🎉"])
        defaults.set(["s1|m1": "👍"], forKey: "pincer.reactions.g1")
        a.removeAll()
        #expect(a.load().isEmpty)
        #expect(b.load() == ["s1|m1": "🎉"])
        #expect(defaults.object(forKey: "pincer.reactions.g1") == nil)
    }
}
