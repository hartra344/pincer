import CryptoKit
import Foundation

/// One file in a demo agent workspace.
struct DemoAgentFile: Sendable {
    var content: String
    var updatedAtMs: Double
}

/// A demo agent workspace: its bootstrap files and whether onboarding (BOOTSTRAP.md) is done.
struct DemoAgentWorkspace: Sendable {
    var files: [String: DemoAgentFile] = [:]
    var setupCompleted = false
}

/// The demo's agent management and workspace files (`agents.create/update/delete`,
/// `agent.identity.get`, `agents.files.list/get/set`), with the Gateway's id rules, hash checks
/// and error messages (as `mock-gateway/agents.mjs`). Edits live in memory for the session.
extension DemoGateway {
    static let agentMethods = [
        "agents.create", "agents.update", "agents.delete", "agent.identity.get",
        "agents.files.list", "agents.files.get", "agents.files.set",
    ]
    static let agentStateDir = "/Users/demo/.openclaw"
    /// Upstream `WORKSPACE_BOOTSTRAP_FILENAMES`: the names agents.files.get/set accept.
    static let workspaceFileNames = ["AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md", "MEMORY.md"]
    private static let expectedAbsentFiles: Set<String> = ["SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md"]
    private static let reservedAgentIds: Set<String> = ["openclaw", "crestodian"]

    static func defaultWorkspace(_ agentId: String) -> String {
        agentId == "main" ? "\(Self.agentStateDir)/workspace" : "\(Self.agentStateDir)/workspace-\(agentId)"
    }

    /// `normalizeAgentIdStrict`: nil when the value has no id characters.
    static func normalizedAgentId(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil { return lower }
        let id = lower.replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-+$", with: "", options: .regularExpression)
        let cut = String(id.prefix(64))
        return cut.isEmpty ? nil : cut
    }

    static func workspaceHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Seeds

    static func seedAgentWorkspaces() -> [String: DemoAgentWorkspace] {
        let now = Self.now().double ?? 0
        let hour = 3_600_000.0
        func workspace(_ files: [String: String], at: Double, setupCompleted: Bool = true) -> DemoAgentWorkspace {
            DemoAgentWorkspace(files: files.mapValues { DemoAgentFile(content: $0, updatedAtMs: at) },
                               setupCompleted: setupCompleted)
        }
        return [
            Self.defaultWorkspace("main"): workspace([
                "AGENTS.md": """
                # AGENTS.md - Claw's Workspace

                This folder is home. Treat it that way.

                ## Every Session

                1. Read `SOUL.md` - this is who you are.
                2. Read `USER.md` - this is who you're helping.
                3. Skim `MEMORY.md` for long-term context.

                ## Safety

                - Don't exfiltrate private data. Ever.
                - Ask before anything destructive; `trash` beats `rm`.
                - In group chats, speak when you add value.

                """,
                "SOUL.md": """
                # SOUL.md - Who You Are

                You're **Claw** 🦞, the house assistant for a small home lab.

                - Be concise. Lead with the answer, then the details.
                - Have opinions and share them.
                - Earn trust through competence, not chatter.

                """,
                "IDENTITY.md": Self.identityMarkdown(name: "Claw", emoji: "🦞", avatar: nil),
                "USER.md": """
                # USER.md - About Your Human

                - **Name:** Sam
                - **Timezone:** America/New_York
                - **Notes:** Prefers short status updates. Runs a NAS, two Raspberry Pis and a Mac mini.

                """,
                "MEMORY.md": """
                # MEMORY.md

                - 2026-09-20: NAS scrub finished clean; next one is monthly.
                - Sam likes disk reports as a table.
                - The garage Pi reboots itself on Sundays at 04:00.

                """,
            ], at: now - 3 * hour),
            Self.defaultWorkspace("research"): workspace([
                "AGENTS.md": """
                # AGENTS.md - Scout's Workspace

                You investigate papers, repos and docs.

                - Cite every claim with a link.
                - Summaries first, methods second.

                """,
                "SOUL.md": """
                # SOUL.md

                You're **Scout** 🔭: curious, skeptical and precise. Say "I don't know" when you don't.

                """,
                "IDENTITY.md": Self.identityMarkdown(name: "Scout", emoji: "🔭", avatar: nil),
            ], at: now - 26 * hour),
            Self.defaultWorkspace("coder"): workspace([
                "AGENTS.md": """
                # AGENTS.md - Forge's Workspace

                You edit code, run builds and report concise status.

                - Run the tests before saying something works.
                - Keep diffs small and explain why.

                """,
                "IDENTITY.md": Self.identityMarkdown(name: "Forge", emoji: "🛠️", avatar: nil),
                "BOOTSTRAP.md": Self.bootstrapTemplate,
            ], at: now - 1 * hour, setupCompleted: false),
            Self.defaultWorkspace("kiko"): workspace([
                "AGENTS.md": """
                # AGENTS.md - Kiko's Workspace

                You keep Alex's budget: bills, subscriptions and renewals. Ask the other agents for the costs they know about.

                """,
                "SOUL.md": """
                # SOUL.md

                You're **Kiko** 🌕: calm, exact with numbers and never pushy about money.

                """,
                "IDENTITY.md": Self.identityMarkdown(name: "Kiko", emoji: "🌕", avatar: nil),
            ], at: now - 30 * hour),
        ]
    }

