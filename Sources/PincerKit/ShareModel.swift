import Foundation
import Observation

/// Where shared content goes: an existing chat, or a new chat with an agent.
public enum ShareTarget: Hashable, Sendable {
    case chat(String)
    case newChat(agentId: String)

    /// Stored form, remembered for the next share.
    public var storageValue: String {
        switch self {
        case let .chat(key): "chat:\(key)"
        case let .newChat(agentId): "new:\(agentId)"
        }
    }

    public init?(storageValue: String) {
        if storageValue.hasPrefix("chat:") {
            self = .chat(String(storageValue.dropFirst(5)))
        } else if storageValue.hasPrefix("new:") {
            self = .newChat(agentId: String(storageValue.dropFirst(4)))
        } else {
            return nil
        }
    }
}

/// State behind the Share extension: picks a gateway and chat, connects as the app's
/// already-paired device, and sends the shared content with `sessions.create` / `chat.send`.
@MainActor
@Observable
public final class ShareModel {
    public enum Phase: Equatable, Sendable {
        /// No saved gateways, or the app hasn't created its device key yet.
        case unavailable(String)
        case connecting(String?)
        case awaitingPairing(deviceId: String)
        case ready
        case sending
        case sent
        case failed(String)
    }

    public let profiles: [GatewayProfile]
    public private(set) var phase: Phase
    public private(set) var agents: [AgentSummary] = []
    public private(set) var defaultAgentId = "main"
    /// Chats the content can go to, most relevant first.
    public private(set) var chats: [SessionRow] = []
    public var target: ShareTarget?
    public var note = ""
    public private(set) var content = SharedContent()
    /// Attachments sized for the connected Gateway, and files that won't be sent.
    public private(set) var attachments: [OutgoingAttachment] = []
    public private(set) var attachmentProblems: [String] = []
    public private(set) var sendError: String?

    public var profileId: UUID? {
        didSet {
            // `@Observable` runs observers for the assignment in `init` too.
            guard self.isInitialized, oldValue != self.profileId else { return }
            self.defaults.set(self.profileId?.uuidString, forKey: Self.lastGatewayKey)
            self.connect()
        }
    }

    @ObservationIgnored private let identity: DeviceIdentity?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var connection: GatewayConnection?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var hello: GatewayHello?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isInitialized = false

    public static let lastGatewayKey = "pincer.share.lastGateway"
    public static func lastTargetKey(_ gatewayId: UUID) -> String { "pincer.share.lastTarget.\(gatewayId.uuidString)" }

    public init(
        profiles: [GatewayProfile] = GatewayProfileStore.load(),
        identity: DeviceIdentity? = DeviceIdentity.loadExisting(),
        defaults: UserDefaults = SharedContainer.defaults)
    {
        self.profiles = profiles
        self.identity = identity
        self.defaults = defaults
        if profiles.isEmpty {
            self.phase = .unavailable("Add a Gateway in Pincer first, then share again.")
        } else if identity == nil {
            self.phase = .unavailable("Open Pincer once to finish setting up sharing, then share again.")
        } else {
            self.phase = .connecting(nil)
        }
        let remembered = [Self.lastGatewayKey, AppModel.selectedGatewayKey]
            .lazy.compactMap { defaults.string(forKey: $0).flatMap(UUID.init(uuidString:)) }
            .first { id in profiles.contains { $0.id == id } }
        self.profileId = remembered ?? profiles.first?.id
        self.isInitialized = true
    }

    public var profile: GatewayProfile? { self.profiles.first { $0.id == self.profileId } }

    public var messageText: String { self.content.message(note: self.note) }

    public var canSend: Bool {
        self.phase == .ready && self.target != nil && (!self.messageText.isEmpty || !self.attachments.isEmpty)
    }

    public func setContent(_ content: SharedContent) {
        self.content = content
        self.prepareAttachments()
    }

    /// Connects to the selected gateway. Called on start and whenever the gateway changes.
    public func connect() {
        self.disconnect()
        guard let profile = self.profile, let identity = self.identity else { return }
        self.generation += 1
        let generation = self.generation
        self.phase = .connecting(nil)
        self.agents = []
        self.chats = []
        self.target = nil
        let connection = GatewayConnection(profile: profile, identity: identity)
        self.connection = connection
        let (stream, continuation) = AsyncStream<(ConnectionState, GatewayHello?)>.makeStream()
        self.pumpTask = Task { [weak self] in
            for await (state, hello) in stream {
                guard let self, self.generation == generation else { return }
                await self.update(state: state, hello: hello, generation: generation)
            }
        }
        Task {
            await connection.setHandlers(onEvent: { _ in }, onState: { continuation.yield(($0, $1)) })
            await connection.start()
        }
    }

    public func disconnect() {
        self.pumpTask?.cancel()
        self.pumpTask = nil
        self.hello = nil
        if let connection = self.connection {
            Task { await connection.stop() }
        }
        self.connection = nil
    }

