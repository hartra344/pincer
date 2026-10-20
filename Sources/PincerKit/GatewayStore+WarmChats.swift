import Foundation
import Observation

extension GatewayStore {
    /// The selected chat, the most recent ones up to the cap, and any chat with a live run.
    func warmKeys(includingLive: Bool) -> Set<String> {
        var keys = Set(self.recentKeys.prefix(Self.warmChatLimit))
        if let selected = self.selectedKey { keys.insert(selected) }
        keys.formUnion(self.windowCounts.keys)
        if includingLive {
            for chat in self.chats.values where chat.isRunning { keys.insert(chat.sessionKey) }
        }
        return keys
    }

    func noteSelected(_ key: String) {
        self.recentKeys.removeAll { $0 == key }
        self.recentKeys.insert(key, at: 0)
        if self.recentKeys.count > Self.warmChatLimit { self.recentKeys.removeLast(self.recentKeys.count - Self.warmChatLimit) }
        let warm = self.warmKeys(includingLive: true)
        for chat in self.chats.values where !warm.contains(chat.sessionKey) && chat.isSubscribed {
            Task { await chat.releaseSubscription() }
        }
        self.residency.touch(key)
        self.enforceChatBudget()
    }

    /// Indexes cached transcripts the message index hasn't seen yet (caches from before it
    /// existed, or after it was rebuilt), in the background.
    func reconcileMessageIndex() {
        guard MessageIndex.status(gatewayId: self.id, root: self.cacheRoot) != .unavailable else {
            self.messageIndexProgress = .unavailable
            return
        }
        self.reconcileTask?.cancel()
        let keys = self.sessions.values.filter { !$0.isSubagent }.map(\.key)
        let index = self.messageIndex
        self.reconcileTask = Task.detached(priority: .utility) { [weak self] in
            // One main-actor hop per interval rather than per chat; ready/unavailable always go through.
            let throttle = ProgressThrottle<MessageIndex.Status> { status in
                await MainActor.run { self?.messageIndexProgress = status }
            }
            await index.reconcile(sessionKeys: keys) { status in await throttle.submit(status) }
        }
    }

    /// Chats message search may show: listed, not subagent runs, archived only while listed.
    var searchableSessionKeys: Set<String> {
        Set(self.sessions.values.filter { !$0.isSubagent && (self.showArchived || !$0.isArchived) }.map(\.key))
    }

    /// Messages matching `query` across this Gateway's cached chats, grouped by chat. Throws
    /// `CancellationError` when a newer search replaced this one.
    public func searchMessages(_ query: String) async throws -> MessageSearch.Results {
        let query = TranscriptSearch.normalized(query)
        guard MessageSearch.ftsQuery(query) != nil else { return MessageSearch.Results(query: query) }
        let index = self.messageIndex
        let allowed = self.searchableSessionKeys
        let candidates: [MessageSearch.Hit]
        do {
            // Cancelling this task interrupts the search.
            candidates = try await index.search(query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The index may have been deleted; refill it from the transcripts, at most once a minute.
            let now = ContinuousClock.now
            if self.lastFailureReconcile.map({ now - $0 >= .seconds(60) }) ?? true {
                self.lastFailureReconcile = now
                self.reconcileMessageIndex()
            }
            return MessageSearch.Results(query: query, failed: true)
        }
        let groups = await Task.detached(priority: .userInitiated) {
            MessageSearch.collect(candidates, query: query, allowed: allowed)
        }.value
        try Task.checkCancellation()
        let snippets = await Task.detached(priority: .userInitiated) {
            groups.map { $0.hits.map { MessageSearch.snippet(query: query, markdown: $0.text) } }
        }.value
        try Task.checkCancellation()
        let chats: [MessageSearch.Chat] = zip(groups, snippets).compactMap { group, snippets in
            guard let row = self.sessions[group.sessionKey] else { return nil }
            let agent = self.agent(row.agentId).name
            let messages = zip(group.hits, snippets).map { hit, snippet in
                MessageSearch.Message(
                    hit: hit,
                    sender: hit.sender?.displayName(agents: self.agents)
                        ?? (hit.role == .user ? hit.via.map { "via \($0)" } ?? "You" : agent),
                    snippet: snippet)
            }
            return MessageSearch.Chat(sessionKey: row.key, title: row.title, isArchived: row.isArchived,
                                      messages: messages, hasMore: group.hasMore)
        }
        return MessageSearch.Results(query: query, chats: chats)
    }

    /// The transcript cache was cleared (Settings): chats open here are saved again and the rest
    /// refetched in the background, so the cache and search index fill back up without a relaunch.
    func cacheCleared() async {
        for chat in self.chats.values { await chat.saveToCache() }
        guard self.state.isConnected else { return }
        self.startPrefetch()
    }
}
