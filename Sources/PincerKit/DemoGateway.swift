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
    private static let modelCatalog: [JSONValue] = [
        ["id": "claude-opus-4-8", "name": "Claude Opus 4.8", "provider": "anthropic", "available": true],
        ["id": "claude-sonnet-5", "name": "Claude Sonnet 5", "provider": "anthropic", "available": true],
        ["id": "gpt-5.6-sol", "name": "GPT-5.6 Sol", "provider": "openai", "available": true],
        ["id": "gemini-3.8-flash", "name": "Gemini 3.8 Flash", "provider": "google", "available": false,
         "unavailableReason": "missing-auth"],
    ]
    private static let methods = [
        "agents.list", "sessions.subscribe", "sessions.list", "sessions.groups.list", "sessions.messages.subscribe",
        "sessions.messages.unsubscribe", "chat.history", "chat.send", "chat.abort", "sessions.patch", "models.list",
        "sessions.create", "artifacts.download", "exec.approval.list", "exec.approval.resolve", "users.prefs.get",
        "users.prefs.set",
    ]

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
    private var prefs: [String: JSONValue] = [:]
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
        self.artifacts["demo-chart"] = ("image/png", Self.chartPNG())
    }

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
            return ["groups": [["name": "Home"], ["name": "Personal"], ["name": "Work"]], "sectionOrder": []]
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
        case "exec.approval.list":
            return ["approvals": .array(self.approvalOrder.compactMap { self.approvals[$0] })]
        case "exec.approval.resolve":
            guard let id = params["id"]?.string, let decision = params["decision"]?.string,
                  ["allow-once", "allow-always", "deny"].contains(decision)
            else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid decision", details: nil) }
            self.approvals[id] = nil
            self.approvalOrder.removeAll { $0 == id }
            self.emit("exec.approval.resolved", ["id": .string(id), "decision": .string(decision)])
            return ["ok": true, "id": .string(id), "decision": .string(decision)]
        default:
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "The demo doesn't support \(method).", details: nil)
        }
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
                         "contextTokens": nil],
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
        row["parentSessionKey"] = params["parentSessionKey"] ?? .null
        row["spawnedBy"] = params["parentSessionKey"] ?? .null
        self.sessions[key] = row
        self.transcripts[key] = message.map { [Self.message("user", [Self.text($0)])] } ?? []
        self.sessionChanged(key, reason: "create")
        return ["key": .string(key), "sessionId": row["sessionId"] ?? .null, "session": .object(row)]
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
        if lowered.range(of: #"\bapprove\b"#, options: .regularExpression) != nil {
            let id = Self.shortId("approval_")
            let approval: JSONValue = [
                "id": .string(id),
                "request": ["command": "rm -rf ./build", "cwd": "/home/claw/project", "sessionKey": .string(key),
                            "agentId": self.sessions[key]?["agentId"] ?? "main"],
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

        let reply = Self.reply(to: text, usedTool: wantsTool)
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
        }
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
        - Say **approve** to raise a command approval.
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

    private static func now() -> JSONValue {
        .number((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func shortId(_ prefix: String = "") -> String {
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
            row.merge(extra) { _, new in new }
            sessions[key] = row
            transcripts[key] = messages
        }

        let dfCall = "call_seed_df"
        add("agent:main:main", agent: "main", title: "Main", preview: "Disk looks healthy.", age: 10_000,
            ["isMain": true], messages: [
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
                ]),
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
