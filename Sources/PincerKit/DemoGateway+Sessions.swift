import Foundation

/// The demo's session manager (`sessions.preview/describe/delete/patchMany/recover`,
/// `sessions.branches.list/switch`, `sessions.rewind`), shaped like the Gateway's replies. Seeds a
/// couple of archived chats, a restart-tombstoned one and an extra branch so every action works.
/// Nothing persists across launches.
extension DemoGateway {
    static let sessionManagerMethods = [
        "sessions.preview", "sessions.describe", "sessions.delete", "sessions.patchMany", "sessions.recover",
        "sessions.branches.list", "sessions.branches.switch", "sessions.rewind",
    ]

    /// Archived and tombstoned seed chats, and an older branch of the Japan trip chat.
    static func seedSessionManager(sessions: inout [String: Row], transcripts: inout [String: [JSONValue]])
        -> [String: [String: [JSONValue]]]
    {
        let day = 86_400_000.0
        let now = Self.now().double ?? 0
        func seed(_ key: String, agent: String, title: String, ageDays: Double, _ extra: Row, messages: [(String, String)]) {
            let at = JSONValue.number(now - ageDays * day)
            var row: Row = [
                "key": .string(key), "sessionId": .string(UUID().uuidString.lowercased()), "kind": "direct",
                "derivedTitle": .string(title), "lastMessagePreview": .string(messages.last?.1 ?? ""),
                "channel": "webchat", "agentId": .string(agent), "isMain": false, "pinned": false, "unread": false,
                "archived": false, "updatedAt": at, "lastActivityAt": at, "createdAt": .number(now - (ageDays + 1) * day),
                "status": "done", "hasActiveRun": false, "activeRunIds": [],
                "startedAt": .number(now - ageDays * day - 42_000), "endedAt": .number(now - ageDays * day),
                "runtimeMs": 42_000, "totalTokens": 8_400, "inputTokens": 8_000, "outputTokens": 400,
            ]
            row.merge(extra) { _, new in new }
            sessions[key] = row
            transcripts[key] = messages.enumerated().map { index, message in
                Self.sessionManagerMessage(message.0, message.1, id: "\(key)#\(index)",
                                           at: now - ageDays * day - Double(messages.count - index) * 60_000)
            }
        }
        seed("agent:main:dashboard:taxes", agent: "main", title: "2025 taxes", ageDays: 40,
             ["archived": true, "archivedAt": .number(now - 30 * day), "archiveReason": "manual", "label": "2025 taxes"],
             messages: [("user", "Which receipts do I still need for the home office deduction?"),
                        ("assistant", "Internet, electricity and the desk. The chair receipt is already filed.")])
        seed("agent:research:dashboard:gpu", agent: "research", title: "GPU shortlist", ageDays: 21,
             ["archived": true, "archivedAt": .number(now - 14 * day), "archiveReason": "age-retention"],
             messages: [("user", "Shortlist GPUs for local inference under 300W."),
                        ("assistant", "Three picks: a 24 GB card, a 16 GB card and a used datacenter card.")])
        seed("agent:coder:dashboard:migration", agent: "coder", title: "Schema migration", ageDays: 6,
             ["restartRecoveryStatus": "tombstoned", "status": "killed", "lastRunError": "The gateway restarted during this run."],
             messages: [("user", "Write the migration that splits the users table."),
                        ("assistant", "Drafting the migration: adding `profiles` and backfilling in batches…")])

        // An older branch of the trip chat: its last user message asked for Osaka instead.
        let trip = "agent:main:dashboard:trip"
        guard let transcript = transcripts[trip],
              let lastUser = transcript.lastIndex(where: { $0["role"]?.string == "user" })
        else { return [:] }
        let branch = Array(transcript[..<lastUser]) + [
            Self.sessionManagerMessage("user", "Plan the Osaka day instead.", id: "demo-trip-osaka-q", at: now - 2 * day),
            Self.sessionManagerMessage("assistant", "Osaka: Kuromon market, the castle, then Dotonbori at night.",
                                       id: "demo-trip-osaka-a", at: now - 2 * day + 60_000),
        ]
        return [trip: ["demo-trip-osaka-a": branch]]
    }

