import Foundation
import Observation

extension ChatStore {
    /// True when the message subscription was sent on the current connection.
    public var isSubscribed: Bool {
        guard let gateway else { return false }
        return self.subscribedEpoch == gateway.connectionEpoch
    }

    /// The next `load()` refetches history and resubscribes even if not forced.
    public func markStale() { self.stale = true }

    public func releaseSubscription() async {
        let wasSubscribed = self.isSubscribed
        self.subscribedEpoch = nil
        self.stale = true
        if wasSubscribed, let gateway, gateway.state.isConnected {
            _ = try? await gateway.connection.request(
                "sessions.messages.unsubscribe",
                .object(self.params(keyName: "key")),
                timeout: 10)
        }
    }

    public func load(force: Bool = false) async {
        self.isDehydrated = false
        await self.restoreDraft()
        await self.restoreFromCache()
        guard let gateway, gateway.state.isConnected else { return }
        if self.hasLoaded, !force, !self.stale { return }
        if self.loadInFlight, !force { return }
        self.loadInFlight = true
        defer { self.loadInFlight = false }
        self.isLoading = !self.hasLoaded
        defer { self.isLoading = false }
        do {
            let epoch = gateway.connectionEpoch
            if self.subscribedEpoch != epoch {
                self.subscribedEpoch = epoch
                do {
                    _ = try await gateway.connection.request(
                        "sessions.messages.subscribe",
                        .object(self.params(keyName: "key")),
                        timeout: 10)
                } catch is CancellationError {
                    if self.subscribedEpoch == epoch { self.subscribedEpoch = nil }
                    return
                } catch {
                    if self.subscribedEpoch == epoch { self.subscribedEpoch = nil }
                }
            }
            var params = self.params(keyName: "sessionKey")
            params["limit"] = .number(Double(self.historyLimit))
            let result = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
            let parsed = await Self.parseDetached(result["messages"]?.array ?? [], fallbackBase: 0)
            self.apply(history: result, parsed: parsed)
            self.hasLoaded = true
            self.stale = false
            self.loadCount += 1
            self.errorMessage = nil
            self.scheduleSave()
            self.startBackfill()
            self.refreshProgressCard()
        } catch is CancellationError {
            return
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Shows the cached transcript before the Gateway answers; the newest page is merged over it.
    /// Without a usable one (missing, or discarded as corrupt, outdated or from a newer app)
    /// nothing is shown: the chat stays loading until the Gateway's history arrives.
    struct CacheState: Equatable {
        var revision: Int
        var hasMoreHistory: Bool
        var activityMs: Double?
    }

    var currentCacheState: CacheState {
        CacheState(revision: self.contentRevision, hasMoreHistory: self.hasMoreHistory,
                   activityMs: self.gateway?.sessions[self.sessionKey]?.activityMs)
    }

    /// Saves the current snapshot unless the cache already holds this state (or can't be trusted).
    func saveSnapshot() async {
        guard !self.cacheUnreadable else { return }
        let state = self.currentCacheState
        guard state != self.savedState else { return }
        await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                   keepingOlder: self.olderInCache)
        self.savedState = state
    }

    func restoreFromCache() async {
        guard !self.cacheChecked else { return }
        self.cacheChecked = true
        let cached = await TranscriptCache.loadNewest(gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                                      limit: self.windowLimit)
        let outcome = cached.outcome
        self.cacheOutcome = outcome
        if case .unavailable = outcome {
            // Retried on the next load; until then a save would replace the cached history.
            self.cacheChecked = false
            self.cacheUnreadable = true
            return
        }
        // Unsent messages shown before the cache arrived stay, after it.
        guard !cached.items.isEmpty else {
            self.cacheUnreadable = false
            return
        }
        // A full window may have older items behind it (or exactly end at the start; the first page finds out).
        let moreInCache = cached.items.count >= self.windowLimit
        guard self.items.allSatisfy(\.isPending) else {
            self.mergeCached(cached.items, complete: cached.complete, moreInCache: moreInCache)
            return
        }
        self.cacheUnreadable = false
        // With the whole cache in memory, item count never exceeds the raw message count, so this
        // offset can only overlap (deduped by id), never skip; the first older page's `nextOffset`
        // makes it exact again. Behind a window the offset is set once paging reaches the cache start.
        self.olderOffset = moreInCache ? nil : cached.items.count
        self.olderInCache = moreInCache
        self.hasMoreHistory = !cached.complete
        self.hasPagedOlder = true
        self.items = cached.items + self.items
        if outcome == .loaded, self.items == cached.items { self.savedState = self.currentCacheState }
    }

    /// The cache arrived after the Gateway's newest page (a retry after `.unavailable`): puts the
    /// cached items that come before that page in front, so a save keeps the older history.
    private func mergeCached(_ cachedItems: [ChatItem], complete: Bool, moreInCache: Bool) {
        defer { self.cacheUnreadable = false }
        let loaded = Set(self.items.map(\.id))
        // Without an overlap, messages may be missing between the cache and the loaded page, so
        // nothing is spliced in: the Gateway pages older history and the next save replaces the cache.
        guard let firstLoaded = self.items.first(where: { !$0.isPending }),
              let cut = cachedItems.firstIndex(where: { $0.id == firstLoaded.id })
        else { return }
        let older = Array(cachedItems[..<cut]).filter { !loaded.contains($0.id) }
        // The window's own start has more cached behind it only if it wasn't cut at the overlap.
        let more = moreInCache
        guard !older.isEmpty || more else { return }
        let committed = self.items.filter { !$0.isPending }.count
        self.olderOffset = more ? nil : committed + older.count
        self.olderInCache = more
        self.hasMoreHistory = !complete
        self.hasPagedOlder = true
        self.items = older + self.items
    }

    /// Brings back the draft saved on disk, unless one was started here in the meantime.
    func restoreDraft() async {
        guard !self.draftChecked, !self.headless else { return }
        self.draftChecked = true
        guard let saved = await DraftStore.load(gatewayId: self.gatewayId, sessionKey: self.sessionKey),
              !self.draftEdited
        else { return }
        self.restoringDraft = true
        self.draft = saved
        self.restoringDraft = false
    }

    func scheduleDraftSave(after delay: Duration = .milliseconds(400)) {
        let previous = self.draftSaveTask
        previous?.cancel()
        let draft = self.draft
        self.draftSaveTask = Task { [gatewayId, sessionKey] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            // Saves land in order, so an older draft never overwrites a newer one.
            await previous?.value
            await DraftStore.save(draft, gatewayId: gatewayId, sessionKey: sessionKey)
        }
    }

    /// Writes a pending draft now, e.g. before the app is suspended.
    public func flushDraft() async {
        guard self.draftSaveTask != nil else { return }
        self.scheduleDraftSave(after: .zero)
        await self.draftSaveTask?.value
    }

    /// Brings the on-disk cache up to date with the full history, without touching the UI.
    func fillCache() async {
        await self.restoreFromCache()
        guard !self.cacheUnreadable, let gateway, gateway.state.isConnected else { return }
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        guard let result = try? await gateway.connection.request("chat.history", .object(params), timeout: 30) else { return }
        let parsed = await Self.parseDetached(result["messages"]?.array ?? [], fallbackBase: 0)
        self.apply(history: result, parsed: parsed)
        self.live = nil
        self.hasLoaded = true
        await self.loadAllCached()
        // Older items past the retention limit would be dropped anyway.
        while self.hasMoreHistory, !Task.isCancelled, self.committedCount < TranscriptCache.maxItems {
            guard self.gateway?.appIsActive ?? false else { return }
            guard await self.loadOlder() else { return }
        }
        guard !Task.isCancelled else { return }
        await self.saveSnapshot()
    }

    var committedCount: Int { self.items.lazy.filter { !$0.isPending }.count }

    func snapshot() -> TranscriptCache.Snapshot {
        Self.snapshot(items: self.items, hasMoreHistory: self.hasMoreHistory,
                      activityMs: self.gateway?.sessions[self.sessionKey]?.activityMs)
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
    func reloadAfterHistoryChange(clearingCache clearCache: @MainActor () async -> Void = {}) async {
        self.saveTask?.cancel()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cacheChecked = true
        self.cacheUnreadable = false
        self.savedState = nil
        self.hasPagedOlder = false
        self.olderOffset = nil
        self.olderInCache = false
        self.hasMoreHistory = false
        self.fullMessages = [:]
        self.recoveryAttempted = []
        let pending = self.items.filter(\.isPending)
        if pending != self.items { self.items = pending }
        self.hasLoaded = false
        await clearCache()
        await self.load(force: true)
    }

    /// The session was deleted: nothing more is written to the transcript cache.
    func stopCaching() {
        self.saveTask?.cancel()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cachingStopped = true
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
        self.saveTask?.cancel()
        // The cache was cleared, so it no longer holds what was saved.
        self.savedState = nil
        await self.saveSnapshot()
    }

    func scheduleSave() {
        guard self.hasLoaded, !self.isDehydrated, !self.cachingStopped, !self.cacheUnreadable,
              self.currentCacheState != self.savedState
        else { return }
        self.saveTask?.cancel()
        self.saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.isDehydrated else { return }
            await self.saveSnapshot()
        }
    }

    /// Brings the whole history to disk (and the search index) right after opening, in a headless
    /// store, so this one keeps only its window in memory. Resumes on reconnect if it was cut short.
    func startBackfill() {
        guard self.backfillTask == nil, self.hasMoreHistory, !self.headless, let gateway = self.gateway else { return }
        self.backfillTask = Task { [weak self, sessionKey, agentId] in
            let filler = ChatStore(sessionKey: sessionKey, agentId: agentId, gateway: gateway, headless: true)
            await filler.fillCache()
            guard !Task.isCancelled, let self else { return }
            self.backfillTask = nil
            await self.adoptBackfilledCache()
        }
    }

    /// The background fill finished: the cache may now hold items older than the loaded window.
    private func adoptBackfilledCache() async {
        guard !self.cachingStopped, !self.isDehydrated, !self.olderInCache,
              let first = self.items.first(where: { !$0.isPending })
        else { return }
        let older = await TranscriptCache.loadOlder(gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                                    before: first.id, limit: 1)
        guard !self.cachingStopped, !self.isDehydrated, !self.olderInCache,
              Self.cacheReadable(older.outcome), !older.items.isEmpty
        else { return }
        self.olderInCache = true
        self.olderOffset = nil
        self.hasPagedOlder = true
        if let meta = await TranscriptCache.meta(gatewayId: self.gatewayId, sessionKey: self.sessionKey), meta.complete {
            self.hasMoreHistory = false
        }
        // The filler's save may lack what this store already saved; write the window over it, keeping the older part.
        self.savedState = nil
        self.scheduleSave()
    }

    /// Prepends the next older page, from the cache while it holds older items and then from the
    /// Gateway, keeping everything already loaded (and its row identity). Returns false when it
    /// couldn't reach the source.
    @discardableResult
    public func loadOlder() async -> Bool {
        await self.loadOlder(cachePageSize: Self.olderCachePageSize)
    }

    func loadOlder(cachePageSize: Int) async -> Bool {
        // Concurrent callers share the in-flight page rather than returning early and spinning.
        if let inFlight = self.olderTask { return await inFlight.value }
        guard self.hasOlderItems else { return true }
        guard self.olderInCache || self.olderOffset != nil else { return false }
        self.isLoadingOlder = true
        let task = Task {
            let ok = self.olderInCache ? await self.loadCachedOlderPage(limit: cachePageSize) : await self.fetchOlderPage()
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
            guard await self.loadOlder(cachePageSize: Self.lookupCachePageSize) else { return }
        }
    }

    private func loadCachedOlderPage(limit: Int) async -> Bool {
        guard let first = self.items.first(where: { !$0.isPending }) else {
            self.olderInCache = false
            return true
        }
        let page = await TranscriptCache.loadOlder(gatewayId: self.gatewayId, sessionKey: self.sessionKey,
                                                   before: first.id, limit: limit)
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
        let known = Set(self.items.map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }
        self.olderInCache = !page.reachedStart && !fresh.isEmpty
        self.hasPagedOlder = true
        if !self.olderInCache { self.olderOffset = self.committedCount + fresh.count }
        if !fresh.isEmpty { self.items = fresh + self.items }
        return true
    }

    /// The index of the first item kept when only the newest `limit` committed items stay. Moves
    /// forward to the start of a turn (a user message) so a turn is never split; unsent items are
    /// never cut, and 0 means nothing to drop.
    nonisolated static func windowCut(_ items: [ChatItem], limit: Int) -> Int {
        let committed = items.indices.filter { !items[$0].isPending }
        guard limit >= 0, committed.count > limit else { return 0 }
        let start = limit == 0 ? items.count : committed[committed.count - limit]
        return items[start...].firstIndex { $0.role == .user && !$0.isPending } ?? min(start, items.count)
    }

    /// Drops the oldest committed items beyond `windowLimit` from a chat that isn't in use. What's
    /// dropped stays on disk and pages back in through `loadOlder`.
    func trimToWindow() async {
        guard self.canTrim, self.committedCount > self.windowLimit else { return }
        self.saveTask?.cancel()
        await self.saveSnapshot()
        // The save suspended: the chat may have been opened or become busy meanwhile.
        guard self.canTrim, self.savedState == self.currentCacheState else { return }
        let cut = Self.windowCut(self.items, limit: self.windowLimit)
        guard cut > 0 else { return }
        self.olderInCache = true
        self.hasPagedOlder = true
        self.olderOffset = nil
        self.items = self.items[cut...] + self.items[..<cut].filter(\.isPending)
        self.saveTask?.cancel()
        self.savedState = self.currentCacheState
    }

    private static func cacheReadable(_ outcome: TranscriptCache.LoadOutcome) -> Bool {
        switch outcome {
        case .loaded, .migrated: true
        default: false
        }
    }

    /// Warm chats may be trimmed too: only a selected or busy chat is left alone.
    private var canTrim: Bool {
        guard !self.headless, self.isHydrated, !self.cachingStopped, !self.cacheUnreadable, self.olderTask == nil,
              !self.residencySnapshot.isPinned,
              TranscriptCache.file(gatewayId: self.gatewayId, sessionKey: self.sessionKey) != nil
        else { return false }
        return true
    }

    func fetchOlderPage() async -> Bool {
        guard let offset = self.olderOffset, let gateway, gateway.state.isConnected else { return false }
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
            guard var item = ChatItem(message, fallbackIndex: fallbackBase + index) else { continue }
            let count = seen[item.id, default: 0]
            seen[item.id] = count + 1
            if count > 0 { item.id += "#\(count)" }
            parsed.append(item)
        }
        return parsed
    }