    private func update(state: ConnectionState, hello: GatewayHello?, generation: Int) async {
        guard self.phase != .sending, self.phase != .sent else { return }
        switch state {
        case .idle, .connecting:
            if self.hello == nil { self.phase = .connecting(nil) }
        case let .reconnecting(_, _, reason):
            self.hello = nil
            self.phase = .connecting(reason)
        case let .awaitingPairing(_, deviceId):
            self.phase = .awaitingPairing(deviceId: deviceId)
        case let .failed(message):
            self.phase = .failed(message)
        case .connected:
            guard let hello else { return }
            self.hello = hello
            self.prepareAttachments()
            await self.loadTargets()
            guard generation == self.generation else { return }
            self.phase = .ready
        }
    }

    /// Reloads agents and chats, as every (re)connect does.
    public func refreshTargets() async {
        await self.loadTargets()
    }

    private func loadTargets() async {
        guard let connection else { return }
        async let agents = try? connection.request("agents.list", [:])
        async let sessions = try? connection.request(
            "sessions.list", ["limit": 200, "includeLastMessage": false, "archived": false], timeout: 30)
        if let agents = await agents {
            self.agents = agents["agents"]?.array?.compactMap(AgentSummary.init) ?? []
            self.defaultAgentId = agents["defaultId"]?.text ?? self.agents.first?.id ?? "main"
        }
        let rows = await sessions?["sessions"]?.array?.compactMap(SessionRow.init) ?? []
        self.chats = Self.shareableChats(rows)
        let remembered = self.profileId.flatMap { self.defaults.string(forKey: Self.lastTargetKey($0)) }
            .flatMap(ShareTarget.init(storageValue:))
        // A reconnect keeps what the user picked, as long as it's still there.
        if let current = self.target, Self.isAvailable(current, chats: self.chats, agents: self.agents) { return }
        self.target = Self.defaultTarget(
            remembered: remembered, chats: self.chats, agents: self.agents, defaultAgentId: self.defaultAgentId)
    }

    private func prepareAttachments() {
        let prepared = self.content.attachments(limits: UploadLimits(hello: self.hello))
        self.attachments = prepared.attachments
        self.attachmentProblems = prepared.problems
    }

    /// Sends the note and shared content. Returns whether the Gateway accepted it.
    @discardableResult
    public func send() async -> Bool {
        guard self.canSend, let connection, let target else { return false }
        self.phase = .sending
        self.sendError = nil
        do {
            let sessionKey: String
            let agentId: String?
            switch target {
            case let .chat(key):
                sessionKey = key
                agentId = self.chats.first { $0.key == key }?.agentId
            case let .newChat(newAgentId):
                let created = try await connection.request("sessions.create", ["agentId": .string(newAgentId)], timeout: 30)
                guard let key = created["key"]?.text ?? created["session"]?["key"]?.text else {
                    throw GatewayError.protocolViolation("sessions.create returned no key")
                }
                sessionKey = key
                agentId = newAgentId
            }
            let params = ChatSendRequest.params(
                sessionKey: sessionKey, agentId: agentId, message: self.messageText,
                idempotencyKey: UUID().uuidString.lowercased(), attachments: self.attachments)
            _ = try await connection.request("chat.send", .object(params), timeout: 60)
            if let profileId { self.defaults.set(target.storageValue, forKey: Self.lastTargetKey(profileId)) }
            self.phase = .sent
            return true
        } catch {
            self.sendError = "Couldn’t send: \(error.localizedDescription)"
            self.phase = self.hello == nil ? .connecting(nil) : .ready
            return false
        }
    }

    // MARK: Pure helpers

    /// Chats worth sharing into: no helper runs, automations or archived chats; pinned first,
    /// then most recently active.
    public static func shareableChats(_ rows: [SessionRow]) -> [SessionRow] {
        rows.filter { !$0.isSubagent && !$0.isAutomation && !$0.isSlashCommands && !$0.isArchived && !$0.key.isEmpty }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.activityMs != rhs.activityMs { return lhs.activityMs > rhs.activityMs }
                return lhs.key < rhs.key
            }
    }

    public static func isAvailable(_ target: ShareTarget, chats: [SessionRow], agents: [AgentSummary]) -> Bool {
        switch target {
        case let .chat(key): chats.contains { $0.key == key }
        case let .newChat(agentId): agents.isEmpty || agents.contains { $0.id == agentId }
        }
    }

    /// The last target used on this gateway if it's still there, else the default agent's main chat.
    public static func defaultTarget(remembered: ShareTarget?, chats: [SessionRow], agents: [AgentSummary], defaultAgentId: String) -> ShareTarget {
        if let remembered, self.isAvailable(remembered, chats: chats, agents: agents) { return remembered }
        if let main = chats.first(where: { $0.isMain && $0.agentId == defaultAgentId }) { return .chat(main.key) }
        return .newChat(agentId: defaultAgentId)
    }
}
