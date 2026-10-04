import Foundation

// MCP servers (Gateway Settings → MCP Servers). The server list is the config map `mcp.servers`,
// edited through the shared settings draft. Live state comes from the proposed `mcp.status` and
// `mcp.oauth.*` RPCs when the Gateway advertises them, else from `tools.effective`.

/// How an MCP server is reached.
public enum MCPTransport: String, CaseIterable, Sendable, Hashable {
    case stdio
    case streamableHTTP = "streamable-http"
    case sse

    public var title: String {
        switch self {
        case .stdio: "stdio"
        case .streamableHTTP: L("Streamable HTTP")
        case .sse: "SSE"
        }
    }

    public var isRemote: Bool { self != .stdio }

    init?(configValue: String) {
        switch configValue.lowercased() {
        case "stdio": self = .stdio
        case "streamable-http", "streamablehttp", "streamable_http", "http": self = .streamableHTTP
        case "sse": self = .sse
        default: return nil
        }
    }
}

/// One `env` or `headers` row. `isRedacted` rows hold the Gateway's sentinel: the UI shows
/// "•••• (saved)" and sends nothing unless the value is replaced.
public struct MCPKeyValue: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var key: String
    public var value: String
    public var isRedacted: Bool

    public init(id: UUID = UUID(), key: String = "", value: String = "", isRedacted: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isRedacted = isRedacted
    }

    static func rows(_ json: JSONValue?) -> [MCPKeyValue] {
        (json?.object ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            let text = value.string ?? Self.describe(value)
            return MCPKeyValue(key: key, value: text, isRedacted: value.isRedacted)
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case let .number(number): Int(exactly: number).map { String($0) } ?? String(number)
        case let .bool(flag): String(flag)
        default: ""
        }
    }

    /// The rows as a config object; empty when there are no named rows.
    static func object(_ rows: [MCPKeyValue]) -> JSONValue? {
        var values: [String: JSONValue] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = .string(row.isRedacted ? JSONValue.redactedSentinel : row.value)
        }
        return values.isEmpty ? nil : .object(values)
    }
}

/// One entry of `mcp.servers`, read from config.
public struct MCPServer: Identifiable, Hashable, Sendable {
    public let name: String
    public var id: String { self.name }
    public let enabled: Bool
    /// Nil when the entry has neither a command nor a URL.
    public let transport: MCPTransport?
    public let command: String?
    public let args: [String]
    public let cwd: String?
    public let env: [MCPKeyValue]
    public let url: String?
    public let urlIsRedacted: Bool
    public let headers: [MCPKeyValue]
    public let usesOAuth: Bool
    /// `shared` or `per-requester`.
    public let oauthIdentity: String?
    /// `oauth.authProfileId`, when the server signs in with a named auth profile.
    public let oauthAuthProfileId: String?
    public let oauthScope: String?
    /// `connectionTimeoutMs` / `requestTimeoutMs`, when set to a number.
    public let connectionTimeoutMs: Int?
    public let requestTimeoutMs: Int?
    /// `toolFilter.include` / `toolFilter.exclude` patterns.
    public let toolInclude: [String]
    public let toolExclude: [String]
    /// `sslVerify`; nil when the key is absent (verification on).
    public let sslVerify: Bool?
    public let clientCert: String?
    public let clientKey: String?
    /// The whole entry, so edits keep keys Pincer doesn't know.
    public let raw: JSONValue

