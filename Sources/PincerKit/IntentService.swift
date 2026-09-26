import Foundation

// The logic behind Pincer's Shortcuts / Siri actions. The AppIntents layer (Apps/Intents) is a thin
// wrapper around this, so it can be exercised by PincerChecks without AppIntents.

// MARK: Errors

/// Every failure a Shortcut can report, phrased to be spoken by Siri.
public enum IntentError: LocalizedError, Equatable, Sendable {
    case noGateways
    case identityMissing
    case gatewayRemoved(name: String)
    case awaitingPairing(gateway: String)
    case connectFailed(gateway: String, message: String)
    case unreachable(gateway: String)
    /// The message was delivered; only the reply is missing.
    case replyTimeout(agent: String, seconds: Int)
    case notFound(name: String, gateway: String)
    case sendFailed(String)
    /// The run ended with an error or was stopped; carries the Gateway's message.
    case runFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noGateways: "Add a Gateway in Pincer first."
        case .identityMissing: "Open Pincer once to finish setup."
        case let .gatewayRemoved(name): "\(name) isn't in Pincer anymore."
        case let .awaitingPairing(gateway): "\(gateway) needs this device approved. Run openclaw devices approve on the Gateway host."
        case let .connectFailed(gateway, message): "Can't connect to \(gateway): \(Self.sentence(Self.spokenReason(message)))"
        case let .unreachable(gateway): "\(gateway) isn't reachable."
        case let .replyTimeout(agent, seconds): "Sent, but \(agent) hasn't replied within \(seconds) seconds."
        case let .notFound(name, gateway): "\(name) isn't on \(gateway) anymore."
        case let .sendFailed(message): "Couldn't send: \(Self.spokenReason(message))"
        case let .runFailed(message): Self.spokenReason(message)
        }
    }

    /// `message` without a trailing Gateway error code such as ` [AUTH_TOKEN_MISMATCH]`, which Siri would read out.
    static func spokenReason(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = trimmed.range(of: #" \[[A-Z0-9_]+\]$"#, options: .regularExpression) else { return trimmed }
        return String(trimmed[..<code.lowerBound])
    }

    /// Ends `text` with exactly one full stop.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

// MARK: Identifiers

/// Entity identifiers: `<gatewayUUID>` for gateways, `<gatewayUUID>/<agentId>` for agents and
/// `<gatewayUUID>/<sessionKey>` for chats. Session keys contain `:` (and may contain `/`), so
/// only the first `/` separates.
public enum IntentID {
    public static func gateway(_ id: UUID) -> String { id.uuidString }

    public static func scoped(_ gatewayId: UUID, _ local: String) -> String { "\(gatewayId.uuidString)/\(local)" }

    public static func parse(_ id: String) -> (gatewayId: UUID, local: String)? {
        guard let slash = id.firstIndex(of: "/"),
              let uuid = UUID(uuidString: String(id[..<slash]))
        else { return nil }
        let local = String(id[id.index(after: slash)...])
        return local.isEmpty ? nil : (uuid, local)
    }
}

// MARK: Values

public struct IntentGateway: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let host: String?

    public init(_ profile: GatewayProfile) {
        self.id = profile.id
        self.name = profile.name
        self.host = (try? profile.resolvedURL())?.host() ?? (profile.isDemo ? nil : profile.url)
    }

    public var entityID: String { IntentID.gateway(self.id) }
}

public struct IntentAgent: Hashable, Sendable {
    public let gatewayId: UUID
    public let gatewayName: String
    public let agentId: String
    public let name: String
    public let emoji: String?
    /// Whether more than one gateway is saved, so the gateway is worth naming.
    public let showsGateway: Bool

    public init(gatewayId: UUID, gatewayName: String, agentId: String, name: String, emoji: String?, showsGateway: Bool) {
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.agentId = agentId
        self.name = name
        self.emoji = emoji
        self.showsGateway = showsGateway
    }

    public var entityID: String { IntentID.scoped(self.gatewayId, self.agentId) }
    public var title: String { [self.emoji, self.name].compactMap { $0?.nilIfEmpty }.joined(separator: " ") }
    public var subtitle: String? { self.showsGateway ? self.gatewayName : nil }
}

public struct IntentChat: Hashable, Sendable {
    public let gatewayId: UUID
    public let gatewayName: String
    public let sessionKey: String
    public let title: String
    public let agentId: String
    public let agentName: String

    public init(gatewayId: UUID, gatewayName: String, sessionKey: String, title: String, agentId: String, agentName: String) {
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.sessionKey = sessionKey
        self.title = title
        self.agentId = agentId
        self.agentName = agentName
    }

