import Foundation

extension GatewayStore {
    /// Bookmarks by `Bookmark.id`, each a compact JSON value (#382).
    static let bookmarksPref = "pincer.bookmarks"

    /// The bookmarks as synced entries; setting replaces them without pushing.
    var bookmarkPrefEntries: [String: String] {
        get { self.bookmarkStore.syncedEntries }
        set { self.bookmarkStore.apply(synced: newValue) }
    }

    /// The shared store, with local edits pushed to the gateway.
    var bookmarkStore: BookmarkStore {
        let store = BookmarkStore.shared(gatewayId: self.id)
        if store.onChange == nil {
            store.onChange = { [weak self] changes in
                guard let self else { return }
                Task { await self.push(self.syncedMap(Self.bookmarksPref), changes) }
            }
        }
        return store
    }

    /// Starts pushing bookmark edits; called when the gateway is added.
    func wireBookmarkSync() { _ = self.bookmarkStore }
}

extension GatewayStore {
    /// Forgets this device's bookmarks and sync state when the gateway is removed. The gateway's
    /// user prefs keep them for other devices; nothing is pushed.
    func forgetLocalBookmarks() {
        BookmarkStore.forget(gatewayId: self.id)
        self.defaults.removeObject(forKey: "pincer.bookmarksSynced.\(self.id.uuidString)")
        self.defaults.removeObject(forKey: Self.pendingPrefsKey(self.id))
    }
}
