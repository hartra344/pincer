import Foundation
import Observation

extension ChatStore {
    /// Shows the cached transcript before the Gateway answers; the newest page is merged over it.
    /// Without a usable one (missing, or discarded as corrupt, outdated or from a newer app)
    /// nothing is shown: the chat stays loading until the Gateway's history arrives.
    struct CacheState: Equatable {
        var revision: Int
        var hasMoreHistory: Bool
        var activityMs: Double?
        var forwardedSenderRefreshPending: Bool
        var forwardedSenderRefreshCompleted: Bool
    }

    var currentCacheState: CacheState {
        CacheState(revision: self.contentRevision, hasMoreHistory: self.hasMoreHistory,
                   activityMs: self.gateway?.sessions[self.sessionKey]?.activityMs,
                   forwardedSenderRefreshPending: self.forwardedSenderRefreshPending,
                   forwardedSenderRefreshCompleted: self.forwardedSenderRefreshCompleted)
    }

    /// Saves the current snapshot unless the cache already holds this state (or can't be trusted).
    func saveSnapshot() async {
        guard !self.cacheUnreadable else { return }
        let state = self.currentCacheState
        guard state != self.savedState else { return }
        let snapshot = self.snapshot()
#if DEBUG
        let refreshWrite = state.forwardedSenderRefreshPending || state.forwardedSenderRefreshCompleted
            || !ForwardedSenderRefreshDiagnostics.events(gatewayID: self.gatewayId, sessionKey: self.sessionKey).isEmpty
        if refreshWrite {
            ForwardedSenderRefreshDiagnostics.record(
                gatewayID: self.gatewayId, sessionKey: self.sessionKey,
                phase: .snapshotWriteStarted(store: self.headless ? .headless : .open,
                                             pending: state.forwardedSenderRefreshPending,
                                             completed: state.forwardedSenderRefreshCompleted,
                                             revision: state.revision))
        }
#endif
        let result = await TranscriptCache.saveReturningStats(
            snapshot, gatewayId: self.gatewayId, sessionKey: self.sessionKey,
            keepingOlder: self.olderInCache || self.hasMoreHistory, root: self.cacheRoot)
#if DEBUG
        if refreshWrite {
            ForwardedSenderRefreshDiagnostics.record(
                gatewayID: self.gatewayId, sessionKey: self.sessionKey,
                phase: .snapshotWriteFinished(store: self.headless ? .headless : .open,
                                              pending: state.forwardedSenderRefreshPending,
                                              completed: state.forwardedSenderRefreshCompleted,
                                              modifiedReported: result.modified != nil,
                                              unchangedReported: result.unchanged))
        }
#endif
        self.recordSavedSnapshot(state, result: result)
#if DEBUG
        if refreshWrite {
            let after = self.currentCacheState
            self.recordForwardedRefresh(.snapshotStateAfterWrite(store: self.headless ? .headless : .open,
                                                                 pending: after.forwardedSenderRefreshPending,
                                                                 completed: after.forwardedSenderRefreshCompleted,
                                                                 revision: after.revision))
        }
#endif
    }

    /// Records the state represented by a completed cache write, even if the store changed while
    /// the disk writer was suspended.
    func recordSavedSnapshot(_ state: CacheState, result: TranscriptCache.SaveResult) {
        var persistedState = state
        if state.forwardedSenderRefreshCompleted {
            let completed = result.modified != nil || result.unchanged
            persistedState.forwardedSenderRefreshPending = !completed
            persistedState.forwardedSenderRefreshCompleted = false
            // Another transcript edit or refresh may have happened while the writer was running.
            // Only consume the one-write completion flag if this is still the state we captured.
            if self.currentCacheState == state {
                self.forwardedSenderRefreshPending = !completed
                self.forwardedSenderRefreshCompleted = false
            }
        }
        // The disk contains `snapshot`, not whatever state the store reached during the await.
        // Leaving newer state unequal to this snapshot schedules another save instead of losing it.
        self.savedState = persistedState
    }