    func apply(history: JSONValue, parsed: [ChatItem]) {
        let messages = history["messages"]?.array ?? []
        // Keep optimistic sends that the transcript hasn't committed yet.
        let committedKeys = Set(parsed.compactMap(\.idempotencyKey))
        let pending = self.items.filter { $0.isPending && !committedKeys.contains($0.idempotencyKey ?? "") }
        self.gateway?.reconcileOutbox(committedKeys: committedKeys)
        // The latest page replaces the tail; older pages the user scrolled back through stay put.
        // Overlap is found through a transcript id (index-based fallback ids aren't stable across
        // pages); no overlap means the loaded history is stale (e.g. the session was reset).
        var older: [ChatItem] = []
        if self.hasPagedOlder, let anchor = parsed.firstIndex(where: { $0.transcriptId != nil }),
           let match = self.items.firstIndex(where: { $0.transcriptId == parsed[anchor].transcriptId }),
           match >= anchor
        {
            let latest = Set(parsed.map(\.id))
            older = self.items[..<(match - anchor)].filter { !$0.isPending && !latest.contains($0.id) }
        } else {
            self.hasPagedOlder = false
            self.olderOffset = history["nextOffset"]?.int ?? messages.count
            self.olderInCache = false
            self.hasMoreHistory = history["hasMore"]?.bool ?? (messages.count >= self.historyLimit)
        }
        let merged = older + parsed + pending
        if merged != self.items { self.items = merged }
        self.pruneRecoveryState(keeping: parsed)
        self.recoverCappedMessages()

        if let inFlight = history["inFlightRun"], let runId = inFlight["runId"]?.text {
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            if let text = inFlight["text"]?.string, !text.isEmpty { run.text = text }
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

    // MARK: Capped messages

    /// History caps each text field (8,000 chars by default) and flags the message; like the
    /// Control UI, fetch the full copy with `chat.message.get` and swap it in.
    func recoverCappedMessages() {
        var items = self.items
        var substituted = false
        var missing: [String] = []
        for index in items.indices where items[index].isCapped {
            guard let messageId = items[index].transcriptId else { continue }
            if let full = self.fullMessages[messageId] {
                items[index] = Self.restoring(full, over: items[index])
                substituted = true
            } else if self.recoveryAttempted.insert(messageId).inserted {
                missing.append(messageId)
            }
        }
        if substituted { self.items = items }
        for messageId in missing {
            Task { [weak self] in await self?.fetchFullMessage(messageId) }
        }
    }

    func fetchFullMessage(_ messageId: String) async {
        guard let gateway, gateway.state.isConnected else {
            self.recoveryAttempted.remove(messageId)
            return
        }
        var params = self.params(keyName: "sessionKey")
        params["messageId"] = .string(messageId)
        params["maxChars"] = .number(Double(self.fullMessageMaxChars))
        let result: JSONValue
        do {
            result = try await gateway.connection.request("chat.message.get", .object(params), timeout: 30)
        } catch {
            // Transport failures retry on the next history pass; Gateway refusals below don't.
            self.recoveryAttempted.remove(messageId)
            return
        }
        guard result["ok"]?.bool == true, let message = result["message"],
              let full = ChatItem(message, fallbackIndex: 0), !full.isCapped
        else { return }
        self.fullMessages[messageId] = full
        guard let index = self.items.firstIndex(where: { $0.transcriptId == messageId && $0.isCapped }) else { return }
        self.items[index] = Self.restoring(full, over: self.items[index])
    }

    /// The full copy with the capped row's identity, so the row keeps its place and scroll anchor.
    static func restoring(_ full: ChatItem, over capped: ChatItem) -> ChatItem {
        var item = full
        item.id = capped.id
        item.isPending = capped.isPending
        item.idempotencyKey = full.idempotencyKey ?? capped.idempotencyKey
        return item
    }

    func scheduleReload(after delay: Duration = .milliseconds(250)) {
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load(force: true)
        }
    }
}
