import Foundation
import Observation

/// Sidebar grouping, like Discord categories.
public enum SidebarOrganization: String, CaseIterable, Identifiable, Sendable {
    case servers
    case agent
    case group
    case recent

    public var id: String { self.rawValue }
    public var label: String {
        switch self {
        case .servers: "Like Discord"
        case .agent: "By agent"
        case .group: "By group"
        case .recent: "Recent"
        }
    }
}

public struct SidebarChannel: Identifiable, Hashable, Sendable {
    public let row: SessionRow
    public var threads: [SessionRow]
    public var id: String { self.row.key }
}

public struct SidebarSection: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case agent(String)
        case server(ChatServer)
        case group(String)
        case automations
        case other
    }

    public let id: String
    public let title: String
    public let emoji: String?
    public var channels: [SidebarChannel]
    public let kind: Kind

    public var agentId: String? {
        if case let .agent(id) = self.kind { return id }
        return nil
    }

    public var unreadCount: Int { self.channels.filter { $0.row.isUnread }.count }
}

/// Everything the UI knows about one Gateway ("server" in the rail).
@MainActor
@Observable
public final class GatewayStore: Identifiable {
    public private(set) var profile: GatewayProfile
    public nonisolated let id: UUID
    public private(set) var state: ConnectionState = .idle
    public private(set) var hello: GatewayHello?
    public private(set) var agents: [AgentSummary] = []
    public private(set) var defaultAgentId = "main"
    public private(set) var sessions: [String: SessionRow] = [:]
    public private(set) var approvals: [ExecApproval] = []
    public private(set) var lastError: String?
    public var selectedKey: String? {
        didSet {
            guard oldValue != self.selectedKey, let key = self.selectedKey else { return }
            UserDefaults.standard.set(key, forKey: "pincer.selected.\(self.id.uuidString)")
            Task { await self.openChat(key) }
        }
    }
    public var organization: SidebarOrganization {
        didSet { UserDefaults.standard.set(self.organization.rawValue, forKey: "pincer.org.v2.\(self.id.uuidString)") }
    }
    public var showArchived = false

    @ObservationIgnored let connection: GatewayConnection
    @ObservationIgnored private var chats: [String: ChatStore] = [:]
    @ObservationIgnored private var runSessions: [String: String] = [:]
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored weak var notifier: Notifier?
    public let images: ArtifactImageLoader

