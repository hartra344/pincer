import Foundation

/// The demo's session manager (`sessions.preview/describe/delete/patchMany/recover`,
/// `sessions.branches.list/switch`, `sessions.rewind`), shaped like the Gateway's replies (see
/// mock-gateway/sessions.mjs, which mirrors the same upstream handlers). Seeds archived chats, a
/// run in flight, a failed run, a restart-tombstoned chat and a chat with three branches, so every
/// action works. Nothing persists across launches.
extension DemoGateway {
    static let sessionManagerMethods = [
        "sessions.preview", "sessions.describe", "sessions.delete", "sessions.patchMany", "sessions.recover",
        "sessions.branches.list", "sessions.branches.switch", "sessions.rewind", "sessions.fork",
    ]

    /// Seeded session keys, shared with the checks.
    enum SessionManagerSeed {
        static let garden = "agent:main:dashboard:garden"
        static let taxes = "agent:main:dashboard:tax-2025"
        static let benchmarks = "agent:research:dashboard:gpu-bench"
        static let refactor = "agent:coder:dashboard:refactor"
        static let ciFix = "agent:coder:dashboard:ci-fix"
        static let photoImport = "agent:main:dashboard:photo-import"
        /// The seeded run in flight has no task behind it; chat.abort and archiving clear it.
        static let refactorRunId = "demo-run-refactor"
    }

    private static let branchHeadlineMaxChars = 120
    private static let previewMaxCharsCap = 800

