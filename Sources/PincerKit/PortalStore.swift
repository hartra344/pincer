import Foundation
import PincerPush
import Observation

/// The agent's portals (`portal.list`, `portal.close`), kept fresh by `portal.changed`.
/// Pincer never opens portals: the agent does. The panel never auto-opens; the UI shows a count badge.
/// The Gateway redacts `portal.changed`, so the event only triggers a coalesced `portal.list` refresh.
///
/// Portals carry no owner field, so `portals(for:)` scopes them per chat: the portals the chat's session
/// owns (`environments.session.status` + `portal.session.list`, Gateway 2026.9+) plus the global ones its
/// agent opened in this transcript (a successful `portal` tool call). Portals matched by neither show nowhere.
@MainActor
@Observable
public final class PortalStore {
    public typealias Request = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public static let listMethod = "portal.list"
    public static let closeMethod = "portal.close"
    public static let changedEvent = "portal.changed"
    public static let sessionStatusMethod = "environments.session.status"
    public static let sessionListMethod = "portal.session.list"
    public static let sessionCloseMethod = "portal.session.close"
    /// Sessions whose owned portals are cached (least recently used goes first).
    static let ownedCacheLimit = 32
    /// A session refreshed this recently keeps following `portal.changed` even when not tracked.
    static let ownedFreshness: TimeInterval = 5 * 60

    struct OwnedPortals: Equatable {
        var environmentId: String?
        var portals: [PortalSummary]
        var agentId: String?
    }

    /// Which agent opened a portal, seen in one of its chats (portals carry no owner field).
    struct Attribution: Codable, Equatable {
        var agentId: String
        var sessionKey: String
        var seenAtMs: Double
    }
    struct AttributionFile: Codable {
        var version = 1
        var entries: [String: Attribution]
    }
    static let attributionLimit = 256
    /// Other sessions of the agent whose owned portals `trackOwned` also fetches.
    static let siblingSessionLimit = 6


    public private(set) var portals: [PortalSummary] = []
    /// A `portal.list` reply has been applied since the last connect.
    public private(set) var loaded = false
    /// The Gateway has no portals (method not advertised or refused): hide the portal UI entirely.
    public private(set) var unavailable = false
    /// Some portals came without an access link: this connection can't open them.
    public private(set) var redacted = false
    /// The last close failed (fixed text, never a URL or token). Cleared by the next successful close.
    public private(set) var closeError: String?

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let allowsDemoScheme: Bool
    @ObservationIgnored private let attributionFile: URL?
    @ObservationIgnored private let agentSessions: @MainActor (String) -> [String]
    /// `id:<id>` or `url:<publicUrl>` to the agent that opened it.
    private var attribution: [String: Attribution] = [:]
    @ObservationIgnored private var attributionLoad: Task<Void, Never>?
    @ObservationIgnored private var attributionWrite: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closing: Set<String> = []
    private var owned: [String: OwnedPortals] = [:]
    @ObservationIgnored private var ownedOrder: [String] = []
    /// Views tracking each session; it is followed until the last one lets go.
    @ObservationIgnored private var trackCounts: [String: Int] = [:]
    @ObservationIgnored private var tracked: [String: String?] = [:]
    @ObservationIgnored private var ownedRefreshedAt: [String: Date] = [:]
    @ObservationIgnored private var ownedInFlight: [String: Task<Void, Never>] = [:]

    /// For tests and fakes. `methods` returns the advertised methods; nil or empty means "unknown, try".
    public init(request: @escaping Request, methods: @escaping @MainActor () -> Set<String>? = { nil },
                debounce: Duration = .milliseconds(250), allowsDemoScheme: Bool = false,
                attributionFile: URL? = nil, agentSessions: @escaping @MainActor (String) -> [String] = { _ in [] }) {
        self.attributionFile = attributionFile
        self.agentSessions = agentSessions
        self.allowsDemoScheme = allowsDemoScheme
        self.request = request
        self.methods = methods
        self.debounce = debounce
    }

