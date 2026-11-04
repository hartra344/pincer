import Foundation
import Observation

/// The Assets panel for one chat: every file and image the agent sent, newest first, so a PDF from last week
/// is one click away. Built from the cached transcript (read once, off-main), the loaded chat, and
/// `artifacts.list` (`messageRole: "assistant"`) when the Gateway advertises it, for history the cache
/// doesn't hold. Scanning and merging run off-main; the main actor only assigns the result. Get one per chat
/// from `GatewayStore.assetsModel(for:)`.
@MainActor
@Observable
public final class SessionAssetsModel {
    public typealias Request = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public nonisolated static let artifactsMethod = "artifacts.list"

    public let sessionKey: String
    public let agentId: String?
    /// Everything found, newest first.
    public private(set) var assets: [SessionAsset] = []
    /// What the filter chip and search leave.
    public private(set) var shown: [SessionAsset] = []
    public private(set) var loaded = false
    public private(set) var isLoading = false
    public var filter: SessionAssetFilter = .all { didSet { if oldValue != self.filter { self.applyFilter() } } }
    public var search = "" { didSet { if oldValue != self.search { self.applyFilter() } } }

    @ObservationIgnored let request: Request
    @ObservationIgnored let advertisedCheck: @MainActor (String) -> Bool
    @ObservationIgnored let liveItems: @MainActor () -> [ChatItem]
    @ObservationIgnored let cachedItems: @Sendable () async -> [ChatItem]?
    /// Waits for the chat's own post-run reload, so a run's last message is in `liveItems`.
    @ObservationIgnored let settled: @MainActor () async -> Void
    /// Assets in the on-disk transcript, scanned once per model.
    @ObservationIgnored private var cachedAssets: [SessionAsset]?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var viewers: Set<AnyHashable> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReload = false
    @ObservationIgnored private var dirty = false

    public init(sessionKey: String, agentId: String? = nil, request: @escaping Request,
                advertises: @escaping @MainActor (String) -> Bool = { _ in true },
                liveItems: @escaping @MainActor () -> [ChatItem],
                cachedItems: @escaping @Sendable () async -> [ChatItem]? = { nil },
                settled: @escaping @MainActor () async -> Void = {}) {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.request = request
        self.advertisedCheck = advertises
        self.liveItems = liveItems
        self.cachedItems = cachedItems
        self.settled = settled
    }

    // MARK: Visibility and refresh

    /// The panel shows (or stops showing) this chat's assets. Becoming visible refreshes, which also
    /// catches runs that ended while hidden. Counts as visible while any viewer is.
    public func setVisible(_ visible: Bool, viewer: AnyHashable) {
        if visible {
            let first = self.viewers.isEmpty
            self.viewers.insert(viewer)
            if first || self.dirty { self.requestRefresh() }
        } else {
            self.viewers.remove(viewer)
        }
    }

    /// A run ended in this chat: it may have sent files. Refreshes now when visible, otherwise on next show.
    public func runEnded() {
        if self.viewers.isEmpty { self.dirty = true } else { self.requestRefresh() }
    }

    /// Rescans and re-lists. Safe to call often; calls coalesce.
    public func refresh() async {
        if let running = self.refreshTask {
            self.pendingReload = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                self.pendingReload = false
                await self.load()
            } while self.pendingReload
            self.refreshTask = nil
        }
        self.refreshTask = task
        await task.value
    }

    private func requestRefresh() {
        Task { await self.refresh() }
    }

    /// Keeps what's shown and re-lists: the Gateway may have more (or less) than before.
    public func handleReconnect() {
        self.generation += 1
        self.refreshTask = nil
        self.pendingReload = false
        self.isLoading = false
        if self.viewers.isEmpty { self.dirty = true } else { self.requestRefresh() }
    }

    /// Forgets everything (cache eviction).
    public func reset() {
        self.generation += 1
        self.refreshTask = nil
        self.cachedAssets = nil
        self.assets = []
        self.shown = []
        self.loaded = false
        self.isLoading = false
        self.dirty = false
    }

    // MARK: Loading

    private func load() async {
        self.dirty = false
        self.isLoading = true
        let generation = self.generation
        await self.settled()
        guard generation == self.generation else { return }
        let live = self.liveItems()
        let cached = self.cachedAssets
        let loadCache = self.cachedItems
        var params: [String: JSONValue] = ["sessionKey": .string(self.sessionKey), "messageRole": .string("assistant")]
        if let agentId, !agentId.isEmpty { params["agentId"] = .string(agentId) }
        let payload = JSONValue.object(params)
        let request = self.request
        let listsArtifacts = self.advertisedCheck(Self.artifactsMethod)

        async let server = Task.detached(priority: .userInitiated) { () -> [SessionArtifactItem]? in
            guard listsArtifacts, let value = try? await request(Self.artifactsMethod, payload) else { return nil }
            return SessionFilesParser.artifacts(value).items
        }.value
        let built = await Task.detached(priority: .userInitiated) { () -> (local: [SessionAsset], cache: [SessionAsset]) in
            let cache: [SessionAsset]
            if let cached { cache = cached } else { cache = SessionAssetScanner.scan(await loadCache() ?? []) }
            let liveAssets = SessionAssetScanner.scan(live)
            let liveIds = Set(liveAssets.map(\.id))
            return (liveAssets + cache.filter { !liveIds.contains($0.id) }, cache)
        }.value
        let listed = await server
        guard generation == self.generation else { return }
        self.cachedAssets = built.cache
        let local = built.local
        let merged = await Task.detached(priority: .userInitiated) {
            SessionAssetScanner.merge(local, server: listed ?? [])
        }.value
        guard generation == self.generation else { return }
        self.assets = merged
        self.loaded = true
        self.isLoading = false
        self.applyFilter()
    }

    /// A few hundred names at most: cheap enough to filter as the user types.
    private func applyFilter() {
        self.shown = SessionAssetScanner.filter(self.assets, filter: self.filter, search: self.search)
    }
}
