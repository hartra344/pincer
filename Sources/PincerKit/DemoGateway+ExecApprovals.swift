import CryptoKit
import Foundation

/// The demo's exec approvals file (`exec.approvals.get` / `exec.approvals.set`), with the
/// Gateway's validation, hash checks and error messages (as `mock-gateway/exec-approvals.mjs`).
extension DemoGateway {
    static let execApprovalsPath = "~/.openclaw/exec-approvals.json"

    private static let builtInExecDefaults: [String: JSONValue] = [
        "security": "full", "ask": "off", "askFallback": "deny", "autoAllowSkills": false,
    ]

    static func seedExecApprovals() -> JSONValue {
        let now = self.now().double ?? 0
        let hour = 3_600_000.0
        return [
            "version": 1,
            "socket": ["path": "~/.openclaw/exec-approvals.sock"],
            "defaults": ["security": "allowlist", "ask": "on-miss"],
            "agents": [
                "main": [
                    "allowlist": [
                        [
                            "id": "allow_demo_git", "pattern": "/usr/bin/git", "source": "allow-always",
                            "commandText": "git status", "lastUsedAt": .number(now - 2 * hour),
                            "lastUsedCommand": "git status --short", "lastResolvedPath": "/usr/bin/git",
                        ],
                        [
                            "id": "allow_demo_rg", "pattern": "/usr/bin/rg", "source": "allow-always",
                            "commandText": "rg TODO Sources", "lastUsedAt": .number(now - 5 * hour),
                            "lastUsedCommand": "rg -n \"fixme\" Sources", "lastResolvedPath": "/usr/bin/rg",
                        ],
                        ["id": "allow_demo_deploy", "pattern": "~/bin/deploy.sh", "argPattern": "--staging*"],
                    ],
                    "mcpTools": [
                        ["server": "github", "tool": "create_issue", "source": "allow-always",
                         "addedAt": .number(now - 72 * hour), "lastUsedAt": .number(now - 20 * hour)],
                    ],
                ],
                "research": ["ask": "always", "allowlist": []],
                "coder": [
                    "allowlist": [
                        [
                            "id": "allow_demo_swift", "pattern": "/usr/bin/swift", "source": "allow-always",
                            "commandText": "swift build", "lastUsedAt": .number(now - 0.5 * hour),
                            "lastUsedCommand": "swift build -c release", "lastResolvedPath": "/usr/bin/swift",
                        ],
                        [
                            "id": "allow_demo_npm", "pattern": "/opt/homebrew/bin/npm", "source": "allow-always",
                            "commandText": "npm test", "lastUsedAt": .number(now - 26 * hour),
                            "lastUsedCommand": "npm test -- --watch=false", "lastResolvedPath": "/opt/homebrew/bin/npm",
                        ],
                    ],
                ],
                "old-helper": [
                    "allowlist": [
                        ["id": "allow_demo_curl", "pattern": "/usr/bin/curl", "source": "allow-always",
                         "commandText": "curl -s https://status.example.com", "lastUsedAt": .number(now - 480 * hour)],
                    ],
                ],
            ],
        ]
    }

