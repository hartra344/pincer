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

    public init(id: String, title: String, emoji: String?, channels: [SidebarChannel], kind: Kind) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.channels = channels
        self.kind = kind
    }
}

/// Everything the UI knows about one Gateway ("server" in the rail).
@MainActor
@Observable
public final class GatewayStore: Identifiable {
    public private(set) var profile: GatewayProfile
    public nonisolated let id: UUID
    public private(set) var state: ConnectionState = .idle
    /// Whether this store has ever reached `.connected`, so the UI can tell a first connect
    /// that's still retrying apart from a connection that was lost.
    public private(set) var hasConnected = false
    public private(set) var hello: GatewayHello?
    public private(set) var agents: [AgentSummary] = []
    public private(set) var defaultAgentId = "main"
    public private(set) var sessions: [String: SessionRow] = [:]
    public private(set) var approvals: [ExecApproval] = []
    public private(set) var lastError: String?
    /// `models.list` per agent id, fetched when a model picker opens.
    public private(set) var modelCatalogs: [String: [ModelChoice]] = [:]
    public private(set) var loadingModelCatalogs: Set<String> = []
    /// The model sessions use when nobody picked one (`sessions.list` `defaults`).
    public private(set) var defaultModelRef: String?
    struct CommandCatalog {
        let commands: [SlashCommand]
        let fetchedAt: Date
        let connectionEpoch: Int
    }
    /// `commands.list` per session key.
    private(set) var commandCatalogs: [String: CommandCatalog] = [:]
    @ObservationIgnored private var loadingCommands: Set<String> = []
    /// Bumped on every connect, so catalogs from an earlier connection are refetched.
    @ObservationIgnored private var connectionEpoch = 0
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
    public var showArchived = false {
        didSet {
            guard showArchived != oldValue, self.bootstrapped else { return }
            Task { await self.refreshSessions() }
        }
    }

    @ObservationIgnored let connection: GatewayConnection
    @ObservationIgnored private var chats: [String: ChatStore] = [:]
    @ObservationIgnored private var runSessions: [String: String] = [:]
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var didPickInitialChat = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored weak var notifier: Notifier?
    public let images: ArtifactImageLoader
    public let files: FileContentLoader
    /// Gateway config and plugins; loaded when the settings screen opens.
    @ObservationIgnored public private(set) lazy var settings = GatewaySettingsModel(
        connection: self.connection, scopes: { [weak self] in self?.hello?.scopes ?? [] })
    /// Cron jobs; loaded when the Automations view opens.
    @ObservationIgnored public private(set) lazy var automations = AutomationsModel(
        connection: self.connection, hello: { [weak self] in self?.hello })