    /// Adds the session-manager seeds; returns the inactive branch tips (session key → leaf id → path).
    static func seedSessionManager(sessions: inout [String: Row], transcripts: inout [String: [JSONValue]])
        -> [String: [String: [JSONValue]]]
    {
        let minute = 60_000.0
        let day = 1_440 * minute
        let now = Self.now().double ?? 0
        func message(_ role: String, _ text: String, _ id: String, at ms: Double) -> JSONValue {
            Self.sessionManagerMessage(role, text, id: id, at: ms)
        }
        func seed(_ key: String, agent: String, title: String, activity: Double, _ extra: Row, messages: [JSONValue]) {
            var row: Row = [
                "key": .string(key), "sessionId": .string(UUID().uuidString.lowercased()), "kind": "direct",
                "label": .string(title), "derivedTitle": .string(title),
                "lastMessagePreview": .string(messages.last.map { String(Self.plainText($0).prefix(120)) } ?? ""),
                "channel": "webchat", "agentId": .string(agent), "isMain": false, "pinned": false, "unread": false,
                "archived": false, "updatedAt": .number(activity), "lastActivityAt": .number(activity),
                "createdAt": .number((messages.first?["timestamp"]?.double ?? activity) - minute),
                "status": "done", "hasActiveRun": false, "activeRunIds": [],
                "model": "claude-opus-4-8", "modelProvider": "anthropic", "modelOverrideSource": .null,
            ]
            row.merge(extra) { _, new in new }
            sessions[key] = row
            transcripts[key] = messages
        }
        func archived(at ms: Double, reason: String, by actor: JSONValue = ["type": "human", "label": "Operator"]) -> Row {
            ["archived": true, "archivedAt": .number(ms), "archiveReason": .string(reason), "archivedBy": actor]
        }

        // Three branches: one opening, then three follow-ups the user tried. The newest is active.
        let g0 = now - 2 * day
        let shadeAt = now - 5 * 60 * minute
        let opening = [
            message("user", "Plan a spring vegetable bed for a 4×8 ft raised bed.", "demo-garden-q1", at: g0),
            message("assistant", "Tomatoes along the north edge, peppers in the middle, and a row of bush beans in front.",
                    "demo-garden-a1", at: g0 + minute),
        ]
        let drip = opening + [
            message("user", "Add a drip irrigation plan.", "demo-garden-drip-q", at: g0 + 30 * minute),
            message("assistant", "Run a ½\" mainline along the long edge with three ¼\" drip lines, 12\" emitter spacing.",
                    "demo-garden-drip-a", at: g0 + 31 * minute),
        ]
        let herbs = opening + [
            message("user", "What about an herbs-only bed instead?", "demo-garden-herbs-q", at: g0 + day),
            message("assistant", "Basil, thyme, oregano and parsley in quadrants, with chives along the border.",
                    "demo-garden-herbs-a", at: g0 + day + minute),
        ]
        let shade = opening + [
            Self.withImage(message("user", "Make it shade tolerant; it only gets four hours of sun.", "demo-garden-shade-q", at: shadeAt - minute)),
            message("assistant", "Swap the tomatoes for lettuce, kale and chard; they cope with four hours of sun.",
                    "demo-garden-shade-a", at: shadeAt),
        ]
        seed(SessionManagerSeed.garden, agent: "main", title: "Garden planner", activity: shadeAt,
             ["category": "Home", "totalTokens": 18_400, "inputTokens": 18_000, "outputTokens": 400,
              "startedAt": .number(shadeAt - minute), "endedAt": .number(shadeAt - minute + 8_000), "runtimeMs": 8_000],
             messages: shade)

        // Archived: hidden unless the list asks for archived (or all) sessions.
        let taxesAt = now - 40 * day
        seed(SessionManagerSeed.taxes, agent: "main", title: "2025 taxes", activity: taxesAt,
             archived(at: now - 30 * day, reason: "manual").merging(["category": "Personal"]) { $1 },
             messages: [
                 message("user", "Collect my 1099s and draft the tax estimate.", "demo-taxes-q", at: taxesAt - minute),
                 message("assistant", "All 1099s are in the folder; the estimate is ready for review.", "demo-taxes-a", at: taxesAt),
             ])
        let benchAt = now - 21 * day
        seed(SessionManagerSeed.benchmarks, agent: "research", title: "GPU benchmarks", activity: benchAt,
             archived(at: now - 14 * day, reason: "stale-dashboard", by: ["type": "system", "label": "Gateway"])
                 .merging(["category": "Work"]) { $1 },
             messages: [
                 message("user", "Compare the last two GPU generations on diffusion workloads.", "demo-bench-q", at: benchAt - minute),
                 message("assistant", "The 5090 is 38% faster on the diffusion benchmark.", "demo-bench-a", at: benchAt),
             ])

        // A run in flight for six minutes, and a failed one with its duration.
        let refactorStarted = now - 6 * minute
        seed(SessionManagerSeed.refactor, agent: "coder", title: "Refactor auth module", activity: now - 30_000,
             ["category": "Work", "status": "running", "startedAt": .number(refactorStarted), "hasActiveRun": true,
              "activeRunIds": [.string(SessionManagerSeed.refactorRunId)], "totalTokens": 64_000],
             messages: [
                 message("user", "Refactor the auth module so tokens can live in the keychain or in memory.",
                         "demo-refactor-q", at: refactorStarted),
                 message("assistant", "Splitting TokenStore into a protocol and two implementations…",
                         "demo-refactor-a", at: refactorStarted + 20_000),
             ])
        let ciEnded = now - 50 * minute
        seed(SessionManagerSeed.ciFix, agent: "coder", title: "Fix flaky CI", activity: ciEnded,
             ["category": "Work", "status": "failed", "lastRunError": "Build failed: 3 tests in CacheTests timed out.",
              "startedAt": .number(ciEnded - 94_000), "endedAt": .number(ciEnded), "runtimeMs": 94_000],
             messages: [
                 message("user", "Find out why CI keeps failing on main.", "demo-ci-q", at: ciEnded - 94_000),
                 message("assistant", "Build failed: 3 tests in CacheTests timed out.", "demo-ci-a", at: ciEnded),
             ])

        // Interrupted by a Gateway restart: recoverable into a fresh chat.
        let photoEnded = now - 3 * day
        seed(SessionManagerSeed.photoImport, agent: "main", title: "Photo import", activity: photoEnded,
             ["category": "Home", "status": "killed", "restartRecoveryStatus": "tombstoned",
              "startedAt": .number(photoEnded - 12 * minute), "endedAt": .number(photoEnded), "runtimeMs": .number(12 * minute)],
             messages: [
                 message("user", "Import the SD card photos into the Family library and tag them by date.",
                         "demo-photo-q", at: photoEnded - 12 * minute),
                 message("assistant", "Imported 212 of 480 photos from the SD card…", "demo-photo-a", at: photoEnded - minute),
             ])

        return [SessionManagerSeed.garden: ["demo-garden-drip-a": drip, "demo-garden-herbs-a": herbs]]
    }

