import Foundation
import Observation

// MARK: Settings

/// Whether the macOS menu bar item is shown. Device-local, like Quick Capture; never synced.
public struct MenuBarSettings {
    public static let enabledKey = "pincer.menuBar.enabled"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off until the user turns it on. Read like `@AppStorage` does, so "YES" strings (e.g. a
    /// `-pincer.menuBar.enabled YES` launch argument) agree with the scene's value.
    public var isEnabled: Bool {
        get { self.defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { self.defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Saves `enabled` only when it differs from the stored value; returns whether it wrote.
    /// `MenuBarExtra(isInserted:)` sets its binding again on every app update, even to the same
    /// value, and a write that always lands posts `UserDefaults.didChangeNotification`, which
    /// starts another update: the launch freeze in #119.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled != self.isEnabled else { return false }
        self.isEnabled = enabled
        return true
    }
}

// MARK: Clock

/// The `now` the menu bar item builds its inbox with. Views read `now` instead of calling `Date()`
/// in `body`, and it moves forward on a slow tick so expired approvals and questions (and a stale
/// heartbeat's Degraded) drop out without anything else changing (#119).
@MainActor
@Observable
public final class MenuBarClock {
    public static let shared = MenuBarClock()
    /// At most this long before an expiry shows in the menu bar.
    public nonisolated static let interval: Duration = .seconds(30)

    public private(set) var now: Date
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(now: Date = Date()) {
        self.now = now
    }

    /// Moves `now` to `date`; ignores dates that aren't later, so observers never see it go back.
    public func tick(_ date: Date = Date()) {
        guard date > self.now else { return }
        self.now = date
    }

    /// Ticks every `interval` until `stop()`. Safe to call more than once.
    public func start(interval: Duration = MenuBarClock.interval) {
        guard self.ticker == nil else { return }
        self.tick()
        self.ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    public func stop() {
        self.ticker?.cancel()
        self.ticker = nil
    }

    public var isRunning: Bool { self.ticker != nil }
}

// MARK: Inbox

/// What the menu bar item lists: chats that need the user, active runs, unread chats and each
/// Gateway's status. Built from plain values so it can be checked without a connection.
public struct MenuBarInbox: Equatable, Sendable {
    public struct Item: Identifiable, Hashable, Sendable {
        public enum Kind: Sendable {
            case approval, question, running, unread

            /// Approval waits, a question asks, a run thinks, unread rests.
            public var pose: AvatarState {
                switch self {
                case .approval: .awaitingApproval
                case .question: .tool(.question)
                case .running: .thinking
                case .unread: .idle
                }
            }
        }

        public let id: String
        public let kind: Kind
        public let title: String
        private let petTitle: String?
        public let target: Notifier.Target
        /// The agent behind the row, for its pet; nil when the Gateway didn't say.
        public let agentId: String?
        /// The still pose the row's pet shows.
        public let pose: AvatarState

        public init(id: String, kind: Kind, title: String, target: Notifier.Target,
                    agentId: String? = nil, pose: AvatarState? = nil, petTitle: String? = nil)
        {
            self.id = id
            self.kind = kind
            self.title = title
            self.petTitle = petTitle
            self.target = target
            self.agentId = agentId
            self.pose = pose ?? kind.pose
        }

        /// Pet rows avoid repeating the agent emoji; text-only rows keep their original title.
        public func displayTitle(showingPet: Bool) -> String {
            showingPet ? self.petTitle ?? self.title : self.title
        }
    }

    public struct GatewayStatus: Identifiable, Hashable, Sendable {
        public enum Level: Sendable {
            case ok, warning, error, pending
        }

        public let id: UUID
        public let name: String
        public let text: String
        public let symbol: String
        public let level: Level

        /// For example "Home — Connected".
        public var title: String { "\(self.name) — \(self.text)" }
    }

    /// One saved Gateway, as the menu needs it.
    public struct GatewayInput: Sendable {
        public var id: UUID
        public var name: String
        public var state: ConnectionState
        public var healthLevel: GatewayHealthLevel
        public var sessions: [SessionRow]
        public var approvals: [ExecApproval]
        public var questions: [QuestionPrompt]
        public var agents: [AgentSummary]
        /// Chats the sidebar hides (automations, slash commands); they stay out of Unread like the badge.
        public var hiddenKeys: Set<String>

        public init(id: UUID = UUID(), name: String, state: ConnectionState, healthLevel: GatewayHealthLevel = .healthy,
                    sessions: [SessionRow] = [], approvals: [ExecApproval] = [], questions: [QuestionPrompt] = [],
                    agents: [AgentSummary] = [], hiddenKeys: Set<String> = [])
        {
            self.id = id
            self.name = name
            self.state = state
            self.healthLevel = healthLevel
            self.sessions = sessions
            self.approvals = approvals
            self.questions = questions
            self.agents = agents
            self.hiddenKeys = hiddenKeys
        }

        /// Same fallback as `GatewayStore.agent(_:)`.
        func agent(_ id: String) -> AgentSummary {
            self.agents.first { $0.id == id } ?? AgentSummary(id: id, name: id == "main" ? "Main" : id.capitalized)
        }
    }

    public static let needsYouLimit = 5
    public static let runningLimit = 5
    public static let unreadLimit = 8
    /// Longest chat title, command or question shown before it's cut with "…".
    public static let textLimit = 40

    /// Icon symbols; the alert one is used while something needs the user.
    public static let symbol = "bubble.left.and.text.bubble.right"
    public static let alertSymbol = "bubble.left.and.exclamationmark.bubble.right"

    public var needsYou: [Item] = []
    public var running: [Item] = []
    public var unread: [Item] = []
    public var needsYouOverflow = 0
    public var runningOverflow = 0
    public var unreadOverflow = 0
    /// Every unexpired approval and answerable question on a connected Gateway.
    public var needsYouCount = 0
    /// Every unread chat on a connected Gateway, including ones listed in another section.
    public var unreadCount = 0
    public var gateways: [GatewayStatus] = []
    public var hasConnectedGateway = false

    public init() {}

    /// No rows in Needs You, Running or Unread.
    public var isEmpty: Bool { self.needsYou.isEmpty && self.running.isEmpty && self.unread.isEmpty }

    /// Shows "You're all caught up": something is connected and nothing is listed.
    public var isCaughtUp: Bool { self.isEmpty && self.hasConnectedGateway }

    /// Number next to the icon: nil at zero, "99+" above 99.
    public var badgeText: String? {
        let total = self.unreadCount + self.needsYouCount
        guard total > 0 else { return nil }
        return total > 99 ? "99+" : "\(total)"
    }

    /// For example "Pincer, 2 unread, 1 needs you".
    public var accessibilityLabel: String {
        var parts = ["Pincer"]
        if self.unreadCount > 0 { parts.append("\(self.unreadCount) unread") }
        if self.needsYouCount > 0 { parts.append("\(self.needsYouCount) \(self.needsYouCount == 1 ? "needs" : "need") you") }
        return parts.joined(separator: ", ")
    }

    // MARK: Building

    public static func build(_ inputs: [GatewayInput], now: Date = Date()) -> MenuBarInbox {
        var inbox = MenuBarInbox()
        let showsGateway = inputs.count > 1
        inbox.gateways = inputs.map { input in
            let status = Self.statusText(state: input.state, healthLevel: input.healthLevel)
            return GatewayStatus(id: input.id, name: input.name, text: status.text, symbol: status.symbol, level: status.level)
        }
        let connected = inputs.filter { $0.state.isConnected }
        inbox.hasConnectedGateway = !connected.isEmpty

        struct Chat {
            let input: GatewayInput
            let row: SessionRow
            let gatewayIndex: Int
        }
        struct Key: Hashable {
            let gatewayId: UUID
            let sessionKey: String
        }
        func suffix(_ input: GatewayInput) -> String { showsGateway ? " — \(input.name)" : "" }
        func lookup(_ input: GatewayInput, _ key: String?) -> SessionRow? {
            guard let key, !key.isEmpty else { return nil }
            return input.sessions.first { $0.key == key }
                ?? input.sessions.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        }
        func needsYouItem(_ input: GatewayInput, id: String, kind: Item.Kind, text: String, sessionKey: String?,
                          agentId: String?) -> (Item, Key)
        {
            let row = lookup(input, sessionKey)
            let chat = row.map { " — \(Self.chatLabel(row: $0, agent: input.agent($0.agentId)))" } ?? ""
            let petChat = row.map { " — \(Self.chatLabel(row: $0, agent: input.agent($0.agentId), includeEmoji: false))" } ?? ""
            let key = row?.key ?? sessionKey ?? ""
            let target = Notifier.Target(gatewayId: input.id, sessionKey: key)
            return (Item(id: "\(kind):\(input.id.uuidString):\(id)", kind: kind, title: text + chat + suffix(input), target: target,
                         agentId: row?.agentId ?? agentId ?? sessionKey.flatMap(SessionKey.agentId(from:)),
                         petTitle: row.map { _ in text + petChat + suffix(input) }),
                    Key(gatewayId: input.id, sessionKey: key))
        }

        var needsYou: [Item] = []
        var claimed: Set<Key> = []
        for input in connected {
            for approval in input.approvals where !approval.isExpired(at: now) {
                let (item, key) = needsYouItem(input, id: approval.id, kind: .approval,
                                               text: "Approve: \(Self.truncated(approval.command))", sessionKey: approval.sessionKey, agentId: approval.agentId)
                needsYou.append(item)
                claimed.insert(key)
            }
        }
        for input in connected {
            for prompt in input.questions where prompt.isAnswerable(at: now) {
                let first = prompt.questions.first
                let text = first.map { $0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.header : $0.question } ?? ""
                let (item, key) = needsYouItem(input, id: prompt.id, kind: .question,
                                               text: "Question: \(Self.truncated(text))", sessionKey: prompt.sessionKey, agentId: prompt.agentId)
                needsYou.append(item)
                claimed.insert(key)
            }
        }
        inbox.needsYouCount = needsYou.count

        var chats: [Chat] = []
        for (index, input) in connected.enumerated() {
            for row in input.sessions where !row.isSubagent && !row.isArchived {
                chats.append(Chat(input: input, row: row, gatewayIndex: index))
            }
        }
        func newestFirst(_ chats: [Chat]) -> [Chat] {
            chats.sorted { lhs, rhs in
                if lhs.row.activityMs != rhs.row.activityMs { return lhs.row.activityMs > rhs.row.activityMs }
                if lhs.gatewayIndex != rhs.gatewayIndex { return lhs.gatewayIndex < rhs.gatewayIndex }
                return lhs.row.key < rhs.row.key
            }
        }
        func chatItem(_ chat: Chat, kind: Item.Kind) -> Item {
            let agent = chat.input.agent(chat.row.agentId)
            return Item(id: "\(kind):\(chat.input.id.uuidString):\(chat.row.key)", kind: kind,
                        title: Self.chatLabel(row: chat.row, agent: agent) + suffix(chat.input),
                        target: Notifier.Target(gatewayId: chat.input.id, sessionKey: chat.row.key),
                        agentId: chat.row.agentId,
                        petTitle: Self.chatLabel(row: chat.row, agent: agent, includeEmoji: false) + suffix(chat.input))
        }
        func key(_ chat: Chat) -> Key { Key(gatewayId: chat.input.id, sessionKey: chat.row.key) }

        let running = newestFirst(chats.filter { $0.row.hasActiveRun && !claimed.contains(key($0)) })
        claimed.formUnion(running.map(key))
        let unreadRows = chats.filter { $0.row.isUnread && !$0.input.hiddenKeys.contains($0.row.key) }
        inbox.unreadCount = unreadRows.count
        let unread = newestFirst(unreadRows.filter { !claimed.contains(key($0)) })

        (inbox.needsYou, inbox.needsYouOverflow) = Self.capped(needsYou, Self.needsYouLimit)
        (inbox.running, inbox.runningOverflow) = Self.capped(running.map { chatItem($0, kind: .running) }, Self.runningLimit)
        (inbox.unread, inbox.unreadOverflow) = Self.capped(unread.map { chatItem($0, kind: .unread) }, Self.unreadLimit)
        return inbox
    }

    /// Menu wording for a Gateway's connection: the health level wins while restarting.
    public static func statusText(state: ConnectionState, healthLevel: GatewayHealthLevel)
        -> (text: String, symbol: String, level: GatewayStatus.Level)
    {
        if healthLevel == .restarting { return ("Restarting…", "arrow.clockwise.circle", .pending) }
        switch state {
        case .connected:
            return healthLevel == .healthy
                ? ("Connected", "checkmark.circle", .ok)
                : ("Degraded", "exclamationmark.triangle", .warning)
        case .idle, .connecting: return ("Connecting…", "circle.dotted", .pending)
        case .reconnecting: return ("Reconnecting…", "exclamationmark.triangle", .warning)
        case .awaitingPairing: return ("Waiting for approval", "hourglass", .pending)
        case .failed: return ("Can't connect", "xmark.circle", .error)
        }
    }

    /// `🦞 home-lab · Claw`, like a notification's title.
    public static func chatLabel(row: SessionRow, agent: AgentSummary) -> String {
        Self.chatLabel(row: row, agent: agent, includeEmoji: true)
    }

    private static func chatLabel(row: SessionRow, agent: AgentSummary, includeEmoji: Bool) -> String {
        let prefix = includeEmoji ? agent.emoji.map { "\($0) " } ?? "" : ""
        return "\(prefix)\(Self.truncated(row.title)) · \(agent.name)"
    }

    /// One line, at most `textLimit` characters, ending in "…" when cut.
    public static func truncated(_ text: String, limit: Int = MenuBarInbox.textLimit) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        return line.prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func capped(_ items: [Item], _ limit: Int) -> ([Item], Int) {
        (Array(items.prefix(limit)), max(0, items.count - limit))
    }
}

extension MenuBarInbox {
    /// The live inbox for every saved Gateway, in rail order. Views pass `MenuBarClock.shared.now`,
    /// never the `Date()` default (checks use it), so expiry moves with the clock's tick.
    @MainActor
    public init(app: AppModel, now: Date = Date()) {
        self = Self.build(app.gateways.map { gateway in
            GatewayInput(id: gateway.id, name: gateway.profile.name, state: gateway.state, healthLevel: gateway.health.level(now: now),
                         sessions: Array(gateway.sessions.values), approvals: gateway.approvals, questions: gateway.questions,
                         agents: gateway.agents,
                         hiddenKeys: Set(gateway.sessions.values.filter(gateway.isHiddenInSidebar).map(\.key)))
        }, now: now)
    }
}
