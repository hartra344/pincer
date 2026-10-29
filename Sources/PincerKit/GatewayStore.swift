import Foundation
import Observation

/// Everything the UI knows about one Gateway ("server" in the rail).
@MainActor
@Observable
public final class GatewayStore: Identifiable {
    /// Installed by the app; auxiliary operator clients never acquire device location.
    public var locationContext: LocationContextModel?
    public private(set) var profile: GatewayProfile
    public nonisolated let id: UUID
    public internal(set) var state: ConnectionState = .idle
    /// Whether this store has ever reached `.connected`, so the UI can tell a first connect
    /// that's still retrying apart from a connection that was lost.
    public internal(set) var hasConnected = false
    public internal(set) var hello: GatewayHello?
    /// The host name this gateway last reported for itself (`GatewayHello.gatewayHost`), kept so
    /// links and Handoff from other devices find it before it has connected (#375).
    public internal(set) var gatewayHost: String?
    /// True after this connection has received at least one successful session-list snapshot.
    /// A successfully empty list is ready too; emptiness alone cannot distinguish it from cold.
    @ObservationIgnored internal(set) var sessionListReady = false
    /// Keeps the last complete snapshot usable during reconnect, without trusting partial events
    /// received before the first successful list.
    @ObservationIgnored internal(set) var hasSessionListSnapshot = false
    /// Lets the owning AppModel retry a pending external route without retaining either object.
    @ObservationIgnored var routeCandidatesDidChange: (@MainActor () -> Void)?
    public internal(set) var agents: [AgentSummary] = []
    public internal(set) var defaultAgentId = "main"
    /// Session rows by key. Writes that change nothing are dropped, so they don't invalidate every
    /// view reading the list (sidebar, open chats) or clear the cached subagent trees.
    public internal(set) var sessions: [String: SessionRow] {
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
        self.routeCandidatesDidChange?()
    }
    /// The chat each viewer (the main window, later chat windows) shows on screen right now, in an
    /// active, focused scene. See `setVisibleChat(_:viewer:)`.
    @ObservationIgnored var visibleChatsByViewer: [String: String] = [:]
    /// Keys with a `sessions.patch unread=false` in flight, so a burst of row changes sends one.
    @ObservationIgnored var markingRead: Set<String> = []
    /// The latest `setThinkingLevel` request per session; a failed older one doesn't roll back a newer pick.
    @ObservationIgnored var thinkingLevelRequests: [String: Int] = [:]
    /// Visible keys that changed while their patch was in flight; checked again once it lands.
    @ObservationIgnored var recheckRead: Set<String> = []
    /// Runs whose reply was already checked for unread, so a repeated `final` sends at most one patch (#426).
    @ObservationIgnored var markedReplyRuns: Set<String> = []
    /// Chats with a finished reply waiting out `replyUnreadGrace`; showing the chat meanwhile drops it.
    @ObservationIgnored var pendingReplyUnread: Set<String> = []
    /// How long a finished reply waits before Pincer marks it unread; per store so tests can't leak it.
    @ObservationIgnored var replyUnreadGrace: Duration = GatewayStore.defaultReplyUnreadGrace
    @ObservationIgnored var replyUnreadTimers: [String: Task<Void, Never>] = [:]
    /// Per chat, how many finished replies have been decided (marked or not); tests wait on it.
    @ObservationIgnored var replyUnreadDecisions: [String: Int] = [:]
    @ObservationIgnored private var sessionStorage: [String: SessionRow] = [:]
    /// Compact exact tool-id to original server-name snapshots, scoped to this Gateway.
    @ObservationIgnored var mcpToolServerIndexes = BoundedLRUCache<String, MCPToolServerIndex>(countLimit: 16, costLimit: 64 * 1024)
    /// Latest in-flight effective snapshot per session; distinct entries are capped at 32.
    @ObservationIgnored var mcpToolServerReadVersions: [String: UInt64] = [:]
    @ObservationIgnored var mcpToolServerReadSequence: UInt64 = 0
    @ObservationIgnored var sortedRowsCache: [SessionRow]?
#if DEBUG
    /// Counts actual parent-candidate derivations performed while building sidebar sections.
    /// Used by a focused performance regression test; this is omitted from release builds.
    @ObservationIgnored var sidebarParentCandidateDerivationCount = 0
#endif
    /// `subagentTree(rootKey:)` per root and connection state, until the rows change.
    @ObservationIgnored var subagentTrees: [String: SubagentTree] = [:]
    /// Streamed run activity, read through `runTimeline`; bumping the revision publishes it.
    @ObservationIgnored var runTimelineState = RunTimeline()
    var runTimelineRevision = 0
    public internal(set) var approvals: [ExecApproval] = []
    /// Pending agent questions (`ask_user`), oldest first.
    public internal(set) var questions: [QuestionPrompt] = []
    public internal(set) var lastError: String?
    /// `models.list` per agent id, fetched when a model picker opens.
    public internal(set) var modelCatalogs: [String: [ModelChoice]] = [:]
    public internal(set) var loadingModelCatalogs: Set<String> = []
    /// The model sessions use when nobody picked one (`sessions.list` `defaults`).
    public internal(set) var defaultModelRef: String?
    /// Context window sessions get when their row doesn't say (`sessions.list` `defaults.contextTokens`).
    public internal(set) var defaultContextTokens: Int?
    struct CommandCatalog {
        let commands: [SlashCommand]
        let fetchedAt: Date
        let connectionEpoch: Int
    }
    /// `commands.list` per session key.
    internal(set) var commandCatalogs: [String: CommandCatalog] = [:]
    @ObservationIgnored var loadingCommands: Set<String> = []
    /// Bumped on every connect, so catalogs from an earlier connection are refetched.
    @ObservationIgnored internal(set) var connectionEpoch = 0
    @ObservationIgnored package private(set) var selectionIntentRevision: UInt64 = 0
    public var selectedKey: String? {
        didSet {
            self.selectionIntentRevision &+= 1
            guard oldValue != self.selectedKey else { return }
            self.splitPaneFocused = false
            if let oldValue, let left = self.chats[oldValue] { Task { await left.trimToWindow() } }
            guard let key = self.selectedKey else { return }
            DefaultsWriter.set(key, forKey: "pincer.selected.\(self.id.uuidString)", in: self.defaults)
            self.noteSelected(key)
            Task { await self.openChat(key) }
        }
    }
    /// The chat beside the selected one in the main window's split view (#48), or nil for none.
    public var splitKey: String? {
        didSet {
            guard oldValue != self.splitKey else { return }
            self.defaults.set(self.splitKey, forKey: "pincer.split.\(self.id.uuidString)")
        }
    }
    /// Whether the split view's right-hand chat, not the selected one, has focus (#404). See `focusedKey`.
    public var splitPaneFocused = false
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
        didSet {
            guard self.outbox != oldValue else { return }
            self.outboxEligibleHeads = nil
            self.outboxChanged(from: oldValue)
        }
    }
    /// Attachment bytes of outbox entries, kept for the current launch only.
    @ObservationIgnored var outboxAttachments: [String: [OutgoingAttachment]] = [:]
    @ObservationIgnored var outboxLoaded = false
    /// The saved outbox has been read and merged in; changes are saved from here on.
    @ObservationIgnored var outboxRestored = false
    @ObservationIgnored var outboxFlushing = false
    /// The restored outbox's attachment files are being checked off-main; sends wait for it.
    @ObservationIgnored var outboxValidating = false
    @ObservationIgnored var replySendLifecycle = 0
    @ObservationIgnored var replyAcceptanceWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored var replyReservationPreparations: [String: Task<String?, Never>] = [:]
    /// Entries visited while building the cached per-session heads; reset by performance checks.
    @ObservationIgnored var outboxHeadScanVisits = 0
    /// First auto-sendable entry per session for this outbox snapshot. Nil means not built yet.
    @ObservationIgnored var outboxEligibleHeads: [String: String]?
    /// The task `start()` reads the saved outbox in; tests await it instead of polling `outboxRestored`.
    @ObservationIgnored var outboxLoadTask: Task<Void, Never>?

    /// The Gateway's last-known upload policy (from its latest hello, saved across launches).
    public internal(set) var lastUploadPolicy: UploadPolicy?
    /// Cellular / Low Data Mode state; large queued uploads wait while it's expensive or constrained.
    @ObservationIgnored public let network: NetworkConditions
    @ObservationIgnored var networkWatch: Task<Void, Never>?

    @ObservationIgnored let connection: GatewayConnection
    /// Opt-in device mode: a second, node-role connection, off by default.
    public let deviceNode: DeviceNodeController
    @ObservationIgnored internal(set) var chats: [String: ChatStore] = [:]
    @ObservationIgnored var runSessions: [String: String] = [:]
    @ObservationIgnored internal(set) var bootstrapped = false
    @ObservationIgnored var didPickInitialChat = false
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var prefetchTask: Task<Void, Never>?
    @ObservationIgnored var prefetchGeneration = 0
    /// Whether a background history prefetch is waiting to start or running (checks wait on it).
    @ObservationIgnored public internal(set) var isPrefetching = false
    /// Prefetch runs that finished without being cancelled or replaced (checks).
    @ObservationIgnored public internal(set) var prefetchesFinished = 0
    /// Background full-history fills, one per chat, shared by the prefetch and the open chat.
    @ObservationIgnored var headlessFills: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// How many background fills actually started per chat (tests).
    @ObservationIgnored var headlessFillStarts: [String: Int] = [:]
    /// Bumped when a chat's cached transcript is removed or rewritten by the Gateway, so a fill that
    /// began before can't save its stale history over the new one.
    @ObservationIgnored var cacheGenerations: [String: Int] = [:]
    /// Whether the app is in the foreground, set from `AppModel.appIsActive`. Background prefetch
    /// stops while it's false and starts again on resume.
    public var appIsActive = true {
        didSet {
            if self.appIsActive, !oldValue, self.state.isConnected { self.startPrefetch() }
            if !self.appIsActive, oldValue { self.prefetchTask?.cancel() }
        }
    }
    /// Whether iOS has put the app in the background (not merely `.inactive`, which every permission
    /// prompt or Control Center pull causes). Both connections stay open while the app has background
    /// time (#1074); returning to the foreground resumes a node connection paused since.
    public var appIsInBackground = false {
        didSet { if !self.appIsInBackground { self.deviceNode.setForeground(true) } }
    }

    /// iOS's background time ran out and the app is about to be suspended: device mode pauses its node
    /// connection, so agents get "node not connected" instead of a request nobody answers.
    func backgroundTimeExpired() {
        guard self.appIsInBackground else { return }
        self.deviceNode.setForeground(false)
    }
    /// Most chats one prefetch run fetches, so a big account isn't paged through all at once.
    static let prefetchBudget = 40
    @ObservationIgnored var reconcileTask: Task<Void, Never>?
    /// When a failed search last asked for the index to be rebuilt; searches that keep failing
    /// don't keep rebuilding it (each rebuild re-runs the search).
    @ObservationIgnored var lastFailureReconcile: ContinuousClock.Instant?
    /// Full-text index of this Gateway's cached transcripts, for message search.
    /// Where this Gateway's transcripts and search index are cached; tests give each store its own folder.
    @ObservationIgnored var cacheRoot: URL? = TranscriptCache.root
    @ObservationIgnored var outboxRoot: URL? = OutboxStore.root
    public var messageIndex: MessageIndex { MessageIndex.shared(gatewayId: self.id, root: self.cacheRoot) }
    /// Whether message search is ready, still indexing cached chats, or off (no transcript cache).
    public internal(set) var messageIndexProgress: MessageIndex.Status = .ready
    @ObservationIgnored weak var notifier: Notifier?
    /// Approvals this session settled (answered, expired or answered elsewhere), so a later duplicate
    /// action is a no-op rather than another RPC and follow-up.
    @ObservationIgnored var answeredApprovals: Set<String> = []
    @ObservationIgnored var resolvingApprovals: [String: Task<ApprovalOutcome, Never>] = [:]
    public let images: ArtifactImageLoader
    /// Page images for browser tool cards (`controlUi.linkPreview`).
    public let pagePreviews = BrowserPagePreviews()
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
        onAgentsChanged: { [weak self] in await self?.agentsDidChange() },
        onAgentDeleted: { [weak self] in self?.clearAvatarChoices(for: $0) })
    /// The agent's live browser (`browser.request`, view-only). Needs `operator.admin`; the demo counts as Full Management.
    @ObservationIgnored public private(set) lazy var browserPanel: BrowserPanelModel = {
        let panel = BrowserPanelModel(
        connection: self.connection, profile: { [weak self] in self?.profile ?? GatewayProfile(name: "", url: "", authMode: .none) },
        hello: { [weak self] in self?.hello },
        fetchDownload: { [weak self] path in
            if let demo = DemoBrowserDownload.data(forPath: path) {
                return try BrowserPanelModel.writeTemp(demo, name: "demo.html")
            }
            guard let loader = await self?.images, let file = try await loader.fetchGatewayFile(path: path) else {
                throw BrowserPanelModel.ActionError.noDownload
            }
            return file
        })
        panel.thumbnailSink = { [weak self] ref, key in self?.pagePreviews.setScreenshot(ref, forTab: key) }
        return panel
    }()
    /// The agent's portals (`portal.list`, `portal.close`); refreshed by `portal.changed`. Hidden when unavailable.
    @ObservationIgnored public private(set) lazy var portals = PortalStore(
        connection: self.connection, hello: { [weak self] in self?.hello }, isDemo: self.profile.isDemo, gatewayId: self.id,
        agentSessions: { [weak self] agent in
            (self?.sessions.values.filter { $0.agentId == agent } ?? []).sorted { $0.activityMs > $1.activityMs }.map(\.key)
        })
    @ObservationIgnored var filesModelCache: [String: SessionFilesModel] = [:]
    @ObservationIgnored var filesModelOrder: [String] = []
    /// Skills (`skills.*`): the per-agent list, ClawHub search, installs and config. The demo may
    /// write without `operator.admin`.
    @ObservationIgnored public private(set) lazy var skills = SkillsModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        allowsWritesWithoutAdmin: self.profile.isDemo)
    /// MCP Servers: the server list (through the shared settings draft), live state and OAuth
    /// sign-in. The demo may write without `operator.admin`.
    @ObservationIgnored public private(set) lazy var mcp = MCPServersModel(
        settings: self.settings, request: self.toolsRequest, hello: { [weak self] in self?.hello },
        sessionKey: { [weak self] in self?.defaultSessionKey }, allowsWritesWithoutAdmin: self.profile.isDemo)
    /// Gateway Settings → Sessions: every session with previews, details, bulk archive/delete and
    /// branch tools. The demo may write without `operator.admin`.
    @ObservationIgnored public private(set) lazy var sessionManager = SessionManagerModel(
        connection: self.connection, hello: { [weak self] in self?.hello },
        allowsWritesWithoutAdmin: self.profile.isDemo,
        onTranscriptChanged: { [weak self] key, change in await self?.transcriptChanged(key: key, change: change) },
        onSessionsChanged: { [weak self] in await self?.refreshSessions() })
    /// Gateway text-to-speech: the Voice settings page and Read Aloud's `tts.speak`. The demo may write without scopes.
    @ObservationIgnored public private(set) lazy var voice: GatewayVoiceModel = {
        let voice = GatewayVoiceModel(
            connection: self.connection, hello: { [weak self] in self?.hello },
            allowsWritesWithoutAdmin: self.profile.isDemo, gatewayName: { [weak self] in self?.profile.name ?? "" })
        if self.profile.isDemo { voice.voiceLister = DemoGateway.demoVoiceLister }
        return voice
    }()
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

    /// The first-run setup wizard (Setup Assistant…); offered after the first successful connection.
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

    public convenience init(profile: GatewayProfile, network: NetworkConditions = .shared) {
        self.init(profile: profile, defaults: .standard, identity: .loadOrCreate(), network: network)
    }

    /// A store keeping its device settings in `defaults`, so checks running side by side don't
    /// share `UserDefaults.standard`.
    public convenience init(profile: GatewayProfile, defaults: UserDefaults, network: NetworkConditions = .shared) {
        self.init(profile: profile, defaults: defaults, identity: .loadOrCreate(), network: network)
    }

    init(profile: GatewayProfile, defaults: UserDefaults, identity: DeviceIdentity, network: NetworkConditions = .shared) {
        self.network = network
        self.profile = profile
        self.id = profile.id
        self.defaults = defaults
        // The demo's chats are always at hand, so its search works even with the cache off.
        if profile.isDemo { MessageIndex.allowInMemory(gatewayId: profile.id) }
        self.messageIndexProgress = MessageIndex.status(gatewayId: profile.id)
        self.identity = identity
        let operatorConnection = GatewayConnection(profile: profile, identity: identity)
        self.connection = operatorConnection
        self.deviceNode = DeviceNodeController(
            profile: profile, identity: identity, operatorConnection: operatorConnection, defaults: defaults)
        self.gatewayHost = profile.isDemo ? nil : defaults.string(forKey: Self.gatewayHostKey(profile.id))
        self.organization = SidebarOrganization(
            rawValue: defaults.string(forKey: "pincer.org.v2.\(profile.id.uuidString)") ?? "") ?? .servers
        self.lastUploadPolicy = profile.isDemo ? nil : Self.savedUploadPolicy(in: defaults, id: profile.id)
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
        self.pendingPrefChanges = Self.loadPending([String: [String: String?]].self, Self.pendingPrefsKey(profile.id), defaults) ?? [:]
        self.queuedAvatarChoices = Self.loadPending([String: String?].self, Self.queuedAvatarsKey(profile.id), defaults) ?? [:]
        self.selectedKey = defaults.string(forKey: "pincer.selected.\(profile.id.uuidString)")
        self.splitKey = defaults.string(forKey: "pincer.split.\(profile.id.uuidString)")
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
        self.pagePreviews.gateway = self
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
        self.wireBookmarkSync()
    }

    public var deviceId: String { self.identity.deviceId }

    enum Inbound: Sendable {
        case event(GatewayEvent)
        case state(ConnectionState, GatewayHello?)
    }

    @ObservationIgnored var pumpTask: Task<Void, Never>?
    @ObservationIgnored var eventBuffer: CoalescingEventBuffer<Inbound>?

    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    #if DEBUG
    /// Test dependency at the actual background reconciliation boundary; nil in production.
    @ObservationIgnored package var cacheInventoryProbe: CacheInventoryProbe?
    @ObservationIgnored package var cacheInventoryDidPrepare: (@Sendable () async -> Void)?
    @ObservationIgnored package var beforeBootstrapReconciliation: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored var observedBootstrapBackground: (epoch: Int, task: Task<Void, Never>)?
    @ObservationIgnored var lastObservedBackground: (epoch: Int, task: Task<Void, Never>)?
    @ObservationIgnored var observedBootstrapFinishedEpoch: Int?
    @ObservationIgnored var observedBackgroundFinishedEpoch: Int?
    package var bootstrapProbeEpoch: Int { self.connectionEpoch }
    package var bootstrapProbeIsTerminal: Bool {
        self.state.isConnected && self.observedBootstrapFinishedEpoch == self.connectionEpoch
            && self.observedBackgroundFinishedEpoch == self.connectionEpoch
    }
    package var bootstrapMainTask: Task<Void, Never>? { self.bootstrapTask }
    /// At most one current-epoch terminal handle, so checks can await real Task.value even after cleanup.
    package var bootstrapLastBackgroundTask: Task<Void, Never>? {
        guard self.lastObservedBackground?.epoch == self.connectionEpoch else { return nil }
        return self.lastObservedBackground?.task
    }

    package var bootstrapBackgroundTask: Task<Void, Never>? {
        guard self.observedBootstrapBackground?.epoch == self.connectionEpoch else { return nil }
        return self.observedBootstrapBackground?.task
    }
    #endif

    /// Row changes seen while a session list is being read (the bootstrap's or a refresh's); they win
    /// over that snapshot, which may have been computed before them.
    struct ListReconcile {
        var rows: [String: SessionRow] = [:]
        var deleted: [String: String?] = [:]
        var needsTrailingRefresh = false
        /// Opened by `refreshSessions` rather than the bootstrap, which manages its own.
        var ownedByRefresh = false
    }

    @ObservationIgnored var listReconcile: ListReconcile?
    @ObservationIgnored var refreshesInFlight = 0

    // MARK: Warm chats

    static let warmChatLimit = ChatResidency.warmFloor
    /// Most recently selected chats, newest first.
    @ObservationIgnored var recentKeys: [String] = []
    /// Recency of chat use, for dehydrating the least recently used ones (see `GatewayStore+Residency`).
    @ObservationIgnored var residency = ChatResidency(limit: max(ChatResidency.defaultLimit, GatewayStore.warmChatLimit))
    @ObservationIgnored var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored var enforcingChatBudget = false
    /// Chats shown in their own windows, with how many windows each (#48).
    var windowCounts: [String: Int] = [:]
    @ObservationIgnored var pendingChatBudgetLimit: Int?

    // MARK: Events

    /// Called after any Gateway's agent list loads, e.g. so the app can refresh Siri's App Shortcut phrases.
    public static var agentsDidLoad: (@MainActor () -> Void)?

    /// `agents.list` `mainKey`: each agent's home chat is `agent:<id>:<mainKey>`.
    @ObservationIgnored var agentMainKey = "main"
    /// `agents.list` `scope`; `global` shares one session instead of per-agent home chats.
    @ObservationIgnored var agentScope: String?

    @ObservationIgnored var eventTaps: [Int: @MainActor (GatewayEvent) -> Void] = [:]
    @ObservationIgnored var nextEventTap = 0

    public var serverNameOverrides: [String: String] {
        didSet { self.defaults.set(self.serverNameOverrides, forKey: "pincer.serverNames.\(self.id.uuidString)") }
    }

    /// Server names from the gateway's channel config (e.g. Discord `guilds.<id>.slug`).
    public internal(set) var configuredServerNames: [String: String] = [:]

    /// Last values seen on the gateway per pref; missing until a successful read.
    @ObservationIgnored var remotePrefMaps: [String: [String: String]] = [:]
    @ObservationIgnored var prefsSupportsExpected = true
    /// Changes not yet confirmed by the gateway, per pref.
    /// Persisted per gateway, so changes that never reached it survive a relaunch.
    @ObservationIgnored var pendingPrefChanges: [String: [String: String?]] = [:] {
        didSet { self.savePending(self.pendingPrefChanges, isEmpty: self.pendingPrefChanges.isEmpty, key: Self.pendingPrefsKey(self.id)) }
    }
    /// The latest nonempty legacy reaction change stays in a fitted prefs value.
    @ObservationIgnored var mostRecentChangedReactionKey: String?
    /// Injectable so tests can hold a fit while the Gateway connection epoch changes.
    @ObservationIgnored var legacyReactionPrefsFitter: @Sendable ([String: String], String?) async -> [String: String]? = { entries, key in
        await Task.detached(priority: .utility) {
            LegacyReactionPrefs.fitting(entries, preserving: key)
        }.value
    }
    /// The latest write per pref, which the next one waits for.
    @ObservationIgnored var prefPushes: [String: Task<Void, Never>] = [:]

    /// This connection's Gateway (before 2026.9.7) rejected `subscriptionId` on message subscriptions.
    @ObservationIgnored var messageSubscriptionIdUnsupported = false

    /// Prefs the gateway refused as invalid (value too large, key limit), with its reason. Their
    /// changes stay pending but only retry on the next push or connect.
    public internal(set) var rejectedPrefs: [String: String] = [:]

    /// `users.prefs.set` writes per pref whose `users.prefs.changed` echo hasn't arrived, so
    /// that echo needs no read back. Reset on each connection, which pulls everything.
    @ObservationIgnored var expectedPrefEchoes: [String: Int] = [:]

    /// Your emoji reactions, `"<sessionKey>|<transcriptId>"` to space-separated emoji in the order
    /// added, synced through `users.prefs` (`pincer.reactions`).
    public internal(set) var reactions: [String: String] {
        didSet { ReactionStore(gatewayId: self.id.uuidString, defaults: self.defaults).apply(old: oldValue, new: self.reactions) }
    }

    /// This connection's Gateway rejected `chat.send`'s `replyToId`, so replies quote instead.
    public internal(set) var replyToUnsupported = false
    /// This Gateway refused the optional location reference field; sends continue without it.
    public internal(set) var locationContextUnsupported = false
    /// Channels whose `message.action` reactions failed as unsupported on this connection.
    @ObservationIgnored var reactionForwardingOff: Set<String> = []
    /// Chats already told a reaction didn't reach their channel on this connection.
    @ObservationIgnored var reactionNoticeShown: Set<String> = []
    /// Gateway reactions (`session.reactions.*`) failed as unavailable on this connection, so reactions use `users.prefs`.
    public internal(set) var sessionReactionsOff = false
    /// Your `users.self` profile id (the Gateway's reaction identity) for one connection; `id` is nil without a profile.
    @ObservationIgnored var selfProfile: (epoch: Int, id: String?)?

    @ObservationIgnored var invalidatingTranscripts: Set<String> = []
    struct PendingTranscriptChange {
        var change: SessionTranscriptChange
        var feedbackAuthority: ChatStore.MessageEditFeedbackAuthority?
    }
    /// The latest change that arrived while that session's invalidation was running; it reruns afterwards.
    @ObservationIgnored var pendingTranscriptChanges: [String: PendingTranscriptChange] = [:]
    @ObservationIgnored var lastTranscriptInvalidation: [String: ContinuousClock.Instant] = [:]
    static let echoWindow: Duration = .seconds(2)
    @ObservationIgnored var runningTranscriptAuthority: [String: ChatStore.MessageEditFeedbackAuthority] = [:]

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
    /// synced through `users.prefs` (`pincer.avatars`). Character mirrors stay scoped to this Gateway.
    public internal(set) var avatarChoices: [String: String] {
        didSet {
            guard self.avatarChoices != oldValue else { return }
            self.defaults.set(self.avatarChoices, forKey: "pincer.avatars.\(self.id.uuidString)")
            AvatarPreferences.apply(self.avatarChoices, previous: oldValue, to: self.defaults, gatewayId: self.id)
        }
    }

    /// Choices made while this Gateway was unreachable. Its map is left alone until it reconnects,
    /// so pulling its older map can't undo them on this device; they're pushed after that pull.
    var queuedAvatarChoices: [String: String?] = [:] {
        didSet { self.savePending(self.queuedAvatarChoices, isEmpty: self.queuedAvatarChoices.isEmpty, key: Self.queuedAvatarsKey(self.id)) }
    }

    /// The connection epoch whose bootstrap prefs pull has finished; seeds are only recorded after
    /// it, so a device that hasn't read the Gateway's map can't overwrite an older seed.
    @ObservationIgnored var avatarPrefsPulledEpoch: Int?

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