    public var entityID: String { IntentID.scoped(self.gatewayId, self.sessionKey) }
    public var subtitle: String { "\(self.agentName) · \(self.gatewayName)" }
    public var target: Notifier.Target { Notifier.Target(gatewayId: self.gatewayId, sessionKey: self.sessionKey) }
}

public struct IntentApproval: Hashable, Sendable {
    public let gatewayName: String
    public let approval: ExecApproval

    public init(gatewayName: String, approval: ExecApproval) {
        self.gatewayName = gatewayName
        self.approval = approval
    }
}

/// What a gateway offers as targets: agents and non-archived chats.
public struct GatewayTargets: Sendable {
    public var agents: [AgentSummary]
    public var defaultAgentId: String
    public var sessions: [SessionRow]

    public init(agents: [AgentSummary], defaultAgentId: String, sessions: [SessionRow]) {
        self.agents = agents
        self.defaultAgentId = defaultAgentId
        self.sessions = sessions
    }

    public func agentName(_ id: String) -> String {
        self.agents.first { $0.id == id }?.name ?? id.capitalized
    }
}

// MARK: Connections

/// The slice of a Gateway connection Shortcuts need. Implemented over the app's live
/// `GatewayStore`, a one-shot `GatewayConnection`, or a fake in PincerChecks.
@MainActor
public protocol IntentConnection: AnyObject {
    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue
    /// Observes Gateway events, in wire order, until `stopObserving` with the returned token.
    func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int
    func stopObserving(_ token: Int)
    /// Releases the connection. Never stops the app's own connection.
    func close() async
}

@MainActor
public protocol IntentConnector {
    /// A connected connection, or an `IntentError` (pairing, failure, timeout).
    func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection
    /// Agents and chats the running app already has for this gateway, when it's connected.
    func liveTargets(_ gatewayId: UUID) -> GatewayTargets?
    /// Pending approvals the running app already has for this gateway, when it's connected.
    func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]?
}

/// Reuses the app's connected `GatewayStore` when there is one, else connects once as the app's
/// paired device, like the Share extension does.
@MainActor
public struct GatewayIntentConnector: IntentConnector {
    let liveStore: @MainActor (UUID) -> GatewayStore?
    let identity: @MainActor () -> DeviceIdentity?

    public init(
        liveStore: @escaping @MainActor (UUID) -> GatewayStore? = { _ in nil },
        identity: @escaping @MainActor () -> DeviceIdentity? = { DeviceIdentity.loadExisting() })
    {
        self.liveStore = liveStore
        self.identity = identity
    }

    private func connectedStore(_ id: UUID) -> GatewayStore? {
        guard let store = self.liveStore(id), store.state.isConnected else { return nil }
        return store
    }

    public func connect(_ profile: GatewayProfile, timeout: TimeInterval) async throws -> any IntentConnection {
        if let store = self.connectedStore(profile.id) { return LiveStoreConnection(store) }
        // The demo lives in the app's process: use the app's own demo, so chats a Shortcut creates
        // or messages it sends show up there, starting it if the app hasn't yet.
        if profile.isDemo, let store = self.liveStore(profile.id) {
            if case .idle = store.state { store.start() }
            let deadline = Date().addingTimeInterval(timeout)
            while !store.state.isConnected, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if store.state.isConnected { return LiveStoreConnection(store) }
        }
        guard let identity = self.identity() ?? (profile.isDemo ? DeviceIdentity.loadOrCreate() : nil) else {
            throw IntentError.identityMissing
        }
        return try await OneShotConnection.open(profile: profile, identity: identity, timeout: timeout)
    }

    public func liveTargets(_ gatewayId: UUID) -> GatewayTargets? {
        guard let store = self.connectedStore(gatewayId), !store.sessions.isEmpty else { return nil }
        return GatewayTargets(agents: store.agents, defaultAgentId: store.defaultAgentId,
                              sessions: store.sessions.values.filter { !$0.isArchived })
    }

    public func liveApprovals(_ gatewayId: UUID) -> [ExecApproval]? {
        self.connectedStore(gatewayId)?.approvals
    }
}

@MainActor
final class LiveStoreConnection: IntentConnection {
    private let store: GatewayStore
    private var tokens: Set<Int> = []

    init(_ store: GatewayStore) { self.store = store }

    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        try await self.store.connection.request(method, params, timeout: timeout)
    }

    func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int {
        let token = self.store.addEventTap(handler)
        self.tokens.insert(token)
        return token
    }

    func stopObserving(_ token: Int) {
        self.store.removeEventTap(token)
        self.tokens.remove(token)
    }

    func close() async {
        for token in self.tokens { self.store.removeEventTap(token) }
        self.tokens = []
    }
}

