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
    func restoreFromCache() async {
        guard !self.cacheChecked else { return }
        self.cacheChecked = true
        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gatewayId, sessionKey: self.sessionKey)
        self.cacheOutcome = outcome
        // Unsent messages shown before the cache arrived stay, after it.
        guard let snapshot, !snapshot.items.isEmpty, self.items.allSatisfy(\.isPending) else { return }
        // Item count never exceeds the raw message count, so this offset can only overlap (deduped
        // by id), never skip; the first older page's `nextOffset` makes it exact again.
        self.olderOffset = snapshot.items.count
        self.hasMoreHistory = !snapshot.complete
        self.hasPagedOlder = true
        self.items = snapshot.items + self.items
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
        guard let gateway, gateway.state.isConnected else { return }
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        guard let result = try? await gateway.connection.request("chat.history", .object(params), timeout: 30) else { return }
        let parsed = await Self.parseDetached(result["messages"]?.array ?? [], fallbackBase: 0)
        self.apply(history: result, parsed: parsed)
        self.live = nil
        self.hasLoaded = true
        while self.hasMoreHistory, !Task.isCancelled {
            guard await self.loadOlder() else { return }
        }
        guard !Task.isCancelled else { return }
        await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey)
    }

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
        return TranscriptCache.Snapshot(
            items: Array(kept),
            complete: !hasMoreHistory && kept.count == committed.count,
            activityMs: activityMs)
    }

    /// The Gateway rewrote this chat's history (rewind, branch switch, recovery): drops what's
    /// loaded, including tool details, runs `clearCache` once no save can land, then refetches.
    func reloadAfterHistoryChange(clearingCache clearCache: @MainActor () async -> Void = {}) async {
        self.saveTask?.cancel()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cacheChecked = true
        self.hasPagedOlder = false
        self.olderOffset = nil
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
        let save = self.hasLoaded && !self.cachingStopped
        self.stopCaching()
        if save { await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey) }
    }

    /// Writes what's loaded to the transcript cache now (after it was cleared).
    func saveToCache() async {
        guard self.hasLoaded, !self.cachingStopped else { return }
        self.saveTask?.cancel()
        await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey)
    }

    func scheduleSave() {
        guard self.hasLoaded, !self.cachingStopped else { return }
        self.saveTask?.cancel()
        self.saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey)
        }
    }

    /// Pulls the whole history in right after opening, while you're parked at the bottom, so
    /// scrolling up never waits on the network. Resumes on reconnect if it was cut short.
    func startBackfill() {
        guard self.backfillTask == nil, self.hasMoreHistory else { return }
        self.backfillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hasMoreHistory else { break }
                guard await self.loadOlder() else { break }
            }
            self?.backfillTask = nil
        }
    }

    /// Prepends the next older page, keeping everything already loaded (and its row identity).
    /// Returns false when it couldn't reach the Gateway.
    @discardableResult
    public func loadOlder() async -> Bool {
        // Concurrent callers share the in-flight page rather than returning early and spinning.
        if let inFlight = self.olderTask { return await inFlight.value }
        guard self.hasMoreHistory else { return true }
        guard self.olderOffset != nil else { return false }
        self.isLoadingOlder = true
        let task = Task {
            let ok = await self.fetchOlderPage()
            // Cleared by the task itself so every waiter sees it finished.
            self.olderTask = nil
            self.isLoadingOlder = false
            return ok
        }
        self.olderTask = task
        return await task.value
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
            self.hasMoreHistory = history["hasMore"]?.bool ?? (messages.count >= self.historyLimit)
        }
        let merged = older + parsed + pending
        if merged != self.items { self.items = merged }
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