    public init(profile: GatewayProfile) {
        self.profile = profile
        self.id = profile.id
        self.connection = GatewayConnection(profile: profile)
        self.organization = SidebarOrganization(
            rawValue: UserDefaults.standard.string(forKey: "pincer.org.v2.\(profile.id.uuidString)") ?? "") ?? .servers
        self.serverNameOverrides = UserDefaults.standard.dictionary(forKey: "pincer.serverNames.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.chatIcons = UserDefaults.standard.dictionary(forKey: "pincer.chatIcons.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.chatColors = UserDefaults.standard.dictionary(forKey: "pincer.chatColors.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.groupPositions = UserDefaults.standard.dictionary(forKey: "pincer.groups.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.groupIcons = UserDefaults.standard.dictionary(forKey: "pincer.groupIcons.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.chatPositions = UserDefaults.standard.dictionary(forKey: "pincer.chatOrder.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.selectedKey = UserDefaults.standard.string(forKey: "pincer.selected.\(profile.id.uuidString)")
        self.sectionCollapse = UserDefaults.standard.dictionary(forKey: "pincer.collapsed.\(profile.id.uuidString)") as? [String: Bool] ?? [:]
        let images = ArtifactImageLoader()
        self.images = images
        self.files = FileContentLoader(images: images)
        images.gateway = self
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
        self.hasConnected = true
        self.hello = hello
        self.connectionEpoch += 1
        self.lastError = nil
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        self.bootstrapped = false
        async let agents = try? self.connection.request("agents.list", [:])
        async let subscribed = try? self.connection.request(
            "sessions.subscribe",
            .object(self.listParams),
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
        Task { await self.pullServerNames() }
        Task { await self.pullChatIcons() }
        Task { await self.pullChatColors() }
        Task { await self.pull(self.syncedMap(Self.chatOrderPref)) }
        Task { await self.pull(self.syncedMap(Self.groupIconsPref)) }
        Task { await self.loadGroups() }
        // Only pick a chat on the first connect: on iPhone, going back to the sidebar clears the
        // selection, and re-selecting on every reconnect would push a chat the user left.
        let selectionGone = self.selectedKey.map { self.sessions[$0] == nil } ?? false
        if selectionGone || (self.selectedKey == nil && !self.didPickInitialChat) {
            self.selectedKey = self.defaultSessionKey
        }
        self.didPickInitialChat = true
        // The open chat first, so it isn't stuck behind every chat visited since launch.
        if let key = self.selectedKey, let open = self.chats[key] {
            await open.load(force: true)
        }
        for chat in self.chats.values where chat.sessionKey != self.selectedKey {
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

    private var listParams: [String: JSONValue] {
        ["limit": 300, "ownerFirst": true, "includeLastMessage": true, "archived": self.showArchived ? "all" : false]
    }

    public func refreshSessions() async {
        guard let list = try? await self.connection.request("sessions.list", .object(self.listParams), timeout: 30) else {
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
        if let defaults = list["defaults"], let model = defaults["model"]?.text {
            self.defaultModelRef = ModelRef.qualified(model, provider: defaults["modelProvider"]?.text)
        }
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
        case "users.prefs.changed":
            let keys = payload["keys"]?.array?.compactMap(\.string)
            for map in self.syncedMaps where keys?.contains(map.pref) ?? true {
                Task { await self.pull(map) }
            }
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
            if let row = payload["session"].flatMap(SessionRow.init) { self.sessions[row.key] = row.keepingPreview(of: self.sessions[row.key]) }
            if let key { self.chats[key]?.handleSessionMessage(payload) }
        case "progressCard.changed":
            guard let key = payload["sessionKey"]?.text else { return }
            for chat in self.chats.values where chat.matchesProgressCardKey(key) {
                chat.handleProgressCardChanged(payload)
            }
        case "exec.approval.requested":
            if let approval = ExecApproval(payload) {
                self.approvals.removeAll { $0.id == approval.id }
                self.approvals.append(approval)
                self.notifier?.notifyApproval(approval, gateway: self)
            }
        case "cron":
            self.automations.handleCronEvent(payload)
        case "plugins.changed":
            self.settings.handlePluginsChanged()
        case "exec.approval.resolved":
            if let id = payload["id"]?.text ?? payload["request"]?["id"]?.text {
                self.approvals.removeAll { $0.id == id }
            }
        default:
            break
        }
    }

    private func applySessionChange(_ payload: JSONValue) {
        if DebugLog.enabled {
            let row = payload["session"]
            let fields = ["pinned", "unread", "color", "category", "label", "archived", "reasoningLevel"]
                .map { "\($0)=\(row?[$0].map { DebugLog.brief(.object(["v": $0])) } ?? "-")" }
            DebugLog.write("← sessions.changed key=\(row?["key"]?.text ?? payload["key"]?.text ?? "?") reason=\(payload["reason"]?.text ?? "-") \(fields.joined(separator: " "))")
        }
        for ancestor in payload["ancestorSessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            self.sessions[ancestor.key] = ancestor.keepingPreview(of: self.sessions[ancestor.key])
        }
        if let row = payload["session"].flatMap(SessionRow.init) {
            let previous = self.sessions[row.key]
            self.sessions[row.key] = row.keepingPreview(of: previous)
            if self.bootstrapped, let previous, !row.isSubagent,
               row.activityMs > previous.activityMs, row.isUnread, !row.hasActiveRun,
               previous.hasActiveRun || !previous.isUnread
            {
                self.notifier?.notifyActivity(row: row, gateway: self)
            }
            return
        }
        let reason = payload["reason"]?.string
        if reason == "groups" {
            Task { await self.loadGroups() }
        }
        if let key = payload["key"]?.text ?? payload["sessionKey"]?.text, reason == "delete" || reason == "deleted" {
            let removedId = payload["sessionId"]?.text
            if removedId == nil || self.sessions[key]?.sessionId == removedId {
                self.sessions.removeValue(forKey: key)
                self.discardDraft(key)
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

    /// Saves every chat's pending draft now, e.g. before the app is suspended.
    func flushDrafts() async {
        for chat in self.chats.values {
            await chat.flushDraft()
        }
    }

    private func discardDraft(_ key: String) {
        if let chat = self.chats[key] {
            chat.draft = ComposerDraft()
        } else {
            let id = self.id
            Task { await DraftStore.remove(gatewayId: id, sessionKey: key) }
        }
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

    /// Loads the models an agent can use. Cached per agent; `refresh` refetches.
    public func loadModels(agentId: String, refresh: Bool = false) async {
        guard self.state.isConnected, refresh || self.modelCatalogs[agentId] == nil,
              self.loadingModelCatalogs.insert(agentId).inserted
        else { return }
        defer { self.loadingModelCatalogs.remove(agentId) }
        do {
            let result = try await self.connection.request("models.list", ["agentId": .string(agentId)], timeout: 30)
            self.modelCatalogs[agentId] = result["models"]?.array?.compactMap(ModelChoice.init) ?? []
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Slash commands for a session (Gateway `commands.list` plus client commands). Falls back to a
    /// built-in list until the Gateway answers, or when it can't list commands.
    public func slashCommands(for sessionKey: String) -> [SlashCommand] {
        SlashCommand.withClientCommands(self.commandCatalogs[sessionKey]?.commands ?? SlashCommand.fallback)
    }

    /// Fetches a session's commands. Plugins, skills and config change what's available, so a
    /// catalog is refetched once it's older than a minute.
    public func loadCommands(sessionKey: String, agentId: String?) async {
        if let cached = self.commandCatalogs[sessionKey], cached.connectionEpoch == self.connectionEpoch,
           Date().timeIntervalSince(cached.fetchedAt) < 60
        {
            return
        }
        guard self.state.isConnected, self.loadingCommands.insert(sessionKey).inserted else { return }
        defer { self.loadingCommands.remove(sessionKey) }
        if let methods = self.hello?.methods, !methods.isEmpty, !methods.contains("commands.list") { return }
        let epoch = self.connectionEpoch
        var params: [String: JSONValue] = ["includeArgs": true, "scope": "text"]
        if let agentId { params["agentId"] = .string(agentId) }
        var result = try? await self.connection.request(
            "commands.list", .object(params.merging(["sessionKey": .string(sessionKey)]) { $1 }), timeout: 15)
        if result == nil {
            // Chats that haven't been written to yet aren't sessions the Gateway can scope to.
            result = try? await self.connection.request("commands.list", .object(params), timeout: 15)
        }
        guard let result, result["commands"]?.array != nil else { return }
        self.commandCatalogs[sessionKey] = CommandCatalog(
            commands: SlashCommand.parse(result), fetchedAt: Date(), connectionEpoch: epoch)
    }

    /// Sets the model new messages in a session use; `nil` goes back to the agent's default.
    /// Messages already written keep the model the Gateway recorded for them.
    public func setModel(_ key: String, to ref: String?) async {
        await self.patch(key, ["model": ref.map(JSONValue.string) ?? .null])
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
        let value = trimmed.isEmpty ? nil : trimmed
        self.serverNameOverrides[server.id] = value
        Task { await self.push(self.syncedMap(Self.serverNamesPref), server.id, value) }
    }

    // MARK: Synced preferences

    /// Server names and chat icons you set live in your gateway user preferences, so every device
    /// signed in as you shows the same ones. The local copy keeps them instant and works offline.
    static let serverNamesPref = "pincer.serverNames"
    /// SF Symbol names by session key. Kept in prefs because `sessions.patch` only accepts
    /// emoji, OpenClaw glyph ids or SVG for a session's `icon`.
    static let chatIconsPref = "pincer.chatIcons"
    /// Custom "#RRGGBB" colors by session key. Kept in prefs because `sessions.patch` only accepts
    /// OpenClaw's named colors for a session's `color`.
    static let chatColorsPref = "pincer.chatColors"
    /// Group names to display positions, for gateways without the `sessions.groups.*` catalog.
    static let groupsPref = "pincer.groups"
    /// Session keys to positions within their group, so chats can be arranged by hand.
    static let chatOrderPref = "pincer.chatOrder"
    /// SF Symbol names by group name. The gateway's group catalog has no icon field.
    static let groupIconsPref = "pincer.groupIcons"

    private struct SyncedMap {
        let pref: String
        let local: ReferenceWritableKeyPath<GatewayStore, [String: String]>
        let syncedDefaultsKey: String
    }

    private var syncedMaps: [SyncedMap] {
        [
            SyncedMap(pref: Self.serverNamesPref, local: \.serverNameOverrides,
                      syncedDefaultsKey: "pincer.serverNamesSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.chatIconsPref, local: \.chatIcons,
                      syncedDefaultsKey: "pincer.chatIconsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.chatColorsPref, local: \.chatColors,
                      syncedDefaultsKey: "pincer.chatColorsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.groupsPref, local: \.groupPositions,
                      syncedDefaultsKey: "pincer.groupsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.chatOrderPref, local: \.chatPositions,
                      syncedDefaultsKey: "pincer.chatOrderSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.groupIconsPref, local: \.groupIcons,
                      syncedDefaultsKey: "pincer.groupIconsSynced.\(self.id.uuidString)"),
        ]
    }

    private func syncedMap(_ pref: String) -> SyncedMap { self.syncedMaps.first { $0.pref == pref }! }

    /// Last values seen on the gateway per pref; missing until a successful read.
    @ObservationIgnored private var remotePrefMaps: [String: [String: String]] = [:]
    @ObservationIgnored private var prefsSupportsExpected = true

    private static func names(from value: JSONValue?) -> [String: String] {
        (value?.object ?? [:]).compactMapValues { $0.string?.nilIfEmpty }
    }

    private static func json(_ names: [String: String]) -> JSONValue {
        .object(names.mapValues(JSONValue.string))
    }

    /// Reads a map from the gateway; `nil` when this connection has no user profile to store it.
    private func fetchRemoteMap(_ pref: String) async -> [String: String]?? {
        guard let result = try? await self.connection.request(
            "users.prefs.get", ["keys": [.string(pref)]], timeout: 15),
            result["status"]?.string == "ok"
        else { return nil }
        let value = result["entries"]?[pref]
        return .some(value == nil || value == .null ? nil : Self.names(from: value))
    }

    func pullServerNames() async { await self.pull(self.syncedMap(Self.serverNamesPref)) }
    func pullChatIcons() async { await self.pull(self.syncedMap(Self.chatIconsPref)) }
    func pullChatColors() async { await self.pull(self.syncedMap(Self.chatColorsPref)) }

    private func pull(_ map: SyncedMap) async {
        guard let fetched = await self.fetchRemoteMap(map.pref) else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: map.syncedDefaultsKey) {
            // First sync from this device: keep values already set here, remote wins on conflicts.
            var merged = self[keyPath: map.local]
            merged.merge(fetched ?? [:]) { _, remote in remote }
            if merged != (fetched ?? [:]) {
                guard await self.writeRemoteMap(map.pref, merged, expected: fetched) else { return }
            }
            defaults.set(true, forKey: map.syncedDefaultsKey)
            self.remotePrefMaps[map.pref] = merged
            self[keyPath: map.local] = merged
            return
        }
        self.remotePrefMaps[map.pref] = fetched ?? [:]
        if self[keyPath: map.local] != fetched ?? [:] { self[keyPath: map.local] = fetched ?? [:] }
    }

    private func push(_ map: SyncedMap, _ id: String, _ value: String?) async {
        await self.push(map, [id: value])
    }

    private func push(_ map: SyncedMap, _ changes: [String: String?]) async {
        guard !changes.isEmpty, UserDefaults.standard.bool(forKey: map.syncedDefaultsKey) else { return }
        // Optimistic write; on a conflict (another device changed it at the same time) re-read and retry.
        for _ in 0..<3 {
            let cached = self.remotePrefMaps[map.pref]
            guard let current = cached == nil ? await self.fetchRemoteMap(map.pref) : .some(cached) else { return }
            var next = current ?? [:]
            for (id, value) in changes { next[id] = value }
            if await self.writeRemoteMap(map.pref, next, expected: current) {
                self.remotePrefMaps[map.pref] = next
                return
            }
            self.remotePrefMaps[map.pref] = nil
        }
    }

    private func writeRemoteMap(_ key: String, _ names: [String: String], expected: [String: String]?) async -> Bool {
        let entries: JSONValue = .object([key: names.isEmpty ? .null : Self.json(names)])
        if self.prefsSupportsExpected {
            let params: JSONValue = ["entries": entries, "expectedEntries": .object([key: expected.map(Self.json) ?? .null])]
            do {
                let result = try await self.connection.request("users.prefs.set", params, timeout: 15)
                return result["status"]?.string == "ok"
            } catch let GatewayError.rpc(_, message, _) where message.contains("expectedEntries") {
                // Older gateways don't accept compare-and-set; fall back to last write wins.
                self.prefsSupportsExpected = false
            } catch {
                return false
            }
        }
        guard let result = try? await self.connection.request("users.prefs.set", ["entries": entries], timeout: 15) else { return false }
        return result["status"]?.string == "ok"
    }

    // MARK: Chat icons

    /// Custom SF Symbol names by session key, synced through `users.prefs` (`pincer.chatIcons`).
    public var chatIcons: [String: String] {
        didSet { UserDefaults.standard.set(self.chatIcons, forKey: "pincer.chatIcons.\(self.id.uuidString)") }
    }

    /// The SF Symbol chosen for a chat, if any. Callers still validate it for the running OS.
    public func customIcon(for key: String) -> String? { self.chatIcons[key] }

    /// Sets (or with `nil`, clears) a chat's icon on every device.
    public func setIcon(_ symbol: String?, for key: String) {
        let value = symbol?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard self.chatIcons[key] != value else { return }
        self.chatIcons[key] = value
        Task { await self.push(self.syncedMap(Self.chatIconsPref), key, value) }
    }

    // MARK: Chat colors

    /// Custom "#RRGGBB" colors by session key, synced through `users.prefs` (`pincer.chatColors`).
    public var chatColors: [String: String] {
        didSet { UserDefaults.standard.set(self.chatColors, forKey: "pincer.chatColors.\(self.id.uuidString)") }
    }

    /// The custom color picked for a chat, if any. It wins over the session's named `color`.
    public func customColor(for key: String) -> String? { self.chatColors[key] }

    /// Sets (or with `nil`, clears) a chat's custom color on every device.
    public func setColor(_ hex: String?, for key: String) {
        let value = hex?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard self.chatColors[key] != value else { return }
        self.chatColors[key] = value
        Task { await self.push(self.syncedMap(Self.chatColorsPref), key, value) }
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
            var sections = self.groupSections(channels.filter { $0.row.category != nil }, includeEmpty: query.isEmpty)
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
            sections += self.groupSections(Self.channelOrder(grouped), includeEmpty: query.isEmpty)
            if !automations.isEmpty {
                sections.append(SidebarSection(id: Self.automationsSectionId, title: "Automations", emoji: nil,
                                               channels: Self.channelOrder(automations), kind: .automations))
            }
            return sections
        }
    }

    /// The `category` value that dropping chat `key` onto `section` should set (`.null` removes
    /// it from its group), or `nil` when that drop wouldn't move the chat anywhere.
    public func groupDropValue(for key: String, onto section: SidebarSection) -> JSONValue? {
        guard let row = self.sessions[key], !row.isSubagent else { return nil }
        switch section.kind {
        case let .group(name):
            return row.category == name ? nil : .string(name)
        case .other where section.id == "group:":
            return row.category == nil ? nil : .null
        case .server, .agent, .automations:
            // Like Discord: a grouped chat can go back to the section it lives in without a group.
            guard self.organization == .servers, row.category != nil,
                  Self.ungroupedHome(of: row) == section.kind else { return nil }
            return .null
        case .other:
            return nil
        }
    }

    /// Returns true if the drop changed a chat's group.
    @discardableResult
    public func moveToGroup(_ key: String, droppedOn section: SidebarSection) async -> Bool {
        guard let value = self.groupDropValue(for: key, onto: section) else { return false }
        if case let .group(name) = section.kind {
            await self.moveChat(key, toGroup: name, before: nil)
            return true
        }
        if let old = self.sessions[key]?.category { self.registerGroups([old]) }
        if self.chatPositions[key] != nil {
            self.chatPositions[key] = nil
            Task { await self.push(self.syncedMap(Self.chatOrderPref), key, nil) }
        }
        await self.patch(key, ["category": value])
        return true
    }

    private static func ungroupedHome(of row: SessionRow) -> SidebarSection.Kind {
        if let server = row.server { return .server(server) }
        if row.isAutomation { return .automations }
        return .agent(row.agentId)
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

    /// One section per group, in the catalog's order. Empty groups stay until they're deleted;
    /// chats arranged by hand come first in their order, the rest keep the order they came in.
    private func groupSections(_ channels: [SidebarChannel], includeEmpty: Bool) -> [SidebarSection] {
        let grouped = Dictionary(grouping: channels, by: { $0.row.category ?? "" })
        return self.groupNames.compactMap { name in
            let members = grouped[name] ?? []
            guard includeEmpty || !members.isEmpty else { return nil }
            return SidebarSection(id: "group:\(name)", title: name, emoji: nil, channels: self.arranged(members), kind: .group(name))
        }
    }

    private func arranged(_ channels: [SidebarChannel]) -> [SidebarChannel] {
        let positioned = channels.compactMap { channel in self.chatPositions[channel.id].flatMap(Int.init).map { (channel, $0) } }
        let rest = channels.filter { self.chatPositions[$0.id].flatMap(Int.init) == nil }
        return positioned.sorted { $0.1 < $1.1 }.map(\.0) + rest
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

    // MARK: Groups

    /// Every group in display order: the catalog, then any category a chat has that isn't in it.
    public var groupNames: [String] {
        let catalog = self.usesGroupCatalog
            ? self.groupCatalog
            : self.groupPositions.sorted { lhs, rhs in
                let (l, r) = (Int(lhs.value) ?? .max, Int(rhs.value) ?? .max)
                return l != r ? l < r : lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }.map(\.key)
        let known = Set(catalog)
        let extra = Set(self.sessions.values.compactMap(\.category)).subtracting(known)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return catalog + extra
    }

    /// The gateway's custom group catalog (`sessions.groups.list`), in display order.
    public private(set) var groupCatalog: [String] = []
    @ObservationIgnored private var groupCatalogUnsupported = false

    /// Fallback for gateways without the catalog: group names to positions, synced through `users.prefs`.
    public var groupPositions: [String: String] {
        didSet { UserDefaults.standard.set(self.groupPositions, forKey: "pincer.groups.\(self.id.uuidString)") }
    }

    /// SF Symbol names by group name, synced through `users.prefs` (`pincer.groupIcons`).
    public var groupIcons: [String: String] {
        didSet { UserDefaults.standard.set(self.groupIcons, forKey: "pincer.groupIcons.\(self.id.uuidString)") }
    }

    /// The SF Symbol chosen for a group, if any. Callers still validate it for the running OS.
    public func groupIcon(for name: String) -> String? { self.groupIcons[name] }

    /// Sidebar sections the reader expanded or collapsed, by section id. Sections without an
    /// entry start expanded, except Automations, which starts collapsed.
    public private(set) var sectionCollapse: [String: Bool] {
        didSet { UserDefaults.standard.set(self.sectionCollapse, forKey: "pincer.collapsed.\(self.id.uuidString)") }
    }

    public var collapsedSections: Set<String> {
        var ids = Set(self.sectionCollapse.filter(\.value).keys)
        if self.sectionCollapse[Self.automationsSectionId] == nil { ids.insert(Self.automationsSectionId) }
        return ids
    }

    public func setSectionCollapsed(_ id: String, _ collapsed: Bool) {
        guard self.collapsedSections.contains(id) != collapsed else { return }
        self.sectionCollapse[id] = collapsed
    }

    static let automationsSectionId = "automations"

    /// Sets (or with `nil`, clears) a group's icon on every device.
    public func setGroupIcon(_ symbol: String?, for name: String) {
        let value = symbol?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard self.groupIcons[name] != value else { return }
        self.groupIcons[name] = value
        Task { await self.push(self.syncedMap(Self.groupIconsPref), name, value) }
    }

    /// Carries a group's icon over to its new name (or drops it with `nil`).
    private func moveGroupIcon(from name: String, to newName: String?) {
        guard let icon = self.groupIcons[name] else { return }
        var changes: [String: String?] = [name: String?.none]
        if let newName, self.groupIcons[newName] == nil { changes[newName] = icon }
        for (key, value) in changes { self.groupIcons[key] = value }
        Task { await self.push(self.syncedMap(Self.groupIconsPref), changes) }
    }

    /// Session keys to their position within their group, synced through `users.prefs`.
    public var chatPositions: [String: String] {
        didSet { UserDefaults.standard.set(self.chatPositions, forKey: "pincer.chatOrder.\(self.id.uuidString)") }
    }

    /// Whether groups live in the gateway's catalog. Gateways that don't list their methods get a try.
    var usesGroupCatalog: Bool {
        guard !self.groupCatalogUnsupported else { return false }
        let methods = self.hello?.methods ?? []
        return methods.isEmpty || methods.contains("sessions.groups.put")
    }

    func loadGroups() async {
        if self.usesGroupCatalog {
            do {
                let result = try await self.connection.request("sessions.groups.list", [:], timeout: 15)
                self.applyGroupCatalog(result)
                return
            } catch GatewayError.rpc {
                self.groupCatalogUnsupported = true
            } catch {
                return
            }
        }
        await self.pull(self.syncedMap(Self.groupsPref))
        // Chats already in a group keep it listed once they leave it.
        self.registerGroups(Set(self.sessions.values.compactMap(\.category)))
    }

    private func applyGroupCatalog(_ result: JSONValue) {
        guard let groups = result["groups"]?.array else { return }
        let names = groups.enumerated().compactMap { index, group -> (String, Int)? in
            guard let name = group["name"]?.text?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
            return (name, group["position"]?.int ?? index)
        }
        let ordered = names.sorted { $0.1 < $1.1 }.map(\.0)
        if ordered != self.groupCatalog { self.groupCatalog = ordered }
    }

    /// Adds groups to the fallback list so they stay after their last chat leaves.
    private func registerGroups(_ names: Set<String>) {
        guard !self.usesGroupCatalog else { return }
        let missing = names.subtracting(self.groupPositions.keys).sorted()
        guard !missing.isEmpty else { return }
        let next = (self.groupPositions.values.compactMap { Int($0) }.max() ?? -1) + 1
        let changes = Dictionary(uniqueKeysWithValues: missing.enumerated().map { ($1, String(next + $0)) })
        self.groupPositions.merge(changes) { $1 }
        Task { await self.push(self.syncedMap(Self.groupsPref), changes) }
    }

    /// Replaces the group order; with the catalog this is also how groups are created.
    private func setGroupOrder(_ names: [String]) async -> Bool {
        if self.usesGroupCatalog {
            let previous = self.groupCatalog
            self.groupCatalog = names
            do {
                let result = try await self.connection.request("sessions.groups.put", ["names": .array(names.map(JSONValue.string))], timeout: 15)
                self.applyGroupCatalog(result)
                return true
            } catch {
                self.groupCatalog = previous
                self.lastError = error.localizedDescription
                await self.loadGroups()
                return false
            }
        }
        var changes: [String: String?] = [:]
        for (index, name) in names.enumerated() where self.groupPositions[name] != String(index) {
            changes[name] = String(index)
        }
        for name in self.groupPositions.keys where !names.contains(name) {
            changes[name] = .some(nil)
        }
        for (name, value) in changes { self.groupPositions[name] = value }
        await self.push(self.syncedMap(Self.groupsPref), changes)
        return true
    }

    /// Creates an empty group at the end. Returns false if the name is empty or already taken.
    @discardableResult
    public func createGroup(_ name: String) async -> Bool {
        let value = name.trimmingCharacters(in: .whitespaces)
        let names = self.groupNames
        guard !value.isEmpty, !names.contains(value) else { return false }
        return await self.setGroupOrder(names + [value])
    }

    /// Moves a group before another one (`nil` moves it to the end).
    public func moveGroup(_ name: String, before: String?) async {
        var names = self.groupNames
        guard names.contains(name), name != before else { return }
        names.removeAll { $0 == name }
        let index = before.flatMap { names.firstIndex(of: $0) } ?? names.count
        names.insert(name, at: index)
        guard names != self.groupNames else { return }
        _ = await self.setGroupOrder(names)
    }

    /// Renames a group; its chats move with it.
    public func renameGroup(_ name: String, to newName: String) async {
        let value = newName.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != name else { return }
        if self.usesGroupCatalog {
            let previous = self.groupCatalog
            if self.groupCatalog.contains(value) {
                self.groupCatalog.removeAll { $0 == name }
            } else {
                self.groupCatalog = self.groupCatalog.map { $0 == name ? value : $0 }
            }
            do {
                let result = try await self.connection.request("sessions.groups.rename", ["name": .string(name), "to": .string(value)], timeout: 30)
                self.applyGroupCatalog(result)
                self.moveGroupIcon(from: name, to: value)
                return
            } catch {
                self.groupCatalog = previous
                self.lastError = error.localizedDescription
                await self.loadGroups()
                return
            }
        }
        self.moveGroupIcon(from: name, to: value)
        var changes: [String: String?] = [name: String?.none]
        if self.groupPositions[value] == nil { changes[value] = self.groupPositions[name] ?? String(self.groupPositions.count) }
        for (key, change) in changes { self.groupPositions[key] = change }
        Task { await self.push(self.syncedMap(Self.groupsPref), changes) }
        for key in self.memberKeys(of: name) {
            await self.patch(key, ["category": .string(value)])
        }
    }

    /// Deletes a group. Its chats stay, without a group.
    public func deleteGroup(_ name: String) async {
        if self.usesGroupCatalog {
            let previous = self.groupCatalog
            self.groupCatalog.removeAll { $0 == name }
            do {
                let result = try await self.connection.request("sessions.groups.delete", ["name": .string(name)], timeout: 30)
                self.applyGroupCatalog(result)
                self.moveGroupIcon(from: name, to: nil)
                return
            } catch {
                self.groupCatalog = previous
                self.lastError = error.localizedDescription
                await self.loadGroups()
                return
            }
        }
        self.groupPositions[name] = nil
        Task { await self.push(self.syncedMap(Self.groupsPref), name, nil) }
        self.moveGroupIcon(from: name, to: nil)
        for key in self.memberKeys(of: name) {
            await self.patch(key, ["category": .null])
        }
    }

    private func memberKeys(of group: String) -> [String] {
        self.sessions.values.filter { $0.category == group }.map(\.key)
    }

    /// Chats of a group in the order the sidebar shows them.
    public func groupOrder(_ name: String) -> [String] {
        let rows = self.sortedRows.filter { $0.category == name && !$0.isSubagent }
        let channels = rows.map { SidebarChannel(row: $0, threads: []) }
        return self.arranged(self.organization == .servers ? Self.channelOrder(channels) : channels).map(\.row.key)
    }

    /// Puts a chat in a group before another of its chats (`nil` puts it last), moving it
    /// there first if it's in another group.
    public func moveChat(_ key: String, toGroup name: String, before: String?) async {
        guard let row = self.sessions[key], !row.isSubagent, key != before else { return }
        var order = self.groupOrder(name).filter { $0 != key }
        let index = before.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(key, at: index)
        var changes: [String: String?] = [:]
        for (position, key) in order.enumerated() where self.chatPositions[key] != String(position) {
            changes[key] = String(position)
        }
        for (key, value) in changes { self.chatPositions[key] = value }
        Task { await self.push(self.syncedMap(Self.chatOrderPref), changes) }
        if row.category != name {
            self.registerGroups(Set([name] + (row.category.map { [$0] } ?? [])))
            await self.patch(key, ["category": .string(name)])
        }
    }
}