/// A connection opened just for one Shortcut run. Chat events reach every operator connection
/// without `sessions.subscribe`, so none is sent.
@MainActor
final class OneShotConnection: IntentConnection {
    private enum Inbound: Sendable {
        case event(GatewayEvent)
        case state(ConnectionState)
    }

    private let connection: GatewayConnection
    private let gatewayName: String
    private var observers: [Int: @MainActor (GatewayEvent) -> Void] = [:]
    private var nextToken = 0
    private var pump: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    private init(connection: GatewayConnection, gatewayName: String) {
        self.connection = connection
        self.gatewayName = gatewayName
    }

    static func open(profile: GatewayProfile, identity: DeviceIdentity, timeout: TimeInterval) async throws -> OneShotConnection {
        let one = OneShotConnection(connection: GatewayConnection(profile: profile, identity: identity), gatewayName: profile.name)
        do {
            try await one.start(timeout: timeout)
            return one
        } catch {
            await one.close()
            throw error
        }
    }

    private func start(timeout: TimeInterval) async throws {
        let (stream, continuation) = AsyncStream<Inbound>.makeStream()
        self.pump = Task { [weak self] in
            for await inbound in stream {
                guard let self else { return }
                switch inbound {
                case let .event(event):
                    for observer in self.observers.values { observer(event) }
                case let .state(state):
                    self.update(state)
                }
            }
        }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            self.waiter = waiter
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                self.finishWaiting(.failure(IntentError.unreachable(gateway: self.gatewayName)))
            }
            Task {
                await connection.setHandlers(
                    onEvent: { continuation.yield(.event($0)) },
                    onState: { state, _ in continuation.yield(.state(state)) })
                await connection.start()
            }
        }
    }

    private func update(_ state: ConnectionState) {
        switch state {
        case .connected: self.finishWaiting(.success(()))
        case .awaitingPairing: self.finishWaiting(.failure(IntentError.awaitingPairing(gateway: self.gatewayName)))
        case let .failed(message): self.finishWaiting(.failure(IntentError.connectFailed(gateway: self.gatewayName, message: message)))
        case .idle, .connecting, .reconnecting: break
        }
    }

    private func finishWaiting(_ result: Result<Void, Error>) {
        guard let waiter = self.waiter else { return }
        self.waiter = nil
        self.timeoutTask?.cancel()
        waiter.resume(with: result)
    }

    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        try await self.connection.request(method, params, timeout: timeout)
    }

    func observeEvents(_ handler: @escaping @MainActor (GatewayEvent) -> Void) -> Int {
        self.nextToken += 1
        self.observers[self.nextToken] = handler
        return self.nextToken
    }

    func stopObserving(_ token: Int) {
        self.observers.removeValue(forKey: token)
    }

    func close() async {
        self.observers = [:]
        self.finishWaiting(.failure(IntentError.unreachable(gateway: self.gatewayName)))
        await self.connection.stop()
        self.pump?.cancel()
    }
}

// MARK: Reply waiting

/// How a run ended, as reported by its terminal `chat` event.
public enum RunOutcome: Equatable, Sendable {
    case final(JSONValue?)
    case error(String?)
    case aborted(String?)
}

/// Collects terminal `chat` events for one session, keyed by run id. Install it before `chat.send`:
/// a fast run's `final` can arrive before the send's response names the run.
@MainActor
public final class ReplyCollector {
    public let sessionKey: String
    private var outcomes: [String: RunOutcome] = [:]
    private var waiters: [String: CheckedContinuation<RunOutcome?, Never>] = [:]

    public init(sessionKey: String) { self.sessionKey = sessionKey }

    public func handle(_ event: GatewayEvent) {
        guard event.name == "chat", let runId = event.payload["runId"]?.text else { return }
        if let key = event.payload["sessionKey"]?.text, key != self.sessionKey { return }
        let outcome: RunOutcome
        switch event.payload["state"]?.string {
        case "final": outcome = .final(event.payload["message"])
        case "error": outcome = .error(event.payload["errorMessage"]?.text)
        case "aborted": outcome = .aborted(event.payload["errorMessage"]?.text ?? event.payload["stopReason"]?.text)
        default: return
        }
        if let waiter = self.waiters.removeValue(forKey: runId) {
            waiter.resume(returning: outcome)
        } else {
            self.outcomes[runId] = outcome
        }
    }

