import Foundation
import Testing
@testable import PincerKit

/// #382: bookmarks sync through `users.prefs`, sharded over `Bookmark.shardCount` prefs.
@MainActor
@Suite("Bookmark sync store")
struct BookmarkSyncStoreTests {
    let suite = "pincer.tests.bookmarksync.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: self.suite)! }

    func store() -> BookmarkStore { BookmarkStore(gatewayId: UUID(), defaults: self.defaults) }

    func bookmark(_ id: String, session: String = "main", at seconds: TimeInterval = 0, preview: String? = nil) -> Bookmark {
        Bookmark(sessionKey: session, messageId: id, preview: preview ?? "Message \(id)",
                 createdAt: Date(timeIntervalSince1970: seconds))
    }

    /// Records `onChange` calls.
    final class Changes {
        var calls: [[String: String?]] = []
        var all: [String: String?] { self.calls.reduce(into: [:]) { $0.merge($1) { _, new in new } } }
    }

    func observe(_ store: BookmarkStore) -> Changes {
        let changes = Changes()
        store.onChange = { changes.calls.append($0) }
        return changes
    }

    // MARK: Encoding

    @Test func entriesRoundTripThroughTheirSyncedValue() throws {
        let original = Bookmark(sessionKey: "agent:main:main", messageId: "m-1", preview: "Hello there", role: "user",
                                messageDate: Date(timeIntervalSince1970: 1_700_000_000.123),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_100.5))
        let decoded = try #require(Bookmark(syncedKey: original.id, value: original.syncedValue))
        #expect(decoded == original)
        #expect(decoded.id == "agent:main:main\u{1F}m-1")
    }

    @Test func syncedValueIsCompactJSONWithTheSpecKeys() throws {
        let bookmark = Bookmark(sessionKey: "s", messageId: "m", preview: "Hi", role: "assistant",
                                messageDate: Date(timeIntervalSince1970: 10), createdAt: Date(timeIntervalSince1970: 20))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(bookmark.syncedValue.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["p", "r", "m", "c"])
        #expect(json["p"] as? String == "Hi")
        #expect(json["r"] as? String == "assistant")
        #expect(json["m"] as? Int == 10_000)
        #expect(json["c"] as? Int == 20_000)
        #expect(!bookmark.syncedValue.contains(" "))
    }

    @Test func missingMessageDateIsOmittedAndDecodesToNil() throws {
        let bookmark = bookmark("a", at: 5)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(bookmark.syncedValue.utf8)) as? [String: Any])
        #expect(json["m"] == nil)
        #expect(Bookmark(syncedKey: bookmark.id, value: bookmark.syncedValue)?.messageDate == nil)
    }

    @Test func syncedPreviewStaysShort() {
        let long = String(repeating: "x", count: Bookmark.previewLength)
        let value = bookmark("a", preview: long).syncedValue
        let decoded = Bookmark(syncedKey: bookmark("a").id, value: value)
        #expect(decoded != nil)
        #expect((decoded?.preview.count ?? .max) <= Bookmark.previewLength)
        #expect(value.utf8.count < 400)
    }

    @Test func undecodableEntriesDecodeToNil() {
        let id = bookmark("a").id
        #expect(Bookmark(syncedKey: id, value: "not json") == nil)
        #expect(Bookmark(syncedKey: id, value: "{}") == nil)
        #expect(Bookmark(syncedKey: id, value: #"{"p":"x"}"#) == nil)
        #expect(Bookmark(syncedKey: "no-separator", value: bookmark("a").syncedValue) == nil)
        #expect(Bookmark(syncedKey: "\u{1F}only-message", value: bookmark("a").syncedValue) == nil)
    }

    @Test func shardsAreStableAndInRange() {
        for index in 0..<200 {
            let key = bookmark("m\(index)").id
            #expect((0..<Bookmark.shardCount).contains(Bookmark.shard(ofKey: key)))
            #expect(Bookmark.shard(ofKey: key) == Bookmark.shard(ofKey: key))
        }
        #expect(Set((0..<200).map { Bookmark.shard(ofKey: "s\u{1F}m\($0)") }).count > 1)
        #expect(Bookmark.prefKey(shard: 3) == "pincer.bookmarks.3")
    }

    // MARK: apply

    @Test func applyReplacesTheShardAndSortsNewestFirstWithoutFiringOnChange() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let changes = self.observe(store)
        let all = (0..<40).map { bookmark("m\($0)", at: TimeInterval($0)) }
        let shard = Bookmark.shard(ofKey: all[0].id)
        let inShard = all.filter { Bookmark.shard(ofKey: $0.id) == shard }
        #expect(inShard.count >= 2)
        store.apply(synced: Dictionary(uniqueKeysWithValues: inShard.map { ($0.id, $0.syncedValue) }), shard: shard)
        #expect(store.bookmarks.map(\.id) == inShard.sorted { $0.createdAt > $1.createdAt }.map(\.id))
        #expect(changes.calls.isEmpty, "a pull is not a local edit")
        // A second pull replaces: the dropped entries are gone.
        let kept = inShard[0]
        store.apply(synced: [kept.id: kept.syncedValue], shard: shard)
        #expect(store.bookmarks.map(\.id) == [kept.id])
        #expect(store.isBookmarked(sessionKey: kept.sessionKey, messageId: kept.messageId))
        #expect(changes.calls.isEmpty)
    }

    @Test func applyLeavesOtherShardsAlone() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let all = (0..<40).map { bookmark("m\($0)", at: TimeInterval($0)) }
        let shardA = Bookmark.shard(ofKey: all[0].id)
        let other = all.first { Bookmark.shard(ofKey: $0.id) != shardA }!
        store.add(other)
        store.apply(synced: [:], shard: shardA)
        #expect(store.bookmarks.map(\.id) == [other.id])
    }

    @Test func applyIgnoresUndecodableValuesAndForeignShards() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let good = bookmark("good", at: 1)
        let shard = Bookmark.shard(ofKey: good.id)
        let foreign = (0..<100).map { bookmark("f\($0)") }.first { Bookmark.shard(ofKey: $0.id) != shard }!
        store.apply(synced: [good.id: good.syncedValue, "x\u{1F}broken": "garbage", foreign.id: foreign.syncedValue], shard: shard)
        #expect(store.bookmarks.map(\.id) == [good.id])
    }

    @Test func appliedBookmarksPersistLikeLocalOnes() {
        let gateway = UUID()
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: self.suite) }
        let store = BookmarkStore(gatewayId: gateway, defaults: defaults)
        let remote = bookmark("a", at: 9)
        store.apply(synced: [remote.id: remote.syncedValue], shard: Bookmark.shard(ofKey: remote.id))
        #expect(BookmarkStore(gatewayId: gateway, defaults: defaults).bookmarks.map(\.id) == [remote.id])
    }

    @Test func syncedEntriesListOneShard() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let all = (0..<30).map { bookmark("m\($0)", at: TimeInterval($0)) }
        for item in all { store.add(item) }
        for shard in 0..<Bookmark.shardCount {
            let expected = all.filter { Bookmark.shard(ofKey: $0.id) == shard }
            #expect(Set(store.syncedEntries(shard: shard).keys) == Set(expected.map(\.id)))
        }
    }

    // MARK: onChange

    @Test func addAndRemoveFireOnChangeWithTheEntryChanges() throws {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let changes = self.observe(store)
        let item = bookmark("a", at: 7)
        store.add(item)
        #expect(changes.calls.count == 1)
        #expect(changes.calls[0][item.id] == .some(item.syncedValue))
        #expect(changes.calls[0].count == 1)
        store.add(item)
        #expect(changes.calls.count == 1, "a duplicate add changes nothing")
        store.remove(sessionKey: item.sessionKey, messageId: item.messageId)
        #expect(changes.calls.count == 2)
        #expect(changes.calls[1] == [item.id: nil])
        store.remove(sessionKey: item.sessionKey, messageId: item.messageId)
        #expect(changes.calls.count == 2, "removing what isn't there changes nothing")
    }

    @Test func toggleFiresAnUpsertThenADelete() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let changes = self.observe(store)
        let item = bookmark("a")
        store.toggle(item)
        store.toggle(item)
        #expect(changes.calls.count == 2)
        #expect(changes.calls[0][item.id] == .some(item.syncedValue))
        #expect(changes.calls[1] == [item.id: nil])
    }

    @Test func removeAllForASessionDeletesItsEntries() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let a = bookmark("a", session: "one"), b = bookmark("b", session: "one"), c = bookmark("c", session: "two")
        for item in [a, b, c] { store.add(item) }
        let changes = self.observe(store)
        store.removeAll(sessionKey: "one")
        #expect(changes.all == [a.id: nil, b.id: nil])
        #expect(store.bookmarks.map(\.id) == [c.id])
    }

    @Test func removeAllOnGatewayRemovalDoesNotPushDeletes() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        store.add(bookmark("a"))
        let changes = self.observe(store)
        store.removeAll()
        #expect(changes.calls.isEmpty)
        #expect(store.bookmarks.isEmpty)
    }

    @Test func overTheLimitDropsTheOldestAndPushesItAsADelete() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let limit = BookmarkStore.limit
        for index in 0..<limit { store.add(bookmark("m\(index)", at: TimeInterval(index + 1))) }
        #expect(store.bookmarks.count == limit)
        let changes = self.observe(store)
        let newest = bookmark("new", at: TimeInterval(limit + 10))
        store.add(newest)
        #expect(store.bookmarks.count == limit)
        let oldest = bookmark("m0", at: 1)
        #expect(!store.isBookmarked(sessionKey: "main", messageId: "m0"))
        #expect(store.isBookmarked(sessionKey: "main", messageId: "new"))
        #expect(changes.calls.count == 1)
        #expect(changes.calls[0][newest.id] == .some(newest.syncedValue))
        #expect(changes.calls[0][oldest.id] == .some(nil), "the dropped bookmark is deleted remotely too")
        #expect(store.droppedCount >= 1)
    }

    @Test func dropNoticeIncrementsOncePerAddThatDropsAndApplyNeverTouchesIt() {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        for index in 0..<BookmarkStore.limit { store.add(bookmark("m\(index)", at: TimeInterval(index + 1))) }
        #expect(store.dropNotice == 0 && store.droppedCount == 0)
        store.add(bookmark("over-1", at: 10_000))
        #expect(store.dropNotice == 1)
        #expect(store.droppedCount >= 1)
        store.add(bookmark("over-2", at: 10_001))
        #expect(store.dropNotice == 2)
        let (notice, dropped) = (store.dropNotice, store.droppedCount)
        // Pulls and duplicate adds leave both alone.
        let remote = bookmark("remote", at: 20_000)
        store.apply(synced: [remote.id: remote.syncedValue], shard: Bookmark.shard(ofKey: remote.id))
        store.apply(synced: [:], shard: 0)
        store.add(remote)
        #expect(store.dropNotice == notice && store.droppedCount == dropped)
    }

    @Test func persistsAcrossInstancesAsBefore() {
        let gateway = UUID()
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: self.suite) }
        BookmarkStore(gatewayId: gateway, defaults: defaults).add(bookmark("a"))
        #expect(BookmarkStore(gatewayId: gateway, defaults: defaults).bookmarks.count == 1)
    }

    @Test func shardOfKnownKeysIsFNV1aAndNeverChanges() {
        func fnv(_ key: String) -> Int {
            var hash: UInt32 = 2_166_136_261
            for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            return Int(hash % 8)
        }
        for key in ["", "a", "agent:main:main\u{1F}m-1", "s\u{1F}é"] { #expect(Bookmark.shard(ofKey: key) == fnv(key)) }
        // 32-bit FNV-1a of "a" is 0xE40C292C.
        #expect(Bookmark.shard(ofKey: "a") == Int(0xE40C292C % 8))
    }

    @Test func aShardStaysWithinTheSyncedByteBudget() throws {
        let store = self.store()
        defer { self.defaults.removePersistentDomain(forName: self.suite) }
        let shard = 0
        var index = 0
        var added = 0
        while added < 120 {
            let item = bookmark("m\(index)", at: TimeInterval(index), preview: String(repeating: "é", count: 150))
            index += 1
            guard Bookmark.shard(ofKey: item.id) == shard else { continue }
            store.add(item)
            added += 1
            let size = try JSONEncoder().encode(store.syncedEntries(shard: shard)).count
            #expect(size <= BookmarkStore.syncedByteBudget || store.syncedEntries(shard: shard).count == 1)
        }
        #expect(store.bookmarks.count < 120, "the shard dropped its oldest to fit")
    }
}