    func restoreFromCache() async {
        guard !self.cacheChecked else { return }
        self.cacheChecked = true
        let restoreRevision = self.cacheRestoreRevision
        let limit = self.windowLimit + Self.windowExtension
        let loaded: (items: [ChatItem], complete: Bool, outcome: TranscriptCache.LoadOutcome,
                     forwardedSenderRefreshPending: Bool)
        if self.headless {
            loaded = await TranscriptCache.loadNewestForHeadlessFill(
                gatewayId: self.gatewayId, sessionKey: self.sessionKey, limit: limit, root: self.cacheRoot)
        } else {
            loaded = await TranscriptCache.loadNewest(gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                                      limit: limit, root: self.cacheRoot)
        }
        let (windowed, moreInCache) = Self.window(loaded.items, limit: self.windowLimit)
        let cached = (items: windowed, complete: loaded.complete, outcome: loaded.outcome)
        let outcome = cached.outcome
        #if DEBUG
        if let gate = self.exportCacheCompletionGate { await gate() }
        #endif
        guard restoreRevision == self.cacheRestoreRevision else { return }
        self.cacheOutcome = outcome
        let exportAuthorityCurrent = restoreRevision == self.cacheRestoreRevision
        let completeUsableCache: Bool
        switch outcome {
        case .loaded, .migrated: completeUsableCache = cached.complete
        default: completeUsableCache = false
        }
        if exportAuthorityCurrent { self.exportCacheComplete = false }
        if case .unavailable = outcome {
            // Retried on the next load; until then a save would replace the cached history.
            self.cacheChecked = false
            self.cacheUnreadable = true
            return
        }
        self.forwardedSenderRefreshPending = loaded.forwardedSenderRefreshPending
        // Unsent messages shown before the cache arrived stay, after it.
        guard !cached.items.isEmpty else {
            if exportAuthorityCurrent, self.items.allSatisfy(\.isPending) { self.exportCacheComplete = completeUsableCache }
            self.cacheUnreadable = false
            return
        }
        guard self.items.allSatisfy(\.isPending) else {
            let overlaps = self.mergeCached(cached.items, complete: cached.complete, moreInCache: moreInCache)
            if exportAuthorityCurrent && overlaps { self.exportCacheComplete = completeUsableCache }
            return
        }
        self.cacheUnreadable = false
        // With the whole cache in memory, item count never exceeds the raw message count, so this
        // offset can only overlap (deduped by id), never skip; the first older page's `nextOffset`
        // makes it exact again. Behind a window the offset is unset until paging reaches the cache start.
        self.olderOffset = moreInCache ? nil : cached.items.count
        self.olderInCache = moreInCache
        self.hasMoreHistory = !cached.complete
        self.hasPagedOlder = true
        self.replaceRecoveryItems(cached.items + self.items)
        if exportAuthorityCurrent { self.exportCacheComplete = completeUsableCache }
        if outcome == .loaded, self.items == cached.items { self.savedState = self.currentCacheState }
    }

    /// The cache arrived after the Gateway's newest page (a retry after `.unavailable`): puts the
    /// cached items that come before that page in front, so a save keeps the older history.
    private func mergeCached(_ cachedItems: [ChatItem], complete: Bool, moreInCache: Bool) -> Bool {
        defer { self.cacheUnreadable = false }
        let loaded = Set(self.items.map(\.id))
        // Without an overlap, messages may be missing between the cache and the loaded page, so
        // nothing is spliced in: the Gateway pages older history and the next save replaces the cache.
        guard let firstLoaded = self.items.first(where: { !$0.isPending }),
              let cut = cachedItems.firstIndex(where: { $0.id == firstLoaded.id })
        else { return false }
        let older = Array(cachedItems[..<cut]).filter { !loaded.contains($0.id) }
        let more = moreInCache
        guard !older.isEmpty || more else { return true }
        let committed = self.items.filter { !$0.isPending }.count
        self.olderOffset = more ? nil : committed + older.count
        self.olderInCache = more
        self.hasMoreHistory = !complete
        self.hasPagedOlder = true
        self.replaceRecoveryItems(older + self.items)
        return true
    }
}
