import Foundation
import Observation

extension ChatStore {
    /// Brings the whole history to disk (and the search index) right after opening, in a headless
    /// store shared per chat, so this one keeps only its window in memory. Resumes on the next load
    /// if it was cut short. A cache that is current or already holds its retained maximum is left alone.
    func startBackfill() {
        guard self.hasMoreHistory, !self.headless, !self.cachingStopped, let gateway = self.gateway else { return }
        Task { [weak self, sessionKey, agentId, gatewayId, cacheRoot = self.cacheRoot] in
            let meta = await TranscriptCache.meta(gatewayId: gatewayId, sessionKey: sessionKey, root: cacheRoot)
            let activityMs = gateway.sessions[sessionKey]?.activityMs ?? .infinity
            guard (meta?.retained != true || meta?.forwardedSenderRefreshPending == true),
                  !GatewayStore.prefetchIsFresh(meta, activityMs: activityMs),
                  let self, self.hasMoreHistory, !self.cachingStopped else { return }
            gateway.startHeadlessFill(sessionKey: sessionKey, agentId: agentId)
        }
    }

    /// The background fill finished: the cache may now hold items older than the loaded window, and
    /// says whether it is complete. The window is saved over the filler's write, keeping the older part.
    func adoptFilledCache(generation: Int? = nil, connectionEpoch: Int? = nil,
                          afterOlderRead: (@MainActor () async -> Void)? = nil) async {
        guard !self.headless, !self.cachingStopped, !self.isDehydrated, self.hasLoaded, let gateway else { return }
        let generation = generation ?? gateway.cacheGeneration(of: self.sessionKey)
        let connectionEpoch = connectionEpoch ?? gateway.connectionEpoch
        guard gateway.connectionEpoch == connectionEpoch else { return }
        let refreshWasPending = self.forwardedSenderRefreshPending
        var expectedRevision = self.contentRevision
        // A queued save must not land over the filler's write before this store reads it.
        let hadQueuedSave = self.saveTask != nil
        self.cancelScheduledSave()
        var adoptionSaved = false
        func validCacheContext() -> Bool {
            !self.cachingStopped && !self.isDehydrated && self.gateway === gateway
                && gateway.connectionEpoch == connectionEpoch
                && gateway.cacheGeneration(of: self.sessionKey) == generation
        }
        func validContext() -> Bool {
            validCacheContext() && !Task.isCancelled && gateway.state.isConnected && gateway.appIsActive
        }
        func current() -> Bool { validContext() && self.contentRevision == expectedRevision }
        defer {
            // Keep a dirty write queued after an aborted adoption, including while offline. UI
            // adoption needs an active connection; persistence only needs a current cache context.
            if !adoptionSaved, hadQueuedSave, validCacheContext(), !self.cacheUnreadable {
                self.scheduleSave()
            }
        }
        if !self.olderInCache, let first = self.items.first(where: { !$0.isPending }) {
            let older = await TranscriptCache.loadOlder(gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                                        before: first.id, limit: 1, root: self.cacheRoot)
            await afterOlderRead?()
            guard current(), !self.olderInCache else { return }
            if Self.cacheReadable(older.outcome), !older.items.isEmpty {
                self.olderInCache = true
                self.hasPagedOlder = true
                self.olderOffset = nil
            }
        }
        let meta = await TranscriptCache.meta(gatewayId: self.gatewayId, sessionKey: self.sessionKey, root: self.cacheRoot)
        let contextValidAfterMeta = current()
        if refreshWasPending {
            self.recordForwardedRefresh(.adoptionRead(storePending: refreshWasPending,
                                                     diskPending: meta?.forwardedSenderRefreshPending,
                                                     diskComplete: meta?.complete,
                                                     contextValid: contextValidAfterMeta,
                                                     cacheReadable: !self.cacheUnreadable))
        }
        guard contextValidAfterMeta, !self.cacheUnreadable else { return }
        if let meta {
            self.hasMoreHistory = !meta.complete
            if meta.forwardedSenderRefreshPending == true {
                self.forwardedSenderRefreshPending = true
            }
        }
        let completedSenderRefresh = refreshWasPending && meta?.forwardedSenderRefreshPending == false
        if completedSenderRefresh {
            var reconciled: [ChatItem]?
            for attempt in 0...1 {
                expectedRevision = self.contentRevision
                let currentItems = self.items
                let limit = min(max(currentItems.count, self.windowLimit + Self.windowExtension), TranscriptCache.maxItems)
                let refreshed = await TranscriptCache.loadNewest(
                    gatewayId: self.gatewayId, sessionKey: self.sessionKey, limit: limit, root: self.cacheRoot)
                guard validContext(), Self.cacheReadable(refreshed.outcome) else { return }
                let result = await Self.reconcileForwardedRefresh(
                    restoredCache: [], pagesNewestFirst: [refreshed.items], current: currentItems)
                guard validContext() else { return }
                if self.contentRevision == expectedRevision {
                    reconciled = result
                    break
                }
                if attempt == 1 { return }
            }
            guard let reconciled, current() else { return }
            self.replaceRecoveryItems(reconciled)
            // A refresh only becomes consumed once its full disk snapshot has been applied to the
            // rows currently held by this chat. Earlier guards leave the marker set on failure.
            self.forwardedSenderRefreshPending = false
            expectedRevision = self.contentRevision
        }
        self.cancelScheduledSave()
        self.savedState = nil
        guard current() else { return }
        await self.saveSnapshot()
        adoptionSaved = true
    }