    private static let bootstrapTemplate = """
    # BOOTSTRAP.md - Hello, World

    You just woke up. Figure out who you are with your human, fill in `IDENTITY.md` and `SOUL.md`, then delete this file.

    """

    private static func identityMarkdown(name: String, emoji: String?, avatar: String?) -> String {
        var lines = ["# IDENTITY.md - Who Am I?", "", "- **Name:** \(name)"]
        if let emoji, !emoji.isEmpty { lines.append("- **Emoji:** \(emoji)") }
        if let avatar, !avatar.isEmpty { lines.append("- **Avatar:** \(avatar)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func templates(name: String, emoji: String?, avatar: String?) -> [String: String] {
        [
            "AGENTS.md": """
            # AGENTS.md - Your Workspace

            This folder is home. Treat it that way.

            ## Every Session

            1. Read `SOUL.md` - this is who you are.
            2. Read `USER.md` - this is who you're helping.

            """,
            "SOUL.md": """
            # SOUL.md - Who You Are

            Be genuinely helpful, not performatively helpful. Have opinions. Be resourceful before asking.

            """,
            "IDENTITY.md": Self.identityMarkdown(name: name, emoji: emoji, avatar: avatar),
            "USER.md": "# USER.md - About Your Human\n\n- **Name:**\n- **Timezone:**\n- **Notes:**\n",
            "BOOTSTRAP.md": Self.bootstrapTemplate,
        ]
    }

    // MARK: Dispatch

    /// Handles agent management methods (and `agents.list`); nil for anything else.
    func handleAgents(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard method == "agents.list" || Self.agentMethods.contains(method) else { return nil }
        if let problem = Self.agentParamsProblem(method, params) {
            throw Self.agentInvalid("invalid \(method) params: \(problem)")
        }
        switch method {
        case "agents.list":
            return ["defaultId": "main", "mainKey": "main", "scope": "per-sender",
                    "agents": .array(self.agents.map(Self.agentSummary))]
        case "agent.identity.get":
            return self.agentIdentity(params)
        case "agents.create":
            return try self.createAgent(params)
        case "agents.update":
            return try self.updateAgent(params)
        case "agents.delete":
            return try self.deleteAgent(params)
        case "agents.files.list":
            let agentId = try self.configuredAgentId(params["agentId"]?.string ?? "")
            let dir = self.workspaceDir(agentId)
            let ws = self.agentWorkspaces[dir]
            let names = Self.workspaceFileNames.filter {
                $0 != "IDENTITY.md" && !($0 == "BOOTSTRAP.md" && ws?.setupCompleted == true)
            }
            return ["agentId": .string(agentId), "workspace": .string(dir),
                    "files": .array(names.map { Self.fileEntry(dir: dir, name: $0, file: ws?.files[$0], full: false) })]
        case "agents.files.get":
            let (agentId, name) = try self.agentFile(params)
            let dir = self.workspaceDir(agentId)
            return ["agentId": .string(agentId), "workspace": .string(dir),
                    "file": Self.fileEntry(dir: dir, name: name, file: self.agentWorkspaces[dir]?.files[name], full: true)]
        default:
            return try self.setAgentFile(params)
        }
    }

    // MARK: Agents

    private static func agentSummary(_ agent: JSONValue) -> JSONValue {
        guard var row = agent.object else { return agent }
        let id = row["id"]?.string ?? "main"
        if row["workspace"] == nil { row["workspace"] = .string(Self.defaultWorkspace(id)) }
        if let model = row["model"]?.string { row["model"] = ["primary": .string(model)] }
        return .object(row)
    }

    private func agentIndex(_ id: String) -> Int? {
        self.agents.firstIndex { $0["id"]?.string == id }
    }

    private func configuredAgentId(_ raw: String) throws -> String {
        guard let id = Self.normalizedAgentId(raw), self.agentIndex(id) != nil else {
            throw Self.agentInvalid("agent \"\(Self.normalizedAgentId(raw) ?? raw)\" not found")
        }
        return id
    }

    func workspaceDir(_ agentId: String) -> String {
        self.agents[self.agentIndex(agentId) ?? 0]["workspace"]?.string ?? Self.defaultWorkspace(agentId)
    }

    private func ensureWorkspace(_ dir: String, name: String, emoji: String?, avatar: String?) {
        var ws = self.agentWorkspaces[dir] ?? DemoAgentWorkspace()
        let at = Self.now().double ?? 0
        for (file, content) in Self.templates(name: name, emoji: emoji, avatar: avatar) where ws.files[file] == nil {
            ws.files[file] = DemoAgentFile(content: content, updatedAtMs: at)
        }
        self.agentWorkspaces[dir] = ws
    }

    private func agentIdentity(_ params: JSONValue) -> JSONValue {
        let sessionKey = params["sessionKey"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        var agentId = params["agentId"]?.string.map { Self.normalizedAgentId($0) ?? "main" }
        if !sessionKey.isEmpty || agentId == nil {
            let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
            let fromKey = parts.count >= 3 && parts[0] == "agent" ? Self.normalizedAgentId(String(parts[1])) : nil
            agentId = fromKey ?? agentId ?? "main"
        }
        let id = agentId ?? "main"
        let agent = self.agentIndex(id).map { self.agents[$0] }
        let identity = agent?["identity"]
        let name = identity?["name"]?.string ?? agent?["name"]?.string
        let emoji = identity?["emoji"]?.string
        let avatar = [identity?["avatar"]?.string, emoji].compactMap { $0 }.first { !$0.isEmpty } ?? "A"
        var result: [String: JSONValue] = [
            "agentId": .string(id), "name": .string(name ?? "Assistant"),
            "nameSource": .string(name == nil ? "default" : "agent"), "avatar": .string(avatar),
        ]
        if let emoji { result["emoji"] = .string(emoji) }
        return .object(result)
    }

    private static func trimmed(_ value: JSONValue?) -> String? {
        let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "[\r\n]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func createAgent(_ params: JSONValue) throws -> JSONValue {
        guard let rawName = Self.trimmed(params["name"]) else { throw Self.agentInvalid("agent name is required") }
        guard let agentId = Self.normalizedAgentId(rawName) else {
            throw Self.agentInvalid("Agent name \"\(rawName)\" has no valid id characters. Use at least one letter a-z or digit.")
        }
        if Self.reservedAgentIds.contains(agentId) { throw Self.agentInvalid("\"\(agentId)\" is reserved") }
        if self.agentIndex(agentId) != nil { throw Self.agentInvalid("agent \"\(agentId)\" already exists") }
        let name = Self.oneLine(rawName)
        let emoji = Self.trimmed(params["emoji"])
        let avatar = Self.trimmed(params["avatar"])
        let model = Self.trimmed(params["model"])
        let workspace = Self.trimmed(params["workspace"]) ?? Self.defaultWorkspace(agentId)
        var identity: [String: JSONValue] = ["name": .string(name)]
        if let emoji { identity["emoji"] = .string(emoji) }
        if let avatar { identity["avatar"] = .string(avatar) }
        var agent: [String: JSONValue] = [
            "id": .string(agentId), "name": .string(name), "identity": .object(identity),
            "workspace": .string(workspace), "createdAt": Self.now(), "createdVia": "operator",
        ]
        if let model { agent["model"] = .string(model) }
        self.agents.append(.object(agent))
        self.ensureWorkspace(workspace, name: name, emoji: emoji, avatar: avatar)
        var result: [String: JSONValue] = [
            "ok": true, "agentId": .string(agentId), "name": .string(name), "workspace": .string(workspace),
        ]
        if let model { result["model"] = .string(model) }
        return .object(result)
    }

    private func updateAgent(_ params: JSONValue) throws -> JSONValue {
        let agentId = try self.configuredAgentId(params["agentId"]?.string ?? "")
        guard let index = self.agentIndex(agentId), var agent = self.agents[index].object else {
            throw Self.agentInvalid("agent \"\(agentId)\" not found")
        }
        let name = Self.trimmed(params["name"]).map(Self.oneLine)
        let emoji = Self.trimmed(params["emoji"])
        let avatar = Self.trimmed(params["avatar"])
        let workspace = Self.trimmed(params["workspace"])
        var identity = agent["identity"]?.object ?? [:]
        if let name {
            agent["name"] = .string(name)
            identity["name"] = .string(name)
        }
        if let emoji { identity["emoji"] = .string(emoji) }
        if let avatar { identity["avatar"] = .string(avatar) }
        let hasIdentity = name != nil || emoji != nil || avatar != nil
        if hasIdentity { agent["identity"] = .object(identity) }
        if let workspace { agent["workspace"] = .string(workspace) }
        if params["model"]?.isNull == true {
            agent["model"] = nil
        } else if let model = Self.trimmed(params["model"]) {
            agent["model"] = .string(model)
        }
        if let runtime = Self.trimmed(params["agentRuntime"]) { agent["agentRuntime"] = .string(runtime) }
        self.agents[index] = .object(agent)
        let displayName = identity["name"]?.string ?? agent["name"]?.string ?? agentId
        let dir = self.workspaceDir(agentId)
        if workspace != nil {
            self.ensureWorkspace(dir, name: displayName, emoji: identity["emoji"]?.string, avatar: identity["avatar"]?.string)
        }
        if workspace != nil || hasIdentity {
            self.agentWorkspaces[dir, default: DemoAgentWorkspace()].files["IDENTITY.md"] = DemoAgentFile(
                content: Self.identityMarkdown(name: displayName, emoji: identity["emoji"]?.string,
                                               avatar: identity["avatar"]?.string),
                updatedAtMs: Self.now().double ?? 0)
        }
        return ["ok": true, "agentId": .string(agentId)]
    }

    private func deleteAgent(_ params: JSONValue) throws -> JSONValue {
        let agentId = try self.configuredAgentId(params["agentId"]?.string ?? "")
        if self.agents.count == 1 {
            throw Self.agentInvalid("Agent \"\(agentId)\" is the only configured agent and cannot be deleted.")
        }
        let dir = self.workspaceDir(agentId)
        let deleteFiles = params["deleteFiles"]?.bool ?? true
        self.agents.removeAll { $0["id"]?.string == agentId }
        var removed: [JSONValue] = []
        if deleteFiles {
            let shared = self.agents.contains { Self.agentSummary($0)["workspace"]?.string == dir }
            if !shared {
                let existed = self.agentWorkspaces.removeValue(forKey: dir) != nil
                removed.append(["path": .string(dir), "method": existed ? "trash" : "missing"])
            }
            removed.append(["path": .string("\(Self.agentStateDir)/agents/\(agentId)/agent"), "method": "trash"])
            removed.append(["path": .string("\(Self.agentStateDir)/agents/\(agentId)/sessions"), "method": "trash"])
        }
        self.removeSessions(ofAgent: agentId)
        return ["ok": true, "agentId": .string(agentId), "removedBindings": 0, "removed": .array(removed), "failed": []]
    }

    // MARK: Files

    private func agentFile(_ params: JSONValue) throws -> (agentId: String, name: String) {
        let agentId = try self.configuredAgentId(params["agentId"]?.string ?? "")
        let name = (params["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.workspaceFileNames.contains(name) else { throw Self.agentInvalid("unsupported file \"\(name)\"") }
        return (agentId, name)
    }

    private static func fileEntry(dir: String, name: String, file: DemoAgentFile?, full: Bool) -> JSONValue {
        var entry: [String: JSONValue] = ["name": .string(name), "path": .string("\(dir)/\(name)"), "missing": .bool(file == nil)]
        guard let file else {
            entry["expectedAbsent"] = .bool(Self.expectedAbsentFiles.contains(name))
            return .object(entry)
        }
        entry["size"] = JSONValue(file.content.utf8.count)
        entry["updatedAtMs"] = .number(file.updatedAtMs)
        if full {
            entry["hash"] = .string(Self.workspaceHash(file.content))
            entry["content"] = .string(file.content)
        }
        return .object(entry)
    }

    private func setAgentFile(_ params: JSONValue) throws -> JSONValue {
        let (agentId, name) = try self.agentFile(params)
        let dir = self.workspaceDir(agentId)
        let current = self.agentWorkspaces[dir]?.files[name]
        func conflict(_ currentHash: String?) -> GatewayError {
            var details: [String: JSONValue] = ["type": "agent_file_conflict", "name": .string(name)]
            if let currentHash { details["currentHash"] = .string(currentHash) }
            return .rpc(code: "INVALID_REQUEST", message: "agent file \"\(name)\" changed since it was read",
                        details: .object(details))
        }
        if params["expectedMissing"]?.bool == true, current != nil { throw conflict(nil) }
        if let expected = params["expectedHash"]?.string {
            let currentHash = current.map { Self.workspaceHash($0.content) }
            if currentHash != expected.lowercased() { throw conflict(currentHash) }
        }
        let file = DemoAgentFile(content: params["content"]?.string ?? "", updatedAtMs: Self.now().double ?? 0)
        self.agentWorkspaces[dir, default: DemoAgentWorkspace()].files[name] = file
        return ["ok": true, "agentId": .string(agentId), "workspace": .string(dir),
                "file": Self.fileEntry(dir: dir, name: name, file: file, full: true)]
    }

    // MARK: Schema

    private static func agentInvalid(_ message: String) -> GatewayError {
        .rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }

    private enum FieldKind { case nonEmpty, string, bool, nullableNonEmpty, sha256, trueLiteral }

    private static let agentSchemas: [String: (required: [String], fields: [String: FieldKind])] = [
        "agents.list": ([], [:]),
        "agents.create": (["name"], ["name": .nonEmpty, "workspace": .nonEmpty, "model": .nonEmpty,
                                     "emoji": .string, "avatar": .string]),
        "agents.update": (["agentId"], ["agentId": .nonEmpty, "name": .nonEmpty, "workspace": .nonEmpty,
                                        "model": .nullableNonEmpty, "agentRuntime": .nonEmpty,
                                        "emoji": .string, "avatar": .string]),
        "agents.delete": (["agentId"], ["agentId": .nonEmpty, "deleteFiles": .bool]),
        "agent.identity.get": ([], ["agentId": .nonEmpty, "sessionKey": .string]),
        "agents.files.list": (["agentId"], ["agentId": .nonEmpty]),
        "agents.files.get": (["agentId", "name"], ["agentId": .nonEmpty, "name": .nonEmpty]),
        "agents.files.set": (["agentId", "name", "content"],
                             ["agentId": .nonEmpty, "name": .nonEmpty, "content": .string,
                              "expectedHash": .sha256, "expectedMissing": .trueLiteral]),
    ]

    static func agentParamsProblem(_ method: String, _ params: JSONValue) -> String? {
        guard let schema = Self.agentSchemas[method] else { return nil }
        guard let object = params.object else { return "at root: must be object" }
        for key in schema.required where object[key] == nil {
            return "at root: must have required property '\(key)'"
        }
        for key in object.keys.sorted() {
            guard let kind = schema.fields[key] else { return "at root: unexpected property '\(key)'" }
            if let problem = Self.fieldProblem(kind, object[key] ?? .null) { return "at /\(key): \(problem)" }
        }
        if method == "agents.files.set", object["expectedHash"] != nil, object["expectedMissing"] != nil {
            return "at root: must NOT be valid"
        }
        return nil
    }

    private static func fieldProblem(_ kind: FieldKind, _ value: JSONValue) -> String? {
        switch kind {
        case .string:
            return value.string == nil ? "must be string" : nil
        case .bool:
            return value.bool == nil ? "must be boolean" : nil
        case .nonEmpty, .nullableNonEmpty:
            if kind == .nullableNonEmpty, value.isNull { return nil }
            guard let text = value.string else { return "must be string" }
            return text.isEmpty ? "must NOT have fewer than 1 characters" : nil
        case .sha256:
            let valid = value.string?.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
            return valid ? nil : "must match pattern \"^[a-fA-F0-9]{64}$\""
        case .trueLiteral:
            return value.bool == true ? nil : "must be equal to constant"
        }
    }
}
