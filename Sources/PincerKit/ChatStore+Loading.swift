import Foundation
import Observation

extension ChatStore {
    enum ForwardedRefreshPageDisposition: Equatable {
        case more(nextOffset: Int)
        case complete(nextOffset: Int)
        case abort
    }

    /// Validates paging progress before a sender refresh can be considered authoritative.
    nonisolated static func forwardedRefreshPageDisposition(messageCount: Int?, reportedHasMore: Bool?,
                                                             requestedOffset: Int, returnedOffset: Int?,
                                                             fallbackLimit: Int) -> ForwardedRefreshPageDisposition
    {
        guard let messageCount else { return .abort }
        if messageCount == 0 {
            return reportedHasMore == true
                ? .abort
                : .complete(nextOffset: returnedOffset ?? requestedOffset)
        }
        let nextOffset = returnedOffset ?? (requestedOffset + messageCount)
        guard nextOffset > requestedOffset else { return .abort }
        let hasMore = reportedHasMore ?? (messageCount >= fallbackLimit)
        return hasMore ? .more(nextOffset: nextOffset) : .complete(nextOffset: nextOffset)
    }

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
                .object(self.unsubscribeParams()),
                timeout: 10)
        }
    }

    public func load(force: Bool = false) async {
        self.isDehydrated = false
        await self.restoreDraft()
        await self.restoreFromCache()
        guard let gateway, gateway.state.isConnected else { return }
        if self.forwardedSenderRefreshPending, !self.headless {
            gateway.startHeadlessFill(sessionKey: self.sessionKey, agentId: self.agentId)
        }
        if self.hasLoaded, !force, !self.stale { return }
        if !force, let running = self.loadTask {
            await Self.value(of: running)
            // The caller that started it went away mid-fetch; this one still wants the history.
            if running.isCancelled, !Task.isCancelled { await self.load() }
            return
        }
        self.loadGeneration += 1
        let generation = self.loadGeneration
        // Waiters await this task; only the caller that started it passes its cancellation on.
        let task = Task {
            await self.fetchHistory(gateway)
            if self.loadGeneration == generation { self.loadTask = nil }
        }
        self.loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Waits for `task`, but returns as soon as the caller is cancelled; `task` itself keeps running.
    private static func value(of task: Task<Void, Never>) async {
        let gate = WaiterGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                Task {
                    await task.value
                    gate.resume()
                }
            }
        } onCancel: {
            gate.resume()
        }
    }

    private func fetchHistory(_ gateway: GatewayStore) async {
        self.isLoading = !self.hasLoaded
        defer { self.isLoading = false }
        do {
            let epoch = gateway.connectionEpoch
            if self.subscribedEpoch != epoch {
                self.subscribedEpoch = epoch
                do {
                    try await self.subscribeToMessages(on: gateway)
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
            if !self.headless {
                Task { await self.refreshBranches() }
                Task { await self.syncReactions() }
            }
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
        let result = await TranscriptCache.saveReturningStats(
            snapshot, gatewayId: self.gatewayId, sessionKey: self.sessionKey,
            keepingOlder: self.olderInCache || self.hasMoreHistory, root: self.cacheRoot)
        self.recordSavedSnapshot(state, result: result)
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
        self.cacheOutcome = outcome
        if case .unavailable = outcome {
            // Retried on the next load; until then a save would replace the cached history.
            self.cacheChecked = false
            self.cacheUnreadable = true
            return
        }
        self.forwardedSenderRefreshPending = loaded.forwardedSenderRefreshPending
        // Unsent messages shown before the cache arrived stay, after it.
        guard !cached.items.isEmpty else {
            self.cacheUnreadable = false
            return
        }
        guard self.items.allSatisfy(\.isPending) else {
            self.mergeCached(cached.items, complete: cached.complete, moreInCache: moreInCache)
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
    /// `generation` is the cache generation this fill started under; a rewind or delete since
    /// then makes it discard what it fetched instead of saving it.
    func fillCache(generation: Int? = nil, connectionEpoch expectedConnectionEpoch: Int? = nil) async {
        guard let gateway else { return }
        let connectionEpoch = expectedConnectionEpoch ?? gateway.connectionEpoch
        await self.restoreFromCache()
        guard !self.cacheUnreadable, gateway.state.isConnected,
              gateway.connectionEpoch == connectionEpoch
        else { return }
        let expectedGeneration = generation ?? gateway.cacheGeneration(of: self.sessionKey)
        let refreshForwardedSenders = self.forwardedSenderRefreshPending
        // `apply(history:)` can discard cached history when the newest page has no overlap. Keep
        // the complete restored snapshot for reconciliation until the authoritative scan finishes.
        let restoredCacheItems = refreshForwardedSenders ? self.items : []
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        guard let result = try? await gateway.connection.request("chat.history", .object(params), timeout: 30) else { return }
        let receivedFirstPage = result["messages"]?.array
        let firstPageDisposition = Self.forwardedRefreshPageDisposition(
            messageCount: receivedFirstPage?.count, reportedHasMore: result["hasMore"]?.bool,
            requestedOffset: 0, returnedOffset: result["nextOffset"]?.int,
            fallbackLimit: self.historyLimit)
        if refreshForwardedSenders, firstPageDisposition == .abort { return }
        let firstPage = receivedFirstPage ?? []
        let parsed = await Self.parseDetached(firstPage, fallbackBase: 0)
        guard !Task.isCancelled, self.gateway === gateway, gateway.state.isConnected,
              gateway.connectionEpoch == connectionEpoch,
              gateway.cacheGeneration(of: self.sessionKey) == expectedGeneration
        else { return }
        self.apply(history: result, parsed: parsed)
        self.live = nil
        self.hasLoaded = true
        if refreshForwardedSenders {
            var pagesNewestFirst = [parsed]
            var scanned = firstPage.count
            var offset: Int
            var hasMore: Bool
            switch firstPageDisposition {
            case let .more(nextOffset): offset = nextOffset; hasMore = true
            case let .complete(nextOffset): offset = nextOffset; hasMore = false
            case .abort: return
            }
            while hasMore, scanned < TranscriptCache.maxItems {
                guard !Task.isCancelled, self.gateway === gateway, gateway.state.isConnected,
                      gateway.connectionEpoch == connectionEpoch,
                      gateway.cacheGeneration(of: self.sessionKey) == expectedGeneration,
                      gateway.appIsActive
                else { return }
                params["limit"] = .number(Double(min(self.historyLimit, TranscriptCache.maxItems - scanned)))
                params["offset"] = .number(Double(offset))
                let page: JSONValue
                do {
                    page = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
                } catch {
                    return
                }
                let receivedPage = page["messages"]?.array
                guard !Task.isCancelled else { return }
                let disposition = Self.forwardedRefreshPageDisposition(
                    messageCount: receivedPage?.count, reportedHasMore: page["hasMore"]?.bool,
                    requestedOffset: offset, returnedOffset: page["nextOffset"]?.int,
                    fallbackLimit: min(self.historyLimit, TranscriptCache.maxItems - scanned))
                if disposition == .abort { return }
                guard let raw = receivedPage else { return }
                let older = await Self.parseDetached(raw, fallbackBase: -(offset + raw.count))
                pagesNewestFirst.append(older)
                scanned += raw.count
                switch disposition {
                case let .more(nextOffset): offset = nextOffset; hasMore = true
                case let .complete(nextOffset): offset = nextOffset; hasMore = false
                case .abort: return
                }
            }
            guard !Task.isCancelled, self.gateway === gateway, gateway.state.isConnected,
                  gateway.connectionEpoch == connectionEpoch,
                  gateway.cacheGeneration(of: self.sessionKey) == expectedGeneration,
                  gateway.appIsActive,
                  !hasMore || scanned >= TranscriptCache.maxItems
            else { return }
            var reconciled: [ChatItem]?
            for attempt in 0...1 {
                let revision = self.contentRevision
                let currentItems = self.items
                let result = await Self.reconcileForwardedRefresh(
                    restoredCache: restoredCacheItems, pagesNewestFirst: pagesNewestFirst, current: currentItems)
                guard !Task.isCancelled, self.gateway === gateway, gateway.state.isConnected,
                      gateway.connectionEpoch == connectionEpoch,
                      gateway.cacheGeneration(of: self.sessionKey) == expectedGeneration,
                      gateway.appIsActive
                else { return }
                if self.contentRevision == revision {
                    reconciled = result
                    break
                }
                if attempt == 1 { return }
            }
            guard let reconciled else { return }
            self.items = reconciled
            self.hasMoreHistory = hasMore
            self.olderInCache = false
            self.olderOffset = offset
            self.hasPagedOlder = true
            self.forwardedSenderRefreshPending = false
            self.forwardedSenderRefreshCompleted = true
            await self.saveSnapshot()
            return
        }
        await self.loadAllCached()
        // Older items past the retention limit would be dropped anyway.
        while self.hasOlderItems, !Task.isCancelled, self.committedCount < TranscriptCache.maxItems {
            guard self.gateway?.appIsActive ?? false else { return }
            guard await self.loadOlder() else { return }
        }
        guard !Task.isCancelled, generation.map({ gateway.cacheGeneration(of: self.sessionKey) == $0 }) ?? true else { return }
        await self.saveSnapshot()
    }

    /// Replaces stale versions by stable transcript id while retaining offline-only cache rows.
    nonisolated static func mergeForwardedRefresh(cached: [ChatItem], authoritative: [ChatItem]) async -> [ChatItem] {
        await Task.detached(priority: .utility) {
            Self.mergeForwardedRefreshSynchronously(cached: cached, authoritative: authoritative)
        }.value
    }

    /// Filters and flattens full retained transcripts off-main before reconciling stable ids.
    nonisolated static func reconcileForwardedRefresh(restoredCache: [ChatItem], pagesNewestFirst: [[ChatItem]],
                                                       current: [ChatItem]) async -> [ChatItem]
    {
        await Task.detached(priority: .utility) {
            var authoritative = pagesNewestFirst.reversed().flatMap { $0 }
            var currentById: [String: ChatItem] = [:]
            currentById.reserveCapacity(current.count)
            for item in current where !item.isPending {
                currentById[item.transcriptId ?? item.id] = item
            }
            for index in authoritative.indices {
                let key = authoritative[index].transcriptId ?? authoritative[index].id
                guard var currentItem = currentById[key] else { continue }
                if let sender = authoritative[index].sender { currentItem.sender = sender }
                authoritative[index] = currentItem
            }
            // For duplicate ids absent from the authoritative pages, the live row may contain a
            // newer edit than the restored cache. The merge keeps its first matching row.
            let cached = current.filter { !$0.isPending } + restoredCache.filter { !$0.isPending }
            let committed = Self.mergeForwardedRefreshSynchronously(cached: cached, authoritative: authoritative)
            return committed + current.filter(\.isPending)
        }.value
    }

    /// Stable O(n log n) sort plus O(n) merge; preserves authoritative order, cached tie order,
    /// and the existing convention that cached rows without timestamps lead in reverse cache order.
    nonisolated private static func mergeForwardedRefreshSynchronously(cached: [ChatItem],
                                                                        authoritative: [ChatItem]) -> [ChatItem]
    {
        var authoritativeIds = Set<String>()
        authoritativeIds.reserveCapacity(authoritative.count)
        for item in authoritative { authoritativeIds.insert(item.transcriptId ?? item.id) }

        var seenIds = authoritativeIds
        var unmatched: [ChatItem] = []
        unmatched.reserveCapacity(cached.count)
        for item in cached {
            guard seenIds.insert(item.transcriptId ?? item.id).inserted else { continue }
            unmatched.append(item)
        }
        let undated = unmatched.filter { $0.timestamp == nil }.reversed()
        let dated = unmatched.enumerated().compactMap { ordinal, item -> (Int, ChatItem)? in
            item.timestamp == nil ? nil : (ordinal, item)
        }.sorted {
            let left = $0.1.timestamp!
            let right = $1.1.timestamp!
            return left == right ? $0.0 < $1.0 : left < right
        }

        var merged = Array(undated)
        merged.reserveCapacity(authoritative.count + unmatched.count)
        var cachedIndex = 0
        for item in authoritative {
            if let time = item.timestamp {
                while cachedIndex < dated.count, dated[cachedIndex].1.timestamp! < time {
                    merged.append(dated[cachedIndex].1)
                    cachedIndex += 1
                }
            }
            merged.append(item)
        }
        while cachedIndex < dated.count {
            merged.append(dated[cachedIndex].1)
            cachedIndex += 1
        }
        return Array(merged.suffix(TranscriptCache.maxItems))
    }

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
    func reloadAfterHistoryChange(clearingCache clearCache: @MainActor () async -> Void = {}) async {
        self.cancelScheduledSave()
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
        guard current(), !self.cacheUnreadable else { return }
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
            self.items = reconciled
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
            self.startBackfill()
        }
        let merged = older + parsed + pending
        if merged != self.items { self.items = merged }
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
        guard result["ok"]?.bool == true, let message = result["message"] else { return }
        let parsed = await Task.detached(priority: .utility) {
            ChatItem(message, fallbackIndex: 0, projectLegacyLocation: true)
        }.value
        guard let full = parsed, !full.isCapped else { return }
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

private extension ChatItem {
    /// Where a windowed transcript may begin: a committed user message that a history refresh can match by id.
    var startsWindow: Bool { self.role == .user && !self.isPending && self.transcriptId != nil }
}

/// Resumes its continuation exactly once, from whichever of completion or cancellation comes first.
private final class WaiterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = self.lock.withLock {
            if self.done { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func resume() {
        let pending = self.lock.withLock {
            self.done = true
            defer { self.continuation = nil }
            return self.continuation
        }
        pending?.resume()
    }
}
