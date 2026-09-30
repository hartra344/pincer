import CryptoKit
import Foundation

/// The demo's MCP servers: a small config (`config.get/schema/patch/apply` for `mcp.servers`, the only
/// config the demo has) and a status table behind `mcp.status`, `mcp.reconnect` and `mcp.oauth.*`.
/// It mirrors `mock-gateway/mcp.mjs`, with the same seed servers, but transitions happen at once and
/// OAuth is simulated: the authorization URL uses the `pincer-demo-oauth://` scheme and the app shows
/// its own consent sheet, then completes the attempt with `mcp.oauth.complete`.
struct DemoMCPState {
    struct Auth {
        var mode: String
        var state = "requires-authorization"
        var expiresAt: Double?
        var account: String?
    }

    struct Runtime {
        var state = "idle"
        var tools: [String] = []
        var lastError: (message: String, at: Double)?
        var auth: Auth?
    }

    struct Attempt {
        let id: String
        let server: String
        let expiresAt: Double
    }

    var config: JSONValue = DemoMCPState.merge(DemoMCPState.seedConfig, DemoVoiceState.seedTTSConfig) ?? DemoMCPState.seedConfig
    var revision = 1
    var runtime: [String: Runtime] = [:]
    var attempts: [String: Attempt] = [:]
    var seeded = false

    static let account = "demo@pincer.app"
    static let redacted = "__OPENCLAW_REDACTED__"

