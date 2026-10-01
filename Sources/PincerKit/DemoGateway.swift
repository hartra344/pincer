import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An in-process stand-in for a Gateway, so Pincer can be tried (and reviewed) without one.
/// It speaks the same request/event shapes as `mock-gateway/server.mjs`, with canned agents,
/// chats and streamed replies. Nothing leaves the device.
actor DemoGateway {
    static let url = "demo://pincer"
    /// The demo as an older Gateway that rejects `chat.send`'s `replyToId`, for checks.
    static let noReplyToURL = "demo://pincer?replyTo=off"
    /// The demo as an older Gateway without `session.reactions.*`, for checks of the `users.prefs` fallback.
    static let noSessionReactionsURL = "demo://pincer?sessionReactions=off"

    typealias Row = [String: JSONValue]

    struct Run {
        let sessionKey: String
        let text: String
        var seq = 0
        var task: Task<Void, Never>?
    }

    static let defaultModel = (provider: "anthropic", model: "claude-opus-4-8")
    static let contextTokens = 200_000
    static let modelCatalog: [JSONValue] = [
        ["id": "claude-opus-4-8", "name": "Claude Opus 4.8", "provider": "anthropic", "available": true],
        ["id": "claude-sonnet-5", "name": "Claude Sonnet 5", "provider": "anthropic", "available": true],
        ["id": "gpt-5.6-sol", "name": "GPT-5.6 Sol", "provider": "openai", "available": true],
        ["id": "gemini-3.8-flash", "name": "Gemini 3.8 Flash", "provider": "google", "available": false,
         "unavailableReason": "missing-auth"],
    ]
    static let methods = [
        "agents.list", "sessions.subscribe", "sessions.list", "sessions.groups.list", "sessions.groups.put",
        "sessions.groups.rename", "sessions.groups.delete", "sessions.messages.subscribe",
        "sessions.messages.unsubscribe", "chat.history", "chat.send", "chat.abort", "sessions.patch", "models.list",
        "sessions.create", "artifacts.download", "exec.approval.list", "exec.approval.resolve", "users.prefs.get",
        "users.prefs.set", "commands.list", "progressCard.get", "progressCard.put", "question.list", "question.resolve",
        "approval.history", "approval.get", "logs.tail", "channels.pairing.list", "channels.pairing.approve", "channels.pairing.dismiss",
        "health", "status", "last-heartbeat", "system-presence", "gateway.restart.request",
        "exec.approvals.get", "exec.approvals.set", "message.action",
    ] + DemoUsage.methods + DemoGateway.setupMethods + DemoGateway.agentMethods + DemoGateway.channelLifecycleMethods + DemoGateway.skillMethods + DemoGateway.deviceMethods
        + DemoGateway.sessionManagerMethods + DemoGateway.mcpMethods + DemoGateway.voiceMethods
    /// The device the demo credits with decisions made in Pincer ("Decided by: This device").
    static let deviceId = "demo0device0000000000000000000000000000000000000000000000000001"

    /// The roster (`agents.list`); `agents.create/update/delete` edit it (DemoGateway+Agents.swift).
    var agents: [JSONValue] = [
        ["id": "main", "name": "Claw", "identity": ["name": "Claw", "emoji": "🦞"]],
        ["id": "research", "name": "Scout", "identity": ["name": "Scout", "emoji": "🔭"]],
        ["id": "coder", "name": "Forge", "identity": ["name": "Forge", "emoji": "🛠️"]],
        ["id": "kiko", "name": "Kiko", "identity": ["name": "Kiko", "emoji": "🌕"]],
        ["id": "mochi", "name": "Mochi", "identity": ["name": "Mochi", "emoji": "📦"]],
    ]
    var sessions: [String: Row] = [:]
    var transcripts: [String: [JSONValue]] = [:]
    /// Inactive transcript branches by session key, then leaf entry id (DemoGateway+Sessions.swift).
    var branchTips: [String: [String: [JSONValue]]] = [:]
    /// Finishes the seeded run in flight a while after the first connection (DemoGateway+Sessions.swift).
    var seededRunEnd: Task<Void, Never>?
    var artifacts: [String: (mimeType: String, data: Data)] = [:]
    var approvals: [String: JSONValue] = [:]
    var approvalOrder: [String] = []
    /// Answered approvals and their decision, so retries behave like the Gateway's.
    var resolvedApprovals: [String: String] = [:]
    /// Terminal approvals, newest first (`approval.history`).
    var approvalHistory: [JSONValue] = []
    /// The simulated Gateway log file (`logs.tail`).
    var logs = DemoGatewayLogs()
    /// The exec approvals file (`exec.approvals.get/set`). The demo keeps no socket token.
    var execApprovals = DemoGateway.seedExecApprovals()
    /// WhatsApp link state and the running QR login (`DemoGateway+Setup.swift`).
    var setup = DemoSetupState()
    /// Channels stopped or logged out from Channel Status (`DemoGateway+Channels.swift`).
    var channelLifecycle = DemoChannelsState()
    var agentIds: [String] { self.agents.compactMap { $0["id"]?.text } }
    func hasSession(_ key: String) -> Bool { self.sessions[key] != nil }
    var execApprovalsExists = true
    /// Agent workspace files by workspace path (`agents.files.*`).
    var agentWorkspaces = DemoGateway.seedAgentWorkspaces()
    /// `skills.status` entries (DemoGateway+Skills.swift; seeds in DemoSkillsSeed.swift).
    var skillEntries = DemoGateway.seedSkills()
    /// The simulated ClawHub registry (`skills.search/detail`, ClawHub installs and updates).
    var clawHubCatalog = DemoGateway.seedClawHubCatalog()
    /// `ask_user` prompts by id, in the order they were asked.
    var questions: [String: JSONValue] = [:]
    var questionOrder: [String] = []
    /// Pending DM pairing requests (`channels.pairing.*`).
    /// Seeded on first use, so the request about to expire (2 minutes) is timed from when pairing is first opened (#499).
    var pairingRequests: [JSONValue] {
        get {
            if self.seededPairingRequests == nil { self.seededPairingRequests = Self.seedPairingRequests() }
            return self.seededPairingRequests ?? []
        }
        set { self.seededPairingRequests = newValue }
    }
    private var seededPairingRequests: [JSONValue]?
    /// Device pairing (`device.pair.*`) and nodes (`node.*`), from the seeds in DemoGateway+Devices.swift.
    var devicePending: [JSONValue] = []
    var devicePaired: [JSONValue] = []
    var demoNodes: [JSONValue] = []
    var prefs: [String: JSONValue] = [:]
    var voice = DemoVoiceState()
    /// Custom group catalog in display order; groups stay until deleted, even when empty.
    var groups = ["Home", "Personal", "Reading", "Work", "Preparations", "Day of move"]
    var progressCards: [String: JSONValue] = [:]
    var idempotency: [String: String] = [:]
    var runs: [String: Run] = [:]
    var sessionsSubscribed = false
    var holdsHistory = false
    var heldHistory: [CheckedContinuation<Void, Never>] = []
    var historyRequestCounts: [String: Int] = [:]
    /// The seeded runs' activity streams once per demo connection (DemoGateway+Subagents.swift).
    var replayedSeededRuns = false
    /// The seeded running subagent's run: stoppable, but not an active run that defers a restart.
    var seededRunningRuns = [DemoGateway.seededRunningSubagentRunId: DemoGateway.seededSubagents.running]
    /// The last `agent` seq the seeded running helper sent; it keeps streaming tool calls until stopped.
    var seededRunningSeq = DemoGateway.seededRunningLastSeq
    var seededStreamTask: Task<Void, Never>?
    /// Shared reactions by session key, then message id (DemoGateway+Reactions.swift).
    var sessionReactions: [String: [String: [DemoReaction]]] = [:]
    /// Observer ids by session key; "" is the slot used when `subscriptionId` is omitted.
    var messageSubscriptions: [String: Set<String>] = [:]
    var eventSeq = 0
    var sink: (@Sendable (GatewayEvent) -> Void)?
    /// When the simulated Gateway process started; reset by a restart.
    var startedAt = Date().addingTimeInterval(-(3 * 86400 + 4 * 3600 + 17 * 60))
    /// While set, a simulated restart is under way and `attach` waits until then.
    var restartingUntil: Date?
    var restartTask: Task<Void, Never>?
    static let restartExpectedMs = 1500

    /// Whether `chat.send` takes `replyToId`, like current Gateways.
    let acceptsReplyTo: Bool
    /// Whether a finished reply turns its chat unread, like Gateways with openclaw/openclaw#155690.
    /// Released Gateways don't (#426); tests turn it off to play one.
    var repliesMarkUnread = true
    func setRepliesMarkUnread(_ marks: Bool) { self.repliesMarkUnread = marks }
    /// `message.action` calls received, oldest first.
    var recordedActions: [JSONValue] = []
    /// MCP servers config and status (DemoGateway+MCP.swift).
    var mcp = DemoMCPState()

    /// Whether the Gateway has `session.reactions.*` and `users.self` (an older one doesn't: the users.prefs fallback).
    let hasSessionReactions: Bool

    init(acceptsReplyTo: Bool = true, hasSessionReactions: Bool = true) {
        self.acceptsReplyTo = acceptsReplyTo
        self.hasSessionReactions = hasSessionReactions
        self.prefs[Reactions.prefKey] = [
            "agent:main:main|demo-main-status": "👍",
            "agent:main:main|demo-main-gauge": "🎉",
        ]
        self.prefs.merge(DemoBookmarks.prefEntries()) { _, new in new }
        var seeded = Self.seed()
        self.branchTips = Self.seedSessionManager(sessions: &seeded.sessions, transcripts: &seeded.transcripts)
        self.sessions = seeded.sessions
        self.transcripts = seeded.transcripts
        self.sessionReactions = Self.seedSessionReactions()
        Self.seedSubagents(sessions: &self.sessions, transcripts: &self.transcripts)
        self.approvalHistory = Self.seedApprovalHistory()
        let pending = Self.seedPendingApproval()
        if let id = pending["id"]?.string {
            self.approvals[id] = pending
            self.approvalOrder.append(id)
        }
        self.devicePending = Self.seedPendingDevices()
        self.devicePaired = Self.seedPairedDevices()
        self.demoNodes = Self.seedNodes()
        self.artifacts["demo-chart"] = ("image/png", Self.chartPNG())
        self.artifacts["demo-script"] = ("text/x-shellscript", Data(Self.diskScript.utf8))
        self.artifacts[Self.richRenderingPDFId] = ("application/pdf", Self.richRenderingPDF())
    }

    /// A small `commands.list` answer, shaped like the Gateway's `scope: "text"` catalog.
    static let commandCatalog: [JSONValue] = {
        func command(_ name: String, _ description: String, aliases: [String] = [], category: String,
                     source: String = "native", args: [JSONValue] = [], acceptsArgs: Bool? = nil) -> JSONValue
        {
            [
                "name": .string(name), "textAliases": JSONValue(([name] + aliases).map { "/\($0)" }),
                "description": .string(description), "category": .string(category), "source": .string(source),
                "scope": "both", "acceptsArgs": .bool(acceptsArgs ?? !args.isEmpty), "args": .array(args),
            ]
        }
        func arg(_ name: String, _ description: String, choices: [String]? = nil, dynamic: Bool = false) -> JSONValue {
            var arg: [String: JSONValue] = ["name": .string(name), "description": .string(description), "type": "string"]
            if let choices { arg["choices"] = .array(choices.map { ["value": .string($0), "label": .string($0)] }) }
            if dynamic { arg["dynamic"] = true }
            return .object(arg)
        }
        return [
            command("help", "Show available commands.", category: "status"),
            command("status", "Show current status.", category: "status"),
            command("new", "Start a new session.", category: "session", acceptsArgs: true),
            command("reset", "Reset the current session.", category: "session", acceptsArgs: true),
            command("compact", "Compact the session context.", category: "session",
                    args: [arg("instructions", "Extra compaction instructions")]),
            command("stop", "Stop the current run.", category: "session"),
            command("restart", "Restart OpenClaw.", category: "tools"),
            command("model", "Show or set the model; use -s, -a, or -g to choose scope.", category: "options",
                    args: [arg("model", "Model id; add -s for session, -a for agent, or -g for global scope")]),
            command("think", "Set thinking level.", aliases: ["thinking", "t"], category: "options",
                    args: [arg("level", "Thinking level", dynamic: true)]),
            command("verbose", "Toggle verbose mode.", aliases: ["v"], category: "options",
                    args: [arg("mode", "on, off, or full", choices: ["on", "off", "full"])]),
            command("reasoning", "Toggle reasoning visibility.", aliases: ["reason"], category: "options",
                    args: [arg("mode", "on, off, or stream", choices: ["on", "off", "stream"])]),
            command("summarize", "Summarize a URL or file.", category: "tools", source: "skill", acceptsArgs: true),
        ]
    }()

    // MARK: Connection

    func attach(_ sink: @escaping @Sendable (GatewayEvent) -> Void) async -> JSONValue {
        // Like a Gateway coming back up: nobody gets in until the restart is done.
        while let until = self.restartingUntil, until > Date() {
            try? await Task.sleep(for: .milliseconds(max(50, Int(until.timeIntervalSinceNow * 1000))))
        }
        if self.restartingUntil != nil {
            self.restartingUntil = nil
            self.startedAt = Date()
        }
        self.sink = sink
        self.sessionsSubscribed = false
        self.messageSubscriptions.removeAll()
        self.scheduleSeededRunEnd()
        return [
            "type": "hello-ok",
            "protocol": .number(Double(GatewayConnection.protocolVersion)),
            "server": ["version": "demo", "connId": .string(Self.shortId("conn_"))],
            "features": ["methods": JSONValue(self.advertisedMethods), "events": JSONValue(self.hasSessionReactions ? ["session.reaction"] : [])],
            "snapshot": [
                "presence": .array(self.presence()),
                "health": self.health(),
                "stateVersion": ["presence": 1, "health": 1],
                "uptimeMs": .number((Date().timeIntervalSince(self.startedAt) * 1000).rounded()),
            ],
            // operator.pairing lets the demo show Pairing Requests without making settings editable.
            "auth": ["role": "operator", "scopes": JSONValue(GatewayConnection.scopes + [PairingInboxModel.pairingScope])],
            "policy": [
                "maxPayload": 26_214_400,
                "tickIntervalMs": 15000,
                "attachments": ["maxBytes": 20_000_000, "maxImageBytes": 5_000_000],
            ],
        ]
    }

    func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if let result = try self.handleAgents(method, params) { return result }
        if let result = try await self.handleChannelLifecycle(method, params) { return result }
        if let result = try self.handleDevices(method, params) { return result }
        if let result = try await self.handleMCP(method, params) { return result }
        if let result = try self.handleSkills(method, params) { return result }
        if let result = try self.handleSessionManager(method, params) { return result }
        if let result = try self.handleVoice(method, params) { return result }
        if let result = try self.handleCatalog(method, params) { return result }
        if let result = try self.handleReactions(method, params) { return result }
        if let result = try await self.handleSessionList(method, params) { return result }
        if let result = try self.handleGroups(method, params) { return result }
        if let result = try self.handleRuns(method, params) { return result }
        if let result = try self.handleApprovals(method, params) { return result }
        if let result = try self.handleChannelPairing(method, params) { return result }
        if let result = try self.handleQuestions(method, params) { return result }
        if let result = try self.handleHealth(method, params) { return result }
        if Self.setupMethods.contains(method) || Self.webLoginMethods.contains(method) {
            return try await self.handleSetup(method, params) ?? .null
        }
        throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "The demo doesn't support \(method).", details: nil)
    }

    var restartSkipsDeferral = false
    var telegramRecovered = false

    var actionResults: [String: JSONValue] = [:]

}