    public init?(name: String, json: JSONValue) {
        guard let object = json.object else { return nil }
        self.name = name
        self.raw = json
        self.enabled = object["enabled"]?.bool ?? true
        self.command = json["command"]?.text
        self.args = json["args"]?.array?.compactMap { $0.string ?? $0.double.map { String($0) } } ?? []
        self.cwd = json["cwd"]?.text
        self.env = MCPKeyValue.rows(json["env"])
        self.urlIsRedacted = json["url"]?.isRedacted ?? false
        self.url = json["url"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        self.headers = MCPKeyValue.rows(json["headers"])
        self.usesOAuth = json["auth"]?.string == "oauth"
        self.oauthIdentity = json["oauth"]?["identity"]?.text
        self.oauthAuthProfileId = json["oauth"]?["authProfileId"]?.text
        self.oauthScope = json["oauth"]?["scope"]?.text
        self.connectionTimeoutMs = json["connectionTimeoutMs"]?.int
        self.requestTimeoutMs = json["requestTimeoutMs"]?.int
        self.toolInclude = json["toolFilter"]?["include"]?.array?.compactMap(\.text) ?? []
        self.toolExclude = json["toolFilter"]?["exclude"]?.array?.compactMap(\.text) ?? []
        self.sslVerify = json["sslVerify"]?.bool
        self.clientCert = json["clientCert"]?.text
        self.clientKey = json["clientKey"]?.text
        let declared = json["transport"]?.string.flatMap(MCPTransport.init(configValue:))
        if self.command != nil {
            self.transport = .stdio
        } else if self.url != nil {
            // A URL without a transport is SSE.
            self.transport = declared.flatMap { $0.isRemote ? $0 : nil } ?? .sse
        } else {
            self.transport = nil
        }
    }

    /// "npx -y @modelcontextprotocol/server-filesystem ~/Projects" (secret args masked), or the
    /// URL's host and path.
    public var launchSummary: String {
        if let command = self.command {
            return ([command] + Self.maskedArgs(self.args)).joined(separator: " ")
        }
        guard let url = self.url else { return "" }
        if self.urlIsRedacted { return "••••" }
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let path = components.path == "/" ? "" : components.path
        return host + (components.port.map { ":\($0)" } ?? "") + path
    }

    private static let secretFlagWords = ["token", "secret", "password", "passwd", "apikey", "api-key", "api_key", "dsn"]
    private static let secretKeyWords = ["token", "key", "secret", "password"]
    static let mask = "••••"

    /// Args with secret values hidden: the value after `--token`-style flags, the value of
    /// `--token=…`, and the value of `KEY=value` when the key looks secret. Args are not
    /// redacted by the Gateway, so this only hides them on screen.
    public static func maskedArgs(_ args: [String]) -> [String] {
        var masked: [String] = []
        var hideNext = false
        for arg in args {
            if hideNext {
                hideNext = false
                masked.append(Self.mask)
                continue
            }
            if arg.hasPrefix("-") {
                let flag = arg.drop(while: { $0 == "-" })
                if let equals = flag.firstIndex(of: "=") {
                    let name = flag[..<equals].lowercased()
                    masked.append(Self.secretFlagWords.contains { name.contains($0) } || name == "key"
                        ? "\(arg[..<equals])=\(Self.mask)"
                        : arg)
                } else {
                    hideNext = Self.secretFlagWords.contains { flag.lowercased().contains($0) } || flag.lowercased() == "key"
                    masked.append(arg)
                }
            } else if let equals = arg.firstIndex(of: "="), equals != arg.startIndex,
                      Self.secretKeyWords.contains(where: { arg[..<equals].lowercased().contains($0) })
            {
                masked.append("\(arg[..<equals])=\(Self.mask)")
            } else {
                masked.append(arg)
            }
        }
        return masked
    }
}

public enum MCPServers {
    public static let path = ["mcp", "servers"]
    public static let statusMethod = "mcp.status"
    public static let probeMethod = "mcp.probe"
    public static let reconnectMethod = "mcp.reconnect"
    public static let oauthStatusMethod = "mcp.oauth.status"
    public static let oauthStartMethod = "mcp.oauth.start"
    public static let oauthCompleteMethod = "mcp.oauth.complete"
    public static let oauthCancelMethod = "mcp.oauth.cancel"
    public static let oauthLogoutMethod = "mcp.oauth.logout"
    public static let oauthChangedEvent = "mcp.oauth.changed"
    public static let statusChangedEvent = "mcp.status.changed"
    public static let returnURLScheme = "pincer"
    /// The `pincer://` host the Gateway redirects the browser to after sign-in.
    public static let returnURLHost = "mcp-oauth"