    public init(profile: GatewayProfile) {
        self.profile = profile
        self.id = profile.id
        self.connection = GatewayConnection(profile: profile)
        self.organization = SidebarOrganization(
            rawValue: UserDefaults.standard.string(forKey: "pincer.org.v2.\(profile.id.uuidString)") ?? "") ?? .servers
        self.serverNameOverrides = UserDefaults.standard.dictionary(forKey: "pincer.serverNames.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.selectedKey = UserDefaults.standard.string(forKey: "pincer.selected.\(profile.id.uuidString)")
        self.images = ArtifactImageLoader()
        self.images.gateway = self
    }

    public var deviceId: String { DeviceIdentity.loadOrCreate().deviceId }

    private enum Inbound: Sendable {
        case event(GatewayEvent)
        case state(ConnectionState, GatewayHello?)
    }

    @ObservationIgnored private var pumpTask: Task<Void, Never>?

    public func start() {
        guard self.pumpTask == nil else { return }
        // A single ordered stream keeps chat deltas and state changes in wire order.
        let (stream, continuation) = AsyncStream<Inbound>.makeStream()
        self.pumpTask = Task { [weak self] in
            for await inbound in stream {
                guard let self else { return }
                switch inbound {
                case let .event(event): self.handle(event)
                case let .state(state, hello): self.update(state: state, hello: hello)
                }
            }
        }
        let connection = self.connection
        Task {
            await connection.setHandlers(
                onEvent: { continuation.yield(.event($0)) },
                onState: { continuation.yield(.state($0, $1)) })
            await connection.start()
        }
    }

    public func stop() {
        let connection = self.connection
        self.pumpTask?.cancel()
        self.pumpTask = nil
        self.prefetchTask?.cancel()
        Task { await connection.stop() }
    }

    public func reconnectIfNeeded() {
        let connection = self.connection
        Task { await connection.reconnectNow() }
    }

    // MARK: State

    private func update(state: ConnectionState, hello: GatewayHello?) {
        self.state = state
        if case let .failed(message) = state { self.lastError = message }
        guard state == .connected, let hello else { return }
        self.hello = hello
        self.lastError = nil
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        self.bootstrapped = false
        async let agents = try? self.connection.request("agents.list", [:])
        async let subscribed = try? self.connection.request(
            "sessions.subscribe",
            ["limit": 300, "ownerFirst": true, "includeArchived": .bool(self.showArchived)],
            timeout: 30)
        if let agents = await agents {
            self.agents = agents["agents"]?.array?.compactMap(AgentSummary.init) ?? []
            self.defaultAgentId = agents["defaultId"]?.text ?? self.agents.first?.id ?? "main"
        }
        if let list = await subscribed?["list"] {
            self.applySnapshot(list)
        } else {
            await self.refreshSessions()
        }
        if let pending = try? await self.connection.request("exec.approval.list", [:]) {
            let items = pending["approvals"]?.array ?? pending["items"]?.array ?? pending.array ?? []
            self.approvals = items.compactMap(ExecApproval.init)
        }
        self.bootstrapped = true
        self.dumpSessionShapesIfRequested()
        Task { await self.loadConfiguredServerNames() }
        if self.selectedKey == nil || self.sessions[self.selectedKey ?? ""] == nil {
            self.selectedKey = self.defaultSessionKey
        }
        for chat in self.chats.values {
            await chat.load(force: true)
        }
        self.startPrefetch()
    }

    /// Quietly caches every chat's full history, most recently active first, so opening any
    /// channel is instant. Chats that haven't changed since they were cached are skipped.
    private func startPrefetch() {
        self.prefetchTask?.cancel()
        self.prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let rows = self?.sessions.values.filter({ !$0.isSubagent }).sorted(by: { $0.activityMs > $1.activityMs })
            else { return }
            for row in rows {
                guard !Task.isCancelled, let self, self.state.isConnected else { return }
                if self.chats[row.key] != nil { continue }
                if let meta = await TranscriptCache.meta(gatewayId: self.id, sessionKey: row.key),
                   meta.complete, let cached = meta.activityMs, cached >= row.activityMs
                {
                    continue
                }
                let store = ChatStore(sessionKey: row.key, agentId: row.agentId, gateway: self, headless: true)
                await store.fillCache()
            }
        }
    }

    public func refreshSessions() async {
        guard let list = try? await self.connection.request("sessions.list", ["limit": 300, "ownerFirst": true], timeout: 30) else {
            return
        }
        self.applySnapshot(list)
    }

    private func applySnapshot(_ list: JSONValue) {
        var next: [String: SessionRow] = [:]
        for row in list["sessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            next[row.key] = row
        }
        self.sessions = next
    }