    func handleSessionManager(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard Self.sessionManagerMethods.contains(method) else { return nil }
        switch method {
        case "sessions.preview":
            let keys = params["keys"]?.array?.compactMap(\.text) ?? []
            guard !keys.isEmpty else { throw Self.sessionsInvalid("invalid sessions.preview params: keys must have at least 1 item") }
            let limit = max(1, params["limit"]?.int ?? 12)
            let maxChars = max(20, params["maxChars"]?.int ?? 240)
            return ["ts": Self.now(), "previews": .array(keys.prefix(64).map { self.preview($0, limit: limit, maxChars: maxChars) })]
        case "sessions.describe":
            guard let key = params["key"]?.text else { throw Self.sessionsInvalid("invalid sessions.describe params: must have required property 'key'") }
            return ["session": self.sessions[key].map(JSONValue.object) ?? .null]
        case "sessions.delete":
            return try self.deleteSession(params)
        case "sessions.patchMany":
            return try self.patchMany(params)
        case "sessions.recover":
            return try self.recoverSession(params)
        case "sessions.branches.list":
            guard let key = params["sessionKey"]?.text else { throw Self.sessionsInvalid("invalid sessions.branches.list params: must have required property 'sessionKey'") }
            return ["branches": .array(self.branchList(key))]
        case "sessions.branches.switch":
            return try self.switchBranch(params)
        case "sessions.rewind":
            return try self.rewind(params)
        default:
            return nil
        }
    }

    // MARK: Reading

    private func preview(_ key: String, limit: Int, maxChars: Int) -> JSONValue {
        guard self.sessions[key] != nil else { return ["key": .string(key), "status": "missing", "items": []] }
        let items: [JSONValue] = (self.transcripts[key] ?? []).compactMap { message in
            let text = Self.plainText(message)
            guard !text.isEmpty else { return nil }
            let role: String = switch message["role"]?.string {
            case "user": "user"
            case "assistant": "assistant"
            case "toolResult", "tool": "tool"
            case "system": "system"
            default: "other"
            }
            let clipped = text.count > maxChars ? String(text.prefix(maxChars - 1)) + "…" : text
            return ["role": .string(role), "text": .string(clipped)]
        }
        let recent = Array(items.suffix(limit))
        return ["key": .string(key), "status": recent.isEmpty ? "empty" : "ok", "items": .array(recent)]
    }

    private func branchList(_ key: String) -> [JSONValue] {
        guard self.sessions[key] != nil, let transcript = self.transcripts[key], !transcript.isEmpty else { return [] }
        var branches = [Self.branch(transcript, active: true)]
        for (_, tip) in (self.branchTips[key] ?? [:]).sorted(by: { $0.key < $1.key }) {
            branches.append(Self.branch(tip, active: false))
        }
        return branches.compactMap(\.self)
    }

    private static func branch(_ transcript: [JSONValue], active: Bool) -> JSONValue? {
        guard let leaf = transcript.last?["__openclaw"]?["id"]?.text else { return nil }
        let headline = transcript.last(where: { $0["role"]?.string == "user" }).map(Self.plainText) ?? ""
        var branch: Row = ["leafEntryId": .string(leaf), "headline": .string(String(headline.prefix(120))),
                           "messageCount": JSONValue(transcript.count), "active": .bool(active)]
        if let ms = transcript.last?["timestamp"]?.double {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            branch["updatedAt"] = .string(formatter.string(from: Date(timeIntervalSince1970: ms / 1000)))
        }
        return .object(branch)
    }

    // MARK: Mutations