    /// `pincer://mcp-oauth/done?server=<name>`
    public static func returnURL(server: String) -> URL {
        var components = URLComponents()
        components.scheme = self.returnURLScheme
        components.host = self.returnURLHost
        components.path = "/done"
        components.queryItems = [URLQueryItem(name: "server", value: server)]
        return components.url!
    }

    /// Whether `url` is the sign-in return link (`pincer://mcp-oauth/…`).
    public static func isReturnURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == self.returnURLScheme && url.host?.lowercased() == self.returnURLHost
    }

    /// The Gateway's rule for server names (also rejects `__proto__`).
    public static func isValidName(_ name: String) -> Bool {
        name != "__proto__" && name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil
    }

    /// The servers in `config`, by name (case-insensitive).
    public static func servers(in config: JSONValue?) -> [MCPServer] {
        (config?["mcp"]?["servers"]?.object ?? [:])
            .compactMap { MCPServer(name: $0.key, json: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// An add/edit form for one server, validated and turned back into a config object.
public struct MCPServerDraft: Hashable, Sendable {
    /// Nil for a new server.
    public var originalName: String?
    public var name: String
    public var transport: MCPTransport
    public var enabled: Bool
    public var command: String
    public var args: [String]
    public var cwd: String
    public var env: [MCPKeyValue]
    public var url: String
    public var urlIsRedacted: Bool
    public var headers: [MCPKeyValue]
    public var usesOAuth: Bool
    /// Positive whole milliseconds as text; empty removes the key.
    public var connectionTimeoutMs = ""
    public var requestTimeoutMs = ""
    public var toolInclude: [String] = []
    public var toolExclude: [String] = []
    /// Remote only. Off is written as `sslVerify: false`.
    public var sslVerify = true
    /// Remote only: file paths. A saved redacted value holds the sentinel.
    public var clientCert = ""
    public var clientKey = ""
    /// `oauth.identity`: "" (Gateway default), `shared` or `per-requester`. Remote + OAuth only.
    public var oauthIdentity = ""
    public var oauthScope = ""
    public var oauthAuthProfileId = ""

    /// Identity choices for `oauthIdentity`.
    public static let oauthIdentities = ["shared", "per-requester"]

    private var savedEnvKeys: Set<String> = []
    private var savedHeaderKeys: Set<String> = []
    private var savedTransport: MCPTransport?
    private var savedURL: String?
    private var savedUsesOAuth = false
    private var savedFields: [MCPTransport: [String]] = [:]

    public init() {
        self.originalName = nil
        self.name = ""
        self.transport = .stdio
        self.enabled = true
        self.command = ""
        self.args = []
        self.cwd = ""
        self.env = []
        self.url = ""
        self.urlIsRedacted = false
        self.headers = []
        self.usesOAuth = false
    }

    public init(server: MCPServer) {
        self.originalName = server.name
        self.name = server.name
        self.transport = server.transport ?? .stdio
        self.enabled = server.enabled
        self.command = server.command ?? ""
        self.args = server.args
        self.cwd = server.cwd ?? ""
        self.env = server.env
        self.url = server.urlIsRedacted ? JSONValue.redactedSentinel : (server.url ?? "")
        self.urlIsRedacted = server.urlIsRedacted
        self.headers = server.headers
        self.usesOAuth = server.usesOAuth
        self.connectionTimeoutMs = server.connectionTimeoutMs.map(String.init) ?? ""
        self.requestTimeoutMs = server.requestTimeoutMs.map(String.init) ?? ""
        self.toolInclude = server.toolInclude
        self.toolExclude = server.toolExclude
        self.sslVerify = server.sslVerify ?? true
        self.clientCert = server.clientCert ?? ""
        self.clientKey = server.clientKey ?? ""
        self.oauthIdentity = server.oauthIdentity ?? ""
        self.oauthScope = server.oauthScope ?? ""
        self.oauthAuthProfileId = server.oauthAuthProfileId ?? ""
        self.savedEnvKeys = Set(server.env.map(\.key))
        self.savedHeaderKeys = Set(server.headers.map(\.key))
        self.savedTransport = server.transport
        self.savedURL = server.url
        self.savedUsesOAuth = server.usesOAuth
        var local: [String] = []
        if server.command != nil { local.append(L("Command")) }
        if !server.args.isEmpty { local.append(L("Arguments")) }
        if server.cwd != nil { local.append(L("Working directory")) }
        if !server.env.isEmpty { local.append(L("Environment variables")) }
        var remote: [String] = []
        if server.url != nil { remote.append(L("URL")) }
        if !server.headers.isEmpty { remote.append(L("Headers")) }
        if server.usesOAuth { remote.append(L("OAuth options")) }
        if server.sslVerify != nil || server.clientCert != nil || server.clientKey != nil { remote.append(L("TLS settings")) }
        self.savedFields = [.stdio: local, .streamableHTTP: remote, .sse: remote]
    }

    public var isRename: Bool { self.originalName != nil && self.originalName != self.trimmedName }

    /// An OAuth server whose name or URL changed: saved tokens are keyed by both, so it needs to sign in again.
    public var resetsSignIn: Bool {
        guard self.originalName != nil, self.savedUsesOAuth, self.usesOAuth, self.transport.isRemote else { return false }
        let url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.isRename || (!self.urlIsRedacted && url != (self.savedURL ?? ""))
    }

    /// Labels of saved fields that switching transport will remove.
    public var droppedFieldsOnTransportChange: [String] {
        guard let saved = self.savedTransport, saved.isRemote != self.transport.isRemote else { return [] }
        return self.savedFields[saved] ?? []
    }

    private var trimmedName: String { self.name.trimmingCharacters(in: .whitespaces) }

    private static var resecret: String { L("Re-enter this value; saved secrets can't move to a new name.") }

    /// Problems by field: `name`, `command`, `url`, `env.<key>`, `headers.<key>`, `connectionTimeoutMs`, `requestTimeoutMs`, `oauthIdentity`, `oauthAuthProfileId`.
    public func problems(existingNames: Set<String>) -> [String: String] {
        var problems: [String: String] = [:]
        let name = self.trimmedName
        if name.isEmpty {
            problems["name"] = L("Enter a name.")
        } else if !MCPServers.isValidName(name) {
            problems["name"] = L("Use letters, numbers, dots, dashes and underscores, starting with a letter or number.")
        } else if name != self.originalName, existingNames.contains(name) {
            problems["name"] = L("A server named “\(name)” already exists.")
        }
        if self.transport.isRemote {
            let url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.urlIsRedacted {
                if self.isRename { problems["url"] = Self.resecret }
            } else if url.isEmpty {
                problems["url"] = L("Enter the server's URL.")
            } else if let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
                      ["http", "https"].contains(scheme), components.host?.isEmpty == false
            {
                // valid
            } else {
                problems["url"] = L("Enter a full http:// or https:// URL.")
            }
            self.checkRows(self.headers, saved: self.savedHeaderKeys, prefix: "headers", into: &problems)
            if self.usesOAuth {
                if !self.oauthIdentity.isEmpty, !Self.oauthIdentities.contains(self.oauthIdentity) {
                    problems["oauthIdentity"] = L("Choose shared or per-requester.")
                } else if self.oauthIdentity == "per-requester", !self.oauthAuthProfileId.trimmingCharacters(in: .whitespaces).isEmpty {
                    problems["oauthAuthProfileId"] = L("Per-person sign-in can't use an auth profile.")
                }
            }
        } else {
            if self.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems["command"] = L("Enter the command to run.") }
            self.checkRows(self.env, saved: self.savedEnvKeys, prefix: "env", into: &problems)
        }
        for (key, text) in [("connectionTimeoutMs", self.connectionTimeoutMs), ("requestTimeoutMs", self.requestTimeoutMs)] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !Self.isPositiveInteger(trimmed) { problems[key] = L("Enter a whole number of milliseconds.") }
        }
        return problems
    }

    private static func isPositiveInteger(_ text: String) -> Bool {
        text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) && (1...2_147_000_000).contains(Int(text) ?? 0)
    }

    private func checkRows(_ rows: [MCPKeyValue], saved: Set<String>, prefix: String, into problems: inout [String: String]) {
        var seen: Set<String> = []
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                if !row.value.isEmpty || row.isRedacted { problems["\(prefix).\(key)"] = L("Enter a name for this value.") }
                continue
            }
            if !seen.insert(key).inserted {
                problems["\(prefix).\(key)"] = L("“\(key)” is listed twice.")
            } else if row.isRedacted, self.isRename || !saved.contains(key) {
                problems["\(prefix).\(key)"] = Self.resecret
            }
        }
    }

    private static func patterns(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The whole server object for `mcp.servers.<name>`. It starts from the original so unknown
    /// keys survive, drops the other transport's keys, and leaves unchanged secrets as the
    /// sentinel (which the Gateway restores).
    public func json(original: MCPServer?) -> JSONValue {
        var object = original?.raw.object ?? [:]
        func put(_ key: String, _ value: JSONValue?) { object[key] = value }
        let originalTransport = object["transport"]?.string

        if self.enabled {
            put("enabled", object["enabled"]?.bool == true ? .bool(true) : nil)
        } else {
            put("enabled", .bool(false))
        }

        func number(_ text: String) -> JSONValue? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return Self.isPositiveInteger(trimmed) ? Int(trimmed).map { .number(Double($0)) } : nil
        }
        put("connectionTimeoutMs", number(self.connectionTimeoutMs))
        put("requestTimeoutMs", number(self.requestTimeoutMs))
        let include = Self.patterns(self.toolInclude), exclude = Self.patterns(self.toolExclude)
        var filter = original?.raw["toolFilter"]?.object ?? [:]
        filter["include"] = include.isEmpty ? nil : .array(include.map(JSONValue.string))
        filter["exclude"] = exclude.isEmpty ? nil : .array(exclude.map(JSONValue.string))
        filter = filter.filter { !$0.value.isNull }
        put("toolFilter", filter.isEmpty ? nil : .object(filter))

        if self.transport.isRemote {
            for key in ["command", "args", "env", "cwd"] { put(key, nil) }
            put("url", .string(self.urlIsRedacted ? JSONValue.redactedSentinel : self.url.trimmingCharacters(in: .whitespacesAndNewlines)))
            // An SSE URL without a transport is already SSE; don't add a key for it.
            if self.transport == .sse, originalTransport == nil {
                put("transport", nil)
            } else {
                put("transport", .string(self.transport.rawValue))
            }
            put("headers", MCPKeyValue.object(self.headers))
            // Off is written; on removes the key unless the original said `true` explicitly.
            put("sslVerify", self.sslVerify ? (original?.sslVerify == true ? .bool(true) : nil) : .bool(false))
            func path(_ text: String) -> JSONValue? {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .string(trimmed)
            }
            put("clientCert", path(self.clientCert))
            put("clientKey", path(self.clientKey))
            if self.usesOAuth {
                put("auth", .string("oauth"))
                var oauth = original?.raw["oauth"]?.object ?? [:]
                oauth["identity"] = self.oauthIdentity.isEmpty ? nil : .string(self.oauthIdentity)
                oauth["scope"] = path(self.oauthScope)
                oauth["authProfileId"] = path(self.oauthAuthProfileId)
                oauth = oauth.filter { !$0.value.isNull }
                put("oauth", oauth.isEmpty ? nil : .object(oauth))
            } else {
                put("auth", nil)
                put("oauth", nil)
            }
        } else {
            for key in ["url", "headers", "auth", "oauth", "sslVerify", "clientCert", "clientKey"] { put(key, nil) }
            put("transport", originalTransport == "stdio" ? .string("stdio") : nil)
            put("command", .string(self.command.trimmingCharacters(in: .whitespacesAndNewlines)))
            put("args", self.args.isEmpty ? nil : .array(self.args.map(JSONValue.string)))
            let cwd = self.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            put("cwd", cwd.isEmpty ? nil : .string(cwd))
            put("env", MCPKeyValue.object(self.env))
        }
        return .object(object.filter { !$0.value.isNull })
    }
}