    convenience init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, isDemo: Bool,
                     gatewayId: UUID? = nil, agentSessions: @escaping @MainActor (String) -> [String] = { _ in [] }) {
        self.init(request: { try await connection.request($0, $1) }, methods: { hello()?.methods }, allowsDemoScheme: isDemo,
                  attributionFile: isDemo ? nil : gatewayId.flatMap { Self.attributionFile(gatewayId: $0) },
                  agentSessions: agentSessions)
    }

    /// `PINCER_PORTALS_DIR` redirects the attribution files (checks); `off` disables them.
    static func attributionFile(gatewayId: UUID) -> URL? {
        let root: URL?
        if let override = ProcessInfo.processInfo.environment["PINCER_PORTALS_DIR"] {
            root = override == "off" ? nil : URL(filePath: override, directoryHint: .isDirectory)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "\(DevNamespace.folderName("Pincer"))/PortalAttribution", directoryHint: .isDirectory)
        }
        return root?.appending(path: "\(gatewayId.uuidString).json")
    }

    /// Whether the connection advertises `portal.list` (unknown before hello counts as maybe).
    private var advertised: Bool {
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(Self.listMethod)
    }

    /// Fetches the list now. Safe to call often; a call while one is running waits for it.
    public func refresh() async {
        guard self.advertised else {
            self.setUnavailable(true)
            return
        }
        if let running = self.refreshing {
            await running.value
            return
        }
        let generation = self.generation
        let task = Task { await self.fetch(generation) }
        self.refreshing = task
        await task.value
        self.refreshing = nil
    }

    /// Call on connect: forgets the previous connection's list and fetches again.
    public func handleReconnect() {
        self.generation += 1
        self.pendingRefresh?.cancel()
        self.pendingRefresh = nil
        self.refreshing = nil
        self.loaded = false
        self.unavailable = false
        self.closeError = nil
        self.loadAttributionIfNeeded()
        self.owned = [:]
        self.ownedOrder = []
        self.ownedRefreshedAt = [:]
        for task in self.ownedInFlight.values { task.cancel() }
        self.ownedInFlight = [:]
        guard self.advertised else {
            self.setUnavailable(true)
            return
        }
        Task { await self.refresh() }
        for (key, agentId) in self.tracked { Task { await self.refreshOwned(sessionKey: key, agentId: agentId) } }
    }

    /// Feed `portal.changed` here. Bursts are coalesced into one refresh (~250 ms after the last).
    public func handle(event name: String) {
        guard name == Self.changedEvent, !self.unavailable else { return }
        self.pendingRefresh?.cancel()
        self.pendingRefresh = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.pendingRefresh = nil
            await self.refresh()
            await self.refreshStaleOwned()
        }
    }

    /// Closes a portal, removing it at once and putting it back if the Gateway refuses. A portal the
    /// scope's session owns goes through `portal.session.close`; any other through `portal.close`.
    @discardableResult
    public func close(_ id: String, scope: PortalScope? = nil) async -> Bool {
        guard self.closing.insert(id).inserted else { return false }
        defer { self.closing.remove(id) }
        var ownedRoute: (key: String, environmentId: String, agentId: String?, index: Int, portal: PortalSummary)?
        if let scope {
            let agent = scope.agentId ?? SessionKey.agentId(from: scope.sessionKey)
            let candidates = [scope.sessionKey] + self.owned.keys.filter { $0 != scope.sessionKey && self.owned[$0]?.agentId == agent }
            for key in candidates {
                if let entry = self.owned[key], let environmentId = entry.environmentId,
                   let index = entry.portals.firstIndex(where: { $0.id == id }) {
                    ownedRoute = (key, environmentId, entry.agentId, index, entry.portals[index])
                    break
                }
            }
        }
        let globalIndex = self.portals.firstIndex(where: { $0.id == id })
        guard ownedRoute != nil || globalIndex != nil else { return false }
        self.closeError = nil
        let removed = globalIndex.map { self.portals.remove(at: $0) }
        if let route = ownedRoute { self.owned[route.key]?.portals.remove(at: route.index) }
        do {
            if let route = ownedRoute {
                var params: [String: JSONValue] = ["id": .string(id), "sessionKey": .string(route.key),
                                                   "environmentId": .string(route.environmentId)]
                if let agentId = route.agentId { params["agentId"] = .string(agentId) }
                _ = try await self.request(Self.sessionCloseMethod, .object(params))
                await self.refreshOwned(sessionKey: route.key, agentId: route.agentId)
            } else {
                _ = try await self.request(Self.closeMethod, ["id": .string(id)])
            }
            await self.refresh()
            return true
        } catch {
            if let removed, let globalIndex, !self.portals.contains(where: { $0.id == id }) {
                self.portals.insert(removed, at: min(globalIndex, self.portals.count))
            }
            if let route = ownedRoute, self.owned[route.key] != nil, !(self.owned[route.key]?.portals.contains { $0.id == id } ?? true) {
                self.owned[route.key]?.portals.insert(route.portal, at: min(route.index, self.owned[route.key]?.portals.count ?? 0))
            }
            self.closeError = GatewayError.isMissingScope(error)
                ? L("Your connection can't close portals.")
                : L("The portal couldn't be closed.")
            return false
        }
    }

    // MARK: Scoping

    /// What this chat shows, scoped to its agent: global portals the agent opened in any of its chats, the
    /// portals this session owns, and the cached owned portals of the agent's other sessions. No
    /// duplicates, in a stable order (creation time, then id).
    public func portals(for scope: PortalScope) -> [PortalSummary] {
        let agentId = scope.agentId ?? SessionKey.agentId(from: scope.sessionKey)
        var seen = Set<String>()
        var result: [PortalSummary] = []
        for portal in self.owned[scope.sessionKey]?.portals ?? [] where seen.insert(portal.id).inserted { result.append(portal) }
        if let agentId {
            for (key, entry) in self.owned where key != scope.sessionKey && entry.agentId == agentId {
                for portal in entry.portals where seen.insert(portal.id).inserted { result.append(portal) }
            }
        }
        for portal in self.portals where !seen.contains(portal.id) {
            if scope.opened.contains(portal) || (agentId != nil && self.attributedAgent(for: portal) == agentId) {
                seen.insert(portal.id)
                result.append(portal)
            }
        }
        return result.sorted { ($0.createdAtMs, $0.id) < ($1.createdAtMs, $1.id) }
    }

    /// The agent a chat transcript attributed this global portal to, if any.
    public func attributedAgent(for portal: PortalSummary) -> String? {
        (self.attribution["id:" + portal.id] ?? self.attribution["url:" + PortalRefs.normalized(portal.publicURL.absoluteString)])?.agentId
    }

    /// A chat's `openedPortals` changed: remember which agent opened them, so the attribution outlives
    /// /new, compaction and history paging. Only a change is stored and written.
    public func recordOpened(_ refs: PortalRefs, agentId: String?, sessionKey: String) {
        guard !refs.isEmpty, let agent = agentId ?? SessionKey.agentId(from: sessionKey) else { return }
        self.loadAttributionIfNeeded()
        let now = Date().timeIntervalSince1970 * 1000
        var changed = false
        let keys = refs.ids.map { "id:" + $0 } + refs.publicURLs.map { "url:" + $0 }
        for key in keys {
            if let existing = self.attribution[key], existing.agentId == agent, existing.sessionKey == sessionKey { continue }
            self.attribution[key] = Attribution(agentId: agent, sessionKey: sessionKey, seenAtMs: now)
            changed = true
        }
        guard changed else { return }
        if self.attribution.count > Self.attributionLimit {
            let drop = self.attribution.sorted { $0.value.seenAtMs < $1.value.seenAtMs }.prefix(self.attribution.count - Self.attributionLimit)
            for (key, _) in drop { self.attribution[key] = nil }
        }
        self.saveAttribution()
    }

    /// After a successful `portal.list`: forget portals that are gone. Never called for a failed list.
    private func prune(keeping list: [PortalSummary], requestedAtMs: Double) {
        guard !self.attribution.isEmpty else { return }
        var live = Set<String>()
        for portal in list {
            live.insert("id:" + portal.id)
            live.insert("url:" + PortalRefs.normalized(portal.publicURL.absoluteString))
        }
        // Entries recorded after the request started may name a portal the list couldn't know about.
        let stale = self.attribution.filter { !live.contains($0.key) && $0.value.seenAtMs < requestedAtMs }.map(\.key)
        guard !stale.isEmpty else { return }
        for key in stale { self.attribution[key] = nil }
        self.saveAttribution()
    }

    private func loadAttributionIfNeeded() {
        guard self.attributionLoad == nil, let url = self.attributionFile else { return }
        self.attributionLoad = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [String: Attribution] in
                guard let data = try? Data(contentsOf: url),
                      let file = try? JSONDecoder().decode(AttributionFile.self, from: data), file.version == 1 else { return [:] }
                return file.entries
            }.value
            guard let self, !loaded.isEmpty else { return }
            // What this session already saw wins over the file.
            self.attribution.merge(loaded) { current, _ in current }
        }
    }

    private func saveAttribution() {
        guard let url = self.attributionFile else { return }
        let previous = self.attributionWrite
        let load = self.attributionLoad
        self.attributionWrite = Task { [weak self] in
            // Snapshot only once the persisted entries are merged in, so a first save can't drop them.
            await load?.value
            await previous?.value
            guard let snapshot = self?.attribution else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(AttributionFile(entries: snapshot)) else { return }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    /// The cached portals the session owns (empty until `refreshOwned` has run).
    public func ownedPortals(sessionKey: String) -> [PortalSummary] { self.owned[sessionKey]?.portals ?? [] }

    /// Whether the Gateway can report session-owned portals (both 2026.9 methods advertised).
    public var ownedAvailable: Bool {
        guard let methods = self.methods() else { return false }
        return methods.contains(Self.sessionStatusMethod) && methods.contains(Self.sessionListMethod)
    }

    /// The chat's portal panel is showing: fetch its owned portals now and follow `portal.changed`.
    public func trackOwned(sessionKey: String, agentId: String? = nil) {
        self.tracked[sessionKey] = .some(agentId)
        self.trackCounts[sessionKey, default: 0] += 1
        let agent = agentId ?? SessionKey.agentId(from: sessionKey)
        Task {
            await self.refreshOwned(sessionKey: sessionKey, agentId: agentId)
            guard let agent else { return }
            let now = Date()
            let siblings = self.agentSessions(agent).filter { key in
                key != sessionKey && now.timeIntervalSince(self.ownedRefreshedAt[key] ?? .distantPast) > Self.ownedFreshness
            }.prefix(Self.siblingSessionLimit)
            for key in siblings { await self.refreshOwned(sessionKey: key, agentId: agent) }
        }
    }

    public func untrackOwned(sessionKey: String) {
        let count = (self.trackCounts[sessionKey] ?? 0) - 1
        if count > 0 {
            self.trackCounts[sessionKey] = count
        } else {
            self.trackCounts[sessionKey] = nil
            self.tracked[sessionKey] = nil
        }
    }

    /// `environments.session.status`, then `portal.session.list` when the session has a live attached
    /// environment. A failure leaves that session with none: no throw, no retry loop.
    public func refreshOwned(sessionKey: String, agentId: String? = nil) async {
        guard self.ownedAvailable else { return }
        if let running = self.ownedInFlight[sessionKey] {
            await running.value
            return
        }
        let generation = self.generation
        let task = Task { await self.fetchOwned(sessionKey: sessionKey, agentId: agentId, generation: generation) }
        self.ownedInFlight[sessionKey] = task
        await task.value
        if generation == self.generation { self.ownedInFlight[sessionKey] = nil }
    }

    private func refreshStaleOwned() async {
        guard self.ownedAvailable else { return }
        let now = Date()
        var keys: [String: String?] = self.tracked
        for (key, at) in self.ownedRefreshedAt where now.timeIntervalSince(at) < Self.ownedFreshness && keys[key] == nil {
            keys[key] = .some(nil)
        }
        for (key, agentId) in keys { await self.refreshOwned(sessionKey: key, agentId: agentId) }
    }

    private func fetchOwned(sessionKey: String, agentId: String?, generation: Int) async {
        let request = self.request
        let demo = self.allowsDemoScheme
        var base: [String: JSONValue] = ["sessionKey": .string(sessionKey)]
        if let agentId { base["agentId"] = .string(agentId) }
        var entry = OwnedPortals(environmentId: nil, portals: [], agentId: agentId ?? SessionKey.agentId(from: sessionKey))
        do {
            let status = try await request(Self.sessionStatusMethod, .object(base))
            let attachment = status["attachment"]
            if let environmentId = attachment?["environmentId"]?.string, !environmentId.isEmpty,
               status["closed"]?.bool != true, attachment?["closedAtMs"]?.double == nil {
                var params = base
                params["environmentId"] = .string(environmentId)
                let reply = try await request(Self.sessionListMethod, .object(params))
                let list = await Task.detached(priority: .userInitiated) { PortalSummary.parseList(reply, allowsDemoScheme: demo) }.value
                entry.environmentId = environmentId
                entry.portals = list ?? []
            }
        } catch {
            entry.environmentId = nil
            entry.portals = []
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        entry.portals = entry.portals.filter { !self.closing.contains($0.id) }
        self.storeOwned(entry, for: sessionKey)
    }

    private func storeOwned(_ entry: OwnedPortals, for key: String) {
        self.ownedRefreshedAt[key] = Date()
        self.ownedOrder.removeAll { $0 == key }
        self.ownedOrder.append(key)
        if self.owned[key] != entry { self.owned[key] = entry }
        while self.ownedOrder.count > Self.ownedCacheLimit {
            let evicted = self.ownedOrder.removeFirst()
            self.owned[evicted] = nil
            self.ownedRefreshedAt[evicted] = nil
        }
    }

    // MARK: Fetching

    private func fetch(_ generation: Int) async {
        let request = self.request
        let demo = self.allowsDemoScheme
        let requestedAtMs = Date().timeIntervalSince1970 * 1000
        let parsed: [PortalSummary]?
        do {
            let reply = try await request(Self.listMethod, [:])
            parsed = await Task.detached(priority: .userInitiated) { PortalSummary.parseList(reply, allowsDemoScheme: demo) }.value
        } catch {
            guard generation == self.generation else { return }
            if GatewayError.isUnavailable(error) || Self.isPortalsUnavailable(error) { self.setUnavailable(true) }
            return
        }
        guard generation == self.generation, let list = parsed else { return }
        self.setUnavailable(false)
        let visible = list.filter { !self.closing.contains($0.id) }
        if visible != self.portals { self.portals = visible }
        self.prune(keeping: list, requestedAtMs: requestedAtMs)
        let isRedacted = visible.contains { $0.isRedacted }
        if self.redacted != isRedacted { self.redacted = isRedacted }
        if !self.loaded { self.loaded = true }
    }

    private func setUnavailable(_ value: Bool) {
        if self.unavailable != value { self.unavailable = value }
        if value {
            if !self.portals.isEmpty { self.portals = [] }
            if !self.loaded { self.loaded = true }
        }
    }

    private static func isPortalsUnavailable(_ error: Error) -> Bool {
        guard case let .rpc(_, message, _) = error as? GatewayError else { return false }
        return message.lowercased().contains("portals unavailable")
    }
}