    private func deleteSession(_ params: JSONValue) throws -> JSONValue {
        guard let key = params["key"]?.text else { throw Self.sessionsInvalid("invalid sessions.delete params: must have required property 'key'") }
        guard let row = self.sessions[key] else { return ["ok": true, "key": .string(key), "deleted": false, "archived": []] }
        if let expected = params["expectedSessionId"]?.text, expected != row["sessionId"]?.text {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Session \(key) changed; retry delete.", details: nil)
        }
        if params["archivedOnly"]?.bool == true, row["archived"]?.bool != true {
            throw Self.sessionsInvalid("Session \(key) is not archived.")
        }
        if key.hasSuffix(":main") { throw Self.sessionsInvalid("Cannot delete the main session (\(key)).") }
        self.sessions[key] = nil
        self.transcripts[key] = nil
        self.branchTips[key] = nil
        if self.sessionsSubscribed {
            self.emit("sessions.changed", ["sessionKey": .string(key), "reason": "delete",
                                           "sessionId": row["sessionId"] ?? .null])
        }
        return ["ok": true, "key": .string(key), "deleted": true, "archived": []]
    }

    private func patchMany(_ params: JSONValue) throws -> JSONValue {
        guard let targets = params["targets"]?.array, !targets.isEmpty,
              targets.count <= SessionManager.patchManyMaxTargets
        else { throw Self.sessionsInvalid("invalid sessions.patchMany params: targets must have 1 to 100 items") }
        guard let patch = params["patch"]?.object, !patch.isEmpty else {
            throw Self.sessionsInvalid("invalid sessions.patchMany params: patch must have at least 1 property")
        }
        let outcomes: [JSONValue] = targets.map { target in
            guard let key = target["key"]?.text, var row = self.sessions[key] else {
                return ["ok": false, "key": target["key"] ?? "", "error": ["code": "INVALID_REQUEST", "message": "unknown session"]]
            }
            if let expected = target["expectedSessionId"]?.text, expected != row["sessionId"]?.text {
                return ["ok": false, "key": .string(key),
                        "error": ["code": "INVALID_REQUEST", "message": "expectedSessionId mismatch"]]
            }
            for field in ["unread", "pinned", "category", "color", "archived"] {
                if let value = patch[field] { row[field] = value }
            }
            if let archived = patch["archived"]?.bool {
                row["archivedAt"] = archived ? Self.now() : nil
                row["archiveReason"] = archived ? "manual" : nil
            }
            self.touch(&row)
            self.sessions[key] = row
            self.sessionChanged(key, reason: patch["archived"]?.bool == true ? "archive" : "patch")
            return ["ok": true, "key": .string(key)]
        }
        return ["outcomes": .array(outcomes)]
    }

    private func recoverSession(_ params: JSONValue) throws -> JSONValue {
        guard let key = params["key"]?.text else { throw Self.sessionsInvalid("invalid sessions.recover params: must have required property 'key'") }
        guard var source = self.sessions[key] else { throw Self.sessionsInvalid("session not found: \(key)") }
        guard source["restartRecoveryStatus"]?.text == "tombstoned" else {
            throw Self.sessionsInvalid("Session \(key) doesn't need recovery.")
        }
        let agentId = source["agentId"]?.text ?? "main"
        let successorKey = "agent:\(agentId):dashboard:\(Self.shortId())"
        var successor = source
        let sessionId = UUID().uuidString.lowercased()
        successor["key"] = .string(successorKey)
        successor["sessionId"] = .string(sessionId)
        successor["restartRecoveryStatus"] = nil
        successor["status"] = "idle"
        successor["lastRunError"] = nil
        successor["createdAt"] = Self.now()
        self.touch(&successor)
        self.sessions[successorKey] = successor
        self.transcripts[successorKey] = self.transcripts[key] ?? []
        source["restartRecoveryStatus"] = nil
        source["archived"] = true
        source["archivedAt"] = Self.now()
        source["archiveReason"] = "restart-recovery"
        self.sessions[key] = source
        self.sessionChanged(key, reason: "archive")
        self.sessionChanged(successorKey, reason: "create")
        return ["ok": true, "key": .string(successorKey), "sessionId": .string(sessionId),
                "continuation": ["status": "rejected",
                                 "error": ["code": "UNAVAILABLE", "message": "The demo doesn't resume interrupted runs."]]]
    }