/// Controls when validation problems are shown while editing an MCP server draft.
public enum MCPFieldProblemVisibility {
    /// Problems stay hidden until their matching field is touched or the user submits the draft.
    public static func visible(_ problems: [String: String], touched: Set<String>, showAll: Bool) -> [String: String] {
        guard !showAll else { return problems }
        return problems.filter { touched.contains($0.key) }
    }
}

// MARK: Status

public enum MCPServerState: String, Sendable {
    case disabled, invalid, idle, connecting, connected, error, backoff
    /// The Gateway doesn't report this server's state.
    case unknown
    /// In the draft only; not saved yet.
    case unsaved
}

public enum MCPAuthState: String, Sendable {
    case authorized
    case requiresAuthorization = "requires-authorization"
    case pendingAuthorization = "pending-authorization"
    case unauthenticated
}

public struct MCPAuthStatus: Hashable, Sendable {
    public let mode: String
    public let state: MCPAuthState
    public let expiresAt: Date?
    public let account: String?

    public init(mode: String, state: MCPAuthState, expiresAt: Date? = nil, account: String? = nil) {
        self.mode = mode
        self.state = state
        self.expiresAt = expiresAt
        self.account = account
    }

    init?(json: JSONValue) {
        guard let state = json["state"]?.text.flatMap(MCPAuthState.init(rawValue:)) else { return nil }
        self.init(mode: json["mode"]?.text ?? "oauth-shared", state: state,
                  expiresAt: json["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
                  account: json["account"]?.text)
    }

    /// The sign-in ran out: not authorized, and its expiry has passed.
    public var isExpired: Bool {
        guard self.state != .authorized, let expiresAt = self.expiresAt else { return false }
        return expiresAt < Date()
    }
}

/// What the Gateway (or, failing that, an agent's tools) says about one server right now.
public struct MCPServerStatus: Hashable, Sendable {
    public let name: String
    public let state: MCPServerState
    public let toolCount: Int?
    public let tools: [String]
    public let lastError: String?
    public let lastErrorAt: Date?
    public let nextRetryAt: Date?
    public let auth: MCPAuthStatus?