/// Bookmarks through a real `GatewayStore` and a loopback Gateway.
@MainActor
@Suite("Bookmark sync over users.prefs", .serialized)
struct BookmarkGatewaySyncTests {
    /// Bookmarks whose ids land in `shard`, oldest first.
    func bookmarks(inShard shard: Int, count: Int, from start: Int = 0, at base: TimeInterval = 1000) -> [Bookmark] {
        var found: [Bookmark] = []
        var index = start
        while found.count < count {
            let item = Bookmark(sessionKey: "main", messageId: "m\(index)", preview: "Message \(index)",
                                createdAt: Date(timeIntervalSince1970: base + TimeInterval(found.count)))
            if Bookmark.shard(ofKey: item.id) == shard { found.append(item) }
            index += 1
        }
        return found
    }

    func cleanUp(_ h: PrefsHarness) {
        BookmarkStore.forget(gatewayId: h.profile.id)
        h.finish()
    }

    @Test func everyShardIsASyncedMap() async throws {
        let h = try await PrefsHarness()
        defer { self.cleanUp(h) }
        let prefs = Set(h.store.syncedMaps.map(\.pref))
        for shard in 0..<Bookmark.shardCount { #expect(prefs.contains(Bookmark.prefKey(shard: shard))) }
    }

    @Test func addingABookmarkWritesItToItsShardAndRemovingDeletesIt() async throws {
        let h = try await PrefsHarness()
        defer { self.cleanUp(h) }
        let item = bookmarks(inShard: 2, count: 1)[0]
        let pref = Bookmark.prefKey(shard: 2)
        h.store.bookmarkStore.add(item)
        let written = await eventually { h.gateway.map(pref)?[item.id] == item.syncedValue }
        #expect(written)
        h.store.bookmarkStore.remove(sessionKey: item.sessionKey, messageId: item.messageId)
        let removed = await eventually { h.gateway.map(pref)?[item.id] == nil && h.store.pendingPrefChanges.isEmpty }
        #expect(removed)
    }

    @Test func aBookmarkAnotherDeviceAddedArrivesOnPull() async throws {
        let h = try await PrefsHarness()
        defer { self.cleanUp(h) }
        let item = bookmarks(inShard: 5, count: 1)[0]
        h.gateway.externalChange(Bookmark.prefKey(shard: 5), [item.id: item.syncedValue])
        let arrived = await eventually { h.store.bookmarkStore.isBookmarked(sessionKey: "main", messageId: item.messageId) }
        #expect(arrived)
        #expect(h.gateway.sets.isEmpty, "applying a pull pushes nothing back")
    }

    @Test func firstSyncMergesLocalBookmarksIntoTheGateway() async throws {
        let scratch = ScratchDefaults()
        let gateway = try FakePrefsGateway()
        defer { gateway.stop(); scratch.remove() }
        let profile = GatewayProfile(name: "Migrate", url: gateway.url, authMode: .none)
        let local = bookmarks(inShard: 1, count: 2)
        let remote = bookmarks(inShard: 1, count: 1, from: 500, at: 5000)[0]
        gateway.seed(Bookmark.prefKey(shard: 1), [remote.id: remote.syncedValue])
        let store = PrefsHarness.makeStore(profile, scratch.defaults)
        for item in local { store.bookmarkStore.add(item) }
        defer { BookmarkStore.forget(gatewayId: profile.id); store.stop() }
        store.start()
        let expected = Set(local.map(\.id) + [remote.id])
        let merged = await eventually(timeout: .seconds(30)) {
            Set(gateway.map(Bookmark.prefKey(shard: 1))?.keys.map { $0 } ?? []) == expected
        }
        #expect(merged, "local bookmarks join what the gateway had")
        let shown = await eventually { Set(store.bookmarkStore.bookmarks.map(\.id)) == expected }
        #expect(shown)
    }

    @Test func concurrentAddsOnTwoDevicesBothSurvive() async throws {
        let first = try await PrefsHarness()
        let second = try await PrefsHarness(sharing: first.gateway)
        defer { self.cleanUp(second); self.cleanUp(first) }
        let shard = 4
        let pref = Bookmark.prefKey(shard: shard)
        let pair = bookmarks(inShard: shard, count: 2)
        // Neither device hears the other's echo, so the second write's compare-and-set is stale.
        first.gateway.sendsEchoes = false
        first.store.bookmarkStore.add(pair[0])
        let firstLanded = await eventually { first.gateway.map(pref)?[pair[0].id] != nil }
        #expect(firstLanded)
        second.store.bookmarkStore.add(pair[1])
        let both = await eventually { Set(first.gateway.map(pref)?.keys.map { $0 } ?? []) == Set(pair.map(\.id)) }
        #expect(both, "the conflicted write re-reads and retries, keeping the other device's bookmark")
        let cleared = await eventually { second.store.pendingPrefChanges.isEmpty }
        #expect(cleared, "the retried write clears its pending entry once acknowledged")
    }

    @Test func removingGatewayLocalBookmarksPushesNothing() async throws {
        let h = try await PrefsHarness()
        defer { self.cleanUp(h) }
        let item = bookmarks(inShard: 0, count: 1)[0]
        h.store.bookmarkStore.add(item)
        let written = await eventually { h.gateway.map(Bookmark.prefKey(shard: 0))?[item.id] != nil }
        #expect(written)
        let before = h.gateway.sets.count
        h.store.forgetLocalBookmarks()
        await h.settle()
        #expect(h.gateway.sets.count == before)
        #expect(h.gateway.map(Bookmark.prefKey(shard: 0))?[item.id] != nil, "the gateway keeps them for other devices")
    }

    @Test func undecodableRemoteValuesStayRemoteAndPullsPushNothing() async throws {
        let h = try await PrefsHarness()
        defer { self.cleanUp(h) }
        let item = bookmarks(inShard: 6, count: 1)[0]
        let pref = Bookmark.prefKey(shard: 6)
        h.gateway.externalChange(pref, [item.id: item.syncedValue, "x\u{1F}y": "garbage"])
        let arrived = await eventually { h.store.bookmarkStore.isBookmarked(sessionKey: "main", messageId: item.messageId) }
        #expect(arrived)
        await h.store.pull(h.store.syncedMap(pref))
        await h.settle()
        #expect(h.gateway.sets.isEmpty, "pulling never pushes")
        #expect(h.gateway.map(pref)?["x\u{1F}y"] == "garbage", "undecodable values are kept remotely")
        #expect(h.store.bookmarkStore.bookmarks.count == 1)
    }

    @Test func starMadeBeforeTheFirstConnectionReachesTheGateway() async throws {
        let scratch = ScratchDefaults()
        let gateway = try FakePrefsGateway()
        defer { gateway.stop(); scratch.remove() }
        let profile = GatewayProfile(name: "Offline star", url: gateway.url, authMode: .none)
        let store = PrefsHarness.makeStore(profile, scratch.defaults)
        defer { BookmarkStore.forget(gatewayId: profile.id); store.stop() }
        let item = bookmarks(inShard: 3, count: 1)[0]
        // Through the shared store, as the UI does, without touching the gateway store's own accessor.
        BookmarkStore.shared(gatewayId: profile.id).add(item)
        store.start()
        let landed = await eventually(timeout: .seconds(30)) { gateway.map(Bookmark.prefKey(shard: 3))?[item.id] != nil }
        #expect(landed)
        #expect(store.bookmarkStore.isBookmarked(sessionKey: item.sessionKey, messageId: item.messageId), "a pull doesn't revert it")
    }

    @Test func starOnAnAlreadySyncedGatewayMadeOfflineIsPushedAfterConnect() async throws {
        let scratch = ScratchDefaults()
        let gateway = try FakePrefsGateway()
        defer { gateway.stop(); scratch.remove() }
        let profile = GatewayProfile(name: "Synced offline", url: gateway.url, authMode: .none)
        // A first launch syncs and quits.
        let first = PrefsHarness.makeStore(profile, scratch.defaults)
        first.start()
        let keys = first.syncedMaps.map(\.syncedDefaultsKey)
        let up = await eventually(timeout: .seconds(30)) { first.state.isConnected && keys.allSatisfy { scratch.defaults.bool(forKey: $0) } }
        #expect(up)
        first.stop()
        defer { BookmarkStore.forget(gatewayId: profile.id) }
        // The next launch stars a message before connecting.
        let second = PrefsHarness.makeStore(profile, scratch.defaults)
        defer { second.stop() }
        let item = bookmarks(inShard: 2, count: 1)[0]
        BookmarkStore.shared(gatewayId: profile.id).add(item)
        second.start()
        let landed = await eventually(timeout: .seconds(30)) { gateway.map(Bookmark.prefKey(shard: 2))?[item.id] != nil }
        #expect(landed, "pushed after connect")
        await second.pull(second.syncedMap(Bookmark.prefKey(shard: 2)))
        #expect(second.bookmarkStore.isBookmarked(sessionKey: item.sessionKey, messageId: item.messageId), "not reverted by the pull")
    }

    @Test func editsAfterTheGatewayStoreIsReplacedStillPush() async throws {
        let h = try await PrefsHarness()
        defer { self.cleanUp(h) }
        // AppModel.update() replaces the store with a new one for the same profile and defaults.
        h.store.stop()
        let replacement = PrefsHarness.makeStore(h.profile, h.scratch.defaults)
        defer { replacement.stop() }
        replacement.start()
        let keys = replacement.syncedMaps.map(\.syncedDefaultsKey)
        let defaults = h.scratch.defaults
        let up = await eventually(timeout: .seconds(30)) { replacement.state.isConnected && keys.allSatisfy { defaults.bool(forKey: $0) } }
        #expect(up)
        let item = bookmarks(inShard: 7, count: 1)[0]
        BookmarkStore.shared(gatewayId: h.profile.id).add(item)
        let landed = await eventually { h.gateway.map(Bookmark.prefKey(shard: 7))?[item.id] != nil }
        #expect(landed, "the replaced store's wiring is gone; the new one's is used")
        // And it isn't reverted by the next pull.
        await replacement.pull(replacement.syncedMap(Bookmark.prefKey(shard: 7)))
        #expect(replacement.bookmarkStore.isBookmarked(sessionKey: item.sessionKey, messageId: item.messageId))
    }

    @Test func legacyDeviceWithManyBookmarksStillFirstSyncs() async throws {
        let scratch = ScratchDefaults()
        let gateway = try FakePrefsGateway()
        defer { gateway.stop(); scratch.remove() }
        let profile = GatewayProfile(name: "Legacy", url: gateway.url, authMode: .none)
        let legacy = (0..<300).map {
            Bookmark(sessionKey: "agent:main:main", messageId: "legacy-\($0)", preview: String(repeating: "p", count: 150),
                     createdAt: Date(timeIntervalSince1970: TimeInterval(1000 + $0)))
        }
        // The shared bookmark store reads the standard defaults; forget() removes the key again.
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: "pincer.bookmarks.\(profile.id.uuidString)")
        let store = PrefsHarness.makeStore(profile, scratch.defaults)
        defer { BookmarkStore.forget(gatewayId: profile.id); store.stop() }
        store.start()
        let keys = (0..<Bookmark.shardCount).map { store.syncedMap(Bookmark.prefKey(shard: $0)).syncedDefaultsKey }
        let synced = await eventually(timeout: .seconds(30)) { keys.allSatisfy { scratch.defaults.bool(forKey: $0) } }
        #expect(synced, "every shard first-syncs despite the legacy bookmarks not fitting")
        var total = 0
        for shard in 0..<Bookmark.shardCount {
            let map = gateway.map(Bookmark.prefKey(shard: shard)) ?? [:]
            total += map.count
            #expect(((try? JSONEncoder().encode(map).count) ?? 0) <= BookmarkStore.syncedByteBudget)
        }
        #expect(total > 0 && total <= BookmarkStore.limit)
        #expect(store.rejectedPrefs.isEmpty)
        #expect(store.bookmarkStore.bookmarks.count <= BookmarkStore.limit)
        // The newest survive.
        #expect(store.bookmarkStore.isBookmarked(sessionKey: "agent:main:main", messageId: "legacy-299"))
    }
}
