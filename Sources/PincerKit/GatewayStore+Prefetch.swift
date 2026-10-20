import Foundation
import Observation

extension GatewayStore {
    /// Quietly caches every chat's full history, most recently active first, so opening any
    /// channel is instant. Chats that haven't changed since they were cached are skipped.
    /// A cached chat that holds everything it will (all of it, or the newest `maxItems`) and hasn't
    /// seen activity since needs no fetch.
    static func prefetchIsFresh(_ meta: TranscriptCache.Meta?, activityMs: Double) -> Bool {
        guard let meta, meta.version == TranscriptCache.Snapshot.currentVersion,
              meta.forwardedSenderRefreshPending != true,
              meta.complete || meta.retained == true, let cached = meta.activityMs else { return false }
        return cached >= activityMs
    }

    func startPrefetch() {
        self.prefetchTask?.cancel()
        self.prefetchGeneration += 1
        let generation = self.prefetchGeneration
        self.isPrefetching = true
        self.prefetchTask = Task { [weak self] in
            defer {
                if let self, self.prefetchGeneration == generation {
                    self.isPrefetching = false
                    if !Task.isCancelled { self.prefetchesFinished += 1 }
                }
            }
            try? await Task.sleep(for: .seconds(2))
            guard let rows = self?.sessions.values.filter({ !$0.isSubagent && !$0.isPlaceholder })
                .sorted(by: { $0.activityMs > $1.activityMs })
            else { return }
            var fetched = 0
            for row in rows {
                guard !Task.isCancelled, let self, self.state.isConnected, self.appIsActive,
                      fetched < Self.prefetchBudget else { return }
                if let chat = self.chats[row.key], !chat.isDehydrated { continue }
                let meta = await TranscriptCache.meta(gatewayId: self.id, sessionKey: row.key, root: self.cacheRoot)
                if Self.prefetchIsFresh(meta, activityMs: row.activityMs) { continue }
                fetched += 1
                await self.startHeadlessFill(sessionKey: row.key, agentId: row.agentId).value
            }
        }
    }

    func cacheGeneration(of key: String) -> Int { self.cacheGenerations[key, default: 0] }

    /// Caches the chat's full history in a headless store, off the UI. One fill runs per chat at a
    /// time; callers share it. When it finishes, the open chat (if any) picks up what it wrote.
    @discardableResult
    func startHeadlessFill(sessionKey key: String, agentId: String?) -> Task<Void, Never> {
        if let running = self.headlessFills[key] { return running.task }
        let generation = self.cacheGeneration(of: key)
        let connectionEpoch = self.connectionEpoch
        let fillId = UUID()
        self.headlessFillStarts[key, default: 0] += 1
        let task = Task { [weak self] in
            guard let self else { return }
            let store = ChatStore(sessionKey: key, agentId: agentId, gateway: self, headless: true)
            store.windowLimit = TranscriptCache.maxItems
            await store.fillCache(generation: generation, connectionEpoch: connectionEpoch)
            if self.headlessFills[key]?.id == fillId { self.headlessFills[key] = nil }
            guard !Task.isCancelled, self.state.isConnected, self.connectionEpoch == connectionEpoch,
                  self.cacheGeneration(of: key) == generation
            else { return }
            await self.chats[key]?.adoptFilledCache(generation: generation, connectionEpoch: connectionEpoch)
        }
        self.headlessFills[key] = (fillId, task)
        return task
    }

    /// The chat's cached transcript is about to be removed or replaced (delete, rewind, branch
    /// switch, recovery): stops its background fill, waits for it to finish, and invalidates
    /// anything it would still write. Call before clearing the cache.
    func cancelHeadlessFill(_ key: String) async {
        self.cacheGenerations[key, default: 0] += 1
        guard let fill = self.headlessFills[key] else { return }
        fill.task.cancel()
        await fill.task.value
        if self.headlessFills[key]?.id == fill.id { self.headlessFills[key] = nil }
    }
}