    static let seedConfig: JSONValue = ["mcp": ["servers": [
        "filesystem": ["command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/demo/Projects"],
                       "env": ["LOG_LEVEL": "info"]],
        "home-assistant": ["command": "uvx",
                           "args": ["mcp-server-home-assistant", "--url", "http://homeassistant.local:8123", "--token", "ha-long-lived-token"],
                           "env": ["HA_TOKEN": "ha-long-lived-token"]],
        "github": ["url": "https://api.githubcopilot.com/mcp/", "transport": "streamable-http",
                   "headers": ["Authorization": "Bearer ghp_mocktoken123"]],
        "linear": ["url": "https://mcp.linear.app/mcp", "transport": "streamable-http", "auth": "oauth"],
        "notion": ["url": "https://mcp.notion.com/mcp", "transport": "streamable-http", "auth": "oauth"],
        "postgres": ["command": "uvx", "args": ["mcp-server-postgres", "--dsn", "******db.local/app"],
                     "env": ["PGPASSWORD": "mock-pg-password"]],
        "sentry": ["url": "https://mcp.sentry.dev/sse", "transport": "sse", "enabled": false],
        "acme.docs": ["url": "https://mcp.acme.example/docs", "transport": "streamable-http"],
    ]]]

    static let seedTools: [String: [String]] = [
        "filesystem": ["read_file", "write_file", "list_directory", "search_files"],
        "home-assistant": ["get_state", "call_service"],
        "github": ["get_issue", "list_issues", "create_issue", "search_code", "get_pull_request", "list_pull_requests"],
    ]
    static let acmeTools = ["search", "get_page"]
    static let linearTools = ["list_issues", "get_issue", "create_issue", "update_issue", "search_documentation"]
    static let genericTools = ["echo", "ping", "time"]
    static let toolDescriptions = [
        "get_state": "Read the state of a Home Assistant entity", "call_service": "Call a Home Assistant service",
    ]

    var servers: [String: JSONValue] { self.config["mcp"]?["servers"]?.object ?? [:] }
    var serverNames: [String] { self.servers.keys.sorted() }

    static func transport(_ server: JSONValue) -> String? {
        if server["command"]?.string?.isEmpty == false { return "stdio" }
        if server["url"]?.string?.isEmpty == false { return server["transport"]?.string ?? "sse" }
        return nil
    }

    static func authMode(_ server: JSONValue) -> String? {
        guard server["auth"]?.string == "oauth" else { return nil }
        if server["oauth"]?["identity"]?.string == "per-requester" { return "oauth-per-requester" }
        return server["oauth"]?["authProfileId"]?.string != nil ? "oauth-profile" : "oauth-shared"
    }

    /// The state a server settles in: connected with tools, waiting for sign-in, disabled or invalid.
    mutating func settle(_ name: String) {
        guard let server = self.servers[name] else { return }
        var rt = self.runtime[name] ?? Runtime(auth: Self.authMode(server).map { Auth(mode: $0) })
        rt.lastError = nil
        if server["enabled"]?.bool == false {
            (rt.state, rt.tools) = ("disabled", [])
        } else if Self.transport(server) == nil {
            (rt.state, rt.tools) = ("invalid", [])
        } else if let auth = rt.auth, auth.state != "authorized" {
            (rt.state, rt.tools) = ("idle", [])
        } else if name == "postgres" {
            (rt.state, rt.tools) = ("error", [])
            rt.lastError = ("spawn uvx ENOENT", Date().timeIntervalSince1970 * 1000)
        } else if name == "linear" {
            (rt.state, rt.tools) = ("connected", Self.linearTools)
        } else {
            (rt.state, rt.tools) = ("connected", Self.seedTools[name] ?? (name == "acme.docs" ? Self.acmeTools : Self.genericTools))
        }
        self.runtime[name] = rt
    }

    mutating func seedIfNeeded() {
        guard !self.seeded else { return }
        self.seeded = true
        let now = Date().timeIntervalSince1970 * 1000
        for name in self.serverNames {
            self.settle(name)
            if name == "notion" {
                self.runtime[name]?.state = "error"
                self.runtime[name]?.lastError = ("OAuth token expired", now - 3_600_000)
                self.runtime[name]?.auth?.expiresAt = now - 86_400_000
            }
            if name == "postgres" { self.runtime[name]?.lastError?.at = now - 60_000 }
        }
    }

    /// Adds, updates and drops status rows after a config write; returns the names that changed.
    mutating func sync(from before: [String: JSONValue]) -> [String] {
        var touched: [String] = []
        let after = self.servers
        for name in before.keys where after[name] == nil {
            self.runtime[name] = nil
            touched.append(name)
        }
        for (name, server) in after where before[name] != server {
            let auth = self.runtime[name]?.auth
            self.runtime[name] = Runtime(auth: Self.authMode(server).map { mode in auth.map { var kept = $0; kept.mode = mode; return kept } ?? Auth(mode: mode) })
            self.settle(name)
            touched.append(name)
        }
        return touched.sorted()
    }

    func statusEntry(_ name: String) -> JSONValue? {
        guard let server = self.servers[name], let rt = self.runtime[name] else { return nil }
        var entry: [String: JSONValue] = [
            "name": .string(name), "enabled": .bool(server["enabled"]?.bool != false), "source": "config", "state": .string(rt.state),
        ]
        if let transport = Self.transport(server) { entry["transport"] = .string(transport) }
        if rt.state == "connected" {
            entry["toolCount"] = .number(Double(rt.tools.count))
            entry["tools"] = JSONValue(rt.tools)
        }
        if let error = rt.lastError { entry["lastError"] = ["message": .string(error.message), "at": .number(error.at)] }
        if let auth = rt.auth { entry["auth"] = .object(Self.authObject(auth)) }
        return .object(entry)
    }

    static func authObject(_ auth: Auth) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["mode": .string(auth.mode), "state": .string(auth.state)]
        if let expiresAt = auth.expiresAt { object["expiresAt"] = .number(expiresAt) }
        if let account = auth.account { object["account"] = .string(account) }
        return object
    }

    // MARK: Config

    static func redact(_ value: JSONValue, path: [String] = []) -> JSONValue {
        switch value {
        case let .object(object):
            return .object(object.reduce(into: [:]) { $0[$1.key] = redact($1.value, path: path + [$1.key]) })
        case .string:
            let secret = path.count == 5 && path[0] == "mcp" && path[1] == "servers" && (path[3] == "env" || path[3] == "headers")
            return secret || DemoVoiceState.isAPIKeyPath(path) ? .string(redacted) : value
        default:
            return value
        }
    }

    /// `config.patch` semantics: objects merge, null deletes, and a redacted value keeps what's stored.
    static func merge(_ target: JSONValue?, _ patch: JSONValue) -> JSONValue? {
        switch patch {
        case .null:
            return nil
        case let .string(text) where text == redacted:
            return target
        case let .object(patchObject):
            var result = target?.object ?? [:]
            for (key, value) in patchObject { result[key] = merge(result[key], value) }
            return .object(result)
        default:
            return patch
        }
    }

    var hash: String {
        // Sorted keys: dictionary order isn't stable, and the hash must match between config.get and config.patch.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self.config)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The first problem with the servers map, as the Gateway would word it.
    func problem() -> String? {
        for (name, server) in self.servers.sorted(by: { $0.key < $1.key }) {
            let valid = name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil && name != "__proto__"
            if !valid { return "invalid config: mcp.servers.\(name): invalid MCP server name" }
            if server["disabled"] != nil { return "invalid config: mcp.servers.\(name).disabled: unknown key; use \"enabled\": false" }
            if server.object == nil { return "invalid config: mcp.servers.\(name): expected object" }
        }
        return nil
    }
}

