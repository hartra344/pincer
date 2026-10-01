import Foundation

/// The session list, history, patch/create, prefs and message actions.
extension DemoGateway {
    func handleSessionList(_ method: String, _ params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "sessions.subscribe":
            self.sessionsSubscribed = true
            if !self.replayedSeededRuns {
                self.replayedSeededRuns = true
                // After the list lands, so the rows can't settle a lane halfway through its replay.
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(50))
                    await self?.replaySeededRuns()
                }
            }
            return ["subscribed": true, "list": self.sessionList(params)]
        case "sessions.list":
            return self.sessionList(params)
        case "sessions.messages.subscribe":
            let key = try self.knownSession(params["key"])
            self.messageSubscriptions[key, default: []].insert(params["subscriptionId"]?.string ?? "")
            return ["subscribed": true, "key": .string(key)]
        case "sessions.messages.unsubscribe":
            if let key = params["key"]?.string {
                self.messageSubscriptions[key]?.remove(params["subscriptionId"]?.string ?? "")
                if self.messageSubscriptions[key]?.isEmpty == true { self.messageSubscriptions[key] = nil }
            }
            return ["ok": true, "key": params["key"] ?? .null]
        case "chat.history":
            self.historyRequestCounts[params["sessionKey"]?.string ?? "", default: 0] += 1
            if self.holdsHistory {
                await withCheckedContinuation { self.heldHistory.append($0) }
                try Task.checkCancellation()
            }
            return try self.history(params)
        case "sessions.patch":
            return try self.patch(params)
        case "sessions.create":
            return self.create(params)
        case "users.prefs.get":
            let keys = params["keys"]?.array?.compactMap(\.string) ?? Array(self.prefs.keys)
            return ["status": "ok", "entries": .object(self.prefs.filter { keys.contains($0.key) })]
        case "users.prefs.set":
            return try self.setPrefs(params)
        case "message.action":
            return try self.messageAction(params)
        default:
            return nil
        }
    }

    /// Test hook: while held, `chat.history` parks until `holdHistory(false)`.
    func holdHistory(_ hold: Bool) {
        self.holdsHistory = hold
        if !hold {
            let parked = self.heldHistory
            self.heldHistory = []
            for continuation in parked { continuation.resume() }
        }
    }

    // MARK: Sessions

    func knownSession(_ key: JSONValue?) throws -> String {
        guard let key = key?.string, self.sessions[key] != nil else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown session", details: nil)
        }
        return key
    }

    func sessionList(_ params: JSONValue) -> JSONValue {
        // Like the Gateway: `archived: true` lists only archived sessions, "all" both, false/omitted active ones.
        let archived = params["archived"]
        let rows = self.sessions.values
            .filter { row in
                let isArchived = row["archived"]?.bool == true
                if archived?.string == "all" { return true }
                return archived?.bool == true ? isArchived : !isArchived
            }
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

    func history(_ params: JSONValue) throws -> JSONValue {
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

    func patch(_ params: JSONValue) throws -> JSONValue {
        let key = try self.knownSession(params["key"])
        var row = self.sessions[key] ?? [:]
        if let expected = params["expectedSessionId"]?.string, expected != row["sessionId"]?.string {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "expectedSessionId mismatch", details: nil)
        }
        if params["archived"]?.bool == true {
            // Like the Gateway (and the demo's sessions.patchMany): main sessions stay, work in flight stops.
            if Self.isMainKey(key) {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Cannot archive an agent's main session.", details: nil)
            }
            self.stopRuns(key)
            row = self.sessions[key] ?? row
        }
        for field in ["unread", "pinned", "label", "category", "color"] {
            if let value = params[field] { row[field] = value }
        }
        // Like the Gateway, a read is stamped server-side.
        if params["unread"]?.bool == false { row["lastReadAt"] = .number((Date().timeIntervalSince1970 * 1000).rounded()) }
        if let archived = params["archived"]?.bool { Self.applyArchived(&row, archived) }
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

    func create(_ params: JSONValue) -> JSONValue {
        if params["fork"]?.bool == true, let parent = params["parentSessionKey"]?.string, let transcript = self.transcripts[parent] {
            // Through the parent's last completed assistant message.
            let end = transcript.lastIndex { $0["role"]?.string == "assistant" }.map { $0 + 1 } ?? 0
            let key = self.forkSession(from: parent, path: Array(transcript[..<end]))
            return ["key": .string(key), "sessionId": self.sessions[key]?["sessionId"] ?? .null,
                    "session": .object(self.sessions[key] ?? [:])]
        }
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

    /// Like upstream (v2026.9.7): at most 32 entries per set, 128 keys per profile, 4 KiB per value.
    func setPrefs(_ params: JSONValue) throws -> JSONValue {
        for (key, expected) in params["expectedEntries"]?.object ?? [:] where (self.prefs[key] ?? .null) != expected {
            return ["status": "conflict"]
        }
        let entries = params["entries"]?.object ?? [:]
        func invalid(_ message: String) -> GatewayError { .rpc(code: "INVALID_REQUEST", message: message, details: nil) }
        if entries.count > 32 { throw invalid("too-many-entries") }
        if Set(self.prefs.keys).union(entries.filter { !$0.value.isNull }.keys).count > 128 { throw invalid("profile-key-limit") }
        for value in entries.values where ((try? JSONEncoder().encode(value))?.count ?? 0) > 4 * 1024 {
            throw invalid("value-too-large")
        }
        for (key, value) in entries {
            self.prefs[key] = value.isNull ? nil : value
        }
        self.emit("users.prefs.changed", ["profileId": "demo", "keys": JSONValue(Array(entries.keys))])
        return ["status": "ok"]
    }

    /// Reactions on bridged (Discord) chats' messages, like the Gateway's channel `react` action.
    func messageAction(_ params: JSONValue) throws -> JSONValue {
        guard let channel = params["channel"]?.text, let action = params["action"]?.text,
              let inner = params["params"]?.object, let idempotencyKey = params["idempotencyKey"]?.text
        else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "message.action requires channel, action, params and idempotencyKey", details: nil)
        }
        if let existing = self.actionResults[idempotencyKey] { return existing }
        guard action == "react", channel == "discord", let emoji = inner["emoji"]?.text, inner["messageId"]?.text != nil else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unsupported message action \(action) on \(channel)", details: nil)
        }
        self.recordedActions.append(params)
        let result: JSONValue = inner["remove"]?.bool == true
            ? ["ok": true, "removed": .string(emoji)] : ["ok": true, "added": .string(emoji)]
        self.actionResults[idempotencyKey] = result
        return result
    }
}