    public init(name: String, state: MCPServerState, toolCount: Int? = nil, tools: [String] = [], lastError: String? = nil,
                lastErrorAt: Date? = nil, nextRetryAt: Date? = nil, auth: MCPAuthStatus? = nil)
    {
        self.name = name
        self.state = state
        self.toolCount = toolCount
        self.tools = tools
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.nextRetryAt = nextRetryAt
        self.auth = auth
    }

    /// One `mcp.status` server entry.
    public init(json: JSONValue) {
        let tools = json["tools"]?.array?.compactMap(\.text) ?? []
        let error = json["lastError"]
        self.init(
            name: json["name"]?.text ?? "",
            state: json["state"]?.text.flatMap(MCPServerState.init(rawValue:)) ?? .unknown,
            toolCount: json["toolCount"]?.int ?? (json["tools"] == nil ? nil : tools.count),
            tools: tools,
            lastError: error?.text ?? error?["message"]?.text,
            lastErrorAt: error?["at"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
            nextRetryAt: json["nextRetryAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
            auth: json["auth"].flatMap(MCPAuthStatus.init(json:)))
    }

    func with(auth: MCPAuthStatus?) -> MCPServerStatus {
        MCPServerStatus(name: self.name, state: self.state, toolCount: self.toolCount, tools: self.tools, lastError: self.lastError,
                        lastErrorAt: self.lastErrorAt, nextRetryAt: self.nextRetryAt, auth: auth)
    }

    public var needsSignIn: Bool {
        self.auth?.state == .requiresAuthorization || self.auth?.state == .unauthenticated
    }
}

/// A sign-in started with `mcp.oauth.start`.
public struct MCPOAuthAttempt: Hashable, Sendable, Identifiable {
    /// The attempt id.
    public let id: String
    public let server: String
    public let authorizationURL: URL
    public let expiresAt: Date?

    public init(id: String, server: String, authorizationURL: URL, expiresAt: Date? = nil) {
        self.id = id
        self.server = server
        self.authorizationURL = authorizationURL
        self.expiresAt = expiresAt
    }

    /// The demo's consent link isn't a web page; the app shows its own consent sheet.
    public var isSimulated: Bool {
        !["http", "https"].contains(self.authorizationURL.scheme?.lowercased() ?? "")
    }
}

// MARK: Probe

/// The answer to `mcp.probe`: a one-off connection test of a server, saved or still a draft.
public struct MCPProbeResult: Hashable, Sendable {
    public let ok: Bool
    public let tools: [String]
    public let resources: Int?
    public let prompts: Int?
    public let diagnostics: [String]
    public let auth: MCPAuthStatus?

    public init(ok: Bool, tools: [String] = [], resources: Int? = nil, prompts: Int? = nil, diagnostics: [String] = [],
                auth: MCPAuthStatus? = nil)
    {
        self.ok = ok
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.diagnostics = diagnostics
        self.auth = auth
    }

    /// A failed probe made from a message (request errors, missing support).
    public static func failure(_ message: String) -> MCPProbeResult { MCPProbeResult(ok: false, diagnostics: [message]) }

    init(json: JSONValue) {
        // `tools`, `resources` and `prompts` may be lists (of names or objects) or counts.
        func names(_ value: JSONValue?) -> [String] {
            (value?.array ?? []).compactMap { $0.text ?? $0["name"]?.text }
        }
        func count(_ value: JSONValue?) -> Int? { value?.int ?? value?.array?.count }
        self.init(
            ok: json["ok"]?.bool ?? false,
            tools: names(json["tools"]),
            resources: count(json["resources"]),
            prompts: count(json["prompts"]),
            diagnostics: (json["diagnostics"]?.array ?? []).compactMap { $0.text ?? $0["message"]?.text },
            auth: json["auth"].flatMap(MCPAuthStatus.init(json:)))
    }

    public var toolCount: Int { self.tools.count }
}

// MARK: Plugin-declared servers

/// An MCP server a plugin declares (`plugins.inspect` → `declared.mcpServers`, names only), read-only.
public struct PluginMCPServer: Identifiable, Hashable, Sendable {
    public var id: String { "\(self.pluginId)/\(self.name)" }
    public let name: String
    public let pluginId: String
    public let pluginName: String?
    /// False when the Gateway lists the server under `components.unavailable.mcpServers`.
    public let isAvailable: Bool
    /// Sign-in state from `mcpAuth`, present only when the Gateway has a matching OAuth server in `mcp.servers`.
    public let auth: MCPAuthStatus?

    public init(name: String, pluginId: String, pluginName: String? = nil, isAvailable: Bool = true, auth: MCPAuthStatus? = nil) {
        self.name = name
        self.pluginId = pluginId
        self.pluginName = pluginName
        self.isAvailable = isAvailable
        self.auth = auth
    }

    /// Servers declared in a `plugins.inspect` result.
    static func servers(inspect result: JSONValue) -> [PluginMCPServer] {
        guard let pluginId = result["plugin"]?["id"]?.text else { return [] }
        let pluginName = result["plugin"]?["name"]?.text
        let unavailable = Set(result["components"]?["unavailable"]?["mcpServers"]?.array?.compactMap(\.text) ?? [])
        var auth: [String: MCPAuthStatus] = [:]
        for entry in result["mcpAuth"]?.array ?? [] {
            guard let name = entry["serverName"]?.text, let state = entry["state"]?.text.flatMap(MCPAuthState.init(rawValue:)) else { continue }
            auth[name] = MCPAuthStatus(mode: "oauth-shared", state: state)
        }
        var seen: Set<String> = []
        return (result["declared"]?["mcpServers"]?.array ?? []).compactMap(\.text).filter { seen.insert($0).inserted }.map {
            PluginMCPServer(name: $0, pluginId: pluginId, pluginName: pluginName, isAvailable: !unavailable.contains($0), auth: auth[$0])
        }
    }
}
