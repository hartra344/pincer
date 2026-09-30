import Foundation

extension GatewayStore {
    /// Bookmarks sync in this many prefs (`pincer.bookmarks.0`…), each under the gateway's 4 KiB value limit (#382).
    static let bookmarkShardCount = Bookmark.shardCount

    /// The pref holding the bookmarks of `shard`, by `Bookmark.id`, each a compact JSON value.
    static func bookmarksPref(shard: Int) -> String { Bookmark.prefKey(shard: shard) }

    /// One shard's bookmarks as synced entries; setting replaces that shard's bookmarks without pushing.
    subscript(bookmarkShard index: Int) -> [String: String] {
        get { self.bookmarkStore.syncedEntries(shard: index) }
        set { self.bookmarkStore.apply(synced: newValue, shard: index) }
    }

    /// The shared store, with local edits pushed to the gateway.
    var bookmarkStore: BookmarkStore {
        let store = BookmarkStore.shared(gatewayId: self.id)
        if store.onChange == nil { self.wireBookmarkSync(store) }
        return store
    }

    /// Points the shared store's edits at this GatewayStore, replacing a previous one's wiring
    /// (a replaced gateway shares the store but not the instance).
    @discardableResult
    func wireBookmarkSync(_ store: BookmarkStore? = nil) -> BookmarkStore {
        let store = store ?? BookmarkStore.shared(gatewayId: self.id)
        // Bookmarks saved before the cap must fit a pref value before their first sync.
        if !self.defaults.bool(forKey: Self.bookmarksSyncedKey(0, self.id)) { store.enforceLimits() }
        store.onChange = { [weak self] changes in
            guard let self else { return }
            let byShard = Dictionary(grouping: changes) { Bookmark.shard(ofKey: $0.key) }
            for (shard, entries) in byShard {
                let shardChanges = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
                Task { await self.push(self.syncedMap(Self.bookmarksPref(shard: shard)), shardChanges) }
            }
        }
        return store
    }

    /// A merged bookmark shard within the gateway's value limit, dropping the oldest bookmarks first.
    /// Devices from before the cap can hold more than fits; a write over the limit is rejected forever.
    static func fittingBookmarkShard(_ entries: [String: String], pref: String) -> [String: String] {
        guard (0..<bookmarkShardCount).contains(where: { bookmarksPref(shard: $0) == pref }) else { return entries }
        var kept = entries
        while kept.count > 1, BookmarkStore.syncedSize(kept) > BookmarkStore.syncedByteBudget {
            let oldest = kept.min { lhs, rhs in
                let l = Bookmark(syncedKey: lhs.key, value: lhs.value)?.createdAt ?? .distantPast
                let r = Bookmark(syncedKey: rhs.key, value: rhs.value)?.createdAt ?? .distantPast
                return (l, lhs.key) < (r, rhs.key)
            }
            kept.removeValue(forKey: oldest!.key)
        }
        return kept
    }

    /// Why the gateway refused a bookmark write, if it did.
    public var bookmarkSyncProblem: String? {
        (0..<Self.bookmarkShardCount).lazy.compactMap { self.rejectedPrefs[Self.bookmarksPref(shard: $0)] }.first
    }

    /// Forgets this device's bookmarks and sync state when the gateway is removed. The gateway's
    /// user prefs keep them for other devices; nothing is pushed.
    func forgetLocalBookmarks() {
        BookmarkStore.forget(gatewayId: self.id)
        for shard in 0..<Self.bookmarkShardCount { self.defaults.removeObject(forKey: Self.bookmarksSyncedKey(shard, self.id)) }
        self.defaults.removeObject(forKey: Self.pendingPrefsKey(self.id))
    }

    static func bookmarksSyncedKey(_ shard: Int, _ id: UUID) -> String { "pincer.bookmarksSynced.\(shard).\(id.uuidString)" }
}