    func handleSessionManager(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        if method == "chat.abort" {
            // The seeded run in flight has no task; stop it here, then let the regular abort run.
            if let key = params["sessionKey"]?.string ?? self.stubRunSession(params["runId"]?.string) {
                self.stopStubRun(key)
            }
            return nil
        }
        guard Self.sessionManagerMethods.contains(method) else { return nil }
        switch method {
        case "sessions.preview":
            guard let keys = params["keys"]?.array, !keys.isEmpty else {
                throw Self.sessionsInvalid("invalid sessions.preview params: at /keys: must NOT have fewer than 1 items")
            }
            if let limit = params["limit"], (limit.int ?? 0) < 1 {
                throw Self.sessionsInvalid("invalid sessions.preview params: at /limit: must be >= 1")
            }
            if let maxChars = params["maxChars"], (maxChars.int ?? 0) < 20 {
                throw Self.sessionsInvalid("invalid sessions.preview params: at /maxChars: must be >= 20")
            }
            let limit = params["limit"]?.int ?? 12
            let maxChars = params["maxChars"]?.int ?? 240
            let previews = keys.compactMap(\.text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .prefix(64).map { self.preview($0, limit: limit, maxChars: maxChars) }
            return ["ts": Self.now(), "previews": .array(Array(previews))]
        case "sessions.describe":
            guard let key = params["key"]?.text else {
                throw Self.sessionsInvalid("invalid sessions.describe params: at root: must have required property 'key'")
            }
            try self.checkAgent(params)
            guard var row = self.sessions[key] else { return ["session": .null] }
            // Like the Gateway: derived titles and last-message previews only when asked for.
            if params["includeDerivedTitles"]?.bool != true { row["derivedTitle"] = nil }
            if params["includeLastMessage"]?.bool != true { row["lastMessagePreview"] = nil }
            return ["session": .object(row)]
        case "sessions.delete":
            return try self.deleteSession(params)
        case "sessions.patchMany":
            return try self.patchMany(params)
        case "sessions.recover":
            return try self.recoverSession(params)
        case "sessions.branches.list":
            guard let key = params["sessionKey"]?.text else {
                throw Self.sessionsInvalid("invalid sessions.branches.list params: at root: must have required property 'sessionKey'")
            }
            try self.checkAgent(params)
            return ["branches": .array(self.branchList(key))]
        case "sessions.branches.switch":
            return try self.switchBranch(params)
        case "sessions.rewind":
            return try self.rewind(params)
        case "sessions.fork":
            return try self.fork(params)
        default:
            return nil
        }
    }

    // MARK: Reading

    /// Like upstream buildSessionPreviewItems: the latest user/assistant text, trimmed and capped.
    private func preview(_ key: String, limit: Int, maxChars: Int) -> JSONValue {
        guard self.sessions[key] != nil, let transcript = self.transcripts[key] else {
            return ["key": .string(key), "status": "missing", "items": []]
        }
        let cap = min(Self.previewMaxCharsCap, max(20, maxChars))
        var items: [JSONValue] = []
        for message in transcript.reversed() where items.count < limit {
            guard let role = message["role"]?.string, role == "user" || role == "assistant",
                  message["display"]?.bool != false
            else { continue }
            let text = Self.plainText(message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = text.count <= cap ? text : String(text.prefix(cap - 3)) + "..."
            items.append(["role": .string(role), "text": .string(clipped)])
        }
        return ["key": .string(key), "status": items.isEmpty ? "empty" : "ok", "items": .array(items.reversed())]
    }

    /// Transcript tips: the active leaf first, then the other tips newest first.
    private func branchList(_ key: String) -> [JSONValue] {
        guard self.sessions[key] != nil else { return [] }
        let active = self.transcripts[key] ?? []
        let tips = (self.branchTips[key] ?? [:]).values
            .filter { !Self.isPrefix($0, of: active) }
            .sorted { ($0.last?["timestamp"]?.double ?? 0) > ($1.last?["timestamp"]?.double ?? 0) }
        return ((active.isEmpty ? [] : [Self.branch(active, active: true)]) + tips.map { Self.branch($0, active: false) })
            .compactMap(\.self)
    }

    private static func branch(_ path: [JSONValue], active: Bool) -> JSONValue? {
        guard let leaf = Self.entryId(path.last) else { return nil }
        var branch: Row = ["leafEntryId": .string(leaf), "headline": .string(Self.headline(path)),
                           "messageCount": JSONValue(path.count), "active": .bool(active)]
        if let ms = path.last?["timestamp"]?.double {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            branch["updatedAt"] = .string(formatter.string(from: Date(timeIntervalSince1970: ms / 1000)))
        }
        return .object(branch)
    }

    /// The nearest user/assistant text walking back from the leaf, cut to 120 characters.
    private static func headline(_ path: [JSONValue]) -> String {
        for message in path.reversed() {
            guard let role = message["role"]?.string, role == "user" || role == "assistant" else { continue }
            let text = Self.plainText(message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return text.count <= Self.branchHeadlineMaxChars ? text : String(text.prefix(Self.branchHeadlineMaxChars - 1)) + "…"
        }
        return ""
    }

    // MARK: Mutations

    private func deleteSession(_ params: JSONValue) throws -> JSONValue {
        guard let key = params["key"]?.text?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            throw Self.sessionsInvalid("invalid sessions.delete params: at root: must have required property 'key'")
        }
        try self.checkAgent(params)
        if Self.isMainKey(key) { throw Self.sessionsInvalid("Cannot delete the main session (\(key)).") }
        guard let row = self.sessions[key] else { return ["ok": true, "key": .string(key), "deleted": false, "archived": []] }
        if params["archivedOnly"]?.bool == true, !Self.isArchived(row) {
            throw Self.sessionsInvalid("Session \(key) is not archived. Archive it first, then delete it.")
        }
        if let expected = params["expectedSessionId"]?.text, expected != row["sessionId"]?.text {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Session \(key) changed before deletion. Retry.",
                                   details: ["details": ["reason": "session-changed"]])
        }
        self.stopRuns(key)
        let agentId = row["agentId"]?.text ?? "main"
        let sessionId = row["sessionId"]?.text ?? ""
        let transcript = self.transcripts[key] ?? []
        let archivedPaths: [JSONValue] = params["deleteTranscript"]?.bool != false && !transcript.isEmpty
            ? [.string("/Users/claw/.openclaw/agents/\(agentId)/sessions/\(sessionId).jsonl.deleted.\(Self.fileStamp())")]
            : []
        self.sessions[key] = nil
        self.transcripts[key] = nil
        self.branchTips[key] = nil
        if self.sessionsSubscribed {
            self.emit("sessions.changed", ["sessionKey": .string(key), "sessionId": .string(sessionId),
                                           "agentId": .string(agentId), "reason": "delete"])
            self.emit("sessions.changed", ["reason": "delete"])
        }
        return ["ok": true, "key": .string(key), "deleted": true, "archived": .array(archivedPaths)]
    }

    private func patchMany(_ params: JSONValue) throws -> JSONValue {
        guard let targets = params["targets"]?.array, !targets.isEmpty else {
            throw Self.sessionsInvalid("invalid sessions.patchMany params: at /targets: must NOT have fewer than 1 items")
        }
        guard targets.count <= SessionManager.patchManyMaxTargets else {
            throw Self.sessionsInvalid("invalid sessions.patchMany params: at /targets: must NOT have more than 100 items")
        }
        guard let patch = params["patch"]?.object, !patch.isEmpty else {
            throw Self.sessionsInvalid("invalid sessions.patchMany params: at /patch: must NOT have fewer than 1 properties")
        }
        let fields = ["unread", "pinned", "label", "category", "color", "archived"]
        if let unsupported = patch.keys.sorted().first(where: { !fields.contains($0) }) {
            throw Self.sessionsInvalid("invalid sessions.patchMany params: at /patch: unexpected property '\(unsupported)'")
        }
        let outcomes: [JSONValue] = targets.map { target in
            var identity: Row = ["key": target["key"] ?? ""]
            if let agentId = target["agentId"] { identity["agentId"] = agentId }
            func failure(_ message: String, _ details: JSONValue? = nil) -> JSONValue {
                var error: Row = ["code": "INVALID_REQUEST", "message": .string(message)]
                if let details { error["details"] = details }
                return .object(identity.merging(["ok": false, "error": .object(error)]) { $1 })
            }
            guard let key = target["key"]?.text, self.sessions[key] != nil else { return failure("unknown session") }
            if let expected = target["expectedSessionId"]?.text, expected != self.sessions[key]?["sessionId"]?.text {
                return failure("Session \(key) changed before patch. Retry.", ["reason": "session-changed"])
            }
            if patch["archived"]?.bool == true {
                if Self.isMainKey(key) { return failure("Cannot archive an agent's main session.") }
                // Like the Gateway, archiving stops work in flight first.
                self.stopRuns(key)
            }
            guard var row = self.sessions[key] else { return failure("unknown session") }
            for field in fields where field != "archived" {
                if let value = patch[field] { row[field] = value }
            }
            if let label = patch["label"] {
                row["derivedTitle"] = label.isNull ? (row["isMain"]?.bool == true ? "Main" : row["derivedTitle"] ?? .null) : label
            }
            if let archived = patch["archived"]?.bool { Self.applyArchived(&row, archived) }
            row["updatedAt"] = Self.now()
            self.sessions[key] = row
            self.sessionChanged(key, reason: "patch")
            return .object(identity.merging(["ok": true]) { $1 })
        }
        return ["outcomes": .array(outcomes)]
    }

    private func recoverSession(_ params: JSONValue) throws -> JSONValue {
        guard let key = params["key"]?.text else {
            throw Self.sessionsInvalid("invalid sessions.recover params: at root: must have required property 'key'")
        }
        try self.checkAgent(params)
        guard var source = self.sessions[key] else { throw Self.sessionsInvalid("Session recovery source was not found.") }
        if let successorKey = source["recoveredSessionKey"]?.text, let successor = self.sessions[successorKey] {
            // Already recovered: the same successor comes back.
            self.sessionChanged(successorKey, reason: "recovery")
            return ["ok": true, "key": .string(successorKey), "sessionId": successor["sessionId"] ?? .null,
                    "continuation": ["status": "started", "runId": .string(Self.shortId("demo-run-"))]]
        }
        guard source["restartRecoveryStatus"]?.text == "tombstoned" else {
            throw Self.sessionsInvalid("Session recovery requires a restart-tombstoned session.")
        }
        guard source["hasActiveRun"]?.bool != true else {
            throw Self.sessionsInvalid("Session recovery is unavailable while the source still has active work.")
        }
        let agentId = source["agentId"]?.text ?? "main"
        let successorKey = "agent:\(agentId):dashboard:\(UUID().uuidString.lowercased())"
        let sessionId = UUID().uuidString.lowercased()
        let now = Self.now()
        let note = Self.sessionManagerMessage("assistant", "Recovered after a Gateway restart; picking up where the last run stopped.",
                                              id: Self.shortId("demo-recovered-"), at: now.double ?? 0)
        var successor = source
        for field in ["restartRecoveryStatus", "lastRunError", "archivedAt", "archiveReason", "archivedBy", "recoveredSessionKey"] {
            successor[field] = nil
        }
        successor.merge([
            "key": .string(successorKey), "sessionId": .string(sessionId), "previousSessionId": source["sessionId"] ?? .null,
            "status": "done", "startedAt": now, "endedAt": now, "runtimeMs": 0, "archived": false,
            "pinned": false, "unread": false, "createdAt": now, "createdVia": "operator",
            "updatedAt": now, "lastActivityAt": now, "lastMessagePreview": .string(Self.plainText(note)),
            "hasActiveRun": false, "activeRunIds": [],
        ]) { $1 }
        self.sessions[successorKey] = successor
        self.transcripts[successorKey] = (self.transcripts[key] ?? []) + [note]
        source["restartRecoveryStatus"] = nil
        source["recoveredSessionKey"] = .string(successorKey)
        Self.applyArchived(&source, true, reason: "restart-recovery")
        source["updatedAt"] = now
        self.sessions[key] = source
        self.sessionChanged(key, reason: "archive")
        self.sessionChanged(successorKey, reason: "create")
        return ["ok": true, "key": .string(successorKey), "sessionId": .string(sessionId),
                "continuation": ["status": "started", "runId": .string(Self.shortId("demo-run-"))]]
    }

    private func switchBranch(_ params: JSONValue) throws -> JSONValue {
        let key = try self.historyTarget(params, switching: true)
        guard let leaf = params["leafEntryId"]?.text else {
            throw Self.sessionsInvalid("invalid sessions.branches.switch params: at root: must have required property 'leafEntryId'")
        }
        let active = self.transcripts[key] ?? []
        if Self.entryId(active.last) == leaf { throw Self.sessionsInvalid("branch is already active: \(leaf)") }
        guard let target = self.branchTips[key]?[leaf], !Self.isPrefix(target, of: active) else {
            let known = ([active] + (self.branchTips[key] ?? [:]).values).contains { $0.contains { Self.entryId($0) == leaf } }
            throw Self.sessionsInvalid(known ? "entry is not a branch tip: \(leaf)" : "branch entry not found: \(leaf)")
        }
        self.branchTips[key]?[leaf] = nil
        self.retainTip(key, active)
        self.transcripts[key] = target
        self.historyChanged(key, reason: "branch-switch")
        return [:]
    }

    private func rewind(_ params: JSONValue) throws -> JSONValue {
        let key = try self.historyTarget(params, switching: false)
        guard let entryId = params["entryId"]?.text else {
            throw Self.sessionsInvalid("invalid sessions.rewind params: at root: must have required property 'entryId'")
        }
        let active = self.transcripts[key] ?? []
        guard let index = active.firstIndex(where: { Self.entryId($0) == entryId }) else {
            let known = (self.branchTips[key] ?? [:]).values.contains { $0.contains { Self.entryId($0) == entryId } }
            throw Self.sessionsInvalid(known ? "message entry is not on the active path: \(entryId)" : "message entry not found: \(entryId)")
        }
        guard active[index]["role"]?.string == "user" else { throw Self.sessionsInvalid("entry is not a user message: \(entryId)") }
        self.retainTip(key, active)
        self.transcripts[key] = Array(active[..<index])
        self.historyChanged(key, reason: "rewind")
        var result: Row = [:]
        let text = Self.plainText(active[index])
        if !text.isEmpty { result["editorText"] = .string(text) }
        if let attachments = self.editorAttachments(active[index]) { result["editorAttachments"] = attachments }
        return .object(result)
    }

    /// Like upstream sessions.fork: a new chat holding the active path before user message `entryId`.
    private func fork(_ params: JSONValue) throws -> JSONValue {
        let key = try self.historyTarget(params, switching: false)
        guard let entryId = params["entryId"]?.text else {
            throw Self.sessionsInvalid("invalid sessions.fork params: at root: must have required property 'entryId'")
        }
        let active = self.transcripts[key] ?? []
        guard let index = active.firstIndex(where: { Self.entryId($0) == entryId }) else {
            throw Self.sessionsInvalid("message entry not found: \(entryId)")
        }
        guard active[index]["role"]?.string == "user" else { throw Self.sessionsInvalid("entry is not a user message: \(entryId)") }
        let newKey = self.forkSession(from: key, path: Array(active[..<index]))
        let text = Self.plainText(active[index])
        var result: Row = ["sessionKey": .string(newKey)]
        if !text.isEmpty { result["editorText"] = .string(text) }
        if let attachments = self.editorAttachments(active[index]) { result["editorAttachments"] = attachments }
        return .object(result)
    }

    /// Image blocks of a user message as upstream's `editorAttachments` ({mimeType, data}, base64).
    /// Images sent through chat.send are stored as uploaded artifacts; those resolve back to their bytes.
    private func editorAttachments(_ message: JSONValue) -> JSONValue? {
        let images = (message["content"]?.array ?? []).compactMap { block -> JSONValue? in
            guard block["type"]?.string == "image" else { return nil }
            if let data = block["data"]?.string, !data.isEmpty, let mime = block["mimeType"]?.string, mime.hasPrefix("image/") {
                return ["mimeType": .string(mime), "data": .string(data)]
            }
            guard let id = block["artifactId"]?.string, let artifact = self.artifacts[id], artifact.0.hasPrefix("image/") else { return nil }
            return ["mimeType": .string(artifact.0), "data": .string(artifact.1.base64EncodedString())]
        }
        return images.isEmpty ? nil : .array(images)
    }

    /// Adds a tiny inline image block (the shape of a pasted image in chat.history) to a user message.
    private static func withImage(_ message: JSONValue) -> JSONValue {
        guard var row = message.object else { return message }
        row["content"] = .array((row["content"]?.array ?? []) + [["type": "image", "mimeType": "image/png", "data": .string(demoImageBase64)]])
        return .object(row)
    }

    /// A 48×48 PNG of a raised bed under the sun.
    static let demoImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAABC0lEQVR42u2VPWpCURCFz2rExh28IpWNjTvIDqyzAwlRRCRKCEEkiIi4BRP/f/O7jbODVBaCqPP0VqNjGPiqxzm8D+7Mvcj3aArcv9EUeHinKVDs0xQoDajN329aciyM8pCqxNpsiM2jMqIeJ2w2yAoex9QjKCQrqE2oR1BIVvA0pR5BIVnB84x6BIVkBS9z6hEUkhXUF9QjKCQraCypygmb2DxeV9Qm1uZYGM0PmgKtT5oC7S+aAp1vmgLdH5oCUTXakrxLbdn9fs4MLEjsCVmQ2M34kV3fkd3eJA7IZVIHnDODy/5eZlwoKGRuhswJZQuRKXyofcv+35b5WxaaIb+HfMt8y/wtu7DQGi5MKF8FwYahAAAAAElFTkSuQmCC"

    /// A child chat with `path` as its transcript (whole-chat fork for sessions.create `fork`).
    func forkSession(from key: String, path: [JSONValue]) -> String {
        let parent = self.sessions[key] ?? [:]
        let agentId = parent["agentId"]?.string ?? "main"
        let newKey = "agent:\(agentId):dashboard:\(Self.shortId())"
        let title = (parent["label"]?.text ?? "Chat") + " (fork)"
        var row = Self.row(key: newKey, agentId: agentId, title: title,
                           preview: path.last.map { String(Self.plainText($0).prefix(120)) } ?? "")
        row["parentSessionKey"] = .string(key)
        row["forkedFromParent"] = true
        row["category"] = parent["category"] ?? .null
        self.sessions[newKey] = row
        self.transcripts[newKey] = path
        self.sessionChanged(newKey, reason: "fork")
        return newKey
    }

    private func historyTarget(_ params: JSONValue, switching: Bool) throws -> String {
        let key = params["sessionKey"]?.text ?? ""
        try self.checkAgent(params)
        guard let row = self.sessions[key] else { throw Self.sessionsInvalid("session not found: \(key)") }
        if row["hasActiveRun"]?.bool == true {
            throw GatewayError.rpc(code: "UNAVAILABLE", message: switching
                ? "Branch switch is unavailable while the agent is working."
                : "Rewind is unavailable while the agent is working.", details: nil)
        }
        return key
    }

    /// Keeps a path as an inactive tip unless another tip already contains it.
    private func retainTip(_ key: String, _ path: [JSONValue]) {
        guard let leaf = Self.entryId(path.last) else { return }
        if (self.branchTips[key] ?? [:]).values.contains(where: { Self.isPrefix(path, of: $0) }) { return }
        self.branchTips[key, default: [:]][leaf] = path
    }

    private func historyChanged(_ key: String, reason: String) {
        guard var row = self.sessions[key] else { return }
        let transcript = self.transcripts[key] ?? []
        row["activeLeafEntryId"] = Self.entryId(transcript.last).map(JSONValue.string) ?? .null
        row["lastMessagePreview"] = transcript.last.map { .string(String(Self.plainText($0).prefix(120))) }
        row["updatedAt"] = Self.now()
        self.sessions[key] = row
        self.sessionChanged(key, reason: reason)
    }

    private func stubRunSession(_ runId: String?) -> String? {
        guard let runId else { return nil }
        return self.sessions.first { $0.value["activeRunIds"]?.array?.contains(.string(runId)) == true }?.key
    }

    /// Stops everything running in a session: the seeded run and any demo reply.
    func stopRuns(_ key: String) {
        self.stopStubRun(key)
        self.abort(sessionKey: key, runId: nil)
    }

    /// How long after the demo first connects the seeded run finishes on its own.
    static let seededRunDuration: Duration = .seconds(90)

    /// Lets the seeded run finish by itself, so Running (and the menu bar) empties like a real run.
    func scheduleSeededRunEnd() {
        guard self.seededRunEnd == nil else { return }
        self.seededRunEnd = Task { [weak self] in
            try? await Task.sleep(for: Self.seededRunDuration)
            guard !Task.isCancelled else { return }
            await self?.finishSeededRun()
        }
    }

    /// The seeded run's normal end: its reply, `final`, lifecycle end, and a done row with its duration.
    func finishSeededRun() {
        let key = SessionManagerSeed.refactor
        let runId = SessionManagerSeed.refactorRunId
        guard var row = self.sessions[key], row["activeRunIds"]?.array?.contains(.string(runId)) == true else { return }
        let now = Self.now()
        let reply = "Done: TokenStore is now a protocol with KeychainTokenStore and MemoryTokenStore; all auth tests pass."
        let message = Self.sessionManagerMessage("assistant", reply, id: "demo-refactor-done", at: now.double ?? 0)
        self.append(key, message)
        self.emit("chat", ["runId": .string(runId), "sessionKey": .string(key), "seq": 1, "state": "final", "message": message])
        self.emit("agent", ["runId": .string(runId), "sessionKey": .string(key), "seq": 2, "stream": "lifecycle",
                            "data": ["phase": "end"]])
        row["hasActiveRun"] = false
        row["activeRunIds"] = []
        row["status"] = "done"
        row["endedAt"] = now
        if let started = row["startedAt"]?.double, let ended = now.double { row["runtimeMs"] = .number(max(0, ended - started)) }
        row["lastMessagePreview"] = .string(String(reply.prefix(120)))
        self.touch(&row)
        self.sessions[key] = row
        self.sessionChanged(key, reason: "run-finished")
    }

    /// Ends the seeded run in flight (it has no task behind it).
    private func stopStubRun(_ key: String) {
        guard var row = self.sessions[key],
              row["activeRunIds"]?.array?.contains(.string(SessionManagerSeed.refactorRunId)) == true
        else { return }
        let now = Self.now()
        row["hasActiveRun"] = false
        row["activeRunIds"] = []
        row["status"] = "killed"
        row["endedAt"] = now
        if let started = row["startedAt"]?.double, let ended = now.double { row["runtimeMs"] = .number(max(0, ended - started)) }
        self.touch(&row)
        self.sessions[key] = row
        self.emit("chat", ["runId": .string(SessionManagerSeed.refactorRunId), "sessionKey": .string(key), "seq": 1, "state": "aborted"])
        self.sessionChanged(key, reason: "abort")
    }

    private func checkAgent(_ params: JSONValue) throws {
        guard let agentId = params["agentId"]?.text else { return }
        guard self.agents.contains(where: { $0["id"]?.string == agentId.lowercased() }) else {
            throw Self.sessionsInvalid("unknown agent id \"\(agentId)\"")
        }
    }

    // MARK: Helpers

    static func isMainKey(_ key: String) -> Bool {
        key == "global" || (key.hasPrefix("agent:") && key.split(separator: ":").count == 3 && key.hasSuffix(":main"))
    }

    private static func isArchived(_ row: Row) -> Bool {
        row["archived"]?.bool == true || row["archivedAt"]?.double != nil
    }

    /// Like the Gateway: archivedAt/archiveReason are set on archive and cleared on unarchive.
    static func applyArchived(_ row: inout Row, _ archived: Bool, reason: String = "manual") {
        row["archived"] = .bool(archived)
        if archived {
            if row["archivedAt"] == nil { row["archivedAt"] = Self.now() }
            if row["archiveReason"] == nil { row["archiveReason"] = .string(reason) }
            if row["archivedBy"] == nil { row["archivedBy"] = ["type": "human", "label": "Operator"] }
        } else {
            row["archivedAt"] = nil
            row["archiveReason"] = nil
            row["archivedBy"] = nil
        }
    }

    private static func entryId(_ message: JSONValue?) -> String? {
        message?["__openclaw"]?["id"]?.text
    }

    private static func isPrefix(_ prefix: [JSONValue], of path: [JSONValue]) -> Bool {
        prefix.count <= path.count && zip(prefix, path).allSatisfy { Self.entryId($0) == Self.entryId($1) }
    }

    private static func fileStamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

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
        return (message["content"]?.array ?? []).compactMap {
            ($0["type"]?.string == "text" || $0["type"]?.string == "input_text") ? $0["text"]?.string : nil
        }.joined(separator: "\n")
    }

    private static func sessionsInvalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }
}
