import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An in-process stand-in for a Gateway, so Pincer can be tried (and reviewed) without one.
/// It speaks the same request/event shapes as `mock-gateway/server.mjs`, with canned agents,
/// chats and streamed replies. Nothing leaves the device.
actor DemoGateway {
    static let url = "demo://pincer"

    private typealias Row = [String: JSONValue]

    private struct Run {
        let sessionKey: String
        let text: String
        var seq = 0
        var task: Task<Void, Never>?
    }

    private static let defaultModel = (provider: "anthropic", model: "claude-opus-4-8")
    private static let contextTokens = 200_000
    private static let modelCatalog: [JSONValue] = [
        ["id": "claude-opus-4-8", "name": "Claude Opus 4.8", "provider": "anthropic", "available": true],
        ["id": "claude-sonnet-5", "name": "Claude Sonnet 5", "provider": "anthropic", "available": true],
        ["id": "gpt-5.6-sol", "name": "GPT-5.6 Sol", "provider": "openai", "available": true],
        ["id": "gemini-3.8-flash", "name": "Gemini 3.8 Flash", "provider": "google", "available": false,
         "unavailableReason": "missing-auth"],
    ]
    private static let methods = [
        "agents.list", "sessions.subscribe", "sessions.list", "sessions.groups.list", "sessions.groups.put",
        "sessions.groups.rename", "sessions.groups.delete", "sessions.messages.subscribe",
        "sessions.messages.unsubscribe", "chat.history", "chat.send", "chat.abort", "sessions.patch", "models.list",
        "sessions.create", "artifacts.download", "exec.approval.list", "exec.approval.resolve", "users.prefs.get",
        "users.prefs.set", "commands.list", "progressCard.get", "progressCard.put", "question.list", "question.resolve",
        "approval.history", "approval.get", "exec.approvals.get", "exec.approvals.set",
    ]
    /// The device the demo credits with decisions made in Pincer ("Decided by: This device").
    static let deviceId = "demo0device0000000000000000000000000000000000000000000000000001"

    private let agents: [JSONValue] = [
        ["id": "main", "name": "Claw", "identity": ["name": "Claw", "emoji": "🦞"]],
        ["id": "research", "name": "Scout", "identity": ["name": "Scout", "emoji": "🔭"]],
        ["id": "coder", "name": "Forge", "identity": ["name": "Forge", "emoji": "🛠️"]],
    ]
    private var sessions: [String: Row] = [:]
    private var transcripts: [String: [JSONValue]] = [:]
    private var artifacts: [String: (mimeType: String, data: Data)] = [:]
    private var approvals: [String: JSONValue] = [:]
    private var approvalOrder: [String] = []
    /// Answered approvals and their decision, so retries behave like the Gateway's.
    private var resolvedApprovals: [String: String] = [:]
    /// Terminal approvals, newest first (`approval.history`).
    private var approvalHistory: [JSONValue] = []
    /// The exec approvals file (`exec.approvals.get/set`). The demo keeps no socket token.
    var execApprovals = DemoGateway.seedExecApprovals()
    var execApprovalsExists = true
    /// `ask_user` prompts by id, in the order they were asked.
    private var questions: [String: JSONValue] = [:]
    private var questionOrder: [String] = []
    private var prefs: [String: JSONValue] = [:]
    /// Custom group catalog in display order; groups stay until deleted, even when empty.
    private var groups = ["Home", "Personal", "Work"]
    private var progressCards: [String: JSONValue] = [:]
    private var idempotency: [String: String] = [:]
    private var runs: [String: Run] = [:]
    private var sessionsSubscribed = false
    private var messageSubscriptions: Set<String> = []
    private var eventSeq = 0
    private var sink: (@Sendable (GatewayEvent) -> Void)?

    init() {
        let seeded = Self.seed()
        self.sessions = seeded.sessions
        self.transcripts = seeded.transcripts
        self.approvalHistory = Self.seedApprovalHistory()
        self.artifacts["demo-chart"] = ("image/png", Self.chartPNG())
        self.artifacts["demo-script"] = ("text/x-shellscript", Data(Self.diskScript.utf8))
    }

    /// A small `commands.list` answer, shaped like the Gateway's `scope: "text"` catalog.
    private static let commandCatalog: [JSONValue] = {
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

    func attach(_ sink: @escaping @Sendable (GatewayEvent) -> Void) -> JSONValue {
        self.sink = sink
        self.sessionsSubscribed = false
        self.messageSubscriptions.removeAll()
        return [
            "type": "hello-ok",
            "protocol": .number(Double(GatewayConnection.protocolVersion)),
            "server": ["version": "demo", "connId": .string(Self.shortId("conn_"))],
            "features": ["methods": JSONValue(Self.methods), "events": []],
            "snapshot": [:],
            "auth": ["role": "operator", "scopes": JSONValue(GatewayConnection.scopes)],
            "policy": [
                "maxPayload": 26_214_400,
                "tickIntervalMs": 15000,
                "attachments": ["maxBytes": 20_000_000, "maxImageBytes": 5_000_000],
            ],
        ]
    }

    func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
        switch method {
        case "agents.list":
            return ["defaultId": "main", "mainKey": "main", "scope": "per-sender", "agents": .array(self.agents)]
        case "sessions.subscribe":
            self.sessionsSubscribed = true
            return ["subscribed": true, "list": self.sessionList(params)]
        case "sessions.list":
            return self.sessionList(params)
        case "sessions.groups.list":
            return self.groupCatalog()
        case "sessions.groups.put":
            return try self.putGroups(params)
        case "sessions.groups.rename":
            return try self.renameGroup(params)
        case "sessions.groups.delete":
            return try self.deleteGroup(params)
        case "sessions.messages.subscribe":
            let key = try self.knownSession(params["key"])
            self.messageSubscriptions.insert(key)
            return ["subscribed": true, "key": .string(key)]
        case "sessions.messages.unsubscribe":
            if let key = params["key"]?.string { self.messageSubscriptions.remove(key) }
            return ["ok": true, "key": params["key"] ?? .null]
        case "chat.history":
            return try self.history(params)
        case "chat.send":
            return try self.send(params)
        case "chat.abort":
            self.abort(sessionKey: params["sessionKey"]?.string, runId: params["runId"]?.string)
            return ["aborted": true]
        case "sessions.patch":
            return try self.patch(params)
        case "models.list":
            return ["models": .array(Self.modelCatalog)]
        case "commands.list":
            return ["commands": .array(Self.commandCatalog)]
        case "sessions.create":
            return self.create(params)
        case "artifacts.download":
            guard let id = params["artifactId"]?.string, let artifact = self.artifacts[id] else {
                throw GatewayError.rpc(code: "NOT_FOUND", message: "artifact not found", details: nil)
            }
            return ["artifactId": .string(id), "mimeType": .string(artifact.mimeType), "encoding": "base64",
                    "data": .string(artifact.data.base64EncodedString())]
        case "users.prefs.get":
            let keys = params["keys"]?.array?.compactMap(\.string) ?? Array(self.prefs.keys)
            return ["status": "ok", "entries": .object(self.prefs.filter { keys.contains($0.key) })]
        case "users.prefs.set":
            return self.setPrefs(params)
        case "progressCard.get":
            return ["card": self.progressCards[try self.knownSession(params["sessionKey"])] ?? .null]
        case "progressCard.put":
            return try self.putProgressCard(params)
        case "exec.approval.list":
            return ["approvals": .array(self.approvalOrder.compactMap { self.approvals[$0] })]
        case "exec.approval.resolve":
            guard let id = params["id"]?.string, let decision = params["decision"]?.string,
                  ["allow-once", "allow-always", "deny"].contains(decision)
            else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid decision", details: nil) }
            if let previous = self.resolvedApprovals[id] {
                guard previous == decision else {
                    throw GatewayError.rpc(code: "INVALID_REQUEST", message: "approval already resolved",
                                           details: ["reason": "APPROVAL_ALREADY_RESOLVED"])
                }
                return ["ok": true, "id": .string(id), "decision": .string(decision)]
            }
            guard let approval = self.approvals[id],
                  (approval["expiresAtMs"]?.double ?? .infinity) > (Self.now().double ?? 0)
            else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "approval expired or not found",
                                       details: ["reason": "APPROVAL_NOT_FOUND"])
            }
            if decision == "allow-always",
               approval["request"]?["allowedDecisions"]?.array?.contains(.string("allow-always")) == false
            {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "allow-always is unavailable for this command",
                                       details: ["reason": "APPROVAL_ALLOW_ALWAYS_UNAVAILABLE"])
            }
            self.resolvedApprovals[id] = decision
            if decision == "allow-always" { self.appendAllowAlways(approval) }
            self.approvalHistory.insert(Self.resolvedRecord(approval, decision: decision), at: 0)
            self.approvals[id] = nil
            self.approvalOrder.removeAll { $0 == id }
            self.emit("exec.approval.resolved", ["id": .string(id), "decision": .string(decision)])
            return ["ok": true, "id": .string(id), "decision": .string(decision)]
        case "approval.history":
            return try self.approvalHistoryPage(params)
        case "approval.get":
            return try self.approvalSnapshot(params)
        case "exec.approvals.get":
            return try self.execApprovalsGet(params)
        case "exec.approvals.set":
            return try self.execApprovalsSet(params)
        case "question.list":
            return ["questions": .array(self.questionOrder.compactMap { self.questions[$0] }
                    .filter { $0["status"]?.string == "pending" })]
        case "question.resolve":
            return try self.resolveQuestion(params)
        default:
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "The demo doesn't support \(method).", details: nil)
        }
    }

    // MARK: Approval history

    private func approvalHistoryPage(_ params: JSONValue) throws -> JSONValue {
        let limit = max(1, min(100, params["limit"]?.int ?? 50))
        var offset = 0
        if let cursor = params["cursor"]?.string {
            guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8),
                  let value = Int(text), value >= 0
            else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid approval.history cursor", details: nil) }
            offset = value
        }
        let kind = params["kind"]?.string
        let matching = self.approvalHistory.filter { kind == nil || $0["presentation"]?["kind"]?.string == kind }
        let page = Array(matching.dropFirst(offset).prefix(limit))
        var result: Row = ["items": .array(page)]
        if offset + page.count < matching.count {
            result["nextCursor"] = .string(Data(String(offset + page.count).utf8).base64EncodedString())
        }
        return .object(result)
    }

    private func approvalSnapshot(_ params: JSONValue) throws -> JSONValue {
        let id = params["id"]?.string
        if let id, let pending = self.approvals[id] {
            let request = pending["request"] ?? [:]
            var snapshot: Row = [
                "id": .string(id), "urlPath": .string("/approve/\(id)"), "status": "pending",
                "createdAtMs": pending["createdAtMs"] ?? Self.now(), "expiresAtMs": pending["expiresAtMs"] ?? Self.now(),
                "presentation": Self.execPresentation(request),
            ]
            if let key = request["sessionKey"] { snapshot["sourceSessionKey"] = key }
            return ["approval": .object(snapshot)]
        }
        guard let id, let record = self.approvalHistory.first(where: { $0["id"]?.string == id }) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "approval not found",
                                   details: ["reason": "APPROVAL_NOT_FOUND"])
        }
        return ["approval": record]
    }

    private static func execPresentation(_ request: JSONValue) -> JSONValue {
        var presentation: Row = [
            "kind": "exec", "commandText": request["command"] ?? "(command)",
            "allowedDecisions": ["allow-once", "allow-always", "deny"],
        ]
        if let agentId = request["agentId"] { presentation["agentId"] = agentId }
        if let warning = request["warningText"] { presentation["warningText"] = warning }
        return .object(presentation)
    }

    /// A decision made in Pincer, as the Gateway's ledger records it.
    private static func resolvedRecord(_ pending: JSONValue, decision: String) -> JSONValue {
        let request = pending["request"] ?? [:]
        let id = pending["id"]?.string ?? Self.shortId("approval_")
        var source: Row = [:]
        if let agentId = request["agentId"] { source["agentId"] = agentId }
        if let key = request["sessionKey"] { source["sessionKey"] = key }
        return [
            "id": .string(id), "urlPath": .string("/approve/\(id)"),
            "createdAtMs": pending["createdAtMs"] ?? Self.now(), "expiresAtMs": pending["expiresAtMs"] ?? Self.now(),
            "resolvedAtMs": Self.now(), "status": decision == "deny" ? "denied" : "allowed",
            "decision": .string(decision), "reason": "user", "source": .object(source),
            "resolver": ["kind": "device", "id": .string(Self.deviceId)],
            "presentation": Self.execPresentation(request),
        ]
    }

    /// A dozen past decisions covering every kind, status and resolver.
    private static func seedApprovalHistory() -> [JSONValue] {
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        let minute = 60_000.0
        func record(_ id: String, ago minutes: Double, status: String, decision: String?, reason: String,
                    agent: String, session: String?, resolver: JSONValue?, presentation: JSONValue) -> JSONValue
        {
            let resolved = now - minutes * minute
            var row: Row = [
                "id": .string(id), "urlPath": .string("/approve/\(id)"),
                "createdAtMs": .number(resolved - 45_000), "expiresAtMs": .number(resolved - 45_000 + 120_000),
                "resolvedAtMs": .number(resolved), "status": .string(status), "reason": .string(reason),
                "presentation": presentation,
            ]
            if let decision { row["decision"] = .string(decision) }
            var source: Row = ["agentId": .string(agent)]
            if let session { source["sessionKey"] = .string(session) }
            row["source"] = .object(source)
            if let resolver { row["resolver"] = resolver }
            return .object(row)
        }
        func exec(_ command: String, agent: String, warning: String? = nil, host: String? = nil) -> JSONValue {
            var presentation: Row = ["kind": "exec", "commandText": .string(command), "agentId": .string(agent),
                                     "allowedDecisions": ["allow-once", "allow-always", "deny"]]
            if let warning { presentation["warningText"] = .string(warning) }
            if let host { presentation["host"] = .string(host) }
            return .object(presentation)
        }
        func plugin(_ title: String, _ description: String, detail: String? = nil, severity: String, pluginId: String,
                    tool: String, agent: String) -> JSONValue
        {
            var presentation: Row = [
                "kind": "plugin", "title": .string(title), "description": .string(description), "severity": .string(severity),
                "pluginId": .string(pluginId), "toolName": .string(tool), "agentId": .string(agent),
                "allowedDecisions": ["allow-once", "deny"],
            ]
            if let detail { presentation["detail"] = .string(detail) }
            return .object(presentation)
        }
        func system(_ title: String, _ description: String, agent: String) -> JSONValue {
            ["kind": "system-agent", "title": .string(title), "description": .string(description),
             "proposalHash": .string(String(repeating: "ab", count: 32)), "agentId": .string(agent),
             "allowedDecisions": ["allow-once", "deny"]]
        }
        let me: JSONValue = ["kind": "device", "id": .string(Self.deviceId)]
        let laptop: JSONValue = ["kind": "device", "id": "7f3a9c2e1b8d4f6a0c5e9b2d7a1f3c8e6b4d0a9f2c7e5b1d8a3f6c0e9b2d4a7f"]
        let discord: JSONValue = ["kind": "channel", "id": "discord"]
        let systemResolver: JSONValue = ["kind": "system"]
        return [
            record("hist_disk", ago: 12, status: "allowed", decision: "allow-once", reason: "user", agent: "main",
                   session: "agent:main:main", resolver: me, presentation: exec("df -h /", agent: "main", host: "gateway")),
            record("hist_brew", ago: 55, status: "allowed", decision: "allow-always", reason: "user", agent: "coder",
                   session: "agent:coder:main", resolver: laptop, presentation: exec("brew upgrade --quiet", agent: "coder")),
            record("hist_rm", ago: 130, status: "denied", decision: "deny", reason: "user", agent: "coder",
                   session: "agent:coder:main", resolver: me,
                   presentation: exec("rm -rf ~/Library/Caches", agent: "coder", warning: "Deletes files outside the workspace.")),
            record("hist_email", ago: 240, status: "allowed", decision: "allow-once", reason: "user", agent: "main",
                   session: "agent:main:dashboard:trip", resolver: discord,
                   presentation: plugin("Send email", "Email the Kyoto itinerary to 2 recipients.",
                                        detail: "To: travel@example.com, family@example.com\nSubject: Kyoto day plan",
                                        severity: "warning", pluginId: "mail", tool: "send_email", agent: "main")),
            record("hist_curl", ago: 360, status: "expired", decision: nil, reason: "timeout", agent: "research",
                   session: "agent:research:dashboard:papers", resolver: nil,
                   presentation: exec("curl -sSL https://arxiv.org/list/cs.AI/new | head -n 200", agent: "research")),
            record("hist_config", ago: 600, status: "allowed", decision: "allow-once", reason: "user", agent: "main",
                   session: "agent:main:main", resolver: me,
                   presentation: system("Turn on nightly backups", "Adds a nightly backup automation for the workspace.", agent: "main")),
            record("hist_orphan", ago: 900, status: "denied", decision: "deny", reason: "no-route", agent: "research",
                   session: "agent:research:main", resolver: systemResolver,
                   presentation: exec("pip install --user feedparser", agent: "research")),
            record("hist_payment", ago: 1_440, status: "denied", decision: "deny", reason: "malformed-verdict", agent: "main",
                   session: "agent:main:discord:channel:123", resolver: discord,
                   presentation: plugin("Buy domain", "Register pincer-demo.dev for $12.", severity: "critical",
                                        pluginId: "registrar", tool: "purchase", agent: "main")),
            record("hist_git", ago: 2_000, status: "cancelled", decision: nil, reason: "run-aborted", agent: "coder",
                   session: "agent:coder:main", resolver: nil,
                   presentation: exec("git push --force origin main", agent: "coder", warning: "Force-pushes over remote history.")),
            record("hist_restart", ago: 3_100, status: "cancelled", decision: nil, reason: "gateway-restart", agent: "main",
                   session: nil, resolver: nil, presentation: system("Update OpenClaw", "Installs OpenClaw 2026.9.2 and restarts.", agent: "main")),
            record("hist_notes", ago: 5_000, status: "allowed", decision: "allow-always", reason: "user", agent: "research",
                   session: "agent:research:main", resolver: ["kind": "runtime"],
                   presentation: plugin("Read notes", "Read the Research folder in Notes.", severity: "info",
                                        pluginId: "notes", tool: "read_notes", agent: "research")),
            record("hist_ls", ago: 8_000, status: "allowed", decision: "allow-once", reason: "user", agent: "main",
                   session: "agent:main:main", resolver: laptop, presentation: exec("ls -la ~/projects", agent: "main")),
        ]
    }

    // MARK: Sessions

    private func knownSession(_ key: JSONValue?) throws -> String {
        guard let key = key?.string, self.sessions[key] != nil else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown session", details: nil)
        }
        return key
    }

    private func sessionList(_ params: JSONValue) -> JSONValue {
        let includeArchived = params["archived"]?.bool == true || params["archived"]?.string == "all"
        let rows = self.sessions.values
            .filter { includeArchived || $0["archived"]?.bool != true }
            .sorted { lhs, rhs in
                let (lp, rp) = (lhs["pinned"]?.bool == true, rhs["pinned"]?.bool == true)
                if lp != rp { return lp }
                return (lhs["lastActivityAt"]?.double ?? 0) > (rhs["lastActivityAt"]?.double ?? 0)
            }
            .map(JSONValue.object)
        return [
            "sessions": .array(rows),
            "defaults": ["model": .string(Self.defaultModel.model), "modelProvider": .string(Self.defaultModel.provider),
                         "contextTokens": JSONValue(Self.contextTokens)],
            "nextOffset": nil,
            "hasMore": false,
        ]
    }

    private func history(_ params: JSONValue) throws -> JSONValue {
        let key = try self.knownSession(params["sessionKey"])
        let row = self.sessions[key] ?? [:]
        let transcript = self.transcripts[key] ?? []
        let limit = max(0, params["limit"]?.int ?? transcript.count)
        let offset = max(0, params["offset"]?.int ?? 0)
        let end = max(0, transcript.count - offset)
        let start = max(0, end - limit)
        var result: Row = [
            "sessionKey": .string(key),
            "sessionId": row["sessionId"] ?? .null,
            "messages": .array(Array(transcript[start..<end])),
            "totalMessages": JSONValue(transcript.count),
            "hasMore": .bool(start > 0),
            "thinkingLevel": "medium",
            "sessionInfo": ["hasActiveRun": row["hasActiveRun"] ?? false, "activeRunIds": row["activeRunIds"] ?? []],
        ]
        if start > 0 { result["nextOffset"] = JSONValue(offset + end - start) }
        if let runId = row["activeRunIds"]?.array?.first?.string, let run = self.runs[runId] {
            result["inFlightRun"] = ["runId": .string(runId), "text": .string(run.text)]
        }
        return .object(result)
    }

    private func patch(_ params: JSONValue) throws -> JSONValue {
        let key = try self.knownSession(params["key"])
        var row = self.sessions[key] ?? [:]
        if let expected = params["expectedSessionId"]?.string, expected != row["sessionId"]?.string {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "expectedSessionId mismatch", details: nil)
        }
        for field in ["unread", "pinned", "label", "category", "color", "archived"] {
            if let value = params[field] { row[field] = value }
        }
        self.registerGroup(params["category"]?.string)
        if let model = params["model"] {
            if model.isNull {
                row["model"] = .string(Self.defaultModel.model)
                row["modelProvider"] = .string(Self.defaultModel.provider)
                row["modelOverrideSource"] = .null
            } else {
                let parts = (model.string ?? "").split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let choice = Self.modelCatalog.first(where: { $0["provider"]?.string == parts[0] && $0["id"]?.string == parts[1] })
                else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "model not allowed", details: nil) }
                guard choice["available"]?.bool == true else {
                    throw GatewayError.rpc(code: "UNAVAILABLE", message: "That model isn't set up in the demo.", details: nil)
                }
                row["model"] = .string(parts[1])
                row["modelProvider"] = .string(parts[0])
                row["modelOverrideSource"] = "user"
            }
        }
        if let label = params["label"] {
            row["derivedTitle"] = label.isNull ? (row["isMain"]?.bool == true ? "Main" : row["derivedTitle"] ?? .null) : label
        }
        self.touch(&row)
        self.sessions[key] = row
        self.sessionChanged(key, reason: "patch")
        return ["ok": true, "key": .string(key), "entry": .object(row)]
    }

    private func create(_ params: JSONValue) -> JSONValue {
        let agentId = params["agentId"]?.string ?? "main"
        let key = "agent:\(agentId):dashboard:\(Self.shortId())"
        let message = params["message"]?.text
        var row = Self.row(key: key, agentId: agentId, title: params["label"]?.text ?? "New chat",
                           preview: message.map { String($0.prefix(120)) } ?? "New chat created.")
        row["label"] = params["label"] ?? .null
        row["category"] = params["category"] ?? .null
        self.registerGroup(params["category"]?.string)
        row["parentSessionKey"] = params["parentSessionKey"] ?? .null
        row["spawnedBy"] = params["parentSessionKey"] ?? .null
        self.sessions[key] = row
        self.transcripts[key] = message.map { [Self.message("user", [Self.text($0)])] } ?? []
        self.sessionChanged(key, reason: "create")
        return ["key": .string(key), "sessionId": row["sessionId"] ?? .null, "session": .object(row)]
    }

    // MARK: Groups

    private func groupCatalog(_ extra: Row = [:]) -> JSONValue {
        var result: Row = [
            "groups": .array(self.groups.enumerated().map { ["name": .string($1), "position": JSONValue($0)] }),
            "sectionOrder": [],
        ]
        result.merge(extra) { $1 }
        return .object(result)
    }

    private func registerGroup(_ name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !self.groups.contains(name) else { return }
        self.groups.append(name)
    }

    private func groupsChanged() {
        guard self.sessionsSubscribed else { return }
        self.emit("sessions.changed", ["reason": "groups"])
    }

    private func moveMembers(of name: String, to category: JSONValue) -> Int {
        let keys = self.sessions.filter { $0.value["category"]?.string == name }.map(\.key)
        for key in keys {
            self.sessions[key]?["category"] = category
            self.sessionChanged(key, reason: "patch")
        }
        return keys.count
    }

    private func putGroups(_ params: JSONValue) throws -> JSONValue {
        guard let raw = params["names"]?.array else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "names required", details: nil)
        }
        var names: [String] = []
        for name in raw.compactMap(\.string).map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        let dropped = self.groups.filter { name in !names.contains(name) && self.sessions.values.contains { $0["category"]?.string == name } }
        guard dropped.isEmpty else {
            throw GatewayError.rpc(code: "INVALID_REQUEST",
                                   message: "sessions.groups.put cannot drop groups that still have member sessions", details: nil)
        }
        self.groups = names
        self.groupsChanged()
        return self.groupCatalog(["ok": true])
    }

    private func renameGroup(_ params: JSONValue) throws -> JSONValue {
        guard let from = params["name"]?.string?.trimmingCharacters(in: .whitespaces), !from.isEmpty,
              let to = params["to"]?.string?.trimmingCharacters(in: .whitespaces), !to.isEmpty
        else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "group rename requires non-empty names", details: nil) }
        guard self.groups.contains(from) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown session group: \(from)", details: nil)
        }
        let updated = from == to ? 0 : self.moveMembers(of: from, to: .string(to))
        if from != to, self.groups.contains(to) {
            self.groups.removeAll { $0 == from }
        } else {
            self.groups = self.groups.map { $0 == from ? to : $0 }
        }
        self.groupsChanged()
        return self.groupCatalog(["ok": true, "updatedSessions": JSONValue(updated)])
    }

    private func deleteGroup(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "group delete requires a non-empty name", details: nil)
        }
        let updated = self.moveMembers(of: name, to: .null)
        self.groups.removeAll { $0 == name }
        self.groupsChanged()
        return self.groupCatalog(["ok": true, "updatedSessions": JSONValue(updated)])
    }

    private func setPrefs(_ params: JSONValue) -> JSONValue {
        for (key, expected) in params["expectedEntries"]?.object ?? [:] where (self.prefs[key] ?? .null) != expected {
            return ["status": "conflict"]
        }
        let entries = params["entries"]?.object ?? [:]
        for (key, value) in entries {
            self.prefs[key] = value.isNull ? nil : value
        }
        self.emit("users.prefs.changed", ["profileId": "demo", "keys": JSONValue(Array(entries.keys))])
        return ["status": "ok"]
    }

    // MARK: Runs

    private func send(_ params: JSONValue) throws -> JSONValue {
        guard let idempotencyKey = params["idempotencyKey"]?.string else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "idempotencyKey is required", details: nil)
        }
        let key = try self.knownSession(params["sessionKey"])
        if let existing = self.idempotency[idempotencyKey] {
            return ["runId": .string(existing), "status": "started"]
        }
        let runId = Self.shortId("run_")
        self.idempotency[idempotencyKey] = runId
        self.runs[runId] = Run(sessionKey: key, text: params["message"]?.string ?? "")
        self.runs[runId]?.task = Task { await self.simulate(runId: runId, params: params) }
        return ["runId": .string(runId), "status": "started"]
    }

    private func simulate(runId: String, params: JSONValue) async {
        guard let run = self.runs[runId] else { return }
        let key = run.sessionKey
        let text = run.text
        let model = self.rowModel(key)

        var content = [Self.text(text)]
        for attachment in params["attachments"]?.array ?? [] {
            guard let base64 = attachment["content"]?.string, let mimeType = attachment["mimeType"]?.string,
                  mimeType.hasPrefix("image/"), let data = Data(base64Encoded: base64)
            else { continue }
            let artifactId = "upload-\(Self.shortId())"
            self.artifacts[artifactId] = (mimeType, data)
            content.append(Self.image(artifactId, alt: attachment["fileName"]?.string ?? "Uploaded image"))
        }
        self.append(key, Self.message("user", content, runId: runId,
                                      idempotencyKey: params["idempotencyKey"]?.string))
        self.updateRow(key, reason: "send") { row in
            row["hasActiveRun"] = true
            row["activeRunIds"] = [.string(runId)]
            row["status"] = "running"
            row["lastMessagePreview"] = .string(String(text.prefix(120)))
        }

        let lowered = text.lowercased()
        if lowered == "/compact" || lowered.hasPrefix("/compact ") {
            await self.simulateCompact(runId: runId, key: key, model: model,
                                       instructions: text.dropFirst("/compact".count).trimmingCharacters(in: .whitespaces))
            return
        }
        if lowered.range(of: #"\bapprove\b"#, options: .regularExpression) != nil {
            let id = Self.shortId("approval_")
            // `approve once-only` leaves out Always allow, like a command the Gateway won't grant for good.
            let allowed: JSONValue = lowered.contains("once-only")
                ? ["allow-once", "deny"] : ["allow-once", "allow-always", "deny"]
            let approval: JSONValue = [
                "id": .string(id),
                "request": ["command": "rm -rf ./build", "cwd": "/home/claw/project", "sessionKey": .string(key),
                            "agentId": self.sessions[key]?["agentId"] ?? "main",
                            "allowedDecisions": allowed],
                "createdAtMs": Self.now(),
                "expiresAtMs": .number((Self.now().double ?? 0) + 120_000),
            ]
            self.approvals[id] = approval
            self.approvalOrder.append(id)
            self.emit("exec.approval.requested", approval)
        }

        self.chat(runId, ["state": "status", "phase": "thinking"])
        var thinking = ""
        for part in ["Reading", " the", " request", " and", " picking", " a", " demo", " reply…"] {
            guard await self.pause(runId, milliseconds: 140) else { return }
            thinking += part
            self.chat(runId, ["state": "delta", "deltaText": "",
                              "message": Self.message("assistant", [Self.thinking(thinking)], runId: runId, model: model)])
        }

        if lowered.range(of: #"\bplan\b"#, options: .regularExpression) != nil {
            guard await self.simulatePlan(runId: runId, key: key, model: model) else { return }
        }

        var answered: String?
        if lowered.range(of: #"\bask\b"#, options: .regularExpression) != nil {
            guard let outcome = await self.simulateQuestion(runId: runId, key: key, model: model) else { return }
            answered = outcome
        }

        let wantsTool = ["tool", "disk", "image"].contains { lowered.contains($0) }
        if wantsTool {
            let callId = Self.shortId("call_")
            let output = " 10:42  up 3 days, 4 users, load averages: 1.20 1.04 0.86"
            self.agentEvent(runId, stream: "tool",
                            ["phase": "start", "name": "exec", "toolCallId": .string(callId), "args": ["command": "uptime"]])
            guard await self.pause(runId, milliseconds: 800) else { return }
            self.agentEvent(runId, stream: "tool",
                            ["phase": "result", "name": "exec", "toolCallId": .string(callId), "isError": false,
                             "result": .string(output)])
            self.append(key, Self.message("assistant", [Self.toolCall(callId, "exec", ["command": "uptime"])],
                                          runId: runId, model: model))
            self.append(key, Self.message("toolResult", [Self.text(output)], runId: runId,
                                          extra: ["toolCallId": .string(callId), "toolName": "exec", "isError": false]))
        }

        let reply = answered ?? Self.reply(to: text, usedTool: wantsTool)
        var out = ""
        for word in Self.words(reply) {
            guard await self.pause(runId, milliseconds: 30) else { return }
            out += word
            self.chat(runId, ["state": "delta", "deltaText": .string(word),
                              "message": Self.message("assistant", [Self.thinking(thinking), Self.text(out)],
                                                      runId: runId, model: model)])
        }
        var final = [Self.thinking(thinking), Self.text(reply)]
        if lowered.contains("image") { final.append(Self.image("demo-chart", alt: "Demo usage chart")) }
        let finalMessage = Self.message("assistant", final, runId: runId, model: model)
        self.append(key, finalMessage)
        self.chat(runId, ["state": "final", "message": finalMessage])
        self.agentEvent(runId, stream: "lifecycle", ["phase": "end"])
        self.runs[runId] = nil
        self.updateRow(key, reason: "run-finished") { row in
            row["hasActiveRun"] = false
            row["activeRunIds"] = []
            row["status"] = "idle"
            row["lastMessagePreview"] = .string(String(reply.prefix(120)))
            row["unread"] = true
            // Each turn grows the context snapshot, up to the window.
            if let total = row["totalTokens"]?.int {
                let output = reply.count / 4
                row["inputTokens"] = JSONValue(total)
                row["outputTokens"] = JSONValue(output)
                row["totalTokens"] = JSONValue(min(Self.contextTokens, total + 1_200 + output))
            }
        }
    }

    /// `/compact [instructions]`: summarizes the context, like the Gateway's command.
    private func simulateCompact(runId: String, key: String, model: (provider: String, model: String),
                                 instructions: String) async
    {
        self.agentEvent(runId, stream: "compaction", ["phase": "start"])
        guard await self.pause(runId, milliseconds: 900) else { return }
        let before = self.sessions[key]?["totalTokens"]?.int ?? 0
        let after = before * 18 / 100
        self.append(key, Self.message("system", [], extra: ["__openclaw": ["id": .string(Self.shortId()), "kind": "compaction"]]))
        self.agentEvent(runId, stream: "compaction", ["phase": "end", "completed": true])
        var text = "⚙️ Compacted (\(TokenCount.format(before)) → \(TokenCount.format(after)) tokens)"
        if !instructions.isEmpty { text += ", keeping: \(instructions)" }
        let reply = Self.message("assistant", [Self.text(text + ".")], runId: runId, model: model)
        self.append(key, reply)
        self.chat(runId, ["state": "final", "message": reply])
        self.agentEvent(runId, stream: "lifecycle", ["phase": "end"])
        self.runs[runId] = nil
        self.updateRow(key, reason: "compact") { row in
            row["hasActiveRun"] = false
            row["activeRunIds"] = []
            row["status"] = "idle"
            row["lastMessagePreview"] = .string(text + ".")
            row["totalTokens"] = JSONValue(after)
            row["inputTokens"] = JSONValue(after)
            row["totalTokensFresh"] = true
        }
    }

    /// Asks an `ask_user` question and waits for it to be answered, skipped or to expire.
    /// Returns the reply text, or nil if the run was stopped.
    private func simulateQuestion(runId: String, key: String, model: (provider: String, model: String)) async -> String? {
        let callId = Self.shortId("call_")
        let options: [JSONValue] = [
            ["label": "Disconnect Discord from OpenClaw",
             "description": "Remove the Discord channel integration/config; the server itself stays intact"],
            ["label": "Delete one channel in the Discord server", "description": "e.g. #coworking or #gyms — tell me which"],
            ["label": "Stop watching Discord channels here", "description": "Only stop this chat from ambiently watching them"],
        ]
        let args: JSONValue = ["questions": [["id": "discord_remove", "header": "Discord",
                                              "question": "What do you want removed?", "options": .array(options)]]]
        self.agentEvent(runId, stream: "tool",
                        ["phase": "start", "name": "ask_user", "toolCallId": .string(callId), "args": args])
        let id = Self.shortId("ask_")
        let record: JSONValue = [
            "id": .string(id),
            "questions": [["questionId": "discord_remove", "header": "Discord", "question": "What do you want removed?",
                           "options": .array(options), "isOther": true]],
            "agentId": self.sessions[key]?["agentId"] ?? "main",
            "sessionKey": .string(key),
            "runId": .string(runId),
            "createdAtMs": Self.now(),
            "expiresAtMs": .number((Self.now().double ?? 0) + 900_000),
            "status": "pending",
        ]
        self.questions[id] = record
        self.questionOrder.append(id)
        self.emit("question.requested", record)

        while self.questions[id]?["status"]?.string == "pending" {
            guard await self.pause(runId, milliseconds: 100) else {
                self.settleQuestion(id, status: "cancelled", answers: nil)
                return nil
            }
            if let expires = record["expiresAtMs"]?.double, (Self.now().double ?? 0) >= expires {
                self.settleQuestion(id, status: "expired", answers: nil)
            }
        }
        let status = self.questions[id]?["status"]?.string ?? "cancelled"
        let picked = self.questions[id]?["answers"]?["answers"]?["discord_remove"]?.array?.compactMap(\.string) ?? []
        let output = status == "answered" ? "User answered: \(picked.joined(separator: ", "))" : "User \(status == "expired" ? "didn't answer in time" : "skipped the question")"
        self.agentEvent(runId, stream: "tool",
                        ["phase": "result", "name": "ask_user", "toolCallId": .string(callId), "isError": false,
                         "result": .string(output)])
        self.append(key, Self.message("assistant", [Self.toolCall(callId, "ask_user", args)], runId: runId, model: model))
        self.append(key, Self.message("toolResult", [Self.text(output)], runId: runId,
                                      extra: ["toolCallId": .string(callId), "toolName": "ask_user", "isError": false]))
        return status == "answered"
            ? "Got it — \(picked.joined(separator: ", ")). (This is the demo, so nothing was actually removed.)"
            : "No problem, I'll leave Discord as it is."
    }

    private func resolveQuestion(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["id"]?.string, let record = self.questions[id] else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "question was not found",
                                   details: ["reason": "QUESTION_NOT_FOUND"])
        }
        guard record["status"]?.string == "pending" else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "question is already resolved",
                                   details: ["reason": "QUESTION_ALREADY_TERMINAL"])
        }
        if params["cancel"]?.bool == true {
            self.settleQuestion(id, status: "cancelled", answers: nil)
            return ["status": "cancelled"]
        }
        let answers = params["answers"]?["answers"]
        let ids = (record["questions"]?.array ?? []).compactMap { $0["questionId"]?.string }
        guard ids.allSatisfy({ !(answers?[$0]?.array?.compactMap(\.string) ?? []).isEmpty }) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "every question needs an answer",
                                   details: ["reason": "QUESTION_INVALID_ANSWER"])
        }
        self.settleQuestion(id, status: "answered", answers: ["answers": answers ?? [:]])
        return ["status": "answered", "answers": ["answers": answers ?? [:]]]
    }

    private func settleQuestion(_ id: String, status: String, answers: JSONValue?) {
        guard case var .object(record)? = self.questions[id], record["status"]?.string == "pending" else { return }
        record["status"] = .string(status)
        if let answers { record["answers"] = answers }
        self.questions[id] = .object(record)
        var event: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
        if let answers { event["answers"] = answers }
        self.emit("question.resolved", .object(event))
    }

    /// Walks a three-step `progress_card` checklist, as an agent following a plan would.
    private func simulatePlan(runId: String, key: String, model: (provider: String, model: String)) async -> Bool {
        let markdown = "**Demo plan**\n\nThe card above the composer tracks each phase."
        let labels = ["Look over the request", "Draft a reply", "Double-check the result"]
        for current in 0...labels.count {
            let steps: [JSONValue] = labels.enumerated().map { index, label in
                let status = index < current ? "completed" : index == current ? "in_progress" : "pending"
                return ["step": .string(label), "status": .string(status)]
            }
            let callId = Self.shortId("call_")
            let args: JSONValue = ["markdown": .string(markdown), "plan": .array(steps)]
            self.agentEvent(runId, stream: "tool",
                            ["phase": "start", "name": "progress_card", "toolCallId": .string(callId), "args": args])
            let revision = self.storeProgressCard(key, markdown: .string(markdown), steps: .array(steps))
            let output = "Progress card updated (rev \(revision), \(min(current, labels.count))/\(labels.count) done)"
            self.agentEvent(runId, stream: "tool",
                            ["phase": "result", "name": "progress_card", "toolCallId": .string(callId), "isError": false,
                             "result": .string(output)])
            self.append(key, Self.message("assistant", [Self.toolCall(callId, "progress_card", args)],
                                          runId: runId, model: model))
            self.append(key, Self.message("toolResult", [Self.text(output)], runId: runId,
                                          extra: ["toolCallId": .string(callId), "toolName": "progress_card",
                                                  "isError": false]))
            if current < labels.count {
                guard await self.pause(runId, milliseconds: 1500) else { return false }
            }
        }
        return true
    }

    @discardableResult
    private func storeProgressCard(_ key: String, markdown: JSONValue?, steps: JSONValue?) -> Int {
        let revision = (self.progressCards[key]?["revision"]?.int ?? 0) + 1
        var card: Row = ["sessionKey": .string(key), "revision": JSONValue(revision), "updatedAt": Self.now()]
        if let markdown { card["markdown"] = markdown }
        if let steps { card["steps"] = steps }
        self.progressCards[key] = .object(card)
        self.emit("progressCard.changed", ["sessionKey": .string(key), "revision": JSONValue(revision)])
        return revision
    }

    private func putProgressCard(_ params: JSONValue) throws -> JSONValue {
        let key = try self.knownSession(params["sessionKey"])
        let markdown = params["markdown"], plan = params["plan"]
        if markdown == nil, plan == nil {
            // Conditional clear: only the revision the client saw is dismissed.
            if let expected = params["expectedRevision"]?.int, let card = self.progressCards[key],
               card["revision"]?.int != expected
            {
                return ["card": card]
            }
            self.progressCards[key] = nil
            if params["expectedRevision"] == nil {
                self.emit("progressCard.changed", ["sessionKey": .string(key), "revision": .null])
            }
            return ["card": .null]
        }
        self.storeProgressCard(key, markdown: markdown, steps: plan)
        return ["card": self.progressCards[key] ?? .null]
    }

    /// Sleeps, then reports whether the run should keep going.
    private func pause(_ runId: String, milliseconds: Int) async -> Bool {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        return !Task.isCancelled && self.runs[runId] != nil
    }

    private func abort(sessionKey: String?, runId: String?) {
        let matching = self.runs.filter { id, run in runId.map { $0 == id } ?? (run.sessionKey == sessionKey) }
        for (id, run) in matching {
            run.task?.cancel()
            self.runs[id] = nil
            self.updateRow(run.sessionKey, reason: "abort") { row in
                row["hasActiveRun"] = false
                row["activeRunIds"] = []
                row["status"] = "idle"
            }
            self.emit("chat", ["runId": .string(id), "sessionKey": .string(run.sessionKey),
                               "seq": JSONValue(run.seq + 1), "state": "aborted"])
        }
    }

    // MARK: Events

    private func emit(_ name: String, _ payload: JSONValue) {
        self.eventSeq += 1
        self.sink?(GatewayEvent(name: name, payload: payload, seq: self.eventSeq))
    }

    private func chat(_ runId: String, _ fields: Row) {
        guard var run = self.runs[runId] else { return }
        run.seq += 1
        self.runs[runId] = run
        var payload = fields
        payload["runId"] = .string(runId)
        payload["sessionKey"] = .string(run.sessionKey)
        payload["seq"] = JSONValue(run.seq)
        self.emit("chat", .object(payload))
    }

    private func agentEvent(_ runId: String, stream: String, _ data: JSONValue) {
        guard var run = self.runs[runId] else { return }
        run.seq += 1
        self.runs[runId] = run
        self.emit("agent", ["runId": .string(runId), "sessionKey": .string(run.sessionKey), "seq": JSONValue(run.seq),
                            "stream": .string(stream), "data": data])
    }

    private func append(_ key: String, _ message: JSONValue) {
        self.transcripts[key, default: []].append(message)
        guard self.messageSubscriptions.contains(key) else { return }
        self.emit("session.message", [
            "sessionKey": .string(key),
            "message": message,
            "messageId": message["__openclaw"]?["id"] ?? .null,
            "messageSeq": JSONValue(self.transcripts[key]?.count ?? 0),
            "hasActiveRun": true,
        ])
    }

    private func updateRow(_ key: String, reason: String, _ change: (inout Row) -> Void) {
        guard var row = self.sessions[key] else { return }
        change(&row)
        self.touch(&row)
        self.sessions[key] = row
        self.sessionChanged(key, reason: reason)
    }

    private func touch(_ row: inout Row) {
        row["updatedAt"] = Self.now()
        row["lastActivityAt"] = Self.now()
    }

    private func sessionChanged(_ key: String, reason: String) {
        guard self.sessionsSubscribed, let row = self.sessions[key] else { return }
        self.emit("sessions.changed", ["sessionKey": .string(key), "reason": .string(reason), "session": .object(row)])
    }

    private func rowModel(_ key: String) -> (provider: String, model: String) {
        let row = self.sessions[key]
        return (row?["modelProvider"]?.string ?? Self.defaultModel.provider, row?["model"]?.string ?? Self.defaultModel.model)
    }

    // MARK: Content

    private static func reply(to text: String, usedTool: Bool) -> String {
        let quoted = text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
        return """
        \(quoted.isEmpty ? "" : quoted + "\n\n")This is **Pincer's demo mode**, so this reply is canned. \
        Connect your own OpenClaw Gateway to chat with real agents.

        ## Things to try

        - Mention **tool** or **disk** to watch a live tool call\(usedTool ? " (like the one above)" : "").
        - Ask for an **image** to get an inline chart.
        - Say **approve** to raise a command approval (**approve once-only** for one without Always allow).
        - Ask it to follow a **plan** to watch the task progress card.
        - Switch models from the toolbar, or pin, rename and group chats in the sidebar.

        ```text
        streaming: ok · markdown: ok · tools: \(usedTool ? "ran" : "on request")
        ```
        """
    }

    private static func words(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character.isWhitespace {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func now() -> JSONValue {
        .number((Date().timeIntervalSince1970 * 1000).rounded())
    }

    static func shortId(_ prefix: String = "") -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    private static func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
    private static func thinking(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text)] }
    private static func toolCall(_ id: String, _ name: String, _ args: JSONValue) -> JSONValue {
        ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": args]
    }

    private static func image(_ artifactId: String, alt: String) -> JSONValue {
        ["type": "image", "artifactId": .string(artifactId), "mimeType": "image/png", "alt": .string(alt),
         "width": 320, "height": 200]
    }

    private static func file(_ artifactId: String, name: String, mimeType: String) -> JSONValue {
        ["type": "file", "artifactId": .string(artifactId), "fileName": .string(name), "mimeType": .string(mimeType)]
    }

    private static let diskScript = """
    #!/bin/sh
    # Prints each mounted volume's usage, flagging any above 80%.
    set -eu

    df -h | awk 'NR == 1 { print; next }
    {
      used = $5 + 0
      flag = used > 80 ? "  <- getting full" : ""
      print $0 flag
    }'
    """

    private static func message(
        _ role: String, _ content: [JSONValue], runId: String? = nil, idempotencyKey: String? = nil,
        model: (provider: String, model: String)? = nil, extra: Row = [:]) -> JSONValue
    {
        var openclaw: Row = ["id": .string(UUID().uuidString.lowercased())]
        if let runId { openclaw["runId"] = .string(runId) }
        if let idempotencyKey { openclaw["idempotencyKey"] = .string(idempotencyKey) }
        var message: Row = ["role": .string(role), "content": .array(content), "timestamp": Self.now(),
                            "__openclaw": .object(openclaw)]
        if role == "assistant" {
            let model = model ?? Self.defaultModel
            message["provider"] = .string(model.provider)
            message["model"] = .string(model.model)
        }
        message.merge(extra) { _, new in new }
        return .object(message)
    }

    private static func row(key: String, agentId: String, title: String, preview: String, ageMs: Double = 0) -> Row {
        let at = JSONValue.number((Self.now().double ?? 0) - ageMs)
        return [
            "key": .string(key), "sessionId": .string(UUID().uuidString.lowercased()), "kind": "direct",
            "label": nil, "derivedTitle": .string(title), "lastMessagePreview": .string(preview),
            "channel": "webchat", "agentId": .string(agentId), "isMain": false, "pinned": false, "unread": false,
            "archived": false, "updatedAt": at, "lastActivityAt": at, "status": "idle", "hasActiveRun": false,
            "activeRunIds": [], "model": .string(Self.defaultModel.model),
            "modelProvider": .string(Self.defaultModel.provider), "modelOverrideSource": nil,
        ]
    }

    private static func seed() -> (sessions: [String: Row], transcripts: [String: [JSONValue]]) {
        var sessions: [String: Row] = [:]
        var transcripts: [String: [JSONValue]] = [:]
        func add(_ key: String, agent: String, title: String, preview: String, age: Double, _ extra: Row = [:],
                 messages: [JSONValue])
        {
            var row = Self.row(key: key, agentId: agent, title: title, preview: preview, ageMs: age)
            row.merge(["totalTokens": 24_000, "totalTokensFresh": true, "inputTokens": 24_000, "outputTokens": 900,
                       "contextTokens": JSONValue(Self.contextTokens)]) { _, new in new }
            row.merge(extra) { _, new in new }
            sessions[key] = row
            transcripts[key] = messages
        }

        let dfCall = "call_seed_df"
        add("agent:main:main", agent: "main", title: "Main", preview: "Disk looks healthy.", age: 10_000,
            ["isMain": true, "totalTokens": 172_000, "inputTokens": 172_000], messages: [
                Self.message("user", [Self.text("Can you check disk usage and show me a quick status?")]),
                Self.message("assistant", [
                    Self.thinking("I should look at disk usage and summarize the main volumes."),
                    Self.toolCall(dfCall, "exec", ["command": "df -h"]),
                ]),
                Self.message("toolResult", [Self.text("""
                Filesystem      Size  Used Avail Use% Mounted on
                /dev/disk3s1   926G  411G  490G  46% /
                /dev/disk3s6   926G  7.0G  490G   2% /System/Volumes/VM
                """)], extra: ["toolCallId": .string(dfCall), "toolName": "exec", "isError": false]),
                Self.message("assistant", [
                    Self.text("""
                    ## Disk status

                    - The root volume has plenty of room.
                    - The VM volume is barely used.

                    ```text
                    /dev/disk3s1  46% used
                    ```

                    Here's a quick chart.
                    """),
                    Self.image("demo-chart", alt: "Disk usage chart"),
                    Self.file("demo-script", name: "disk-report.sh", mimeType: "text/x-shellscript"),
                ]),
                Self.message("user", [Self.text("Can you sketch that as a little gauge?")]),
                Self.message("assistant", [Self.text("""
                Here's the root volume as a gauge:

                ```svg
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 140" width="240" height="140">
                  <path d="M20 120 A100 100 0 0 1 220 120" fill="none" stroke="#d9dde3" stroke-width="18" stroke-linecap="round"/>
                  <path d="M20 120 A100 100 0 0 1 108 21" fill="none" stroke="#34a37a" stroke-width="18" stroke-linecap="round"/>
                  <text x="120" y="112" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="30" font-weight="600" fill="#34a37a">46%</text>
                </svg>
                ```
                """)]),
                Self.message("assistant", [Self.text("""
                👋 **Welcome to the Pincer demo.** Everything here is simulated on your device, so no Gateway \
                is needed. Send a message to see a streamed reply. Try the words *tool*, *image* or *approve*.
                """)]),
            ])
        add("agent:main:discord:channel:123", agent: "main", title: "home-lab", preview: "Discord bridge is online.",
            age: 20_000, ["label": "home-lab", "category": "Home", "channel": "discord", "pinned": true, "unread": true],
            messages: [
                Self.message("user", [Self.text("The lab temperature sensor looks noisy tonight.")],
                             extra: ["provenance": ["sourceChannel": "discord"]]),
                Self.message("assistant", [Self.text("I'll keep an eye on the home-lab channel and flag anything unusual.")]),
            ])
        var trip: [JSONValue] = []
        for day in 1...150 {
            trip.append(Self.message("user", [Self.text("Idea for day \(day)?")]))
            trip.append(Self.message("assistant", [Self.text("Day \(day): a slow morning, one museum, and **ramen** nearby.")]))
        }
        trip.append(Self.message("user", [Self.text("Plan a gentle first day in Tokyo.")]))
        trip.append(Self.message("assistant", [Self.text("Start with Meiji Shrine, a low-key lunch, and an early evening in Shinjuku.")]))
        add("agent:main:dashboard:trip", agent: "main", title: "Japan trip", preview: "Kyoto day plan drafted.",
            age: 60_000, ["label": "Japan trip", "category": "Personal", "color": "pink"], messages: trip)
        add("agent:research:main", agent: "research", title: "Main", preview: "Research queue is clear.", age: 90_000,
            ["isMain": true], messages: [
                Self.message("assistant", [Self.text("Scout is ready to dig into papers, repos, and docs.")]),
            ])
        add("agent:research:dashboard:papers", agent: "research", title: "Paper digest",
            preview: "Three papers summarized.", age: 120_000, ["label": "Paper digest", "category": "Work", "unread": true],
            messages: [
                Self.message("user", [Self.text("Summarize the latest diffusion papers.")]),
                Self.message("assistant", [Self.text("The main themes are consistency models, faster sampling, and video generation.")]),
            ])
        add("agent:research:subagent:abc", agent: "research", title: "Summarize arXiv 2401.x",
            preview: "Subagent found the main contribution.", age: 180_000,
            ["label": "Summarize arXiv 2401.x", "parentSessionKey": "agent:research:dashboard:papers",
             "spawnedBy": "agent:research:dashboard:papers"],
            messages: [
                Self.message("assistant", [Self.text("The paper mainly improves how retrieval-augmented summaries are evaluated.")]),
            ])
        add("agent:coder:main", agent: "coder", title: "Main", preview: "No active coding run.", age: 240_000,
            ["isMain": true], messages: [
                Self.message("assistant", [Self.text("Forge can edit code, run builds, and report back briefly.")]),
            ])
        return (sessions, transcripts)
    }

    /// A small bar chart, drawn rather than bundled so the demo needs no assets.
    private static func chartPNG() -> Data {
        let (width, height) = (640, 400)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let values: [CGFloat] = [0.46, 0.02, 0.31, 0.64, 0.18, 0.52]
        let slot = CGFloat(width - 80) / CGFloat(values.count)
        for (index, value) in values.enumerated() {
            let hue = CGFloat(index) / CGFloat(values.count)
            context.setFillColor(CGColor(red: 0.95 - hue * 0.5, green: 0.35 + hue * 0.4, blue: 0.30 + hue * 0.6, alpha: 1))
            let barHeight = max(6, value * CGFloat(height - 80))
            context.fill(CGRect(x: 40 + CGFloat(index) * slot + slot * 0.15, y: 40, width: slot * 0.7, height: barHeight))
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        context.fill(CGRect(x: 40, y: 38, width: width - 80, height: 2))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
