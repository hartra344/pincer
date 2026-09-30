import Foundation

/// Process-wide Spotlight state: the indexer and what each gateway last sent it (so unchanged
/// chats aren't resent). Lives here because stores can't gain stored properties from an extension.
@MainActor
public final class SpotlightCenter {
    public static let shared = SpotlightCenter()

    /// Used by stores without their own `spotlightIndexer`. Core Spotlight in the apps; a no-op
    /// fake under tests and PincerChecks so they never touch the system index.
    public var defaultIndexer: any SpotlightIndexer = SpotlightCenter.makeDefaultIndexer()
    var overrides: [UUID: any SpotlightIndexer] = [:]
    var sent: [UUID: [String: SpotlightEntry]] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    /// How long a snapshot burst settles before the index is updated.
    public var debounce: Duration = .seconds(2)

    private static func makeDefaultIndexer() -> any SpotlightIndexer {
        let info = ProcessInfo.processInfo
        let testing = info.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            || info.processName.hasPrefix("PincerChecks")
        #if canImport(CoreSpotlight)
        if !testing { return CoreSpotlightIndexer() }
        #endif
        return FakeSpotlightIndexer()
    }

    func indexer(for id: UUID) -> any SpotlightIndexer { self.overrides[id] ?? self.defaultIndexer }

    /// A gateway was removed: drop its results and cancel pending work.
    public func forgetGateway(_ id: UUID) {
        self.tasks.removeValue(forKey: id)?.cancel()
        self.sent.removeValue(forKey: id)
        let indexer = self.indexer(for: id)
        self.overrides.removeValue(forKey: id)
        Task { await indexer.deleteDomain(gatewayId: id) }
    }
}

extension GatewayStore {
    /// Replace to index somewhere other than Core Spotlight (tests, checks).
    public var spotlightIndexer: any SpotlightIndexer {
        get { SpotlightCenter.shared.indexer(for: self.id) }
        set { SpotlightCenter.shared.overrides[self.id] = newValue }
    }

    /// Queues an index update for this gateway's chats, after the snapshots settle.
    public func scheduleSpotlightReindex() {
        let center = SpotlightCenter.shared
        center.tasks[self.id]?.cancel()
        guard !self.profile.isDemo, Spotlight.isEnabled(self.defaults) else { return }
        let delay = center.debounce
        center.tasks[self.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.reindexSpotlight()
        }
    }

    /// Indexes now: new and changed chats are sent, chats that left the list are deleted.
    public func reindexSpotlight() async {
        let center = SpotlightCenter.shared
        guard !self.profile.isDemo, Spotlight.isEnabled(self.defaults) else { return }
        let includeMessages = Spotlight.includesMessages(self.defaults)
        let rows = Spotlight.candidates(Array(self.sessions.values), cap: Spotlight.maxEntries)
        var snippets: [String: String] = [:]
        if includeMessages {
            let sent = center.sent[self.id] ?? [:]
            for row in rows {
                let id = Spotlight.identifier(gatewayId: self.id, sessionKey: row.key, gatewayURL: self.profile.url,
                                              gatewayHost: self.gatewayHost)
                // Unchanged activity keeps the snippet already sent; only changed chats are read.
                if let known = sent[id], known.lastActivity == row.activityDate, let snippet = known.snippet {
                    snippets[row.key] = snippet
                    continue
                }
                let tail = await TranscriptCache.loadNewest(gatewayId: self.id, sessionKey: row.key,
                                                            limit: Spotlight.tailItems, root: self.cacheRoot)
                if let snippet = Spotlight.snippet(from: tail.items) { snippets[row.key] = snippet }
            }
        }
        guard !Task.isCancelled, !self.profile.isDemo, Spotlight.isEnabled(self.defaults) else { return }
        let entries = Spotlight.entries(gatewayId: self.id, gatewayURL: self.profile.url, gatewayHost: self.gatewayHost,
                                        sessions: rows, cachedSnippets: snippets, includeMessages: includeMessages)
        let indexer = center.indexer(for: self.id)
        let previous = center.sent[self.id]
        let current = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        center.sent[self.id] = current
        if previous == nil { await indexer.deleteDomain(gatewayId: self.id) }
        let changed = entries.filter { previous?[$0.id] != $0 }
        let removed = (previous ?? [:]).keys.filter { current[$0] == nil }
        if !removed.isEmpty { await indexer.delete(ids: Array(removed)) }
        if !changed.isEmpty, Spotlight.isEnabled(self.defaults) { await indexer.index(changed) }
    }

    /// A chat's cache was dropped (deleted or vanished): it leaves Spotlight too.
    func forgetSpotlight(sessionKey: String) async {
        let center = SpotlightCenter.shared
        let id = Spotlight.identifier(gatewayId: self.id, sessionKey: sessionKey, gatewayURL: self.profile.url,
                                      gatewayHost: self.gatewayHost)
        center.sent[self.id]?.removeValue(forKey: id)
        await center.indexer(for: self.id).delete(ids: [id])
    }
}

extension AppModel {
    /// The transcript cache was cleared: resend every chat so cached snippets go away now.
    public func spotlightCacheCleared() async {
        SpotlightCenter.shared.sent.removeAll()
        for store in self.gateways { await store.reindexSpotlight() }
    }

    /// A Spotlight setting changed: off clears the index, anything else resends every chat.
    public func spotlightPreferencesChanged() {
        let center = SpotlightCenter.shared
        center.sent.removeAll()
        if Spotlight.isEnabled() {
            for store in self.gateways { store.scheduleSpotlightReindex() }
        } else {
            for task in center.tasks.values { task.cancel() }
            center.tasks.removeAll()
            let indexers = [center.defaultIndexer] + Array(center.overrides.values)
            Task { for indexer in indexers { await indexer.deleteAll() } }
        }
    }
}