    /// Prepends the next older page, from the cache while it holds older items and then from the
    /// Gateway, keeping everything already loaded (and its row identity). Returns false when it
    /// couldn't reach the source.
    @discardableResult
    public func loadOlder() async -> Bool {
        await self.loadOlder(cachePageSize: Self.olderCachePageSize)
    }

    func loadOlder(cachePageSize: Int, stopAt targetId: String? = nil) async -> Bool {
        // Concurrent callers share the in-flight page rather than returning early and spinning.
        if let inFlight = self.olderTask { return await inFlight.value }
        guard self.hasOlderItems else { return true }
        self.isLoadingOlder = true
        let task = Task {
            let ok = self.olderInCache ? await self.loadCachedOlderPage(limit: cachePageSize, stopAt: targetId) : await self.fetchOlderPage()
            // Cleared by the task itself so every waiter sees it finished.
            self.olderTask = nil
            self.isLoadingOlder = false
            return ok
        }
        self.olderTask = task
        return await task.value
    }

    /// Pages the whole cached transcript into memory (find in chat).
    public func loadAllCached() async {
        while self.olderInCache, !Task.isCancelled {
            guard await self.loadOlder(cachePageSize: Int.max) else { return }
        }
    }

    /// Reads up to `limit` older cached items (in lookup-sized reads, stopping once `targetId` is among
    /// them) and prepends them in one go, so a long read costs one rebuild rather than one per page.
    private func loadCachedOlderPage(limit: Int, stopAt targetId: String?) async -> Bool {
        guard let first = self.items.first(where: { !$0.isPending }) else {
            self.olderInCache = false
            return true
        }
        let pageSize = targetId == nil ? limit : min(limit, Self.lookupCachePageSize)
        var collected: [ChatItem] = []
        var reachedStart = false
        var cursor = first.id
        while true {
            let page = await TranscriptCache.loadOlder(gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                                       before: cursor, limit: pageSize, root: self.cacheRoot)
            guard self.olderInCache, !self.cachingStopped else { return true }
            switch page.outcome {
            case .loaded, .migrated:
                break
            case .unavailable:
                return false
            default:
                // The cache lost its older part: the Gateway supplies it from the loaded start back.
                self.olderInCache = false
                self.hasMoreHistory = true
                self.hasPagedOlder = true
                self.olderOffset = self.committedCount
                return true
            }
            collected = page.items + collected
            reachedStart = page.reachedStart
            guard !reachedStart, let oldest = page.items.first, collected.count < limit, !Task.isCancelled,
                  !(targetId.map { id in page.items.contains { $0.id == id || $0.transcriptId == id } } ?? false)
            else { break }
            cursor = oldest.id
        }
        let known = Set(self.items.map(\.id))
        let fresh = collected.filter { !known.contains($0.id) }
        self.olderInCache = !reachedStart && !fresh.isEmpty
        self.hasPagedOlder = true
        if !self.olderInCache { self.olderOffset = self.committedCount + fresh.count }
        if !fresh.isEmpty { self.replaceRecoveryItems(fresh + self.items) }
        return true
    }

    /// The index of the first item kept when only the newest `limit` committed items stay. Moves
    /// forward to the start of a turn (a user message) so a turn is never split; unsent items are
    /// never cut, and 0 means nothing to drop.
    nonisolated static func windowCut(_ items: [ChatItem], limit: Int) -> Int {
        let committed = items.indices.filter { !items[$0].isPending }
        guard limit >= 0, committed.count > limit else { return 0 }
        let start = limit == 0 ? items.count : committed[committed.count - limit]
        return items[start...].firstIndex { $0.startsWindow } ?? min(start, items.count)
    }