extension DemoGateway {
    static let mcpMethods = [
        "config.get", "config.schema", "config.patch", "config.apply",
        "mcp.status", "mcp.reconnect", "mcp.probe", "plugins.list", "plugins.inspect", "mcp.oauth.status", "mcp.oauth.start", "mcp.oauth.complete", "mcp.oauth.cancel", "mcp.oauth.logout",
    ]
    static let demoOAuthScheme = "pincer-demo-oauth"

    func handleMCP(_ method: String, _ params: JSONValue) async throws -> JSONValue? {
        guard Self.mcpMethods.contains(method) else { return nil }
        self.mcp.seedIfNeeded()
        switch method {
        case "config.get": return self.mcpConfigSnapshot()
        case "config.schema": return Self.mcpConfigSchema
        case "config.patch", "config.apply": return try self.mcpWriteConfig(method, params)
        case "mcp.status":
            let names = self.mcpNames(params["serverNames"])
            return ["generatedAt": .number((Date().timeIntervalSince1970 * 1000).rounded()),
                    "servers": .array(names.compactMap { self.mcp.statusEntry($0) })]
        case "mcp.probe": return try await self.mcpProbe(params)
        case "plugins.list": return Self.demoPluginList
        case "plugins.inspect": return try self.demoPluginInspect(params)
        case "mcp.oauth.status":
            let names = self.mcpNames(params["serverNames"]).filter { self.mcp.runtime[$0]?.auth != nil }
            return ["servers": .array(names.compactMap { name in
                self.mcp.runtime[name]?.auth.map { auth in
                    var object = DemoMCPState.authObject(auth)
                    object["name"] = .string(name)
                    return .object(object)
                }
            })]
        case "mcp.reconnect":
            let names = self.mcpNames(params["serverNames"])
            for name in names { try self.mcpRequireKnown(name) }
            let disposed = names.filter { self.mcp.servers[$0]?["enabled"]?.bool != false }
            for name in disposed {
                let stuck = self.mcp.runtime[name]?.state == "error" && self.mcp.runtime[name]?.auth?.state == "requires-authorization"
                if !stuck { self.mcp.settle(name) }
            }
            self.emit("mcp.status.changed", ["servers": JSONValue(disposed)])
            return ["ok": true, "disposed": JSONValue(disposed)]
        default:
            return try self.handleMCPOAuth(method, params)
        }
    }

    private func mcpNames(_ filter: JSONValue?) -> [String] {
        let all = self.mcp.serverNames
        guard let wanted = filter?.array?.compactMap(\.string) else { return all }
        return all.filter(wanted.contains)
    }

    private func mcpRequireKnown(_ name: String) throws {
        guard self.mcp.servers[name] != nil else { throw Self.mcpInvalid("unknown MCP server: \(name)") }
    }

    private func mcpOAuthServer(_ params: JSONValue) throws -> String {
        let name = params["serverName"]?.string ?? ""
        try self.mcpRequireKnown(name)
        guard self.mcp.servers[name]?["auth"]?.string == "oauth" else { throw Self.mcpInvalid("MCP server \(name) does not use OAuth") }
        return name
    }

