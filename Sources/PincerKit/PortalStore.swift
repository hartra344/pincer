import Foundation
import Observation

/// The agent's portals (`portal.list`, `portal.close`), kept fresh by `portal.changed`.
/// Pincer never opens portals: the agent does. The panel never auto-opens; the UI shows a count badge.
/// The Gateway redacts `portal.changed`, so the event only triggers a coalesced `portal.list` refresh.
@MainActor
@Observable
public final class PortalStore {
    public typealias Request = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public static let listMethod = "portal.list"
    public static let closeMethod = "portal.close"
    public static let changedEvent = "portal.changed"

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
        guard self.advertised else {
            self.setUnavailable(true)
            return
        }
        Task { await self.refresh() }
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
        }
    }

    /// `portal.close`, removing the portal at once and putting it back if the Gateway refuses.
    @discardableResult
    public func close(_ id: String) async -> Bool {
        guard let index = self.portals.firstIndex(where: { $0.id == id }), self.closing.insert(id).inserted else { return false }
        let removed = self.portals.remove(at: index)
        self.closeError = nil
        defer { self.closing.remove(id) }
        do {
            _ = try await self.request(Self.closeMethod, ["id": .string(id)])
            await self.refresh()
            return true
        } catch {
            if !self.portals.contains(where: { $0.id == id }) {
                self.portals.insert(removed, at: min(index, self.portals.count))
            }
            self.closeError = GatewayError.isMissingScope(error)
                ? L("Your connection can't close portals.")
                : L("The portal couldn't be closed.")
            return false
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
