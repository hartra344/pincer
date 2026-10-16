import Foundation
import Observation

/// Talk availability for one Gateway: `talk.catalog` decides whether a relay call can start. A tiny
/// per-profile cache (relay supported + provider id) keeps the toolbar button stable from launch.
@MainActor @Observable
public final class GatewayTalkModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// Where the cached answer lives; tests inject an in-memory one.
    public struct Persistence: Sendable {
        public var load: @Sendable () -> String?
        public var save: @Sendable (String?) -> Void
        public init(load: @escaping @Sendable () -> String?, save: @escaping @Sendable (String?) -> Void) {
            self.load = load
            self.save = save
        }

        public static let none = Persistence(load: { nil }, save: { _ in })

        public static func defaults(_ defaults: UserDefaults, gatewayId: String) -> Persistence {
            nonisolated(unsafe) let defaults = defaults
            let key = "pincer.talk.relay.\(gatewayId)"
            return Persistence(load: { defaults.string(forKey: key) }, save: { value in
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            })
        }
    }

    public private(set) var catalog: TalkCatalog?
    public private(set) var availability: TalkAvailability

    @ObservationIgnored let request: Request
    @ObservationIgnored let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let persistence: Persistence
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempted = false
    @ObservationIgnored private var answered = false

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, persistence: Persistence = .none) {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.persistence = persistence
        self.availability = Self.cached(persistence)
    }

    /// For checks and tests. `methods` is the advertised list (nil when unknown).
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil }, persistence: Persistence = .none,
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.persistence = persistence
        self.availability = Self.cached(persistence)
    }

    private static func cached(_ persistence: Persistence) -> TalkAvailability {
        guard let provider = persistence.load(), !provider.isEmpty else { return .unknown }
        return .available(provider: provider)
    }

    /// Hello advertises both `talk.catalog` and `talk.session.create`.
    public var isAdvertised: Bool {
        guard let methods = self.methods() else { return false }
        return methods.contains(TalkProtocol.catalogMethod) && methods.contains(TalkProtocol.sessionCreateMethod)
    }

    /// Loads `talk.catalog` once per connection; never blocks the UI.
    public func loadCatalogIfNeeded() {
        guard !self.attempted else { return }
        self.refresh()
    }

    /// Forces a reload.
    public func refresh() {
        guard self.isAdvertised else {
            self.markUnsupported()
            return
        }
        self.attempted = true
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.request(TalkProtocol.catalogMethod, [:])
                guard generation == self.generation else { return }
                self.apply(catalog: TalkCatalog(result))
            } catch {
                guard generation == self.generation else { return }
                // Only the Gateway's own answer changes availability; a timeout or drop retries next trigger.
                guard case let GatewayError.rpc(_, message, _) = error else {
                    self.attempted = false
                    return
                }
                if GatewayError.isUnknownMethod(error) {
                    self.markUnsupported()
                } else {
                    self.answered = true
                    self.availability = .notConfigured(message)
                    self.persistence.save(nil)
                }
            }
        }
    }

    private func markUnsupported() {
        self.answered = true
        self.catalog = nil
        self.availability = .unsupported
        self.persistence.save(nil)
    }

    func apply(catalog: TalkCatalog?) {
        self.answered = true
        self.catalog = catalog
        if let catalog, catalog.supportsRelayCall, let provider = catalog.relayProvider {
            self.availability = .available(provider: provider.id)
            self.persistence.save(provider.id)
        } else {
            self.availability = .notConfigured(nil)
            self.persistence.save(nil)
        }
    }

    /// Call once the new connection's hello is in: an unadvertised Talk is cleared at once, an advertised one loads now.
    public func handleReconnect() {
        self.generation += 1
        self.attempted = false
        self.answered = false
        self.catalog = nil
        guard self.isAdvertised else {
            self.markUnsupported()
            return
        }
        // Keep a cached positive value until the first answer on the new connection.
        self.availability = Self.cached(self.persistence)
        self.loadCatalogIfNeeded()
    }

    public func reset() { self.handleReconnect() }
}
