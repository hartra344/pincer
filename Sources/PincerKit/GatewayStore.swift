import Foundation
import Observation

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
    /// The host name this gateway last reported for itself (`GatewayHello.gatewayHost`), kept so
    /// links and Handoff from other devices find it before it has connected (#375).
    public private(set) var gatewayHost: String?
    public private(set) var agents: [AgentSummary] = []
    public private(set) var defaultAgentId = "main"
    /// Session rows by key. Writes that change nothing are dropped, so they don't invalidate every
    /// view reading the list (sidebar, open chats) or clear the cached subagent trees.
    public private(set) var sessions: [String: SessionRow] {
        get {
            self.access(keyPath: \.sessions)
            return self.sessionStorage
        }
        set {
            guard newValue != self.sessionStorage else { return }
            self.withMutation(keyPath: \.sessions) { self.sessionStorage = newValue }
            self.sessionsDidChange()
            for (key, chat) in self.chats { chat.syncSessionRow(newValue[key]) }
        }
    }

    /// Writes one row (nil removes it) in place, skipping it when nothing changed. Cheaper than
    /// `sessions[key] = row`, which copies and compares the whole list.
    func setSession(_ row: SessionRow?, for key: String) {
        guard self.sessionStorage[key] != row else { return }
        self.withMutation(keyPath: \.sessions) { self.sessionStorage[key] = row }
        self.sessionsDidChange()
        self.chats[key]?.syncSessionRow(row)
    }

    private func sessionsDidChange() {
        self.sortedRowsCache = nil
        self.subagentTrees = [:]
        self.settleRunTimeline()
        self.markVisibleChatsRead()
    }
    /// The chat each viewer (the main window, later chat windows) shows on screen right now, in an
    /// active, focused scene. See `setVisibleChat(_:viewer:)`.
    @ObservationIgnored var visibleChatsByViewer: [String: String] = [:]
    /// Keys with a `sessions.patch unread=false` in flight, so a burst of row changes sends one.
    @ObservationIgnored var markingRead: Set<String> = []
    /// Visible keys that changed while their patch was in flight; checked again once it lands.
    @ObservationIgnored var recheckRead: Set<String> = []
    @ObservationIgnored private var sessionStorage: [String: SessionRow] = [:]
    @ObservationIgnored var sortedRowsCache: [SessionRow]?
    /// `subagentTree(rootKey:)` per root and connection state, until the rows change.
    @ObservationIgnored var subagentTrees: [String: SubagentTree] = [:]
    /// Streamed run activity, read through `runTimeline`; bumping the revision publishes it.
    @ObservationIgnored var runTimelineState = RunTimeline()
    var runTimelineRevision = 0
    public private(set) var approvals: [ExecApproval] = []
    /// Pending agent questions (`ask_user`), oldest first.
    public private(set) var questions: [QuestionPrompt] = []
    public internal(set) var lastError: String?
    /// `models.list` per agent id, fetched when a model picker opens.
    public private(set) var modelCatalogs: [String: [ModelChoice]] = [:]
    public private(set) var loadingModelCatalogs: Set<String> = []
    /// The model sessions use when nobody picked one (`sessions.list` `defaults`).
    public private(set) var defaultModelRef: String?
    /// Context window sessions get when their row doesn't say (`sessions.list` `defaults.contextTokens`).
    public private(set) var defaultContextTokens: Int?
    struct CommandCatalog {
        let commands: [SlashCommand]
        let fetchedAt: Date
        let connectionEpoch: Int
    }
    /// `commands.list` per session key.
    private(set) var commandCatalogs: [String: CommandCatalog] = [:]
    @ObservationIgnored private var loadingCommands: Set<String> = []
    /// Bumped on every connect, so catalogs from an earlier connection are refetched.
    @ObservationIgnored private(set) var connectionEpoch = 0
    public var selectedKey: String? {
        didSet {
            guard oldValue != self.selectedKey else { return }
            if let oldValue, let left = self.chats[oldValue] { Task { await left.trimToWindow() } }
            guard let key = self.selectedKey else { return }
            self.defaults.set(key, forKey: "pincer.selected.\(self.id.uuidString)")
            self.noteSelected(key)
            Task { await self.openChat(key) }
        }
    }
    public var organization: SidebarOrganization {
        didSet { self.defaults.set(self.organization.rawValue, forKey: "pincer.org.v2.\(self.id.uuidString)") }
    }
    public var showArchived = false {
        didSet {
            if showArchived != oldValue { self.sortedRowsCache = nil }
            guard showArchived != oldValue, self.bootstrapped else { return }
            Task { await self.refreshSessions() }
        }
    }
    public var showAutomations: Bool {
        didSet {
            guard showAutomations != oldValue else { return }
            self.defaults.set(self.showAutomations, forKey: "pincer.showAutomations.\(self.id.uuidString)")
        }
    }
    public var showSlashCommands: Bool {
        didSet {
            guard showSlashCommands != oldValue else { return }
            self.defaults.set(self.showSlashCommands, forKey: "pincer.showSlashCommands.\(self.id.uuidString)")
        }
    }

    /// Messages written while offline or that failed to send, across this Gateway's chats.
    public internal(set) var outbox = Outbox() {
        didSet { if self.outbox != oldValue { self.outboxChanged(from: oldValue) } }
    }
    /// Attachment bytes of outbox entries, kept for the current launch only.
    @ObservationIgnored var outboxAttachments: [String: [OutgoingAttachment]] = [:]
    @ObservationIgnored var outboxLoaded = false
    @ObservationIgnored var outboxFlushing = false
    @ObservationIgnored var outboxSaveTask: Task<Void, Never>?

    @ObservationIgnored let connection: GatewayConnection
    @ObservationIgnored internal(set) var chats: [String: ChatStore] = [:]
    @ObservationIgnored private var runSessions: [String: String] = [:]
    @ObservationIgnored private(set) var bootstrapped = false
    @ObservationIgnored private var didPickInitialChat = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// Background full-history fills, one per chat, shared by the prefetch and the open chat.
    @ObservationIgnored private var headlessFills: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// How many background fills actually started per chat (tests).
    @ObservationIgnored var headlessFillStarts: [String: Int] = [:]
    /// Bumped when a chat's cached transcript is removed or rewritten by the Gateway, so a fill that
    /// began before can't save its stale history over the new one.
    @ObservationIgnored private var cacheGenerations: [String: Int] = [:]
    /// Whether the app is in the foreground, set from `AppModel.appIsActive`. Background prefetch
    /// stops while it's false and starts again on resume.
    public var appIsActive = true {
        didSet {
            if self.appIsActive, !oldValue, self.state.isConnected { self.startPrefetch() }
            if !self.appIsActive, oldValue { self.prefetchTask?.cancel() }
        }
    }
    /// Most chats one prefetch run fetches, so a big account isn't paged through all at once.
    static let prefetchBudget = 40
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// When a failed search last asked for the index to be rebuilt; searches that keep failing
    /// don't keep rebuilding it (each rebuild re-runs the search).
    @ObservationIgnored private var lastFailureReconcile: ContinuousClock.Instant?
    /// Full-text index of this Gateway's cached transcripts, for message search.
    /// Where this Gateway's transcripts and search index are cached; tests give each store its own folder.
    @ObservationIgnored var cacheRoot: URL? = TranscriptCache.root
    public var messageIndex: MessageIndex { MessageIndex.shared(gatewayId: self.id, root: self.cacheRoot) }
    /// Whether message search is ready, still indexing cached chats, or off (no transcript cache).
    public private(set) var messageIndexProgress: MessageIndex.Status = .ready
    @ObservationIgnored weak var notifier: Notifier?
    /// Approvals this session settled (answered, expired or answered elsewhere), so a later duplicate
    /// action is a no-op rather than another RPC and follow-up.
    @ObservationIgnored private var answeredApprovals: Set<String> = []
    @ObservationIgnored private var resolvingApprovals: [String: Task<ApprovalOutcome, Never>] = [:]
    public let images: ArtifactImageLoader
    public let files: FileContentLoader
    /// Gateway config and plugins; loaded when the settings screen opens.
    @ObservationIgnored public private(set) lazy var settings: GatewaySettingsModel = {
        let settings = GatewaySettingsModel(connection: self.connection, scopes: { [weak self] in self?.hello?.scopes ?? [] },
                                            rootWritableWithoutAdmin: self.profile.isDemo ? "mcp" : nil)
        settings.onRestartRequired = { [weak self] reason in self?.health.markRestartRequired(reason) }
        return settings
    }()
    /// Cron jobs; loaded when the Automations view opens.
    @ObservationIgnored public private(set) lazy var automations = AutomationsModel(
        connection: self.connection, hello: { [weak self] in self?.hello })
    /// Past approval decisions; loaded when Approval History opens.
    @ObservationIgnored public private(set) lazy var approvalHistory = ApprovalHistoryModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        localDeviceId: self.profile.isDemo ? DemoGateway.deviceId : self.deviceId)
    /// The Gateway's recent log lines (memory only); polled while Gateway Logs is showing.
    @ObservationIgnored public private(set) lazy var gatewayLogs = GatewayLogsModel(
        connection: self.connection, hello: { [weak self] in self?.hello })
    /// Command Policy (the exec approvals file); loaded when its page opens. The demo may write
    /// it without `operator.admin`.
    @ObservationIgnored public private(set) lazy var execPolicy = ExecPolicyModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        allowsWritesWithoutAdmin: self.profile.isDemo)
    /// Creating, editing and deleting agents, and their workspace files. The demo may write
    /// without `operator.admin`. Every agent mutation re-fetches `agents.list`.
    @ObservationIgnored public private(set) lazy var agentManagement = AgentManagementModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        allowsWritesWithoutAdmin: self.profile.isDemo,
        onAgentsChanged: { [weak self] in await self?.agentsDidChange() })
    /// Skills (`skills.*`): the per-agent list, ClawHub search, installs and config. The demo may
    /// write without `operator.admin`.
    @ObservationIgnored public private(set) lazy var skills = SkillsModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        allowsWritesWithoutAdmin: self.profile.isDemo)
    /// MCP Servers: the server list (through the shared settings draft), live state and OAuth
    /// sign-in. The demo may write without `operator.admin`.
    @ObservationIgnored public private(set) lazy var mcp = MCPServersModel(
        settings: self.settings, connection: self.connection, hello: { [weak self] in self?.hello },
        sessionKey: { [weak self] in self?.defaultSessionKey }, allowsWritesWithoutAdmin: self.profile.isDemo)
    /// Gateway Settings → Sessions: every session with previews, details, bulk archive/delete and
    /// branch tools. The demo may write without `operator.admin`.
    @ObservationIgnored public private(set) lazy var sessionManager = SessionManagerModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        allowsWritesWithoutAdmin: self.profile.isDemo,
        onTranscriptChanged: { [weak self] key, change in await self?.transcriptChanged(key: key, change: change) },
        onSessionsChanged: { [weak self] in await self?.refreshSessions() })
    /// Token and cost usage; loaded when the Usage page opens.
    @ObservationIgnored public private(set) lazy var usage = UsageModel(
        connection: self.connection, hello: { [weak self] in self?.hello })
    /// Pending DM pairing requests from channels; loaded when Gateway Settings opens.
    @ObservationIgnored public private(set) lazy var pairingInbox = PairingInboxModel(
        connection: self.connection, hello: { [weak self] in self?.hello })
    /// Health, uptime, connected clients and restart; seeded from every hello and kept current by events.
    /// Built in `init`, not lazily, so reading it from a view body (the menu bar item, #119) never
    /// creates it or wires up its callbacks mid-update.
    @ObservationIgnored public let health: GatewayHealthModel
    /// Channel Status: each channel account's state and its lifecycle (start, stop, log out, reconnect,
    /// QR login). Built in `init` like `health`: Gateway Health's context menu reads it. The demo may
    /// run lifecycle actions without `operator.admin`.
    @ObservationIgnored public let channels: ChannelsModel
    /// Paired operator devices, pending device requests and nodes (`device.pair.*`, `node.*`); seeded
    /// when Gateway Settings opens and kept current by pairing events. Built in `init` so the sidebar
    /// badge never creates it from a view body (#119). The demo may manage without `operator.admin`.
    @ObservationIgnored public let devices: DeviceManagementModel

    /// The first-run setup wizard (Set Up Gateway…); offered after the first successful connection.
    @ObservationIgnored public private(set) lazy var setup: SetupWizardModel = {
        let connection = self.connection
        let environment = SetupWizardModel.Environment(
            request: { method, params in try await connection.request(method, params, timeout: 150) },
            // Real scopes only: the demo's simulated restart doesn't grant setup changes.
            hasAdmin: { [weak self] in self?.hello?.scopes.contains(GatewayConnection.adminScope) ?? false },
            methods: { [weak self] in self?.hello?.methods },
            agentStatus: { [weak self] in
                guard let self else { return .notChecked(nil) }
                return SetupRules.agent(agents: self.agents, defaultAgentId: self.defaultAgentId,
                                        defaultModelRef: self.defaultModelRef, loaded: self.hello != nil)
            },
            refresh: { [weak self] in
                guard let self else { return }
                async let health: Void = self.health.load()
                async let agents: Void = self.reloadAgents()
                _ = await (health, agents)
            })
        let model = SetupWizardModel(gatewayId: self.id, isDemo: self.profile.isDemo, defaults: self.defaults,
                                     connectedBefore: self.connectedBeforeSetup, environment: environment)
        // The demo never offers setup on its own; Try the Demo lands in the chat list (`AppModel.openDemo`).
        model.autoOffers = !self.profile.isDemo
        return model
    }()
    /// This gateway connected before the wizard existed (it has a saved chat selection).
    @ObservationIgnored private let connectedBeforeSetup: Bool

    /// Where per-gateway sidebar and selection preferences persist.
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let identity: DeviceIdentity

    public convenience init(profile: GatewayProfile) {
        self.init(profile: profile, defaults: .standard, identity: .loadOrCreate())
    }

    /// A store keeping its device settings in `defaults`, so checks running side by side don't
    /// share `UserDefaults.standard`.
    public convenience init(profile: GatewayProfile, defaults: UserDefaults) {
        self.init(profile: profile, defaults: defaults, identity: .loadOrCreate())
    }

    init(profile: GatewayProfile, defaults: UserDefaults, identity: DeviceIdentity) {
        self.profile = profile
        self.id = profile.id
        self.defaults = defaults
        // The demo's chats are always at hand, so its search works even with the cache off.
        if profile.isDemo { MessageIndex.allowInMemory(gatewayId: profile.id) }
        self.messageIndexProgress = MessageIndex.status(gatewayId: profile.id)
        self.identity = identity
        self.connection = GatewayConnection(profile: profile, identity: identity)
        self.gatewayHost = profile.isDemo ? nil : defaults.string(forKey: Self.gatewayHostKey(profile.id))
        self.organization = SidebarOrganization(
            rawValue: defaults.string(forKey: "pincer.org.v2.\(profile.id.uuidString)") ?? "") ?? .servers
        self.showAutomations = defaults.bool(forKey: "pincer.showAutomations.\(profile.id.uuidString)")
        self.showSlashCommands = defaults.bool(forKey: "pincer.showSlashCommands.\(profile.id.uuidString)")
        self.serverNameOverrides = defaults.dictionary(forKey: "pincer.serverNames.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.chatIcons = defaults.dictionary(forKey: "pincer.chatIcons.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.chatColors = defaults.dictionary(forKey: "pincer.chatColors.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.groupPositions = defaults.dictionary(forKey: "pincer.groups.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.groupIcons = defaults.dictionary(forKey: "pincer.groupIcons.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.chatPositions = defaults.dictionary(forKey: "pincer.chatOrder.\(profile.id.uuidString)") as? [String: String] ?? [:]
        self.reactions = ReactionStore(gatewayId: profile.id.uuidString, defaults: defaults).load()
        self.healthDismissals = defaults.dictionary(forKey: "pincer.healthDismissals.\(profile.id.uuidString)") as? [String: String] ?? [:]
        // Before this Gateway's first sync, start from the choices already made on this device.
        self.avatarChoices = defaults.dictionary(forKey: "pincer.avatars.\(profile.id.uuidString)") as? [String: String]
            ?? AvatarPreferences.local(in: defaults)
        self.selectedKey = defaults.string(forKey: "pincer.selected.\(profile.id.uuidString)")
        self.connectedBeforeSetup = defaults.string(forKey: "pincer.selected.\(profile.id.uuidString)") != nil
        self.sectionCollapse = defaults.dictionary(forKey: "pincer.collapsed.\(profile.id.uuidString)") as? [String: Bool] ?? [:]
        let images = ArtifactImageLoader()
        self.images = images
        self.files = FileContentLoader(images: images)
        let connection = self.connection
        self.health = GatewayHealthModel(
            connection: connection, hello: { nil },
            localDeviceId: profile.isDemo ? DemoGateway.deviceId : identity.deviceId,
            simulatedRestart: profile.isDemo, quietsInitialIssues: profile.isDemo)
        self.devices = DeviceManagementModel(
            connection: connection, selfDeviceId: profile.isDemo ? DemoGateway.deviceId : identity.deviceId,
            allowsWritesWithoutAdmin: profile.isDemo)
        self.channels = ChannelsModel(connection: connection, hello: { nil }, allowsWritesWithoutAdmin: profile.isDemo)
        images.gateway = self
        self.startMemoryPressureMonitor()
        self.health.hello = { [weak self] in self?.hello }
        self.devices.bind(hello: { [weak self] in self?.hello })
        self.channels.methods = { [weak self] in self?.hello?.methods }
        self.channels.scopes = { [weak self] in self?.hello?.scopes ?? [] }
        // A lifecycle change shows up in `health` too, so its channel issue clears (or appears).
        self.channels.onChanged = { [weak self] in await self?.health.refresh() }
        self.channels.fallbackChannels = { [weak self] in self?.health.health?.channels ?? [] }
        self.health.onRestarted = { [weak self] in
            guard let self, self.settings.hasLoaded else { return }
            Task { await self.settings.load() }
        }
        self.health.dismissals = self.healthDismissals
        self.health.onDismissalsChanged = { [weak self] changes in self?.applyHealthDismissals(changes) }
    }

    public var deviceId: String { self.identity.deviceId }

    private enum Inbound: Sendable {
        case event(GatewayEvent)
        case state(ConnectionState, GatewayHello?)
    }

    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var eventBuffer: CoalescingEventBuffer<Inbound>?

    public func start() {
        guard self.pumpTask == nil else { return }
        Task { await self.loadOutbox() }
        // A single ordered stream keeps chat deltas and state changes in wire order.
        let stream = CoalescingEventBuffer<Inbound> {
            if case let .event(event) = $0 { return event.coalescingKey }
            return nil
        }
        self.eventBuffer = stream
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
                onEvent: { stream.yield(.event($0)) },
                onState: { stream.yield(.state($0, $1)) })
            await connection.start()
        }
    }

    public func stop() {
        let connection = self.connection
        self.pumpTask?.cancel()
        self.pumpTask = nil
        self.eventBuffer?.finish()
        self.eventBuffer = nil
        self.prefetchTask?.cancel()
        for fill in self.headlessFills.values { fill.task.cancel() }
        self.reconcileTask?.cancel()
        self.bootstrapTask?.cancel()
        self.bootstrapTask = nil
        Task { await connection.stop() }
    }

    /// Returns once the background history prefetch has finished and its writes have landed, so a
    /// check can clear a cached chat without it being saved back.
    public func settlePrefetch() async {
        await self.prefetchTask?.value
        for fill in self.headlessFills.values { await fill.task.value }
        await TranscriptCache.flush(gatewayId: self.id, root: self.cacheRoot)
    }

    /// `stop()` for a store that won't be started again, returning once the connection is torn
    /// down and its chats' last cache writes and search indexing have landed.
    public func stopAndFlushCache() async {
        self.stop()
        await self.connection.stop()
        for chat in self.chats.values { await chat.finishCaching() }
        await TranscriptCache.flush(gatewayId: self.id, root: self.cacheRoot)
    }

    /// Whether this connection can see and answer agent questions (`operator.questions`).
    public var canAnswerQuestions: Bool { self.hello?.canAnswerQuestions ?? false }

    /// Reconnects asking for `operator.questions` again, once its upgrade was approved on the host.
    public func retryQuestionAccess() {
        let connection = self.connection
        Task { await connection.retryWithheldScopes() }
    }

    public func reconnectIfNeeded() {
        let connection = self.connection
        Task { await connection.reconnectNow() }
    }

    // MARK: State

    static func gatewayHostKey(_ id: UUID) -> String { "pincer.gatewayHost.\(id.uuidString)" }

    /// Drops the saved host name, for a gateway being removed.
    func forgetGatewayHost() {
        self.gatewayHost = nil
        self.defaults.removeObject(forKey: Self.gatewayHostKey(self.id))
    }

    private func update(state: ConnectionState, hello: GatewayHello?) {
        self.state = state
        if case let .failed(message) = state { self.lastError = message }
        if !state.isConnected {
            self.pairingInbox.reset()
            self.outbox.connectionLost()
            self.channels.disconnected()
            self.devices.reset()
        }
        guard state == .connected, let hello else {
            self.health.connectionChanged(state, hello: nil)
            return
        }
        self.hasConnected = true
        self.hello = hello
        if !self.profile.isDemo, let host = hello.gatewayHost, host != self.gatewayHost {
            self.gatewayHost = host
            self.defaults.set(host, forKey: Self.gatewayHostKey(self.id))
        }
        self.images.retryUnavailable()
        self.health.connectionChanged(state, hello: hello)
        self.connectionEpoch += 1
        self.replyToUnsupported = false
        self.reactionForwardingOff = []
        self.reactionNoticeShown = []
        self.lastError = nil
        self.bootstrapTask?.cancel()
        let epoch = self.connectionEpoch
        self.bootstrapTask = Task { await self.bootstrap(epoch: epoch) }
        self.execPolicy.handleReconnect()
        self.agentManagement.handleReconnect()
        self.devices.handleReconnect()
        self.skills.handleReconnect()
        self.sessionManager.handleReconnect()
    }

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    /// Row changes seen while the bootstrap's session list is being read; they win over that snapshot.
    private struct ListReconcile {
        var rows: [String: SessionRow] = [:]
        var deleted: [String: String?] = [:]
        var needsTrailingRefresh = false
    }

    @ObservationIgnored private var listReconcile: ListReconcile?

    private func recordReconciledRow(_ key: String) {
        self.listReconcile?.rows[key] = self.sessions[key]
        self.listReconcile?.deleted.removeValue(forKey: key)
    }

    func isCurrent(_ epoch: Int) -> Bool {
        !Task.isCancelled && epoch == self.connectionEpoch
    }

    private func bootstrap(epoch: Int) async {
        self.bootstrapped = false
        self.listReconcile = ListReconcile()
        async let agents = try? self.connection.request("agents.list", [:])
        async let subscribed = try? self.connection.request(
            "sessions.subscribe",
            .object(self.listParams),
            timeout: 30)
        let agentsResult = await agents
        let subscribeResult = await subscribed
        guard self.isCurrent(epoch) else { return }
        if let agentsResult { self.applyAgents(agentsResult) }
        if let list = subscribeResult?["list"] {
            self.applySnapshot(list)
            let trailing = self.listReconcile?.needsTrailingRefresh ?? false
            self.listReconcile = trailing ? ListReconcile() : nil
            if trailing {
                self.refreshTask?.cancel()
                await self.refreshSessions()
                let invalidatedAgain = self.listReconcile?.needsTrailingRefresh ?? false
                self.listReconcile = nil
                if invalidatedAgain { self.scheduleRefresh() }
                guard self.isCurrent(epoch) else { return }
            }
        } else {
            self.listReconcile = nil
            await self.refreshSessions()
            guard self.isCurrent(epoch) else { return }
        }
        if let pending = try? await self.connection.request("exec.approval.list", [:]) {
            guard self.isCurrent(epoch) else { return }
            let items = pending["approvals"]?.array ?? pending["items"]?.array ?? pending.array ?? []
            self.approvals = items.compactMap(ExecApproval.init)
        }
        await self.refreshQuestions()
        guard self.isCurrent(epoch) else { return }
        self.bootstrapped = true
        self.setup.connected()
        Task { await PushRegistrar.shared.sync(self) }
        self.dumpSessionShapesIfRequested()
        Task { await self.loadConfiguredServerNames() }
        Task { await self.pullBootstrapPrefs(epoch: epoch) }
        Task { await self.loadGroups() }
        // Only pick a chat on the first connect: on iPhone, going back to the sidebar clears the
        // selection, and re-selecting on every reconnect would push a chat the user left.
        let selectionGone = self.selectedKey.map { self.sessions[$0] == nil } ?? false
        if selectionGone || (self.selectedKey == nil && !self.didPickInitialChat) {
            self.selectedKey = self.defaultSessionKey
        }
        self.didPickInitialChat = true
        // Every other chat lost its subscription with the old socket; it reloads when opened.
        let warm = self.warmKeys(includingLive: true)
        for chat in self.chats.values where !warm.contains(chat.sessionKey) { chat.markStale() }
        // The open chat first, so it isn't stuck behind the others.
        if let key = self.selectedKey, let open = self.chats[key] {
            await open.load(force: true)
            guard self.isCurrent(epoch) else { return }
        }
        for chat in self.chats.values where chat.sessionKey != self.selectedKey && warm.contains(chat.sessionKey) {
            await chat.load(force: true)
            guard self.isCurrent(epoch) else { return }
        }
        self.startPrefetch()
        self.reconcileMessageIndex()
        self.enforceChatBudget()
        await self.flushOutbox()
    }

    // MARK: Warm chats

    static let warmChatLimit = ChatResidency.warmFloor
    /// Most recently selected chats, newest first.
    @ObservationIgnored private var recentKeys: [String] = []
    /// Recency of chat use, for dehydrating the least recently used ones (see `GatewayStore+Residency`).
    @ObservationIgnored var residency = ChatResidency(limit: max(ChatResidency.defaultLimit, GatewayStore.warmChatLimit))
    @ObservationIgnored var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored var enforcingChatBudget = false
    @ObservationIgnored var pendingChatBudgetLimit: Int?

    /// The selected chat, the most recent ones up to the cap, and any chat with a live run.
    func warmKeys(includingLive: Bool) -> Set<String> {
        var keys = Set(self.recentKeys.prefix(Self.warmChatLimit))
        if let selected = self.selectedKey { keys.insert(selected) }
        if includingLive {
            for chat in self.chats.values where chat.isRunning { keys.insert(chat.sessionKey) }
        }
        return keys
    }

    private func noteSelected(_ key: String) {
        self.recentKeys.removeAll { $0 == key }
        self.recentKeys.insert(key, at: 0)
        if self.recentKeys.count > Self.warmChatLimit { self.recentKeys.removeLast(self.recentKeys.count - Self.warmChatLimit) }
        let warm = self.warmKeys(includingLive: true)
        for chat in self.chats.values where !warm.contains(chat.sessionKey) && chat.isSubscribed {
            Task { await chat.releaseSubscription() }
        }
        self.residency.touch(key)
        self.enforceChatBudget()
    }

    /// Indexes cached transcripts the message index hasn't seen yet (caches from before it
    /// existed, or after it was rebuilt), in the background.
    private func reconcileMessageIndex() {
        guard MessageIndex.status(gatewayId: self.id, root: self.cacheRoot) != .unavailable else {
            self.messageIndexProgress = .unavailable
            return
        }
        self.reconcileTask?.cancel()
        let keys = self.sessions.values.filter { !$0.isSubagent }.map(\.key)
        let index = self.messageIndex
        self.reconcileTask = Task.detached(priority: .utility) { [weak self] in
            await index.reconcile(sessionKeys: keys) { status in
                await MainActor.run { self?.messageIndexProgress = status }
            }
        }
    }

    /// Chats message search may show: listed, not subagent runs, archived only while listed.
    var searchableSessionKeys: Set<String> {
        Set(self.sessions.values.filter { !$0.isSubagent && (self.showArchived || !$0.isArchived) }.map(\.key))
    }

    /// Messages matching `query` across this Gateway's cached chats, grouped by chat. Throws
    /// `CancellationError` when a newer search replaced this one.
    public func searchMessages(_ query: String) async throws -> MessageSearch.Results {
        let query = TranscriptSearch.normalized(query)
        guard MessageSearch.ftsQuery(query) != nil else { return MessageSearch.Results(query: query) }
        let index = self.messageIndex
        let allowed = self.searchableSessionKeys
        let candidates: [MessageSearch.Hit]
        do {
            // Cancelling this task interrupts the search.
            candidates = try await index.search(query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The index may have been deleted; refill it from the transcripts, at most once a minute.
            let now = ContinuousClock.now
            if self.lastFailureReconcile.map({ now - $0 >= .seconds(60) }) ?? true {
                self.lastFailureReconcile = now
                self.reconcileMessageIndex()
            }
            return MessageSearch.Results(query: query, failed: true)
        }
        let groups = await Task.detached(priority: .userInitiated) {
            MessageSearch.collect(candidates, query: query, allowed: allowed)
        }.value
        try Task.checkCancellation()
        let snippets = await Task.detached(priority: .userInitiated) {
            groups.map { $0.hits.map { MessageSearch.snippet(query: query, markdown: $0.text) } }
        }.value
        try Task.checkCancellation()
        let chats: [MessageSearch.Chat] = zip(groups, snippets).compactMap { group, snippets in
            guard let row = self.sessions[group.sessionKey] else { return nil }
            let agent = self.agent(row.agentId).name
            let messages = zip(group.hits, snippets).map { hit, snippet in
                MessageSearch.Message(
                    hit: hit,
                    sender: hit.sender?.displayName(agents: self.agents)
                        ?? (hit.role == .user ? hit.via.map { "via \($0)" } ?? "You" : agent),
                    snippet: snippet)
            }
            return MessageSearch.Chat(sessionKey: row.key, title: row.title, isArchived: row.isArchived,
                                      messages: messages, hasMore: group.hasMore)
        }
        return MessageSearch.Results(query: query, chats: chats)
    }

    /// The transcript cache was cleared (Settings): chats open here are saved again and the rest
    /// refetched in the background, so the cache and search index fill back up without a relaunch.
    func cacheCleared() async {
        for chat in self.chats.values { await chat.saveToCache() }
        guard self.state.isConnected else { return }
        self.startPrefetch()
    }

    /// Quietly caches every chat's full history, most recently active first, so opening any
    /// channel is instant. Chats that haven't changed since they were cached are skipped.
    /// A cached chat that holds everything it will (all of it, or the newest `maxItems`) and hasn't
    /// seen activity since needs no fetch.
    static func prefetchIsFresh(_ meta: TranscriptCache.Meta?, activityMs: Double) -> Bool {
        guard let meta, meta.complete || meta.retained == true, let cached = meta.activityMs else { return false }
        return cached >= activityMs
    }

    func startPrefetch() {
        self.prefetchTask?.cancel()
        self.prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let rows = self?.sessions.values.filter({ !$0.isSubagent && !$0.isPlaceholder })
                .sorted(by: { $0.activityMs > $1.activityMs })
            else { return }
            var fetched = 0
            for row in rows {
                guard !Task.isCancelled, let self, self.state.isConnected, self.appIsActive,
                      fetched < Self.prefetchBudget else { return }
                if let chat = self.chats[row.key], !chat.isDehydrated { continue }
                let meta = await TranscriptCache.meta(gatewayId: self.id, sessionKey: row.key, root: self.cacheRoot)
                if Self.prefetchIsFresh(meta, activityMs: row.activityMs) { continue }
                fetched += 1
                await self.startHeadlessFill(sessionKey: row.key, agentId: row.agentId).value
            }
        }
    }

    func cacheGeneration(of key: String) -> Int { self.cacheGenerations[key, default: 0] }

    /// Caches the chat's full history in a headless store, off the UI. One fill runs per chat at a
    /// time; callers share it. When it finishes, the open chat (if any) picks up what it wrote.
    @discardableResult
    func startHeadlessFill(sessionKey key: String, agentId: String?) -> Task<Void, Never> {
        if let running = self.headlessFills[key] { return running.task }
        let generation = self.cacheGeneration(of: key)
        let fillId = UUID()
        self.headlessFillStarts[key, default: 0] += 1
        let task = Task { [weak self] in
            guard let self else { return }
            let store = ChatStore(sessionKey: key, agentId: agentId, gateway: self, headless: true)
            store.windowLimit = TranscriptCache.maxItems
            await store.fillCache(generation: generation)
            if self.headlessFills[key]?.id == fillId { self.headlessFills[key] = nil }
            guard !Task.isCancelled, self.cacheGeneration(of: key) == generation else { return }
            await self.chats[key]?.adoptFilledCache()
        }
        self.headlessFills[key] = (fillId, task)
        return task
    }

    /// The chat's cached transcript is about to be removed or replaced (delete, rewind, branch
    /// switch, recovery): stops its background fill, waits for it to finish, and invalidates
    /// anything it would still write. Call before clearing the cache.
    func cancelHeadlessFill(_ key: String) async {
        self.cacheGenerations[key, default: 0] += 1
        guard let fill = self.headlessFills[key] else { return }
        fill.task.cancel()
        await fill.task.value
        if self.headlessFills[key]?.id == fill.id { self.headlessFills[key] = nil }
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

    func applySnapshot(_ list: JSONValue) {
        let previous = Set(self.sessions.values.filter { !$0.isPlaceholder }.map(\.key))
        var next: [String: SessionRow] = [:]
        for row in list["sessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            next[row.key] = row
        }
        if let reconcile = self.listReconcile {
            for (key, sessionId) in reconcile.deleted where sessionId == nil || next[key]?.sessionId == sessionId {
                next.removeValue(forKey: key)
            }
            for (key, row) in reconcile.rows where reconcile.deleted[key] == nil { next[key] = row }
        }
        self.addAgentHomes(to: &next)
        self.sessions = next
        if let defaults = list["defaults"], let model = defaults["model"]?.text {
            self.defaultModelRef = ModelRef.qualified(model, provider: defaults["modelProvider"]?.text)
        }
        if let defaults = list["defaults"] {
            self.defaultContextTokens = defaults["contextTokens"]?.int.flatMap { $0 > 0 ? $0 : nil }
        }
        // Sessions deleted while we weren't listening (e.g. across a reconnect) lose their cache too.
        let dropped = previous.subtracting(next.keys)
        if !dropped.isEmpty { Task { await self.forgetVanishedSessions(dropped) } }
    }

    private func scheduleRefresh() {
        if self.listReconcile != nil {
            self.listReconcile?.needsTrailingRefresh = true
            return
        }
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

    /// Called after any Gateway's agent list loads, e.g. so the app can refresh Siri's App Shortcut phrases.
    public static var agentsDidLoad: (@MainActor () -> Void)?

    func applyAgents(_ result: JSONValue) {
        self.agents = result["agents"]?.array?.compactMap(AgentSummary.init) ?? []
        self.defaultAgentId = result["defaultId"]?.text ?? self.agents.first?.id ?? "main"
        self.agentMainKey = result["mainKey"]?.text ?? "main"
        self.agentScope = result["scope"]?.text
        var next = self.sessions
        self.addAgentHomes(to: &next)
        if next != self.sessions { self.sessions = next }
        Self.agentsDidLoad?()
    }

    /// `agents.list` `mainKey`: each agent's home chat is `agent:<id>:<mainKey>`.
    @ObservationIgnored private var agentMainKey = "main"
    /// `agents.list` `scope`; `global` shares one session instead of per-agent home chats.
    @ObservationIgnored private var agentScope: String?

    /// The Gateway only lists sessions it has stored, and an agent's home chat isn't stored until
    /// its first message, so a new agent would have no chats and no sidebar section. Like the
    /// Control UI, list each agent's home chat anyway; it opens empty and the first send creates
    /// it. Placeholders for agents that are gone are dropped.
    private func addAgentHomes(to rows: inout [String: SessionRow]) {
        let agentIds = Set(self.agents.filter { !$0.isSystem }.map(\.id))
        for (key, row) in rows where row.isPlaceholder && !agentIds.contains(row.agentId) {
            rows.removeValue(forKey: key)
        }
        guard self.agentScope != "global" else { return }
        let mainAgents = Set(rows.values.filter { $0.isMain && !$0.isPlaceholder }.map(\.agentId))
        for agent in self.agents where !agent.isSystem && !mainAgents.contains(agent.id) {
            let key = "agent:\(agent.id):\(self.agentMainKey)"
            guard rows[key] == nil,
                  let row = SessionRow(.object([
                      "key": .string(key), "agentId": .string(agent.id), "isMain": true, "kind": "direct",
                      SessionRow.placeholderField: true,
                  ]))
            else { continue }
            rows[key] = row
        }
    }

    /// Re-fetches `agents.list` so the sidebar and pickers show created, renamed and deleted agents.
    public func reloadAgents() async {
        guard self.state.isConnected, let result = try? await self.connection.request("agents.list", [:]) else { return }
        self.applyAgents(result)
    }

    /// After an agent mutation: the roster, and the config (its agent entries and bindings changed).
    private func agentsDidChange() async {
        await self.reloadAgents()
        if self.settings.hasLoaded { await self.settings.reloadConfig() }
    }

    @ObservationIgnored private var eventTaps: [Int: @MainActor (GatewayEvent) -> Void] = [:]
    @ObservationIgnored private var nextEventTap = 0

    /// Sees every event this store handles, in wire order (for Shortcuts reusing this connection).
    func addEventTap(_ tap: @escaping @MainActor (GatewayEvent) -> Void) -> Int {
        self.nextEventTap += 1
        self.eventTaps[self.nextEventTap] = tap
        return self.nextEventTap
    }

    func removeEventTap(_ token: Int) {
        self.eventTaps.removeValue(forKey: token)
    }

    private func handle(_ event: GatewayEvent) {
        for tap in self.eventTaps.values { tap(event) }
        let payload = event.payload
        switch event.name {
        case "sessions.changed":
            self.applySessionChange(payload)
        case "users.prefs.changed":
            let keys = payload["keys"]?.array?.compactMap(\.string)
            let maps = self.syncedMaps.filter { keys?.contains($0.pref) ?? true && !self.consumeOwnWrite($0.pref) }
            if !maps.isEmpty { Task { await self.pullMaps(maps) } }
        case "chat":
            guard let key = payload["sessionKey"]?.text else { return }
            if let runId = payload["runId"]?.text { self.runSessions[runId] = key }
            self.recordRunActivity(event)
            self.chats[key]?.handleChat(payload)
            if payload["state"]?.string == "final" {
                self.notifyReply(sessionKey: key, runId: payload["runId"]?.text, snapshot: payload["message"])
            }
        case "agent":
            guard let runId = payload["runId"]?.text else { return }
            let key = payload["sessionKey"]?.text ?? self.runSessions[runId]
            self.recordRunActivity(event, sessionKey: key)
            if let key { self.chats[key]?.handleAgent(payload) }
        case "session.message":
            let key = payload["sessionKey"]?.text ?? payload["session"]?["key"]?.text
            if let row = payload["session"].flatMap(SessionRow.init) {
                self.setSession(row.keepingPreview(of: self.sessions[row.key]), for: row.key)
                self.recordReconciledRow(row.key)
            }
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
        case "question.requested":
            if let prompt = QuestionPrompt(payload) {
                let isNew = !self.questions.contains { $0.id == prompt.id }
                self.upsertQuestion(prompt)
                if isNew, prompt.isAnswerable() { self.notifier?.notifyQuestion(prompt, gateway: self) }
            }
        case "question.resolved":
            if let id = payload["id"]?.text {
                self.questions.removeAll { $0.id == id }
            }
        case DeviceManagementModel.requestedEvent, DeviceManagementModel.resolvedEvent, DeviceManagementModel.changedEvent,
             DeviceManagementModel.nodeRequestedEvent, DeviceManagementModel.nodeResolvedEvent:
            self.devices.handle(event: event.name, payload: payload)
        case "cron":
            self.automations.handleCronEvent(payload)
        case MCPServers.oauthChangedEvent, MCPServers.statusChangedEvent:
            self.mcp.handle(event)
        case "plugins.changed":
            self.settings.handlePluginsChanged()
        case "health", "heartbeat", "presence", "shutdown":
            self.health.handle(event: event.name, payload: payload)
            if event.name == "health" { self.channels.healthDidChange() }
        case "exec.approval.resolved":
            if let id = payload["id"]?.text ?? payload["request"]?["id"]?.text {
                self.approvals.removeAll { $0.id == id }
                self.clearApprovalNotifications(id)
            }
            self.approvalHistory.handleApprovalResolved()
            self.execPolicy.handleApprovalResolved()
        default:
            break
        }
    }

    func applySessionChange(_ payload: JSONValue) {
        self.sessionManager.handleSessionsChanged(payload)
        if let reason = payload["reason"]?.text, SessionManager.transcriptChangingReasons.contains(reason),
           let key = payload["session"]?["key"]?.text ?? payload["sessionKey"]?.text ?? payload["key"]?.text
        {
            Task { await self.transcriptChanged(key: key, change: .changed(editorText: nil)) }
        }
        if DebugLog.enabled {
            let row = payload["session"]
            let fields = ["pinned", "unread", "color", "category", "label", "archived", "reasoningLevel"]
                .map { "\($0)=\(row?[$0].map { DebugLog.brief(.object(["v": $0])) } ?? "-")" }
            DebugLog.write("← sessions.changed key=\(row?["key"]?.text ?? payload["key"]?.text ?? "?") reason=\(payload["reason"]?.text ?? "-") \(fields.joined(separator: " "))")
        }
        for ancestor in payload["ancestorSessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            self.setSession(ancestor.keepingPreview(of: self.sessions[ancestor.key]), for: ancestor.key)
            self.recordReconciledRow(ancestor.key)
        }
        if let row = payload["session"].flatMap(SessionRow.init) {
            let previous = self.sessions[row.key]
            self.setSession(row.keepingPreview(of: previous), for: row.key)
            self.recordReconciledRow(row.key)
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
            self.listReconcile?.needsTrailingRefresh = true
            Task { await self.loadGroups() }
        }
        if let key = payload["key"]?.text ?? payload["sessionKey"]?.text, reason == "delete" || reason == "deleted" {
            let removedId = payload["sessionId"]?.text
            if self.listReconcile != nil {
                self.listReconcile?.rows.removeValue(forKey: key)
                self.listReconcile?.deleted[key] = removedId
            }
            if removedId == nil || self.sessions[key]?.sessionId == removedId {
                self.setSession(nil, for: key)
                Task { await self.transcriptChanged(key: key, change: .deleted) }
                self.discardDraft(key)
                self.outbox.removeSession(key)
                if self.selectedKey == key { self.selectedKey = self.defaultSessionKey }
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
        self.residency.touch(key)
        if let existing = self.chats[key] { return existing }
        let store = ChatStore(sessionKey: key, agentId: self.sessions[key]?.agentId, gateway: self)
        self.chats[key] = store
        store.syncOutbox(self.outbox.entries(for: key))
        self.enforceChatBudget()
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
        guard let row = self.sessions[key], row.isUnread, self.state.isConnected,
              !self.markingRead.contains(key) else { return }
        self.markingRead.insert(key)
        let sent = (try? await self.connection.request("sessions.patch", ["key": .string(key), "unread": false])) != nil
        self.markingRead.remove(key)
        if self.recheckRead.remove(key) != nil, sent { self.markVisibleChatsRead() }
    }

    // MARK: Mutations

    /// Creates a chat and, with `select`, opens it in the main window.
    public func createSession(agentId: String?, label: String?, category: String? = nil, select: Bool = true) async -> String? {
        var params: [String: JSONValue] = ["agentId": .string(agentId ?? self.defaultAgentId)]
        if let label = label?.nilIfEmpty { params["label"] = .string(label) }
        if let category = category?.nilIfEmpty { params["category"] = .string(category) }
        do {
            let result = try await self.connection.request("sessions.create", .object(params), timeout: 30)
            guard let key = result["key"]?.text ?? result["session"]?["key"]?.text else { return nil }
            if let row = result["session"].flatMap(SessionRow.init) {
                self.setSession(row, for: key)
            } else {
                await self.refreshSessions()
            }
            if select { self.selectedKey = key }
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
            // `includeDetails` adds each model's effective `contextTokens`; released Gateways reject it.
            let result: JSONValue
            if let detailed = try? await self.connection.request(
                "models.list", ["agentId": .string(agentId), "includeDetails": true], timeout: 30)
            {
                result = detailed
            } else {
                result = try await self.connection.request("models.list", ["agentId": .string(agentId)], timeout: 30)
            }
            self.modelCatalogs[agentId] = result["models"]?.array?.compactMap(ModelChoice.init) ?? []
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// How full a session's context is. The row's own limits win; otherwise the serving model's window
    /// from `models.list` (see `loadModels`), then the Gateway default.
    public func contextUsage(for key: String) -> ContextUsage? {
        guard let row = self.sessions[key] else { return nil }
        return ContextUsage(row: row, fallbackLimit: self.fallbackContextLimit(for: row))
    }

    /// Whether `contextUsage` needs the agent's model catalog to find a limit.
    public func needsModelCatalogForContext(_ key: String) -> Bool {
        guard let row = self.sessions[key], row.totalTokens != nil,
              row.promptBudgetTokens == nil, row.contextTokens == nil
        else { return false }
        return self.modelCatalogs[row.agentId] == nil
    }

    private func fallbackContextLimit(for row: SessionRow) -> Int? {
        let refs = [row.activeModelRef, row.modelRef, self.defaultModelRef].compactMap(\.self)
        let catalog = self.modelCatalogs[row.agentId] ?? []
        for ref in refs {
            if let limit = catalog.first(where: { $0.ref == ref || $0.modelId == ref })?.contextTokens { return limit }
        }
        return self.defaultContextTokens
    }

    /// `sessions.compact` needs `operator.admin`; without it, "Compact now" sends `/compact` instead.
    public var canCompactDirectly: Bool {
        guard self.hello?.scopes.contains(GatewayConnection.adminScope) == true else { return false }
        let methods = self.hello?.methods ?? []
        return methods.isEmpty || methods.contains("sessions.compact")
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

    /// From the chat banner. Same guard, stale handling and cleanup as a notification action; a
    /// problem shows in `lastError`.
    @discardableResult
    public func resolveApproval(_ approval: ExecApproval, decision: String) async -> ApprovalOutcome {
        await self.resolveApproval(id: approval.id, decision: decision)
    }

    /// Sends `exec.approval.resolve` once per approval, from a notification action (which may have
    /// launched the app) or the banner. A socket that went stale while suspended is replaced first.
    /// The decision must leave within `connectWithin` seconds of the call (wall clock, so time spent
    /// suspended counts) and the RPC gets `timeout`; past that, or if the calling task is cancelled,
    /// it's dropped (`.unreachable`), never sent later. A second call for an approval that's in
    /// flight or already settled here sends nothing and returns `.alreadyHandled`.
    @discardableResult
    public func resolveApproval(
        id: String, decision: String, connectWithin: Double = 15, timeout: Double = 10) async -> ApprovalOutcome
    {
        let deadline = Date().addingTimeInterval(connectWithin)
        if self.answeredApprovals.contains(id) { return .alreadyHandled }
        if let inFlight = self.resolvingApprovals[id] {
            _ = await inFlight.value
            return .alreadyHandled
        }
        let outcome: ApprovalOutcome
        if self.approvals.first(where: { $0.id == id })?.isExpired() == true {
            outcome = .expired
        } else {
            let connection = self.connection
            let task = Task { () -> ApprovalOutcome in
                await Self.send(id: id, decision: decision, on: connection, deadline: deadline, timeout: timeout)
            }
            self.resolvingApprovals[id] = task
            outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            self.resolvingApprovals[id] = nil
        }
        if outcome.removesApproval { self.answeredApprovals.insert(id) }
        if outcome.removesApproval {
            self.approvals.removeAll { $0.id == id }
            await self.notifier?.removeApproval(gatewayId: self.id, id: id)
        } else if let message = outcome.inAppMessage(gatewayName: self.profile.name) {
            self.lastError = message
        }
        return outcome
    }

    /// Resolved elsewhere (or here): its delivered notifications go too.
    private func clearApprovalNotifications(_ id: String) {
        guard let notifier = self.notifier else { return }
        let gatewayId = self.id
        Task { await notifier.removeApproval(gatewayId: gatewayId, id: id) }
    }

    private static func send(
        id: String, decision: String, on connection: GatewayConnection, deadline: Date, timeout: Double) async -> ApprovalOutcome
    {
        await connection.reconnectNow()
        while await !connection.isReady {
            guard Date() < deadline, !Task.isCancelled else { return .unreachable }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Re-checked right before sending: a suspension during the wait mustn't let a stale allow through.
        guard Date() < deadline, !Task.isCancelled else { return .unreachable }
        do {
            _ = try await connection.request(
                "exec.approval.resolve", ["id": .string(id), "decision": .string(decision)], timeout: timeout)
            return .resolved
        } catch {
            return ApprovalOutcome.classify(error)
        }
    }

    /// Pushes name an agent's main chat as `agent:<id>:main`; the Gateway's main key may differ.
    public func resolveSessionKey(_ key: String) -> String {
        guard self.sessions[key] == nil else { return key }
        let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "agent", parts[2] == "main",
              let main = self.sessions.values.first(where: { $0.isMain && $0.agentId == parts[1] })
        else { return key }
        return main.key
    }

    // MARK: Questions

    /// Pending questions for a chat, dropping any that have expired.
    public func pendingQuestions(for sessionKey: String?, at date: Date = Date()) -> [QuestionPrompt] {
        self.questions.filter { $0.isAnswerable(at: date) && $0.belongs(to: sessionKey) }
    }

    func refreshQuestions() async {
        // Older Gateways and connections without `operator.questions` just have none.
        guard let result = try? await self.connection.request("question.list", [:]) else { return }
        let items = result["questions"]?.array ?? result.array ?? []
        self.questions = items.compactMap(QuestionPrompt.init).filter { $0.isAnswerable() }
    }

    private func upsertQuestion(_ prompt: QuestionPrompt) {
        guard prompt.isAnswerable() else {
            self.questions.removeAll { $0.id == prompt.id }
            return
        }
        if let index = self.questions.firstIndex(where: { $0.id == prompt.id }) {
            self.questions[index] = prompt
        } else {
            self.questions.append(prompt)
        }
    }

    /// Sends the answers. Returns an error message to show on the card, or nil once it's answered.
    public func answerQuestion(_ prompt: QuestionPrompt, answers: [String: [String]]) async -> String? {
        let params: JSONValue = [
            "id": .string(prompt.id),
            "answers": ["answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) })],
        ]
        return await self.resolveQuestion(prompt, params)
    }

    /// Skips the prompt; the agent is told the user declined to answer.
    public func skipQuestion(_ prompt: QuestionPrompt) async -> String? {
        await self.resolveQuestion(prompt, ["id": .string(prompt.id), "cancel": true])
    }

    private func resolveQuestion(_ prompt: QuestionPrompt, _ params: JSONValue) async -> String? {
        do {
            _ = try await self.connection.request("question.resolve", params)
            self.questions.removeAll { $0.id == prompt.id }
            return nil
        } catch {
            if case let GatewayError.rpc(_, message, details) = error {
                // Already settled elsewhere (another client, a channel button, expiry) or the agent stopped.
                let reason = details?["reason"]?.string
                if ["QUESTION_NOT_FOUND", "QUESTION_ALREADY_TERMINAL", "QUESTION_REQUESTER_INACTIVE"].contains(reason)
                    || message.contains("was not found")
                {
                    self.questions.removeAll { $0.id == prompt.id }
                    return nil
                }
                if details?["missingScope"]?.string == GatewayConnection.questionsScope
                    || message.contains(GatewayConnection.questionsScope)
                {
                    return "This device isn't allowed to answer questions yet. Approve its pending request on the Gateway host."
                }
                return message
            }
            return error.localizedDescription
        }
    }

    public func update(profile: GatewayProfile) {
        self.profile = profile
        self.images.media.reset()
    }

    public var serverNameOverrides: [String: String] {
        didSet { self.defaults.set(self.serverNameOverrides, forKey: "pincer.serverNames.\(self.id.uuidString)") }
    }

    /// Server names from the gateway's channel config (e.g. Discord `guilds.<id>.slug`).
    public internal(set) var configuredServerNames: [String: String] = [:]

    /// Last values seen on the gateway per pref; missing until a successful read.
    @ObservationIgnored var remotePrefMaps: [String: [String: String]] = [:]
    @ObservationIgnored var prefsSupportsExpected = true
    /// Changes not yet confirmed by the gateway, per pref.
    @ObservationIgnored var pendingPrefChanges: [String: [String: String?]] = [:]
    /// The latest write per pref, which the next one waits for.
    @ObservationIgnored var prefPushes: [String: Task<Void, Never>] = [:]

    /// Prefs we just wrote, whose `users.prefs.changed` echo needs no read back.
    @ObservationIgnored var ownPrefWrites: [String: ContinuousClock.Instant] = [:]

    /// Your emoji reactions, `"<sessionKey>|<transcriptId>"` to space-separated emoji in the order
    /// added, synced through `users.prefs` (`pincer.reactions`).
    public internal(set) var reactions: [String: String] {
        didSet { ReactionStore(gatewayId: self.id.uuidString, defaults: self.defaults).apply(old: oldValue, new: self.reactions) }
    }

    /// This connection's Gateway rejected `chat.send`'s `replyToId`, so replies quote instead.
    public internal(set) var replyToUnsupported = false
    /// Channels whose `message.action` reactions failed as unsupported on this connection.
    @ObservationIgnored var reactionForwardingOff: Set<String> = []
    /// Chats already told a reaction didn't reach their channel on this connection.
    @ObservationIgnored var reactionNoticeShown: Set<String> = []

    @ObservationIgnored var invalidatingTranscripts: Set<String> = []

    /// Dismissed Gateway Health issues, synced through `users.prefs` (`pincer.healthDismissals`).
    public var healthDismissals: [String: String] {
        didSet {
            guard self.healthDismissals != oldValue else { return }
            self.defaults.set(self.healthDismissals, forKey: "pincer.healthDismissals.\(self.id.uuidString)")
            if self.health.dismissals != self.healthDismissals { self.health.dismissals = self.healthDismissals }
        }
    }

    /// `users.prefs` pushes started by `applyHealthDismissals`, for checks.
    @ObservationIgnored internal(set) var healthDismissalPushes = 0

    /// Avatar characters by agent id, plus Pixel or Plush under `AvatarPreferences.renderStyleEntry`,
    /// synced through `users.prefs` (`pincer.avatars`). Changes from the Gateway are written onto
    /// this device's avatar settings, which the views read.
    public internal(set) var avatarChoices: [String: String] {
        didSet {
            guard self.avatarChoices != oldValue else { return }
            self.defaults.set(self.avatarChoices, forKey: "pincer.avatars.\(self.id.uuidString)")
            AvatarPreferences.apply(self.avatarChoices, previous: oldValue, to: self.defaults)
        }
    }

    /// Choices made while this Gateway was unreachable. Its map is left alone until it reconnects,
    /// so pulling its older map can't undo them on this device; they're pushed after that pull.
    var queuedAvatarChoices: [String: String?] = [:]

    /// Custom SF Symbol names by session key, synced through `users.prefs` (`pincer.chatIcons`).
    public var chatIcons: [String: String] {
        didSet { self.defaults.set(self.chatIcons, forKey: "pincer.chatIcons.\(self.id.uuidString)") }
    }

    /// Custom "#RRGGBB" colors by session key, synced through `users.prefs` (`pincer.chatColors`).
    public var chatColors: [String: String] {
        didSet { self.defaults.set(self.chatColors, forKey: "pincer.chatColors.\(self.id.uuidString)") }
    }

    /// The gateway's custom group catalog (`sessions.groups.list`), in display order.
    public internal(set) var groupCatalog: [String] = []
    @ObservationIgnored var groupCatalogUnsupported = false

    /// Fallback for gateways without the catalog: group names to positions, synced through `users.prefs`.
    public var groupPositions: [String: String] {
        didSet { self.defaults.set(self.groupPositions, forKey: "pincer.groups.\(self.id.uuidString)") }
    }

    /// SF Symbol names by group name, synced through `users.prefs` (`pincer.groupIcons`).
    public var groupIcons: [String: String] {
        didSet { self.defaults.set(self.groupIcons, forKey: "pincer.groupIcons.\(self.id.uuidString)") }
    }

    /// Sidebar sections the reader expanded or collapsed, by section id. Sections without an
    /// entry start expanded, except Automations, which starts collapsed.
    public internal(set) var sectionCollapse: [String: Bool] {
        didSet { self.defaults.set(self.sectionCollapse, forKey: "pincer.collapsed.\(self.id.uuidString)") }
    }

    /// Session keys to their position within their group, synced through `users.prefs`.
    public var chatPositions: [String: String] {
        didSet { self.defaults.set(self.chatPositions, forKey: "pincer.chatOrder.\(self.id.uuidString)") }
    }
}
