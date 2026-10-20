import Foundation
import Observation

extension ChatStore {
    var committedCount: Int { self.items.lazy.filter { !$0.isPending }.count }

    func snapshot() -> TranscriptCache.Snapshot {
        var snapshot = Self.snapshot(items: self.items, hasMoreHistory: self.hasMoreHistory || self.olderInCache,
                                     activityMs: self.gateway?.sessions[self.sessionKey]?.activityMs)
        snapshot.forwardedSenderRefreshPending = self.forwardedSenderRefreshPending
        snapshot.forwardedSenderRefreshCompleted = self.forwardedSenderRefreshCompleted
        return snapshot
    }

    /// Committed items, newest `maxItems` kept; complete only when nothing older was left out.
    nonisolated static func snapshot(items: [ChatItem], hasMoreHistory: Bool, activityMs: Double?,
                                     maxItems: Int = TranscriptCache.maxItems) -> TranscriptCache.Snapshot
    {
        let committed = items.filter { !$0.isPending }
        let kept = committed.suffix(maxItems)
        var snapshot = TranscriptCache.Snapshot(
            items: Array(kept),
            complete: !hasMoreHistory && kept.count == committed.count,
            activityMs: activityMs)
        snapshot.retained = kept.count < committed.count || (hasMoreHistory && kept.count >= maxItems)
        return snapshot
    }

    /// The Gateway rewrote this chat's history (rewind, branch switch, recovery): drops what's
    /// loaded, including tool details, runs `clearCache` once no save can land, then refetches.
    func reloadAfterHistoryChange(feedbackAuthority: MessageEditFeedbackAuthority? = nil,
                                 clearingCache clearCache: (@MainActor () async -> Void)? = nil) async {
        #if DEBUG
        self.fullReloadCount += 1
        #endif
        self.stopQuotePreviewPublication()
        self.cancelScheduledSave()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cacheChecked = true
        self.exportCacheComplete = false
        self.cacheRestoreRevision &+= 1
        self.cacheUnreadable = false
        self.savedState = nil
        self.hasPagedOlder = false
        self.olderOffset = nil
        self.olderInCache = false
        self.hasMoreHistory = false
        self.fullMessages = [:]
        self.recoveryAttempted = []
        self.cappedRecoveryPending = false
        let pending = self.items.filter(\.isPending)
        if pending != self.items { self.items = pending }
        self.hasLoaded = false
        await clearCache?()
        await self.load(force: true, feedbackAuthority: feedbackAuthority)
    }

    /// A follow-up refetch for a change already handled by `reloadAfterHistoryChange`: no cache wipe and the
    /// transcript stays on screen; the newest fetch (by load generation) wins.
    func refetchAfterHistoryChange(feedbackAuthority: MessageEditFeedbackAuthority? = nil) async {
        await self.load(force: true, feedbackAuthority: feedbackAuthority)
    }

    /// The session was deleted: nothing more is written to the transcript cache.
    func stopCaching() {
        self.stopReplyPreviewPublication()
        self.cancelScheduledSave()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cachingStopped = true
        self.cancelOutboxImagePreviews()
    }

    /// The store is going away: writes what's loaded now, then nothing more is cached.
    func finishCaching() async {
        let save = self.hasLoaded && !self.isDehydrated && !self.cachingStopped
        self.stopCaching()
        if save { await self.saveSnapshot() }
    }

    /// Writes what's loaded to the transcript cache now (after it was cleared).
    func saveToCache() async {
        guard self.hasLoaded, !self.isDehydrated, !self.cachingStopped else { return }
        self.cancelScheduledSave()
        // The cache was cleared, so it no longer holds what was saved.
        self.savedState = nil
        await self.saveSnapshot()
    }

    func scheduleSave() {
        guard self.hasLoaded, !self.isDehydrated, !self.cachingStopped, !self.cacheUnreadable,
              self.currentCacheState != self.savedState
        else { return }
        let now = self.saveNow()
        let runId = self.activeSaveRunId
        let deadline: Date
        if let runId {
            // Keep the first deadline for this run: continuous deltas cannot postpone a save.
            if let existing = self.saveDeadline,
               self.saveDeadlineRunId == runId || self.saveDeadlineRunId == nil {
                // A committed user message or an earlier idle save must stay searchable promptly.
                deadline = min(existing, now.addingTimeInterval(5))
            } else {
                deadline = now.addingTimeInterval(5)
            }
        } else {
            deadline = now.addingTimeInterval(1)
        }
        self.queueSave(until: deadline, forRunId: runId)
    }

    /// A completed run is a natural persistence boundary, so its latest transcript is saved now.
    func flushScheduledSave() {
        guard self.hasLoaded, !self.isDehydrated, !self.cachingStopped, !self.cacheUnreadable,
              self.currentCacheState != self.savedState
        else { return }
        self.queueSave(until: self.saveNow(), forRunId: nil)
    }

    /// Invalidates both the queued task and its deadline so a canceled task cannot block later saves.
    func cancelScheduledSave() {
        self.saveScheduleGeneration &+= 1
        self.saveTask?.cancel()
        self.saveTask = nil
        self.saveDeadline = nil
        self.saveDeadlineRunId = nil
    }

    private var activeSaveRunId: String? {
        guard let runId = self.live?.runId, !self.finishedRunIds.contains(runId) else { return nil }
        return runId
    }

    private func queueSave(until deadline: Date, forRunId runId: String?) {
        self.cancelScheduledSave()
        self.saveDeadline = deadline
        self.saveDeadlineRunId = runId
#if DEBUG
        let state = self.currentCacheState
        let hasRefreshTrace = !ForwardedSenderRefreshDiagnostics.events(
            gatewayID: self.gatewayId, sessionKey: self.sessionKey).isEmpty
        if state.forwardedSenderRefreshPending || state.forwardedSenderRefreshCompleted || hasRefreshTrace {
            self.recordForwardedRefresh(.saveScheduled(store: self.headless ? .headless : .open,
                                                       pending: state.forwardedSenderRefreshPending,
                                                       completed: state.forwardedSenderRefreshCompleted,
                                                       revision: state.revision,
                                                       delayMilliseconds: max(0, Int(deadline.timeIntervalSinceNow * 1_000))))
        }
#endif
        let generation = self.saveScheduleGeneration
        let wait = self.waitForSaveDeadline
        self.saveTask = Task { [weak self] in
            do { try await wait(deadline) } catch { return }
            guard !Task.isCancelled, let self, self.saveScheduleGeneration == generation,
                  !self.isDehydrated, !self.cachingStopped
            else { return }
            self.saveDeadline = nil
            self.saveDeadlineRunId = nil
            await self.saveSnapshot()
            guard self.saveScheduleGeneration == generation else { return }
            self.saveTask = nil
            // If the disk write suspended while the transcript changed, make sure the newer
            // revision still has a queued save even when the mutation did not schedule one.
            self.scheduleSave()
        }
    }
}