    private func scheduleRefresh() {
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshSessions()
        }
    }

    var defaultSessionKey: String? {
        let main = self.sessions.values.first { $0.isMain && $0.agentId == self.defaultAgentId }
        return main?.key ?? self.sortedRows.first?.key
    }

    // MARK: Events

    private func handle(_ event: GatewayEvent) {
        let payload = event.payload
        switch event.name {
        case "sessions.changed":
            self.applySessionChange(payload)
        case "chat":
            guard let key = payload["sessionKey"]?.text else { return }
            if let runId = payload["runId"]?.text { self.runSessions[runId] = key }
            self.chats[key]?.handleChat(payload)
            if payload["state"]?.string == "final" {
                self.notifyReply(sessionKey: key, runId: payload["runId"]?.text, snapshot: payload["message"])
            }
        case "agent":
            guard let runId = payload["runId"]?.text else { return }
            let key = payload["sessionKey"]?.text ?? self.runSessions[runId]
            if let key { self.chats[key]?.handleAgent(payload) }
        case "session.message":
            let key = payload["sessionKey"]?.text ?? payload["session"]?["key"]?.text
            if let row = payload["session"].flatMap(SessionRow.init) { self.sessions[row.key] = row }
            if let key { self.chats[key]?.handleSessionMessage(payload) }
        case "exec.approval.requested":
            if let approval = ExecApproval(payload) {
                self.approvals.removeAll { $0.id == approval.id }
                self.approvals.append(approval)
                self.notifier?.notifyApproval(approval, gateway: self)
            }
        case "exec.approval.resolved":
            if let id = payload["id"]?.text ?? payload["request"]?["id"]?.text {
                self.approvals.removeAll { $0.id == id }
            }
        default:
            break
        }
    }

    private func applySessionChange(_ payload: JSONValue) {
        for ancestor in payload["ancestorSessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            self.sessions[ancestor.key] = ancestor
        }
        if let row = payload["session"].flatMap(SessionRow.init) {
            let previous = self.sessions[row.key]
            self.sessions[row.key] = row
            if self.bootstrapped, let previous, !row.isSubagent,
               row.activityMs > previous.activityMs, row.isUnread, !row.hasActiveRun,
               previous.hasActiveRun || !previous.isUnread
            {
                self.notifier?.notifyActivity(row: row, gateway: self)
            }
            return
        }
        let reason = payload["reason"]?.string
        if let key = payload["key"]?.text ?? payload["sessionKey"]?.text, reason == "delete" || reason == "deleted" {
            let removedId = payload["sessionId"]?.text
            if removedId == nil || self.sessions[key]?.sessionId == removedId {
                self.sessions.removeValue(forKey: key)
            }
            return
        }
        self.scheduleRefresh()
    }

    private func notifyReply(sessionKey: String, runId: String?, snapshot: JSONValue?) {
        guard let row = self.sessions[sessionKey], !row.isSubagent else { return }
        let text = snapshot.flatMap { ChatItem($0, fallbackIndex: 0) }?.plainText
        self.notifier?.notifyReply(row: row, text: text ?? row.preview, dedupe: runId, gateway: self)
    }

    func track(runId: String, sessionKey: String) {
        self.runSessions[runId] = sessionKey
    }

    // MARK: Chats

    public func chat(for key: String) -> ChatStore {
        if let existing = self.chats[key] { return existing }
        let store = ChatStore(sessionKey: key, agentId: self.sessions[key]?.agentId, gateway: self)
        self.chats[key] = store
        return store
    }

    private func openChat(_ key: String) async {
        let chat = self.chat(for: key)
        await chat.load()
        await self.markRead(key)
    }

    public func markRead(_ key: String) async {
        guard let row = self.sessions[key], row.isUnread, self.state.isConnected else { return }
        _ = try? await self.connection.request("sessions.patch", ["key": .string(key), "unread": false])
    }

    // MARK: Mutations

    public func createSession(agentId: String?, label: String?, category: String? = nil) async -> String? {
        var params: [String: JSONValue] = ["agentId": .string(agentId ?? self.defaultAgentId)]
        if let label = label?.nilIfEmpty { params["label"] = .string(label) }
        if let category = category?.nilIfEmpty { params["category"] = .string(category) }
        do {
            let result = try await self.connection.request("sessions.create", .object(params), timeout: 30)
            guard let key = result["key"]?.text ?? result["session"]?["key"]?.text else { return nil }
            if let row = result["session"].flatMap(SessionRow.init) {
                self.sessions[key] = row
            } else {
                await self.refreshSessions()
            }
            self.selectedKey = key
            return key
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    public func patch(_ key: String, _ fields: [String: JSONValue]) async {
        var params = fields
        params["key"] = .string(key)
        if fields["archived"] != nil, let sessionId = self.sessions[key]?.sessionId {
            params["expectedSessionId"] = .string(sessionId)
        }
        do {
            _ = try await self.connection.request("sessions.patch", .object(params))
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    public func resolveApproval(_ approval: ExecApproval, decision: String) async {
        do {
            _ = try await self.connection.request(
                "exec.approval.resolve",
                ["id": .string(approval.id), "decision": .string(decision)])
            self.approvals.removeAll { $0.id == approval.id }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    public func update(profile: GatewayProfile) {
        self.profile = profile
    }

    // MARK: Sidebar

    public func agent(_ id: String) -> AgentSummary {
        self.agents.first { $0.id == id } ?? AgentSummary(id: id, name: id == "main" ? "Main" : id.capitalized)
    }

    var sortedRows: [SessionRow] {
        self.sessions.values
            .filter { self.showArchived || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.activityMs > rhs.activityMs
            }
    }

    /// Subagent runs are the agent's own work; their parent chat carries the result.
    public var totalUnread: Int { self.sessions.values.filter { $0.isUnread && !$0.isArchived && !$0.isSubagent }.count }

    public var serverNameOverrides: [String: String] {
        didSet { UserDefaults.standard.set(self.serverNameOverrides, forKey: "pincer.serverNames.\(self.id.uuidString)") }
    }

    /// Server names from the gateway's channel config (e.g. Discord `guilds.<id>.slug`).
    public private(set) var configuredServerNames: [String: String] = [:]

    private func loadConfiguredServerNames() async {
        guard let result = try? await self.connection.request("config.get", [:], timeout: 15) else { return }
        let config = result["resolved"] ?? result["config"] ?? result["parsed"] ?? .null
        var names: [String: String] = [:]
        for (_, channel) in config["channels"]?.object ?? [:] {
            for (id, guild) in channel["guilds"]?.object ?? [:] {
                if let name = (guild["name"]?.text ?? guild["slug"]?.text.map(Self.humanizedSlug))?.nilIfEmpty {
                    names[id] = name
                }
            }
        }
        self.configuredServerNames = names
    }

    static func humanizedSlug(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public func displayName(for server: ChatServer) -> String {
        if let override = self.serverNameOverrides[server.id] { return override }
        if let name = server.name ?? self.configuredServerNames[server.id] { return name }
        let named = self.sessions.values.lazy.compactMap(\.server).first { $0.id == server.id && $0.name != nil }
        return named?.name ?? server.displayName
    }

    public func renameServer(_ server: ChatServer, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        self.serverNameOverrides[server.id] = trimmed.isEmpty ? nil : trimmed
    }

    public func sections(search: String = "") -> [SidebarSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = self.sortedRows.filter { row in
            query.isEmpty || row.title.lowercased().contains(query) || (row.preview?.lowercased().contains(query) ?? false)
        }
        // Subagent sessions become threads under their parent, one level deep.
        let keys = Set(rows.map(\.key))
        var threads: [String: [SessionRow]] = [:]
        var topLevel: [SessionRow] = []
        for row in rows {
            if query.isEmpty, let parent = row.parentCandidates.first(where: keys.contains) {
                threads[parent, default: []].append(row)
            } else {
                topLevel.append(row)
            }
        }
        let channels = topLevel.map { SidebarChannel(row: $0, threads: threads[$0.key] ?? []) }

        switch self.organization {
        case .recent:
            return [SidebarSection(id: "recent", title: "Recent", emoji: nil, channels: channels, kind: .other)]
        case .agent:
            return self.agentSections(channels)
        case .group:
            var sections = self.groupSections(channels.filter { $0.row.category != nil })
            let ungrouped = channels.filter { $0.row.category == nil }
            if !ungrouped.isEmpty {
                sections.append(SidebarSection(id: "group:", title: "Ungrouped", emoji: nil, channels: ungrouped, kind: .other))
            }
            return sections
        case .servers:
            // Agent chats first, then each chat server with its uncategorized channels,
            // then groups, which play the role of Discord categories.
            let grouped = channels.filter { $0.row.category != nil }
            let serverChannels = channels.filter { $0.row.category == nil && $0.row.server != nil }
            let automations = channels.filter { $0.row.category == nil && $0.row.server == nil && $0.row.isAutomation }
            let rest = channels.filter { $0.row.category == nil && $0.row.server == nil && !$0.row.isAutomation }
            var sections = self.agentSections(rest)
            var servers: [ChatServer] = []
            var byServer: [String: [SidebarChannel]] = [:]
            for channel in serverChannels {
                guard let server = channel.row.server else { continue }
                if byServer[server.id] == nil { servers.append(server) }
                byServer[server.id, default: []].append(channel)
            }
            for server in servers.sorted(by: { self.displayName(for: $0) < self.displayName(for: $1) }) {
                sections.append(SidebarSection(
                    id: "server:\(server.provider):\(server.id)",
                    title: self.displayName(for: server),
                    emoji: nil,
                    channels: Self.channelOrder(byServer[server.id] ?? []),
                    kind: .server(server)))
            }
            sections += self.groupSections(grouped).map { section in
                var section = section
                section.channels = Self.channelOrder(section.channels)
                return section
            }
            if !automations.isEmpty {
                sections.append(SidebarSection(id: "automations", title: "Automations", emoji: nil,
                                               channels: Self.channelOrder(automations), kind: .automations))
            }
            return sections
        }
    }

    private func agentSections(_ channels: [SidebarChannel]) -> [SidebarSection] {
        let grouped = Dictionary(grouping: channels, by: { $0.row.agentId })
        let order = self.agents.map(\.id) + grouped.keys.filter { id in !self.agents.contains { $0.id == id } }.sorted()
        return order.compactMap { agentId in
            guard let channels = grouped[agentId], !channels.isEmpty else { return nil }
            let agent = self.agent(agentId)
            return SidebarSection(id: "agent:\(agentId)", title: agent.name, emoji: agent.emoji, channels: channels, kind: .agent(agentId))
        }
    }

    private func groupSections(_ channels: [SidebarChannel]) -> [SidebarSection] {
        let grouped = Dictionary(grouping: channels, by: { $0.row.category ?? "" })
        let names = grouped.keys.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return names.map { name in
            SidebarSection(id: "group:\(name)", title: name, emoji: nil, channels: grouped[name] ?? [], kind: .group(name))
        }
    }

    /// Stable, name-ordered channels like a Discord server; pinned first.
    private static func channelOrder(_ channels: [SidebarChannel]) -> [SidebarChannel] {
        channels.sorted { lhs, rhs in
            if lhs.row.isPinned != rhs.row.isPinned { return lhs.row.isPinned }
            let order = lhs.row.title.localizedCaseInsensitiveCompare(rhs.row.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.row.activityMs > rhs.row.activityMs
        }
    }

    /// Debug aid: `PINCER_DUMP_SESSIONS=/path.json` writes routing/naming fields only (no message text).
    private func dumpSessionShapesIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PINCER_DUMP_SESSIONS"] else { return }
        let fields = ["key", "kind", "label", "displayName", "derivedTitle", "autoLabel", "groupChannel", "space", "subject",
                      "chatType", "channel", "lastChannel", "category", "parentSessionKey", "spawnedBy", "isMain",
                      "createdVia", "spawnDepth", "parentSessionId", "forkedFromParent"]
        let rows: [JSONValue] = self.sessions.values.sorted { $0.key < $1.key }.map { row in
            var object: [String: JSONValue] = [:]
            for field in fields { if let value = row.raw[field] { object[field] = value } }
            if let origin = row.raw["origin"]?.object {
                object["origin"] = .object(origin.filter { ["label", "provider", "surface", "chatType", "threadId", "nativeChannelId"].contains($0.key) })
            }
            return .object(object)
        }
        if let data = try? JSONEncoder().encode(JSONValue.array(rows)) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    public var groupNames: [String] {
        Array(Set(self.sessions.values.compactMap(\.category))).sorted()
    }
}