    private func handleMCPOAuth(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "mcp.oauth.start":
            let name = try self.mcpOAuthServer(params)
            let attempt = DemoMCPState.Attempt(id: "oauth_\(Self.shortId(""))", server: name,
                                               expiresAt: ((Date().timeIntervalSince1970 + 600) * 1000).rounded())
            self.mcp.attempts[attempt.id] = attempt
            self.mcp.runtime[name]?.auth?.state = "pending-authorization"
            self.emit("mcp.oauth.changed", ["serverName": .string(name), "state": "pending-authorization"])
            self.emit("mcp.status.changed", ["servers": [.string(name)]])
            return ["attemptId": .string(attempt.id),
                    "authorizationUrl": .string("\(Self.demoOAuthScheme)://authorize?attempt=\(attempt.id)&server=\(name)"),
                    "redirectUrl": .string("\(Self.demoOAuthScheme)://callback"), "expiresAt": .number(attempt.expiresAt)]
        case "mcp.oauth.complete":
            guard let attempt = self.mcp.attempts[params["attemptId"]?.string ?? ""] else {
                throw Self.mcpInvalid("unknown or expired OAuth attempt")
            }
            var code = params["code"]?.string
            if code == nil, let callback = params["callbackUrl"]?.string, let components = URLComponents(string: callback) {
                code = components.queryItems?.first { $0.name == "code" }?.value
            }
            guard let code, !code.isEmpty else { throw Self.mcpInvalid("missing authorization code") }
            self.mcp.attempts[attempt.id] = nil
            let now = Date().timeIntervalSince1970 * 1000
            self.mcp.runtime[attempt.server]?.auth?.state = "authorized"
            self.mcp.runtime[attempt.server]?.auth?.account = DemoMCPState.account
            self.mcp.runtime[attempt.server]?.auth?.expiresAt = now + 3_600_000
            self.mcp.settle(attempt.server)
            self.emit("mcp.oauth.changed", ["serverName": .string(attempt.server), "state": "authorized", "account": .string(DemoMCPState.account)])
            self.emit("mcp.status.changed", ["servers": [.string(attempt.server)]])
            return ["state": "authorized", "account": .string(DemoMCPState.account)]
        case "mcp.oauth.cancel":
            guard let attempt = self.mcp.attempts.removeValue(forKey: params["attemptId"]?.string ?? "") else { return ["cancelled": false] }
            if self.mcp.runtime[attempt.server]?.auth?.state == "pending-authorization" {
                self.mcp.runtime[attempt.server]?.auth?.state = "requires-authorization"
            }
            self.emit("mcp.oauth.changed", ["serverName": .string(attempt.server), "state": "requires-authorization"])
            self.emit("mcp.status.changed", ["servers": [.string(attempt.server)]])
            return ["cancelled": true]
        case "mcp.oauth.logout":
            let name = try self.mcpOAuthServer(params)
            let cleared = self.mcp.runtime[name]?.auth?.state == "authorized"
            let mode = self.mcp.runtime[name]?.auth?.mode ?? "oauth-shared"
            self.mcp.runtime[name]?.auth = DemoMCPState.Auth(mode: mode)
            self.mcp.settle(name)
            self.emit("mcp.oauth.changed", ["serverName": .string(name), "state": "requires-authorization"])
            self.emit("mcp.status.changed", ["servers": [.string(name)]])
            return ["cleared": .bool(cleared)]
        default:
            return nil
        }
    }

    // MARK: probe and plugins

    /// One-off connection test of a saved server or an unsaved draft; the status table is untouched. A draft may
    /// carry redacted sentinels, which are restored from the saved entry. By server name (mirrors `mock-gateway/mcp.mjs`):
    /// `postgres` fails with three diagnostics, `home-assistant` succeeds after ~2 s, OAuth servers that aren't signed in
    /// (`linear`, `notion`) need authorization, `github` succeeds with 6 tools, 3 resources and 2 prompts,
    /// `filesystem` with 4 tools, 1 resource, 0 prompts, and anything else with the generic tools.
    /// A command containing "nonexistent" or "missing", a non-http(s) URL or no transport also fails.
    private func mcpProbe(_ params: JSONValue) async throws -> JSONValue {
        let name = params["serverName"]?.string ?? ""
        let saved = self.mcp.servers[name]
        var candidate = saved
        if let draft = params["server"], draft.object != nil {
            candidate = DemoMCPState.restoring(draft, from: saved)
        }
        guard let server = candidate else { throw Self.mcpInvalid("unknown MCP server: \(name)") }
        func failure(_ messages: [String], auth: JSONValue? = nil) -> JSONValue {
            var result: [String: JSONValue] = ["ok": false, "tools": [], "resources": 0, "prompts": 0,
                                               "diagnostics": .array(messages.map { ["message": .string($0)] })]
            result["auth"] = auth
            return .object(result)
        }
        guard DemoMCPState.transport(server) != nil else { return failure(["Server needs a command or a url."]) }
        if let command = server["command"]?.string, command.contains("nonexistent") || command.contains("missing") {
            return failure(["spawn \(command) ENOENT", "Check that \(command) is installed and on the Gateway's PATH."])
        }
        if let url = server["url"]?.string, !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
            return failure(["Invalid url: \(url)"])
        }
        if server["auth"]?.string == "oauth" {
            let auth = (server == saved ? self.mcp.runtime[name]?.auth : nil)
                ?? DemoMCPState.Auth(mode: DemoMCPState.authMode(server) ?? "oauth-shared")
            if auth.state != "authorized" { return failure(["Authorization required."], auth: .object(DemoMCPState.authObject(auth))) }
        }
        if name == "postgres" {
            return failure(["spawn uvx ENOENT", "uvx was not found on the Gateway's PATH.", "Install uv (https://docs.astral.sh/uv/) on the Gateway host."])
        }
        let slow = name == "home-assistant"
        let limit = params["timeoutMs"]?.int ?? 15_000
        if slow {
            if limit < 2000 {
                try? await Task.sleep(for: .milliseconds(max(0, limit)))
                return failure(["Timed out after \(limit) ms waiting for the server to initialize."])
            }
            try? await Task.sleep(for: .seconds(2))
        }
        var tools = name == "linear" ? DemoMCPState.linearTools
            : (DemoMCPState.seedTools[name] ?? (name == "acme.docs" ? DemoMCPState.acmeTools : DemoMCPState.genericTools))
        let include = server["toolFilter"]?["include"]?.array?.compactMap(\.string) ?? []
        let exclude = server["toolFilter"]?["exclude"]?.array?.compactMap(\.string) ?? []
        // Like the Gateway: `*` is the only wildcard; include applies first, then exclude.
        func matches(_ tool: String, _ patterns: [String]) -> Bool {
            patterns.contains { pattern in
                let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
                return tool.range(of: regex, options: .regularExpression) != nil
            }
        }
        tools = tools.filter { (include.isEmpty || matches($0, include)) && !matches($0, exclude) }
        let counts = ["github": (3, 2), "filesystem": (1, 0), "linear": (2, 1)][name] ?? (0, 0)
        return ["ok": true, "tools": JSONValue(tools), "resources": .number(Double(counts.0)), "prompts": .number(Double(counts.1)),
                "diagnostics": []]
    }

    private typealias DemoPlugin = (id: String, name: String, description: String, servers: [String], unavailable: [String])

    private static let demoPlugins: [DemoPlugin] = [
        ("linear", "Linear", "Linear issues through its hosted MCP server.", ["linear"], []),
        ("asana", "Asana", "Asana tasks through its hosted MCP server.", ["asana", "asana-beta"], ["asana-beta"]),
    ]

    private static func demoPluginEntry(_ plugin: DemoPlugin) -> JSONValue {
        ["id": .string(plugin.id), "name": .string(plugin.name), "description": .string(plugin.description), "version": "1.0.0",
         "origin": "clawhub", "installed": true, "enabled": true, "state": "enabled", "runtime": ["state": "active"],
         "removable": true, "kind": ["tool"]]
    }

    private static var demoPluginList: JSONValue {
        ["plugins": .array(demoPlugins.map(demoPluginEntry)), "diagnostics": [], "mutationAllowed": false]
    }

    private func demoPluginInspect(_ params: JSONValue) throws -> JSONValue {
        guard let plugin = Self.demoPlugins.first(where: { $0.id == params["pluginId"]?.string }) else {
            throw Self.mcpInvalid("unknown plugin: \(params["pluginId"]?.string ?? "")")
        }
        self.mcp.seedIfNeeded()
        var result: JSONValue = ["ok": true, "plugin": Self.demoPluginEntry(plugin), "credentials": [],
                "declared": ["mcpServers": JSONValue(plugin.servers)],
                "components": ["mcpServers": JSONValue(plugin.servers.filter { !plugin.unavailable.contains($0) }),
                               "unavailable": ["mcpServers": JSONValue(plugin.unavailable)]],
                "grants": [:]]
        // Like upstream, `mcpAuth` only covers servers with a matching configured OAuth entry, and follows its sign-in.
        let auth: [JSONValue] = plugin.servers.compactMap { name in
            guard self.mcp.servers[name]?["auth"]?.string == "oauth", let state = self.mcp.runtime[name]?.auth?.state else { return nil }
            return ["serverName": .string(name), "state": .string(state)]
        }
        if !auth.isEmpty, case var .object(object) = result {
            object["mcpAuth"] = .array(auth)
            result = .object(object)
        }
        return result
    }

    // MARK: config

    private func mcpConfigSnapshot() -> JSONValue {
        let redacted = DemoMCPState.redact(self.mcp.config)
        return ["path": "/home/demo/.openclaw/openclaw.json", "exists": true, "raw": .string(redacted.prettyPrinted()),
                "parsed": redacted, "resolved": redacted, "config": redacted, "valid": true, "issues": [], "warnings": [],
                "legacyIssues": [], "hash": .string(self.mcp.hash)]
    }

    private static let mcpConfigSchema: JSONValue = [
        "schema": ["type": "object", "properties": ["mcp": ["type": "object", "properties": [
            "servers": ["type": "object", "additionalProperties": ["type": "object"]],
        ]]]],
        "uiHints": [:], "version": "demo", "generatedAt": "2026-01-01T00:00:00Z",
    ]

    private func mcpWriteConfig(_ method: String, _ params: JSONValue) throws -> JSONValue {
        guard params["baseHash"]?.string == self.mcp.hash else {
            throw Self.mcpInvalid(params["baseHash"] == nil ? "config base hash required; re-run config.get and retry"
                : "config changed since last load; re-run config.get and retry")
        }
        guard let raw = params["raw"]?.string, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
            throw Self.mcpInvalid("invalid config: could not parse JSON")
        }
        let before = self.mcp.config
        let beforeServers = self.mcp.servers
        let next = method == "config.patch"
            ? DemoMCPState.merge(before, value)
            : DemoMCPState.restoring(value, from: before)
        var candidate = self.mcp
        candidate.config = next ?? .object([:])
        if let problem = candidate.problem() { throw Self.mcpInvalid(problem) }
        if candidate.config == before {
            return ["ok": true, "noop": true, "changedPaths": [], "config": DemoMCPState.redact(before)]
        }
        self.mcp = candidate
        self.mcp.revision += 1
        let touched = self.mcp.sync(from: beforeServers)
        if !touched.isEmpty { self.emit("mcp.status.changed", ["servers": JSONValue(touched)]) }
        return ["ok": true, "path": "/home/demo/.openclaw/openclaw.json", "hash": .string(self.mcp.hash),
                "config": DemoMCPState.redact(self.mcp.config)]
    }

    // MARK: tools.effective

    /// Rebuilds the MCP group and notices of a seeded `tools.effective` reply from the status table.
    func mcpEffective(_ effective: JSONValue) -> JSONValue {
        self.mcp.seedIfNeeded()
        guard var result = effective.object else { return effective }
        let connected = self.mcp.serverNames.flatMap { name in
            (self.mcp.runtime[name]?.state == "connected" ? self.mcp.runtime[name]?.tools ?? [] : []).map { (name, $0) }
        }
        var groups = result["groups"]?.array ?? []
        var access = result["toolAccess"]?["tools"]?.array ?? []
        if let index = groups.firstIndex(where: { $0["source"]?.string == "mcp" }) {
            let old = Set((groups[index]["tools"]?.array ?? []).compactMap { $0["id"]?.string })
            access.removeAll { old.contains($0["id"]?.string ?? "") }
            let tools: [JSONValue] = connected.map { server, tool in
                let description = DemoMCPState.toolDescriptions[tool] ?? "\(tool) (\(server))"
                var entry: [String: JSONValue] = [
                    "id": .string("\(MCPToolName.safeServerName(server))__\(tool)"), "label": .string(tool), "description": .string(description),
                    "rawDescription": .string(description), "source": "mcp", "mcpServer": .string(server), "mcpToolName": .string(tool),
                ]
                if tool == "call_service" { entry["risk"] = "medium" }
                access.append(["id": entry["id"] ?? "", "status": "available", "reasons": []])
                return .object(entry)
            }
            groups[index] = Self.setting(groups[index], "tools", .array(tools))
        }
        var notices = (result["notices"]?.array ?? []).filter { !($0["id"]?.string ?? "").hasPrefix("mcp-") }
        if result["agentId"]?.string == "main" {
            for name in self.mcp.serverNames {
                guard let rt = self.mcp.runtime[name], rt.state == "error", rt.auth?.state != "requires-authorization" else { continue }
                notices.append(["id": .string("mcp-server-diagnostic:\(name)"), "severity": "warning",
                                "message": .string(rt.lastError?.message ?? "connection failed"), "servers": [.string(name)]])
            }
        }
        result["groups"] = .array(groups)
        result["toolAccess"] = Self.setting(result["toolAccess"] ?? .object([:]), "tools", .array(access))
        result["notices"] = notices.isEmpty ? nil : .array(notices)
        return .object(result)
    }

    private static func mcpInvalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }
}

extension DemoMCPState {
    /// `config.apply` semantics: the whole value replaces the config; redacted values keep what's stored.
    static func restoring(_ value: JSONValue, from original: JSONValue?) -> JSONValue? {
        switch value {
        case let .string(text) where text == redacted:
            return original
        case let .object(object):
            return .object(object.reduce(into: [:]) { $0[$1.key] = restoring($1.value, from: original?[$1.key]) })
        default:
            return value
        }
    }
}