    /// The run's outcome, or nil after `timeout` seconds.
    public func wait(runId: String, timeout: TimeInterval) async -> RunOutcome? {
        if let outcome = self.outcomes.removeValue(forKey: runId) { return outcome }
        return await withCheckedContinuation { continuation in
            self.waiters[runId] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.waiters.removeValue(forKey: runId)?.resume(returning: nil)
            }
        }
    }
}

// MARK: Service

@MainActor
public final class IntentService {
    public let profiles: [GatewayProfile]
    public let selectedGatewayId: UUID?
    private let hasIdentity: Bool
    private let connector: any IntentConnector
    private let labels: UserDefaults
    public var connectTimeout: TimeInterval = 10
    /// Bound for listing targets when Shortcuts asks for suggestions.
    public var suggestionTimeout: TimeInterval = 5

    public init(
        profiles: [GatewayProfile],
        hasIdentity: Bool,
        selectedGatewayId: UUID?,
        connector: any IntentConnector,
        labels: UserDefaults = SharedContainer.defaults)
    {
        self.profiles = profiles
        self.hasIdentity = hasIdentity
        self.selectedGatewayId = selectedGatewayId
        self.connector = connector
        self.labels = labels
    }

    /// The service as the app uses it: saved gateways, the paired identity, and `liveStore` for
    /// reusing the app's connection when it has one.
    public static func live(liveStore: @escaping @MainActor (UUID) -> GatewayStore?) -> IntentService {
        let defaults = SharedContainer.defaults
        let identity = DeviceIdentity.loadExisting()
        let selected = (defaults.string(forKey: AppModel.selectedGatewayKey)
            ?? UserDefaults.standard.string(forKey: AppModel.selectedGatewayKey)).flatMap(UUID.init(uuidString:))
        let profiles = GatewayProfileStore.load()
        let demoIds = Set(profiles.filter(\.isDemo).map(\.id))
        return IntentService(
            profiles: profiles,
            hasIdentity: identity != nil,
            selectedGatewayId: selected,
            // Without an identity nothing connects, and creating the app's stores would make one;
            // the demo needs none.
            connector: GatewayIntentConnector(
                liveStore: { identity == nil && !demoIds.contains($0) ? nil : liveStore($0) },
                identity: { identity }))
    }

    // MARK: Gateways

    public var gateways: [IntentGateway] { self.profiles.map(IntentGateway.init) }

    public func gateways(for ids: [String]) -> [IntentGateway] {
        ids.compactMap { id in self.profiles.first { $0.id.uuidString == id || $0.id == UUID(uuidString: id) } }
            .map(IntentGateway.init)
    }

    /// One gateway is used silently; with several, the app's selected one, then the first.
    public static func defaultGateway(_ profiles: [GatewayProfile], selected: UUID?) -> GatewayProfile? {
        if profiles.count == 1 { return profiles[0] }
        return profiles.first { $0.id == selected } ?? profiles.first
    }

    public func resolveGateway(_ id: UUID?, name: String? = nil) throws -> GatewayProfile {
        guard !self.profiles.isEmpty else { throw IntentError.noGateways }
        if let id {
            guard let profile = self.profiles.first(where: { $0.id == id }) else {
                throw IntentError.gatewayRemoved(name: name ?? "That Gateway")
            }
            return profile
        }
        return Self.defaultGateway(self.profiles, selected: self.selectedGatewayId)!
    }

    private func connect(_ profile: GatewayProfile, timeout: TimeInterval? = nil) async throws -> any IntentConnection {
        if !self.hasIdentity, !profile.isDemo { throw IntentError.identityMissing }
        return try await self.connector.connect(profile, timeout: timeout ?? self.connectTimeout)
    }

    // MARK: Targets

    public func targets(_ profile: GatewayProfile, on connection: (any IntentConnection)? = nil) async throws -> GatewayTargets {
        if let live = self.connector.liveTargets(profile.id) { return live }
        if let connection { return try await Self.fetchTargets(connection) }
        let connection = try await self.connect(profile)
        do {
            let targets = try await Self.fetchTargets(connection)
            await connection.close()
            return targets
        } catch {
            await connection.close()
            throw error
        }
    }

    static func fetchTargets(_ connection: any IntentConnection) async throws -> GatewayTargets {
        let agents = try await connection.request("agents.list", [:], timeout: 20)
        let sessions = try await connection.request(
            "sessions.list", ["limit": 200, "includeLastMessage": false, "archived": false], timeout: 30)
        let summaries = agents["agents"]?.array?.compactMap(AgentSummary.init) ?? []
        return GatewayTargets(
            agents: summaries,
            defaultAgentId: agents["defaultId"]?.text ?? summaries.first?.id ?? "main",
            sessions: (sessions["sessions"]?.array?.compactMap(SessionRow.init) ?? []).filter { !$0.isArchived })
    }

