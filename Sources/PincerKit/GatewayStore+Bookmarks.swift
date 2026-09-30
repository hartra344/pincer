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
        if store.onChange == nil {
            store.onChange = { [weak self] changes in
                guard let self else { return }
                let byShard = Dictionary(grouping: changes) { Bookmark.shard(ofKey: $0.key) }
                for (shard, entries) in byShard {
                    let shardChanges = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
                    Task { await self.push(self.syncedMap(Self.bookmarksPref(shard: shard)), shardChanges) }
                }
            }
        }
        return store
    }

    /// Starts pushing bookmark edits; called when the gateway is added.
    func wireBookmarkSync() { _ = self.bookmarkStore }

    /// Forgets this device's bookmarks and sync state when the gateway is removed. The gateway's
    /// user prefs keep them for other devices; nothing is pushed.
    func forgetLocalBookmarks() {
        BookmarkStore.forget(gatewayId: self.id)
        for shard in 0..<Self.bookmarkShardCount { self.defaults.removeObject(forKey: Self.bookmarksSyncedKey(shard, self.id)) }
        self.defaults.removeObject(forKey: Self.pendingPrefsKey(self.id))
    }

    static func bookmarksSyncedKey(_ shard: Int, _ id: UUID) -> String { "pincer.bookmarksSynced.\(shard).\(id.uuidString)" }
}