    private func switchBranch(_ params: JSONValue) throws -> JSONValue {
        let key = try self.historyTarget(params, action: "Branch switch")
        guard let leaf = params["leafEntryId"]?.text else {
            throw Self.sessionsInvalid("invalid sessions.branches.switch params: must have required property 'leafEntryId'")
        }
        let current = self.transcripts[key] ?? []
        if current.last?["__openclaw"]?["id"]?.text == leaf { return [:] }
        guard let target = self.branchTips[key]?[leaf] else { throw Self.sessionsInvalid("branch not found: \(leaf)") }
        self.branchTips[key]?[leaf] = nil
        if let currentLeaf = current.last?["__openclaw"]?["id"]?.text { self.branchTips[key, default: [:]][currentLeaf] = current }
        self.transcripts[key] = target
        self.historyChanged(key, reason: "branch-switch")
        return [:]
    }

    private func rewind(_ params: JSONValue) throws -> JSONValue {
        let key = try self.historyTarget(params, action: "Rewind")
        guard let entryId = params["entryId"]?.text else {
            throw Self.sessionsInvalid("invalid sessions.rewind params: must have required property 'entryId'")
        }
        let current = self.transcripts[key] ?? []
        guard let index = current.firstIndex(where: { $0["__openclaw"]?["id"]?.text == entryId }),
              current[index]["role"]?.string == "user"
        else { throw Self.sessionsInvalid("Rewind target \(entryId) is not a persisted user message.") }
        if let leaf = current.last?["__openclaw"]?["id"]?.text { self.branchTips[key, default: [:]][leaf] = current }
        self.transcripts[key] = Array(current[..<index])
        self.historyChanged(key, reason: "rewind")
        let text = Self.plainText(current[index])
        return text.isEmpty ? [:] : ["editorText": .string(text)]
    }

    private func historyTarget(_ params: JSONValue, action: String) throws -> String {
        guard let key = params["sessionKey"]?.text, let row = self.sessions[key] else {
            throw Self.sessionsInvalid("session not found: \(params["sessionKey"]?.text ?? "")")
        }
        if row["archived"]?.bool == true { throw Self.sessionsInvalid("\(action) is unavailable for archived sessions.") }
        if row["hasActiveRun"]?.bool == true {
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "\(action) is unavailable while the agent is working.", details: nil)
        }
        return key
    }

    private func historyChanged(_ key: String, reason: String) {
        guard var row = self.sessions[key] else { return }
        let transcript = self.transcripts[key] ?? []
        row["activeLeafEntryId"] = transcript.last?["__openclaw"]?["id"] ?? .null
        row["lastMessagePreview"] = transcript.last.map { .string(String(Self.plainText($0).prefix(120))) } ?? .null
        self.touch(&row)
        self.sessions[key] = row
        self.sessionChanged(key, reason: reason)
    }

    // MARK: Helpers

    private static func sessionManagerMessage(_ role: String, _ text: String, id: String, at ms: Double) -> JSONValue {
        var message: Row = ["role": .string(role), "content": [["type": "text", "text": .string(text)]],
                            "timestamp": .number(ms.rounded()), "__openclaw": ["id": .string(id)]]
        if role == "assistant" {
            message["provider"] = "anthropic"
            message["model"] = "claude-opus-4-8"
        }
        return .object(message)
    }

    private static func plainText(_ message: JSONValue) -> String {
        if let text = message["content"]?.string { return text }
        return (message["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            .joined(separator: "\n")
    }

    private static func sessionsInvalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }
}
