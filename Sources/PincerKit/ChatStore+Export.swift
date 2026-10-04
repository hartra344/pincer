import Foundation

extension ChatStore {
    /// Pages the whole transcript into memory, from the cache and then the Gateway, for export
    /// (#42). Returns false if an older page couldn't be read. The chat trims back to its window
    /// once it's idle again.
    @discardableResult
    public func loadFullHistory() async -> Bool {
        if !self.hasLoaded { await self.load() }
        guard self.hasLoaded || self.exportCacheComplete else { return false }
        var lastCount = -1
        while self.hasOlderItems, !Task.isCancelled {
            guard await self.loadOlder(cachePageSize: Int.max) else { return false }
            // A page that adds nothing would loop forever.
            if self.items.count == lastCount, !self.olderInCache { break }
            lastCount = self.items.count
        }
        return !Task.isCancelled
    }

    /// Every committed message in the chat, oldest first, for export.
    public func exportItems() async -> [ChatItem]? {
        guard await self.loadFullHistory() else { return nil }
        return self.items.filter { !$0.isPending }
    }
}