    /// How far back a restored window may reach for a turn start.
    nonisolated static let windowExtension = 200

    /// The newest `limit` items of what `loadNewest` returned (which asked for `limit + windowExtension`),
    /// starting at a turn start with a transcript id, and whether more is cached before it.
    nonisolated static func window(_ items: [ChatItem], limit: Int) -> (items: [ChatItem], more: Bool) {
        guard items.count > limit else { return (items, false) }
        let start = items.count - limit
        let lower = max(0, start - windowExtension)
        let back = (lower...start).reversed().first { items[$0].startsWindow }
        let cut = back ?? items[start...].firstIndex { $0.startsWindow } ?? start
        return (Array(items[cut...]), cut > 0 || items.count >= limit + windowExtension)
    }

    /// For the UI, e.g. once Find closes: trims if the chat is idle and not selected.
    public func trimWhenIdle() async { await self.trimToWindow() }

    /// For the open chat once Find has closed and its transcript is anchored at the bottom (#335), so
    /// dropping rows above the window doesn't move what the reader sees. Otherwise like `trimWhenIdle`.
    /// `stillWanted` is checked again after the save, which suspends (Find may have reopened).
    public func trimOpenChatToWindow(stillWanted: @MainActor () -> Bool) async {
        await self.trimToWindow(allowSelected: true, stillWanted: stillWanted)
    }

    /// Drops the oldest committed items beyond `windowLimit` from a chat that isn't in use. What's
    /// dropped stays on disk and pages back in through `loadOlder`.
    func trimToWindow(allowSelected: Bool = false, stillWanted: @MainActor () -> Bool = { true }) async {
        guard self.canTrim(allowSelected: allowSelected), self.committedCount > self.windowLimit else { return }
        self.cancelScheduledSave()
        await self.saveSnapshot()
        // The save suspended: the chat may have been opened or become busy meanwhile.
        guard self.canTrim(allowSelected: allowSelected), self.savedState == self.currentCacheState, stillWanted()
        else { return }
        let cut = Self.windowCut(self.items, limit: self.windowLimit)
        guard cut > 0 else { return }
        self.olderInCache = true
        self.hasPagedOlder = true
        self.olderOffset = nil
        self.items = self.items[cut...] + self.items[..<cut].filter(\.isPending)
        self.cancelScheduledSave()
        self.savedState = self.currentCacheState
    }

    private static func cacheReadable(_ outcome: TranscriptCache.LoadOutcome) -> Bool {
        switch outcome {
        case .loaded, .migrated: true
        default: false
        }
    }

    /// Warm chats may be trimmed too: only a selected, running, locating or paging chat is left alone.
    private func canTrim(allowSelected: Bool) -> Bool {
        let state = self.residencySnapshot
        guard !self.headless, self.isHydrated, !self.cachingStopped, !self.cacheUnreadable, self.olderTask == nil,
              allowSelected || !state.isSelected, !state.isRunning, !state.isLocatingReply, !state.isLoadingOlder,
              TranscriptCache.file(gatewayId: self.gatewayId, sessionKey: self.sessionKey, root: self.cacheRoot) != nil
        else { return false }
        return true
    }

