import Foundation

extension ChatStore {
    /// The parts of this chat's state that keep it resident.
    var residencySnapshot: ChatResidencySnapshot {
        ChatResidencySnapshot(
            isSelected: self.gateway?.selectedKey == self.sessionKey,
            isRunning: self.isRunning,
            hasActiveRun: self.sessionRow?.hasActiveRun == true,
            compactionRunning: self.compaction?.isRunning == true,
            loadInFlight: self.loadInFlight,
            isLoadingOlder: self.isLoadingOlder,
            isLocatingReply: self.locatingReplyId != nil,
            isSending: self.isSending,
            hasUnsent: !self.unsentEntries.isEmpty,
            isSetupTestChat: self.gateway?.setup.testChatKey == self.sessionKey)
    }

    /// Whether there is heavy content to drop.
    var isHydrated: Bool { self.hasLoaded && !self.isDehydrated }

    /// Saves the transcript, then drops its heavy contents (items, entries, maps, full copies) in place.
    /// The store keeps its identity, draft, live run and unsent messages, and reloads through `load()`.
    func dehydrate() async {
        guard !self.headless, self.isHydrated, !self.cachingStopped,
              TranscriptCache.file(gatewayId: self.gatewayId, sessionKey: self.sessionKey, root: self.cacheRoot) != nil
        else { return }
        self.cancelScheduledSave()
        // Writes nothing when the cache already holds what's loaded.
        await self.saveSnapshot()
        // The save suspended: the chat may have been opened or become busy meanwhile.
        guard self.isHydrated, let gateway, !gateway.isChatPinned(self.sessionKey) else { return }
        self.cancelScheduledSave()
        self.backfillTask?.cancel()
        self.backfillTask = nil
        self.olderTask?.cancel()
        self.olderTask = nil
        self.reloadTask?.cancel()
        self.reloadTask = nil
        self.hasLoaded = false
        self.isDehydrated = true
        self.cacheChecked = false
        self.stale = true
        self.hasPagedOlder = false
        self.olderOffset = nil
        self.hasMoreHistory = false
        self.olderInCache = false
        self.fullMessages = [:]
        self.recoveryAttempted = []
        self.cappedRecoveryPending = false
        self.sawThinking = false
        // Unsent rows survive; the restore guard accepts pending-only items.
        let pending = self.items.filter(\.isPending)
        if pending != self.items { self.items = pending }
    }

    /// Full copies and the tried-set only cover the latest page, the one the Gateway re-sends capped.
    func pruneRecoveryState(keeping parsed: [ChatItem]) {
        let ids = Set(parsed.compactMap(\.transcriptId))
        self.fullMessages = self.fullMessages.filter { ids.contains($0.key) }
        // Refused older capped rows stay marked; anything else is retried if it returns capped.
        let stillCapped = Set(self.items.filter(\.isCapped).compactMap(\.transcriptId))
        self.recoveryAttempted = self.recoveryAttempted.filter { ids.contains($0) || stillCapped.contains($0) }
    }
}