    /// Targets from the app if connected, else a bounded one-shot fetch; nil on any failure.
    private func quickTargets(_ profile: GatewayProfile) async -> GatewayTargets? {
        if let live = self.connector.liveTargets(profile.id) { return live }
        guard self.hasIdentity || profile.isDemo else { return nil }
        let bound = self.suggestionTimeout
        return await withBound(seconds: bound) { [self] in
            guard let connection = try? await self.connect(profile, timeout: bound) else { return nil }
            let targets = try? await Self.fetchTargets(connection)
            await connection.close()
            return targets
        } ?? nil
    }

    func agent(_ summary: AgentSummary, on profile: GatewayProfile) -> IntentAgent {
        IntentAgent(gatewayId: profile.id, gatewayName: profile.name, agentId: summary.id, name: summary.name,
                    emoji: summary.emoji, showsGateway: self.profiles.count > 1)
    }

    func chat(_ row: SessionRow, on profile: GatewayProfile, targets: GatewayTargets?) -> IntentChat {
        let agentName = targets?.agentName(row.agentId) ?? row.agentId.capitalized
        return IntentChat(gatewayId: profile.id, gatewayName: profile.name, sessionKey: row.key,
                          title: Self.chatTitle(row.title, isMain: row.isMain, agentName: agentName),
                          agentId: row.agentId, agentName: agentName)
    }

    /// Every agent's main chat is called "Main"; name it after its agent instead, so a list reads
    /// "Claw, Forge" rather than "Main, Main". A main chat renamed by the user keeps its name.
    static func chatTitle(_ title: String, isMain: Bool, agentName: String) -> String {
        guard isMain, title.isEmpty || title.caseInsensitiveCompare("main") == .orderedSame else { return title }
        return agentName
    }

    /// Chats worth offering: not helpers, automations or archived; pinned, then recent.
    public static func suggestableChats(_ rows: [SessionRow]) -> [SessionRow] {
        ShareModel.shareableChats(rows)
    }

    /// Quick targets for every gateway at once, so suggestions take one bound however many
    /// gateways are saved. In `profiles` order; unreachable gateways are left out.
    private func allQuickTargets() async -> [(GatewayProfile, GatewayTargets)] {
        let tasks = self.profiles.map { profile in (profile, Task { await self.quickTargets(profile) }) }
        var result: [(GatewayProfile, GatewayTargets)] = []
        for (profile, task) in tasks {
            if let targets = await task.value { result.append((profile, targets)) }
        }
        return result
    }

    public func suggestedAgents() async -> [IntentAgent] {
        let result = await self.allQuickTargets().flatMap { profile, targets in
            targets.agents.map { self.agent($0, on: profile) }
        }
        self.remember(agents: result)
        return result
    }

    public func suggestedChats(limit: Int = 50) async -> [IntentChat] {
        let result = await self.allQuickTargets().flatMap { profile, targets in
            Self.suggestableChats(targets.sessions).prefix(limit).map { self.chat($0, on: profile, targets: targets) }
        }
        self.remember(chats: result)
        return result
    }