    func fetchOlderPage() async -> Bool {
        // Unset behind a window: the whole cached suffix is in memory by then, so its count is the offset.
        let offset = self.olderOffset ?? self.committedCount
        guard let gateway, gateway.state.isConnected else { return false }
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        params["offset"] = .number(Double(offset))
        do {
            let page = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
            let raw = page["messages"]?.array ?? []
            // Negative fallback indexes keep id-less messages from colliding with the newest page's.
            let older = await Self.parseDetached(raw, fallbackBase: -(offset + raw.count))
            let known = Set(self.items.map(\.id))
            let fresh = older.filter { !known.contains($0.id) }
            self.olderOffset = page["nextOffset"]?.int ?? (offset + older.count)
            self.hasMoreHistory = (page["hasMore"]?.bool ?? (older.count >= self.historyLimit)) && !older.isEmpty
            self.hasPagedOlder = true
            if !fresh.isEmpty { self.items = fresh + self.items }
            self.recoverCappedMessages()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Parsing a page off the main actor keeps scrolling smooth while history streams in.
    nonisolated static func parseDetached(_ messages: [JSONValue], fallbackBase: Int) async -> [ChatItem] {
        await Task.detached(priority: .userInitiated) { Self.parse(messages, fallbackBase: fallbackBase) }.value
    }

    nonisolated static func parse(_ messages: [JSONValue], fallbackBase: Int = 0) -> [ChatItem] {
        var parsed: [ChatItem] = []
        parsed.reserveCapacity(messages.count)
        var seen: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            guard var item = ChatItem(message, fallbackIndex: fallbackBase + index, projectLegacyLocation: true) else { continue }
            let count = seen[item.id, default: 0]
            seen[item.id] = count + 1
            if count > 0 { item.id += "#\(count)" }
            parsed.append(item)
        }
        return parsed
    }

    func apply(history: JSONValue, parsed: [ChatItem]) {
        let messages = history["messages"]?.array ?? []
        var incomingItemIDs: Set<String>? = self.hasPagedOlder ? [] : nil
        let trackedLiveReplyIDs = Set(self.liveReplyItemTokens.keys)
            .union(self.liveReplyCandidate.map { [$0.id] } ?? [])
        var matchingLiveReplyRows: [String: (item: ChatItem, parsedIndex: Int)] = [:]
        // Keep optimistic sends that the transcript hasn't committed yet.
        var committedKeys: Set<String> = []
        for (parsedIndex, item) in parsed.enumerated() {
            if let key = item.idempotencyKey { committedKeys.insert(key) }
            incomingItemIDs?.insert(item.id)
            if trackedLiveReplyIDs.contains(item.id) {
                matchingLiveReplyRows[item.id] = (item: item, parsedIndex: parsedIndex)
            }
        }
        let pending = self.items.filter { $0.isPending && !committedKeys.contains($0.idempotencyKey ?? "") }
        self.gateway?.reconcileOutbox(committedKeys: committedKeys)
        // The latest page replaces the tail; older pages the user scrolled back through stay put.
        // Overlap is found through a transcript id (index-based fallback ids aren't stable across
        // pages); no overlap means the loaded history is stale (e.g. the session was reset).
        var older: [ChatItem] = []
        if self.hasPagedOlder, let incomingItemIDs,
           let anchor = parsed.firstIndex(where: { $0.transcriptId != nil }),
           let match = self.items.firstIndex(where: { $0.transcriptId == parsed[anchor].transcriptId }),
           match >= anchor
        {
            older = self.items[..<(match - anchor)].filter { !$0.isPending && !incomingItemIDs.contains($0.id) }
        } else {
            self.hasPagedOlder = false
            self.olderOffset = history["nextOffset"]?.int ?? messages.count
            self.olderInCache = false
            self.hasMoreHistory = history["hasMore"]?.bool ?? (messages.count >= self.historyLimit)
            self.startBackfill()
        }
        let merged = older + parsed + pending
        if merged != self.items { self.items = merged }
        let refreshedRows = matchingLiveReplyRows.values.map {
            (item: $0.item, fallbackIndex: older.count + $0.parsedIndex)
        }
        self.refreshLiveReplyPreparations(matching: refreshedRows)
        self.releaseCommittedOutboxImagePreviews(committedKeys)
        self.pruneRecoveryState(keeping: parsed)
        self.recoverCappedMessages()

        if let inFlight = history["inFlightRun"], let runId = inFlight["runId"]?.text {
            let isSameRun = self.live?.runId == runId
            var run = isSameRun ? self.live! : LiveRun(runId: runId)
            if let text = inFlight["text"]?.string, !text.isEmpty {
                let textUTF8Count = text.utf8.count
                let grew = textUTF8Count > run.textUTF8Count
                run.text = text
                run.textUTF8Count = textUTF8Count
                if !isSameRun || grew { run.isTextStreaming = true }
            }
            self.live = run
            self.gateway?.track(runId: runId, sessionKey: self.sessionKey)
        } else if history["sessionInfo"]?["hasActiveRun"]?.bool == false {
            // A `/compact` run that ended while events were missed (e.g. a reconnect) still settles.
            if let runId = self.compactionRunId, self.live?.runId == runId {
                Task { await self.finishCompaction(runId: runId) }
            }
            self.live = nil
        }
    }
}

private extension ChatItem {
    /// Where a windowed transcript may begin: a committed user message that a history refresh can match by id.
    var startsWindow: Bool { self.role == .user && !self.isPending && self.transcriptId != nil }
}
