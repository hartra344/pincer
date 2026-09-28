import Foundation

/// Exec approvals and approval history.
extension DemoGateway {
    func handleApprovals(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "exec.approval.list":
            return ["approvals": .array(self.approvalOrder.compactMap { self.approvals[$0] })]
        case "exec.approval.resolve":
            return try self.resolveExecApproval(params)
        case "approval.history":
            return try self.approvalHistoryPage(params)
        case "approval.get":
            return try self.approvalSnapshot(params)
        case "exec.approvals.get":
            return try self.execApprovalsGet(params)
        case "exec.approvals.set":
            return try self.execApprovalsSet(params)
        default:
            return nil
        }
    }

    func resolveExecApproval(_ params: JSONValue) throws -> JSONValue {
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
        self.logs.approvalResolved(id: id, decision: decision)
        self.emit("exec.approval.resolved", ["id": .string(id), "decision": .string(decision)])
        if id == Self.seededApprovalId { self.finishSeededPush(approved: decision != "deny") }
        return ["ok": true, "id": .string(id), "decision": .string(decision)]
    }

    // MARK: Approval history

    func approvalHistoryPage(_ params: JSONValue) throws -> JSONValue {
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

    func approvalSnapshot(_ params: JSONValue) throws -> JSONValue {
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

    static func execPresentation(_ request: JSONValue) -> JSONValue {
        var presentation: Row = [
            "kind": "exec", "commandText": request["command"] ?? "(command)",
            "allowedDecisions": ["allow-once", "allow-always", "deny"],
        ]
        if let agentId = request["agentId"] { presentation["agentId"] = agentId }
        if let warning = request["warningText"] { presentation["warningText"] = warning }
        return .object(presentation)
    }

    /// A decision made in Pincer, as the Gateway's ledger records it.
    static func resolvedRecord(_ pending: JSONValue, decision: String) -> JSONValue {
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

    /// The approval waiting when the demo opens.
    static let seededApprovalId = "approval_demo_push"

    /// Forge's reply once the seeded push is answered, so the demo's story ends.
    func finishSeededPush(approved: Bool) {
        let key = "agent:coder:main"
        let reply = approved ? "Pushed fix/login-timeout to origin." : "OK, I won't push."
        self.append(key, Self.message("assistant", [Self.text(reply)]))
        self.updateRow(key, reason: "approval-resolved") { row in
            row["lastMessagePreview"] = .string(reply)
            row["unread"] = true
        }
    }

    /// One command already waiting when the demo opens, so approvals (and Shortcuts' Pending
    /// Approvals) have something to show. It lasts longer than a real one, for a leisurely look.
    static func seedPendingApproval() -> JSONValue {
        let created = (Self.now().double ?? 0) - 45_000
        return [
            "id": .string(Self.seededApprovalId),
            "request": ["command": "git push origin fix/login-timeout", "cwd": "/home/claw/projects/pincer",
                        "sessionKey": "agent:coder:main", "agentId": "coder", "host": "gateway",
                        "allowedDecisions": ["allow-once", "allow-always", "deny"]],
            "createdAtMs": .number(created),
            "expiresAtMs": .number(created + 30 * 60_000),
        ]
    }

    /// A dozen past decisions covering every kind, status and resolver.
    static func seedApprovalHistory() -> [JSONValue] {
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

    // MARK: Demo showcase: approve later

    /// How long after an "approve later" reply the approval arrives, long enough to switch apps or lock the
    /// screen. `PINCER_DEMO_LATER_APPROVAL_MS` overrides it (checks use a short delay).
    static var laterApprovalDelay: Duration {
        if let raw = ProcessInfo.processInfo.environment["PINCER_DEMO_LATER_APPROVAL_MS"], let ms = Int(raw), ms >= 0 {
            return .milliseconds(ms)
        }
        return .seconds(8)
    }

    static let laterApprovalNote =
        "I'll ask for approval in a few seconds — switch apps or lock the screen to answer it from the notification."

    static func wantsLaterApproval(_ lowered: String) -> Bool {
        lowered.range(of: #"\bapprove\b"#, options: .regularExpression) != nil && lowered.contains("later")
    }

    /// Raises an approval outside any run, a while after the reply, so it can be answered from a notification.
    func scheduleLaterApproval(sessionKey key: String) {
        let delay = Self.laterApprovalDelay
        Task {
            try? await Task.sleep(for: delay)
            self.raiseLaterApproval(sessionKey: key)
        }
    }

    func raiseLaterApproval(sessionKey key: String) {
        guard self.sessions[key] != nil else { return }
        let id = Self.shortId("approval_")
        let approval: JSONValue = [
            "id": .string(id),
            "request": ["command": "brew upgrade --greedy", "cwd": "/home/claw", "sessionKey": .string(key),
                        "agentId": self.sessions[key]?["agentId"] ?? "main",
                        "allowedDecisions": ["allow-once", "allow-always", "deny"]],
            "createdAtMs": Self.now(),
            "expiresAtMs": .number((Self.now().double ?? 0) + 600_000),
        ]
        self.approvals[id] = approval
        self.approvalOrder.append(id)
        self.emit("exec.approval.requested", approval)
    }
}