    public func agents(matching query: String) async -> [IntentAgent] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await self.suggestedAgents()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.agentId.localizedCaseInsensitiveContains(query) }
    }

    public func chats(matching query: String) async -> [IntentChat] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await self.suggestedChats(limit: 200)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.sessionKey.localizedCaseInsensitiveContains(query) }
    }

    /// Agents from their ids, without the network: live app state when connected, else the names
    /// last seen. Ids for removed gateways, or agents the connected app no longer lists, are dropped.
    public func agents(for ids: [String]) -> [IntentAgent] {
        ids.compactMap { id in
            guard let (gatewayId, agentId) = IntentID.parse(id),
                  let profile = self.profiles.first(where: { $0.id == gatewayId })
            else { return nil }
            if let live = self.connector.liveTargets(gatewayId), !live.agents.isEmpty {
                return live.agents.first { $0.id == agentId }.map { self.agent($0, on: profile) }
            }
            let label = self.label(id)
            return IntentAgent(gatewayId: gatewayId, gatewayName: profile.name, agentId: agentId,
                               name: label?.first ?? agentId.capitalized, emoji: label?.dropFirst().first?.nilIfEmpty,
                               showsGateway: self.profiles.count > 1)
        }
    }

    public func chats(for ids: [String]) -> [IntentChat] {
        ids.compactMap { id in
            guard let (gatewayId, key) = IntentID.parse(id),
                  let profile = self.profiles.first(where: { $0.id == gatewayId })
            else { return nil }
            if let live = self.connector.liveTargets(gatewayId) {
                return live.sessions.first { $0.key == key }.map { self.chat($0, on: profile, targets: live) }
            }
            let label = self.label(id)
            let agentId = SessionKey.agentId(from: key) ?? "main"
            let agentName = label?.dropFirst().first ?? agentId.capitalized
            return IntentChat(gatewayId: gatewayId, gatewayName: profile.name, sessionKey: key,
                              title: label?.first ?? Self.chatTitle(SessionKey.shortName(key), isMain: SessionKey.isMain(key),
                                                                    agentName: agentName),
                              agentId: agentId, agentName: agentName)
        }
    }

    // Display names seen in the last listing, so saved Shortcuts show names offline.
    static let labelsKey = "pincer.intents.labels"
    static let labelLimit = 1000

    private func label(_ id: String) -> [String]? {
        (self.labels.dictionary(forKey: Self.labelsKey) as? [String: [String]])?[id]
    }

    private func remember(agents: [IntentAgent] = [], chats: [IntentChat] = []) {
        guard !agents.isEmpty || !chats.isEmpty else { return }
        var stored = self.labels.dictionary(forKey: Self.labelsKey) as? [String: [String]] ?? [:]
        var current: [String: [String]] = [:]
        for agent in agents { current[agent.entityID] = [agent.name, agent.emoji ?? ""] }
        for chat in chats { current[chat.entityID] = [chat.title, chat.agentName] }
        stored.merge(current) { $1 }
        if stored.count > Self.labelLimit {
            // Keep what was just listed, then fill up with older names.
            var trimmed = current.count > Self.labelLimit
                ? Dictionary(uniqueKeysWithValues: current.sorted { $0.key < $1.key }.prefix(Self.labelLimit).map { ($0.key, $0.value) })
                : current
            for (id, label) in stored.sorted(by: { $0.key < $1.key }) where trimmed.count < Self.labelLimit && trimmed[id] == nil {
                trimmed[id] = label
            }
            stored = trimmed
        }
        self.labels.set(stored, forKey: Self.labelsKey)
    }

    // MARK: Ask / send / start

    public struct AskResult: Sendable, Equatable {
        public let text: String
        public let agentName: String
        public let chat: IntentChat
    }

    /// Sends `prompt` to the agent's main chat (creating a chat if it has none) and, when
    /// `waitForReply`, returns the reply's plain text.
    public func ask(
        _ prompt: String, agentId: String?, agentName: String? = nil, gatewayId: UUID?, gatewayName: String? = nil,
        waitForReply: Bool, timeoutSeconds: Int) async throws -> AskResult
    {
        let profile = try self.resolveGateway(gatewayId, name: gatewayName)
        let connection = try await self.connect(profile)
        do {
            let result = try await self.ask(prompt, agentId: agentId, agentName: agentName, profile: profile,
                                             connection: connection, waitForReply: waitForReply, timeoutSeconds: timeoutSeconds)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    private func ask(
        _ prompt: String, agentId requested: String?, agentName: String?, profile: GatewayProfile,
        connection: any IntentConnection, waitForReply: Bool, timeoutSeconds: Int) async throws -> AskResult
    {
        let targets = try await self.targets(profile, on: connection)
        let agentId = requested ?? targets.defaultAgentId
        if requested != nil, !targets.agents.isEmpty, !targets.agents.contains(where: { $0.id == agentId }) {
            throw IntentError.notFound(name: agentName ?? agentId.capitalized, gateway: profile.name)
        }
        let name = targets.agents.isEmpty ? (agentName ?? agentId.capitalized) : targets.agentName(agentId)
        let row: SessionRow
        if let main = Self.mainChat(for: agentId, in: targets.sessions) {
            row = main
        } else {
            row = try await Self.createSession(agentId: agentId, on: connection)
        }
        let chat = self.chat(row, on: profile, targets: targets)
        let text = try await Self.send(
            prompt, sessionKey: row.key, agentId: agentId, agentName: name, on: connection,
            waitSeconds: waitForReply ? Self.clampTimeout(timeoutSeconds) : nil)
        return AskResult(text: text ?? "", agentName: name, chat: chat)
    }

    public static func clampTimeout(_ seconds: Int) -> Int { min(max(seconds, 5), 300) }

    public static func mainChat(for agentId: String, in rows: [SessionRow]) -> SessionRow? {
        rows.first { $0.isMain && $0.agentId == agentId && !$0.isArchived && !$0.isSubagent }
    }

    static func createSession(agentId: String, on connection: any IntentConnection) async throws -> SessionRow {
        let created: JSONValue
        do {
            created = try await connection.request("sessions.create", ["agentId": .string(agentId)], timeout: 30)
        } catch {
            throw IntentError.sendFailed(error.localizedDescription)
        }
        guard let key = created["key"]?.text ?? created["session"]?["key"]?.text else {
            throw IntentError.sendFailed("the Gateway didn't create a chat.")
        }
        if let row = created["session"].flatMap(SessionRow.init), row.key == key { return row }
        return SessionRow(["key": .string(key), "agentId": .string(agentId)])!
    }

    /// Sends a message. With `waitSeconds`, waits for that run's reply and returns its text.
    static func send(
        _ message: String, sessionKey: String, agentId: String?, agentName: String,
        on connection: any IntentConnection, waitSeconds: Int?) async throws -> String?
    {
        // Listen before sending: the run can finish before `chat.send` returns.
        let collector = ReplyCollector(sessionKey: sessionKey)
        let token = waitSeconds == nil ? nil : connection.observeEvents { collector.handle($0) }
        defer { if let token { connection.stopObserving(token) } }
        let idempotencyKey = UUID().uuidString.lowercased()
        let params = ChatSendRequest.params(
            sessionKey: sessionKey, agentId: agentId, message: message, idempotencyKey: idempotencyKey, attachments: [])
        let response: JSONValue
        do {
            response = try await connection.request("chat.send", .object(params), timeout: 60)
        } catch {
            throw IntentError.sendFailed(error.localizedDescription)
        }
        guard let waitSeconds else { return nil }
        let runId = response["runId"]?.text ?? idempotencyKey
        switch await collector.wait(runId: runId, timeout: TimeInterval(waitSeconds)) {
        case nil:
            throw IntentError.replyTimeout(agent: agentName, seconds: waitSeconds)
        case let .error(message):
            throw IntentError.runFailed(message?.nilIfEmpty ?? "The run failed.")
        case let .aborted(message):
            throw IntentError.runFailed(message?.nilIfEmpty ?? "The run was stopped.")
        case let .final(snapshot):
            if let text = snapshot.flatMap({ ChatItem($0, fallbackIndex: 0) })?.plainText.nilIfEmpty { return text }
            return await self.lastAssistantText(sessionKey: sessionKey, on: connection) ?? ""
        }
    }

    static func lastAssistantText(sessionKey: String, on connection: any IntentConnection) async -> String? {
        guard let history = try? await connection.request(
            "chat.history", ["sessionKey": .string(sessionKey), "limit": 20], timeout: 20) else { return nil }
        let items = (history["messages"]?.array ?? []).enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
        return items.last { $0.role == .assistant && !$0.plainText.isEmpty }?.plainText
    }

    public func send(_ message: String, to chat: IntentChat) async throws {
        let profile = try self.resolveGateway(chat.gatewayId, name: chat.gatewayName)
        let connection = try await self.connect(profile)
        defer { Task { await connection.close() } }
        if let live = self.connector.liveTargets(profile.id), !live.sessions.contains(where: { $0.key == chat.sessionKey }) {
            throw IntentError.notFound(name: chat.title, gateway: profile.name)
        }
        do {
            _ = try await Self.send(message, sessionKey: chat.sessionKey, agentId: chat.agentId, agentName: chat.agentName,
                                    on: connection, waitSeconds: nil)
        } catch let IntentError.sendFailed(reason) where Self.isUnknownSession(reason) {
            throw IntentError.notFound(name: chat.title, gateway: profile.name)
        }
    }

    static func isUnknownSession(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("unknown session") || lower.contains("session not found")
    }

    /// Creates a chat with the agent and optionally sends a first message (without waiting).
    public func startChat(
        agentId: String, agentName: String, gatewayId: UUID, gatewayName: String? = nil, message: String?) async throws -> IntentChat
    {
        let profile = try self.resolveGateway(gatewayId, name: gatewayName)
        let connection = try await self.connect(profile)
        defer { Task { await connection.close() } }
        let targets = self.connector.liveTargets(profile.id)
        if let targets, !targets.agents.isEmpty, !targets.agents.contains(where: { $0.id == agentId }) {
            throw IntentError.notFound(name: agentName, gateway: profile.name)
        }
        let row: SessionRow
        do {
            row = try await Self.createSession(agentId: agentId, on: connection)
        } catch IntentError.sendFailed(let reason) where reason.lowercased().contains("unknown agent") {
            throw IntentError.notFound(name: agentName, gateway: profile.name)
        }
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            _ = try await Self.send(message, sessionKey: row.key, agentId: agentId, agentName: agentName,
                                    on: connection, waitSeconds: nil)
        }
        return IntentChat(gatewayId: profile.id, gatewayName: profile.name, sessionKey: row.key, title: row.title,
                          agentId: agentId, agentName: targets?.agentName(agentId) ?? agentName)
    }

    // MARK: Unread / approvals

    /// The same chats the app counts in its unread badge.
    public static func unreadRows(_ rows: [SessionRow]) -> [SessionRow] {
        rows.filter { $0.isUnread && !$0.isArchived && !$0.isSubagent }
            .sorted { $0.activityMs != $1.activityMs ? $0.activityMs > $1.activityMs : $0.key < $1.key }
    }

    /// Runs `body` for one gateway, or for every gateway when `gatewayId` is nil. With every
    /// gateway, ones that fail are skipped unless all of them do.
    private func eachGateway<T>(
        _ gatewayId: UUID?, name: String?, _ body: (GatewayProfile) async throws -> [T]) async throws -> [T]
    {
        if let gatewayId { return try await body(self.resolveGateway(gatewayId, name: name)) }
        guard !self.profiles.isEmpty else { throw IntentError.noGateways }
        var result: [T] = []
        var firstError: Error?
        var succeeded = false
        for profile in self.profiles {
            do {
                result += try await body(profile)
                succeeded = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if !succeeded, let firstError { throw firstError }
        return result
    }

    public func unreadChats(gatewayId: UUID?, gatewayName: String? = nil) async throws -> [IntentChat] {
        try await self.eachGateway(gatewayId, name: gatewayName) { profile in
            let targets = try await self.targets(profile)
            return Self.unreadRows(targets.sessions).map { self.chat($0, on: profile, targets: targets) }
        }
    }

    public static func pending(_ approvals: [ExecApproval], at date: Date = Date()) -> [ExecApproval] {
        approvals.filter { !$0.isExpired(at: date) }
    }

    public func pendingApprovals(gatewayId: UUID?, gatewayName: String? = nil) async throws -> [IntentApproval] {
        try await self.eachGateway(gatewayId, name: gatewayName) { profile in
            let approvals: [ExecApproval]
            if let live = self.connector.liveApprovals(profile.id) {
                approvals = live
            } else {
                let connection = try await self.connect(profile)
                defer { Task { await connection.close() } }
                let result = try await connection.request("exec.approval.list", [:], timeout: 20)
                let items = result["approvals"]?.array ?? result["items"]?.array ?? result.array ?? []
                approvals = items.compactMap(ExecApproval.init)
            }
            return Self.pending(approvals).map { IntentApproval(gatewayName: profile.name, approval: $0) }
        }
    }

    // MARK: Speech

    /// `text` trimmed for Siri to read: whitespace collapsed and cut near `limit` characters.
    public static func spoken(_ text: String, limit: Int = 500) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        // Keep the last word when the cut falls exactly on a word boundary.
        let endsOnWord = collapsed[cut.endIndex] == " "
        let head = endsOnWord ? cut : cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return head.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    public static func truncated(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    public static func unreadSummary(_ chats: [IntentChat]) -> String {
        guard !chats.isEmpty else { return "No unread chats." }
        let shown = chats.prefix(5).map(\.title)
        let more = chats.count > shown.count ? ", and \(chats.count - shown.count) more" : ""
        return "\(chats.count) unread chat\(chats.count == 1 ? "" : "s"): \(shown.joined(separator: ", "))\(more)."
    }

    public static func approvalsSummary(_ approvals: [IntentApproval]) -> String {
        guard let first = approvals.first else { return "No pending approvals." }
        let command = self.truncated(first.approval.command, 60)
        if approvals.count == 1 { return "1 pending approval: \(command)" }
        return "\(approvals.count) pending approvals. First: \(command)"
    }
}

/// `body`'s result, or nil once `seconds` pass (`body` keeps running to clean up after itself).
@MainActor
func withBound<T: Sendable>(seconds: TimeInterval, _ body: @escaping @MainActor () async -> T) async -> T? {
    let once = BoundOnce<T>()
    return await withCheckedContinuation { continuation in
        once.continuation = continuation
        Task { @MainActor in once.finish(await body()) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            once.finish(nil)
        }
    }
}

@MainActor
private final class BoundOnce<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?

    func finish(_ value: T?) {
        self.continuation?.resume(returning: value)
        self.continuation = nil
    }
}
