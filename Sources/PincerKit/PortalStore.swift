import Foundation
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
    }

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
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closing: Set<String> = []
    private var owned: [String: OwnedPortals] = [:]
    @ObservationIgnored private var ownedOrder: [String] = []
    @ObservationIgnored private var tracked: [String: String?] = [:]
    @ObservationIgnored private var ownedRefreshedAt: [String: Date] = [:]
    @ObservationIgnored private var ownedInFlight: [String: Task<Void, Never>] = [:]

    /// For tests and fakes. `methods` returns the advertised methods; nil or empty means "unknown, try".
    public init(request: @escaping Request, methods: @escaping @MainActor () -> Set<String>? = { nil },
                debounce: Duration = .milliseconds(250), allowsDemoScheme: Bool = false) {
        self.allowsDemoScheme = allowsDemoScheme
        self.request = request
        self.methods = methods
        self.debounce = debounce
    }

    convenience init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, isDemo: Bool) {
        self.init(request: { try await connection.request($0, $1) }, methods: { hello()?.methods }, allowsDemoScheme: isDemo)
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
        var ownedRoute: (key: String, environmentId: String, index: Int, portal: PortalSummary)?
        if let scope, let entry = self.owned[scope.sessionKey], let environmentId = entry.environmentId,
           let index = entry.portals.firstIndex(where: { $0.id == id }) {
            ownedRoute = (scope.sessionKey, environmentId, index, entry.portals[index])
        }
        let globalIndex = self.portals.firstIndex(where: { $0.id == id })
        guard ownedRoute != nil || globalIndex != nil else { return false }
        self.closeError = nil
        let removed = globalIndex.map { self.portals.remove(at: $0) }
        if let route = ownedRoute { self.owned[route.key]?.portals.remove(at: route.index) }
        do {
            if let route = ownedRoute, let scope {
                var params: [String: JSONValue] = ["id": .string(id), "sessionKey": .string(route.key),
                                                   "environmentId": .string(route.environmentId)]
                if let agentId = scope.agentId { params["agentId"] = .string(agentId) }
                _ = try await self.request(Self.sessionCloseMethod, .object(params))
                await self.refreshOwned(sessionKey: route.key, agentId: scope.agentId)
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

    /// What this chat shows: the portals its session owns, then the global ones its agent opened in the
    /// transcript, without duplicates, in a stable order (creation time, then id).
    public func portals(for scope: PortalScope) -> [PortalSummary] {
        var seen = Set<String>()
        var result: [PortalSummary] = []
        for portal in self.owned[scope.sessionKey]?.portals ?? [] where seen.insert(portal.id).inserted { result.append(portal) }
        if !scope.opened.isEmpty {
            for portal in self.portals where scope.opened.contains(portal) && seen.insert(portal.id).inserted { result.append(portal) }
        }
        return result.sorted { ($0.createdAtMs, $0.id) < ($1.createdAtMs, $1.id) }
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
        Task { await self.refreshOwned(sessionKey: sessionKey, agentId: agentId) }
    }

    public func untrackOwned(sessionKey: String) {
        self.tracked[sessionKey] = nil
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
        var entry = OwnedPortals(environmentId: nil, portals: [])
        do {
            let status = try await request(Self.sessionStatusMethod, .object(base))
            let attachment = status["attachment"]
            if let environmentId = attachment?["environmentId"]?.string, !environmentId.isEmpty,
               status["closed"]?.bool != true, attachment?["closedAtMs"]?.double == nil {
                var params = base
                params["environmentId"] = .string(environmentId)
                let reply = try await request(Self.sessionListMethod, .object(params))
                let list = await Task.detached(priority: .userInitiated) { PortalSummary.parseList(reply, allowsDemoScheme: demo) }.value
                entry = OwnedPortals(environmentId: environmentId, portals: list ?? [])
            }
        } catch {
            entry = OwnedPortals(environmentId: nil, portals: [])
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