    /// sha256 of the stored file, keys sorted.
    static func execApprovalsHash(_ file: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(file)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func execApprovalsSnapshot() -> JSONValue {
        var file = self.execApprovals.object ?? [:]
        if var socket = file["socket"]?.object {
            socket["token"] = nil
            file["socket"] = .object(socket)
        }
        var resolved = Self.builtInExecDefaults
        // Like the Gateway, a value it doesn't recognise resolves to the built-in default.
        for (key, value) in self.execApprovals["defaults"]?.object ?? [:] where Self.isValidPolicy(key, value) {
            resolved[key] = value
        }
        return [
            "path": .string(Self.execApprovalsPath), "exists": .bool(self.execApprovalsExists),
            "hash": .string(Self.execApprovalsHash(self.execApprovals)), "file": .object(file),
            "resolvedDefaults": .object(resolved),
        ]
    }

    func execApprovalsGet(_ params: JSONValue) throws -> JSONValue {
        if let extra = params.object?.keys.sorted().first {
            throw Self.invalid("invalid exec.approvals.get params: unexpected property '\(extra)'")
        }
        return self.execApprovalsSnapshot()
    }

    func execApprovalsSet(_ params: JSONValue) throws -> JSONValue {
        if let problem = Self.execSetParamsProblem(params) {
            throw Self.invalid("invalid exec.approvals.set params: \(problem)")
        }
        let hash = Self.execApprovalsHash(self.execApprovals)
        let baseHash = params["baseHash"]?.string
        if self.execApprovalsExists {
            guard let baseHash else {
                throw Self.invalid("exec approvals base hash required; re-run exec.approvals.get and retry")
            }
            guard baseHash == hash else {
                throw Self.invalid("exec approvals changed since last load; re-run exec.approvals.get and retry")
            }
        } else if let baseHash, baseHash != hash {
            throw Self.invalid("exec approvals changed since last load; re-run exec.approvals.get and retry")
        }
        guard var file = params["file"]?.object else { throw Self.invalid("exec approvals file is required") }
        // The socket isn't the client's to change: keep the current one.
        var socket = self.execApprovals["socket"]?.object ?? [:]
        for (key, value) in file["socket"]?.object ?? [:] where socket[key] == nil { socket[key] = value }
        file["socket"] = socket.isEmpty ? nil : .object(socket)
        self.execApprovals = .object(file)
        self.execApprovalsExists = true
        return self.execApprovalsSnapshot()
    }

    /// "Always allow" in the demo adds the command to its agent's allowlist, like the Gateway.
    func appendAllowAlways(_ approval: JSONValue) {
        let request = approval["request"] ?? [:]
        let agentId = request["agentId"]?.string ?? "main"
        let command = request["command"]?.string ?? "(command)"
        let pattern = request["resolvedPath"]?.string ?? command
        var file = self.execApprovals.object ?? ["version": 1]
        var agents = file["agents"]?.object ?? [:]
        var agent = agents[agentId]?.object ?? [:]
        var allowlist = agent["allowlist"]?.array ?? []
        allowlist.append([
            "id": .string(Self.shortId("allow_")), "pattern": .string(pattern), "source": "allow-always",
            "commandText": .string(command), "lastUsedAt": Self.now(),
        ])
        agent["allowlist"] = .array(allowlist)
        agents[agentId] = .object(agent)
        file["agents"] = .object(agents)
        self.execApprovals = .object(file)
        self.execApprovalsExists = true
    }

    private static func invalid(_ message: String) -> GatewayError {
        .rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }

    // MARK: Schema

    private static let securityValues: Set<String> = ["deny", "allowlist", "full"]
    private static let askValues: Set<String> = ["off", "on-miss", "always"]

    private static func isValidPolicy(_ key: String, _ value: JSONValue) -> Bool {
        switch key {
        case "security", "askFallback": value.string.map(self.securityValues.contains) ?? false
        case "ask": value.string.map(self.askValues.contains) ?? false
        case "autoAllowSkills": value.bool != nil
        default: false
        }
    }

    /// The first way `params` breaks the Gateway's closed `exec.approvals.set` schema, or nil.
    static func execSetParamsProblem(_ params: JSONValue) -> String? {
        guard let object = params.object else { return "params must be an object" }
        if let problem = self.unexpected(object, allowed: ["file", "baseHash"], at: "") { return problem }
        if let baseHash = object["baseHash"], baseHash.text == nil { return "/baseHash must be a non-empty string" }
        guard let file = object["file"] else { return "must have required property 'file'" }
        guard let fields = file.object else { return "/file must be an object" }
        if let problem = self.unexpected(fields, allowed: ["version", "socket", "defaults", "agents"], at: "/file") {
            return problem
        }
        guard fields["version"] == 1 else { return "/file/version must be equal to constant 1" }
        if let socket = fields["socket"] {
            guard let socket = socket.object else { return "/file/socket must be an object" }
            if let problem = self.unexpected(socket, allowed: ["path", "token"], at: "/file/socket") { return problem }
            for (key, value) in socket where value.string == nil { return "/file/socket/\(key) must be string" }
        }
        if let defaults = fields["defaults"] {
            if let problem = self.policyProblem(defaults, at: "/file/defaults", extra: []) { return problem }
        }
        if let agents = fields["agents"] {
            guard let agents = agents.object else { return "/file/agents must be an object" }
            for id in agents.keys.sorted() {
                if let problem = self.agentProblem(agents[id]!, at: "/file/agents/\(id)") { return problem }
            }
        }
        return nil
    }

    private static func unexpected(_ object: [String: JSONValue], allowed: Set<String>, at path: String) -> String? {
        object.keys.sorted().first { !allowed.contains($0) }.map { "\(path.isEmpty ? "" : "\(path) ")must NOT have additional property '\($0)'" }
    }

    private static func policyProblem(_ value: JSONValue, at path: String, extra: Set<String>) -> String? {
        guard let object = value.object else { return "\(path) must be an object" }
        if let problem = self.unexpected(object, allowed: Set(["security", "ask", "askFallback", "autoAllowSkills"]).union(extra),
                                         at: path)
        {
            return problem
        }
        // The schema takes any string here, like the Gateway's.
        for key in ["security", "ask", "askFallback"] {
            if let value = object[key], value.string == nil { return "\(path)/\(key) must be string" }
        }
        if let skills = object["autoAllowSkills"], skills.bool == nil { return "\(path)/autoAllowSkills must be boolean" }
        return nil
    }

    private static func agentProblem(_ value: JSONValue, at path: String) -> String? {
        if let problem = self.policyProblem(value, at: path, extra: ["allowlist", "mcpTools"]) { return problem }
        if let allowlist = value["allowlist"] {
            guard let entries = allowlist.array else { return "\(path)/allowlist must be array" }
            let allowed: Set<String> = ["id", "pattern", "source", "commandText", "argPattern", "lastUsedAt",
                                        "lastUsedCommand", "lastResolvedPath"]
            for (index, entry) in entries.enumerated() {
                let at = "\(path)/allowlist/\(index)"
                guard let fields = entry.object else { return "\(at) must be an object" }
                if let problem = self.unexpected(fields, allowed: allowed, at: at) { return problem }
                guard fields["pattern"]?.text != nil else { return "\(at) must have required property 'pattern'" }
                if let source = fields["source"], source != "allow-always" { return "\(at)/source must be equal to constant" }
                if let used = fields["lastUsedAt"], (used.double ?? -1) < 0 { return "\(at)/lastUsedAt must be >= 0" }
            }
        }
        if let tools = value["mcpTools"] {
            guard let grants = tools.array else { return "\(path)/mcpTools must be array" }
            for (index, grant) in grants.enumerated() {
                let at = "\(path)/mcpTools/\(index)"
                guard let fields = grant.object else { return "\(at) must be an object" }
                if let problem = self.unexpected(fields, allowed: ["server", "tool", "source", "addedAt", "lastUsedAt"], at: at) {
                    return problem
                }
                for key in ["server", "tool"] where fields[key]?.text == nil {
                    return "\(at) must have required property '\(key)'"
                }
                guard fields["source"] == "allow-always" else { return "\(at) must have required property 'source'" }
                guard fields["addedAt"]?.double != nil else { return "\(at) must have required property 'addedAt'" }
            }
        }
        return nil
    }
}
