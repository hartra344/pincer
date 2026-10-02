import Foundation
import Observation

/// MCP Servers: the server list (edited through the shared settings draft), each server's live
/// state, and the immediate actions (reconnect, OAuth sign-in and out). Created by
/// `GatewayStore.mcp`. Actions need `operator.admin`, except in the demo.
@MainActor
@Observable
public final class MCPServersModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// Where server states come from.
    public enum StatusSource: Equatable, Sendable {
        /// `mcp.status`.
        case live
        /// Derived from `tools.effective` for this session.
        case session(String)
        /// Nothing reports MCP state.
        case none
    }

    public private(set) var loadState = OperationState.idle
    /// Live or derived state by server name, from the last `load()`.
    public private(set) var statuses: [String: MCPServerStatus] = [:]
    /// Servers declared by installed plugins (`plugins.inspect`), from the last `load()`. Read-only.
    public private(set) var pluginServers: [PluginMCPServer] = []
    /// Live state of plugin-declared servers that `mcp.status` reports with `source: "plugin"` and a `pluginId`,
    /// by `PluginMCPServer.id` ("pluginId/name").
    public private(set) var pluginStatuses: [String: MCPServerStatus] = [:]
    /// Actions in flight or failed, by server name.
    public private(set) var operations: [String: OperationState] = [:]

    @ObservationIgnored private let settings: GatewaySettingsModel
    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private let sessionKey: @MainActor () -> String?
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var reloadQueued = false
    /// The load in flight; later callers queue one more fetch and wait for it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var observingSaves = false

    init(settings: GatewaySettingsModel, request: @escaping Request, hello: @escaping @MainActor () -> GatewayHello?,
         sessionKey: @escaping @MainActor () -> String?, allowsWritesWithoutAdmin: Bool)
    {
        self.settings = settings
        self.request = request
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.sessionKey = sessionKey
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    /// For checks and previews.
    public init(settings: GatewaySettingsModel, methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                sessionKey: @escaping @MainActor () -> String? = { nil },
                allowsWritesWithoutAdmin: Bool = false, request: @escaping Request)
    {
        self.settings = settings
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.sessionKey = sessionKey
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    // MARK: Capability

    private func advertises(_ method: String) -> Bool { self.methods()?.contains(method) ?? false }

    public var hasConfig: Bool { self.settings.hasLoaded }
    public var canEdit: Bool { self.allowsWritesWithoutAdmin || self.settings.canEdit }
    public var supportsLiveStatus: Bool { self.advertises(MCPServers.statusMethod) }
    public var supportsReconnect: Bool { self.advertises(MCPServers.reconnectMethod) }
    /// Whether the Gateway can test a connection (`mcp.probe`).
    public var supportsProbe: Bool { self.advertises(MCPServers.probeMethod) }
    /// Whether plugin-declared servers can be read (`plugins.list` + `plugins.inspect`).
    public var supportsPluginServers: Bool { self.advertises("plugins.list") && self.advertises("plugins.inspect") }
    public var supportsOAuth: Bool { self.advertises(MCPServers.oauthStartMethod) }

    public var statusSource: StatusSource {
        if self.supportsLiveStatus { return .live }
        if self.advertises(ToolsPolicy.effectiveMethod), let key = self.sessionKey() { return .session(key) }
        return .none
    }

    private var hasAdmin: Bool { self.allowsWritesWithoutAdmin || self.scopes().contains(GatewayConnection.adminScope) }

    // MARK: Servers

    public var servers: [MCPServer] { MCPServers.servers(in: self.settings.config) }

    public func server(_ name: String) -> MCPServer? {
        self.settings.value(at: MCPServers.path + [name]).flatMap { MCPServer(name: name, json: $0) }
    }

    public func savedServer(_ name: String) -> MCPServer? {
        self.settings.savedValue(at: MCPServers.path + [name]).flatMap { MCPServer(name: name, json: $0) }
    }

    public func isChanged(_ name: String) -> Bool { self.settings.isChanged(MCPServers.path + [name]) }

    /// Saved, but removed in the draft.
    public func isRemoved(_ name: String) -> Bool {
        self.settings.savedValue(at: MCPServers.path + [name]) != nil && self.settings.value(at: MCPServers.path + [name]) == nil
    }

    /// Brings back a server removed in the draft.
    public func undoRemove(_ name: String) {
        self.settings.revert(MCPServers.path + [name])
    }

    public func isNew(_ name: String) -> Bool {
        self.settings.savedValue(at: MCPServers.path + [name]) == nil && self.settings.value(at: MCPServers.path + [name]) != nil
    }

    /// The server's state: config decides unsaved, disabled and invalid; otherwise what the
    /// Gateway last reported.
    public func status(for name: String) -> MCPServerStatus {
        guard let server = self.server(name) else { return MCPServerStatus(name: name, state: .unknown) }
        if self.isNew(name) { return MCPServerStatus(name: name, state: .unsaved) }
        if !server.enabled { return MCPServerStatus(name: name, state: .disabled) }
        if server.transport == nil { return MCPServerStatus(name: name, state: .invalid) }
        return self.statuses[name] ?? MCPServerStatus(name: name, state: .unknown)
    }

    // MARK: Draft edits

    /// Writes `enabled: false`, or removes the key when enabling.
    public func setEnabled(_ name: String, _ enabled: Bool) {
        self.settings.set(MCPServers.path + [name, "enabled"], enabled ? nil : .bool(false))
    }

    /// Puts the draft's server into the shared draft; a rename also removes the old name.
    public func apply(_ draft: MCPServerDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let original = draft.originalName.flatMap { self.server($0) }
        self.settings.set(MCPServers.path + [name], draft.json(original: original))
        if let old = draft.originalName, old != name {
            self.settings.set(MCPServers.path + [old], nil)
        }
    }

    /// Removes the server (or drops it, when it's only in the draft).
    public func remove(_ name: String) {
        self.settings.set(MCPServers.path + [name], nil)
    }

    // MARK: Loading

    /// The live state of a plugin-declared server, when `mcp.status` reports it.
    public func status(for pluginServer: PluginMCPServer) -> MCPServerStatus? {
        self.pluginStatuses[pluginServer.id]
    }

    public func load() async {
        self.observeSaves()
        if let running = self.loadTask {
            // Callers (e.g. after sign-in) need a fetch that started after their change, not the one in flight.
            self.reloadQueued = true
            await running.value
            return
        }
        self.loadState = .running
        let task = Task { @MainActor in
            repeat {
                self.reloadQueued = false
                async let plugins: Void = self.fetchPluginServers()
                await self.fetchStatuses()
                await plugins
            } while self.reloadQueued
            // Cleared with no suspension after the last check, so no caller can wait on a finished load.
            self.loadTask = nil
        }
        self.loadTask = task
        await task.value
        self.hasLoaded = true
        if self.loadState.isRunning { self.loadState = .idle }
    }

    private func fetchStatuses() async {
        switch self.statusSource {
        case .live:
            do {
                let result = try await self.request(MCPServers.statusMethod, .object([:]))
                var fresh = Dictionary(
                    (result["servers"]?.array ?? []).map(MCPServerStatus.init(json:)).filter { !$0.name.isEmpty }.map { ($0.name, $0) },
                    uniquingKeysWith: { _, new in new })
                if self.supportsOAuthStatus, let auth = try? await self.request(MCPServers.oauthStatusMethod, .object([:])) {
                    for entry in auth["servers"]?.array ?? [] {
                        guard let name = entry["name"]?.text, let status = fresh[name], let merged = MCPAuthStatus(json: entry) else { continue }
                        fresh[name] = status.with(auth: merged)
                    }
                }
                self.pluginStatuses = Dictionary(
                    (result["servers"]?.array ?? []).compactMap { entry in
                        guard entry["source"]?.text == "plugin", let pluginId = entry["pluginId"]?.text, !pluginId.isEmpty else { return nil }
                        let status = MCPServerStatus(json: entry)
                        return status.name.isEmpty ? nil : ("\(pluginId)/\(status.name)", status)
                    },
                    uniquingKeysWith: { _, new in new })
                self.statuses = fresh
            } catch {
                self.loadState = .failed(GatewayError.message(for: error))
            }
        case let .session(key):
            var params: [String: JSONValue] = ["sessionKey": .string(key)]
            if let agentId = SessionKey.agentId(from: key) { params["agentId"] = .string(agentId) }
            do {
                let result = try await self.request(ToolsPolicy.effectiveMethod, .object(params))
                self.statuses = Self.statuses(from: EffectiveTools(result))
            } catch {
                self.loadState = .failed(GatewayError.message(for: error))
            }
        case .none:
            self.statuses = [:]
        }
        if self.statusSource != .live { self.pluginStatuses = [:] }
    }

    private func fetchPluginServers() async {
        guard self.supportsPluginServers else {
            self.pluginServers = []
            return
        }
        guard let list = try? await self.request("plugins.list", .object([:])) else { return }
        let ids = (list["plugins"]?.array ?? []).compactMap(PluginInfo.init).filter { $0.installed && $0.enabled }.map(\.id)
        var found: [PluginMCPServer] = []
        // At most four inspects in flight.
        for batch in stride(from: 0, to: ids.count, by: 4) {
            let tasks = ids[batch..<min(batch + 4, ids.count)].map { id in
                Task { @MainActor in
                    (try? await self.request("plugins.inspect", ["pluginId": .string(id)])).map(PluginMCPServer.servers(inspect:)) ?? []
                }
            }
            for task in tasks { found += await task.value }
        }
        self.pluginServers = found.sorted {
            ($0.pluginId, $0.name.lowercased()) < ($1.pluginId, $1.name.lowercased())
        }
    }

    private var supportsOAuthStatus: Bool { self.advertises(MCPServers.oauthStatusMethod) }

    /// Server states inferred from an agent's effective tools: servers with tools are connected,
    /// diagnostics are errors, and servers still connecting are named by the `mcp-not-yet-*` notices.
    nonisolated static func statuses(from tools: EffectiveTools) -> [String: MCPServerStatus] {
        var names: [String: [String]] = [:]
        for tool in tools.groups.flatMap(\.tools) where tool.source == .mcp {
            guard let server = tool.mcpServer else { continue }
            names[server, default: []].append(tool.mcpToolName ?? tool.label)
        }
        var result: [String: MCPServerStatus] = [:]
        for (server, list) in names {
            result[server] = MCPServerStatus(name: server, state: .connected, toolCount: list.count, tools: list.sorted())
        }
        for notice in tools.notices {
            let prefix = "mcp-server-diagnostic:"
            if notice.id.hasPrefix(prefix) {
                let server = String(notice.id.dropFirst(prefix.count))
                let existing = result[server]
                result[server] = MCPServerStatus(name: server, state: .error, toolCount: existing?.toolCount, tools: existing?.tools ?? [],
                                                 lastError: notice.message.isEmpty ? nil : notice.message)
            } else if notice.id.hasPrefix("mcp-not-yet-") {
                for server in notice.servers where result[server] == nil {
                    result[server] = MCPServerStatus(name: server, state: .connecting)
                }
            }
        }
        return result
    }

    // MARK: Refresh triggers

    func handle(_ event: GatewayEvent) {
        guard event.name == MCPServers.oauthChangedEvent || event.name == MCPServers.statusChangedEvent else { return }
        guard self.hasLoaded || self.loadState.isRunning else { return }
        Task { await self.load() }
    }

    /// The link `pincer://mcp-oauth/done` came back from the browser.
    func handleOAuthReturn() {
        Task { await self.load() }
    }

    /// Reloads state after each settings save: the Gateway hot-applies `mcp.*`, and without
    /// `mcp.status` events a second look catches servers that were still connecting.
    private func observeSaves() {
        guard !self.observingSaves else { return }
        self.observingSaves = true
        self.trackSaves()
    }

    private func trackSaves() {
        withObservationTracking {
            _ = self.settings.lastSave?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackSaves()
                await self.load()
                if self.statusSource != .live {
                    try? await Task.sleep(for: .seconds(2))
                    await self.load()
                }
            }
        }
    }

    // MARK: Actions

    public func operation(for name: String) -> OperationState { self.operations[name] ?? .idle }

    public func clearOperation(_ name: String) { self.operations[name] = nil }

    public func reconnect(_ name: String) async {
        guard self.canRun(name, method: MCPServers.reconnectMethod) else { return }
        self.operations[name] = .running
        do {
            _ = try await self.request(MCPServers.reconnectMethod, ["serverNames": [.string(name)]])
            self.operations[name] = nil
        } catch {
            self.operations[name] = .failed(self.message(for: error, unavailable: L("reconnecting MCP servers")))
        }
        await self.load()
    }

    /// Starts a sign-in; open the returned link to let the user approve it.
    public func startSignIn(_ name: String) async -> MCPOAuthAttempt? {
        guard self.canRun(name, method: MCPServers.oauthStartMethod) else { return nil }
        self.operations[name] = .running
        do {
            let result = try await self.request(MCPServers.oauthStartMethod, [
                "serverName": .string(name), "redirect": "gateway", "returnUrl": .string(MCPServers.returnURL(server: name).absoluteString),
            ])
            guard let id = result["attemptId"]?.text, let link = result["authorizationUrl"]?.text.flatMap({ URL(string: $0) }) else {
                self.operations[name] = .failed(L("The Gateway didn't send a sign-in link."))
                return nil
            }
            self.operations[name] = nil
            return MCPOAuthAttempt(id: id, server: name, authorizationURL: link,
                                   expiresAt: result["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) })
        } catch {
            self.operations[name] = .failed(self.message(for: error, unavailable: L("MCP sign-in")))
            return nil
        }
    }

    /// Finishes a sign-in by hand with the provider's code or callback link.
    public func completeSignIn(_ attempt: MCPOAuthAttempt, code: String?, callbackURL: URL?) async -> Bool {
        guard self.canRun(attempt.server, method: MCPServers.oauthCompleteMethod) else { return false }
        self.operations[attempt.server] = .running
        var params: [String: JSONValue] = ["attemptId": .string(attempt.id)]
        var callbackURL = callbackURL
        // Pasted text may be the whole redirect link rather than the bare code.
        if callbackURL == nil, let pasted = code?.trimmingCharacters(in: .whitespacesAndNewlines),
           let components = URLComponents(string: pasted), components.scheme != nil, components.host != nil,
           components.queryItems?.contains(where: { $0.name == "code" }) == true
        {
            callbackURL = components.url
        }
        if let callbackURL {
            params["callbackUrl"] = .string(callbackURL.absoluteString)
        } else if let code {
            params["code"] = .string(code.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var succeeded = false
        do {
            let result = try await self.request(MCPServers.oauthCompleteMethod, .object(params))
            succeeded = result["state"]?.string.map { $0 == MCPAuthState.authorized.rawValue } ?? true
            self.operations[attempt.server] = succeeded ? nil : .failed(L("The Gateway didn't accept the sign-in."))
        } catch {
            self.operations[attempt.server] = .failed(self.message(for: error, unavailable: L("MCP sign-in")))
        }
        await self.load()
        return succeeded
    }

    public func cancelSignIn(_ attempt: MCPOAuthAttempt) async {
        guard self.hasAdmin, self.supportsOAuth else { return }
        _ = try? await self.request(MCPServers.oauthCancelMethod, ["attemptId": .string(attempt.id)])
        self.operations[attempt.server] = nil
        await self.load()
    }

    public func signOut(_ name: String) async {
        guard self.canRun(name, method: MCPServers.oauthLogoutMethod) else { return }
        self.operations[name] = .running
        do {
            _ = try await self.request(MCPServers.oauthLogoutMethod, ["serverName": .string(name)])
            self.operations[name] = nil
        } catch {
            self.operations[name] = .failed(self.message(for: error, unavailable: L("MCP sign-in")))
        }
        await self.load()
    }

    // MARK: Test connection

    /// Default `timeoutMs` for a probe.
    public static let defaultProbeTimeoutMs = 15_000

    /// Tests a connection with `mcp.probe`. With `draft`, probes that unsaved definition (redacted values stay as
    /// the sentinel; the Gateway restores them from the saved entry); a draft identical to the saved server sends
    /// only `serverName`. `timeoutMs` defaults to the draft's `connectionTimeoutMs`, else 15 s. Never throws:
    /// failures come back as `MCPProbeResult.failure`.
    public func probe(name: String, draft: MCPServerDraft? = nil, timeoutMs: Int? = nil) async -> MCPProbeResult {
        guard self.supportsProbe else { return .failure(L("This Gateway doesn't support that yet.")) }
        guard self.hasAdmin else { return .failure(ConfigWriteError.adminRequired.message) }
        var params: [String: JSONValue] = ["serverName": .string(name)]
        var timeout = timeoutMs
        if let draft {
            let saved = draft.originalName.flatMap { self.savedServer($0) }
            // A disabled saved server can still be tested, so `enabled` isn't part of the comparison or the payload.
            let json = Self.withoutEnabled(draft.json(original: saved))
            if saved == nil || json != saved.map({ Self.withoutEnabled($0.raw) }) || draft.originalName != name { params["server"] = json }
            if timeout == nil, let custom = json["connectionTimeoutMs"]?.int { timeout = custom }
        }
        params["timeoutMs"] = .number(Double(timeout ?? Self.defaultProbeTimeoutMs))
        do {
            return MCPProbeResult(json: try await self.request(MCPServers.probeMethod, .object(params)))
        } catch {
            return .failure(GatewayError.message(for: error, scope: ConfigWriteError.adminRequired.message, unavailable: L("testing MCP connections")))
        }
    }

    private static func withoutEnabled(_ json: JSONValue) -> JSONValue {
        guard case var .object(object) = json else { return json }
        object["enabled"] = nil
        return .object(object)
    }

    private func canRun(_ name: String, method: String) -> Bool {
        if !self.hasAdmin {
            self.operations[name] = .failed(ConfigWriteError.adminRequired.message)
            return false
        }
        if self.isNew(name) || self.isChanged(name) || self.isRemoved(name) {
            self.operations[name] = .failed(L("Save your changes first."))
            return false
        }
        if !self.advertises(method) {
            self.operations[name] = .failed(L("This Gateway doesn't support that yet."))
            return false
        }
        return true
    }

    private func message(for error: Error, unavailable: String) -> String {
        if !GatewayError.isMissingScope(error), case let .rpc(_, text, _)? = error as? GatewayError {
            let lower = text.lowercased()
            if lower.contains("denied") { return L("Sign-in was denied.") }
            if lower.contains("expired") || lower.contains("timed out") || lower.contains("timeout") || lower.contains("unknown attempt") {
                return L("Sign-in timed out. Try again.")
            }
        }
        return GatewayError.message(for: error, scope: ConfigWriteError.adminRequired.message, unavailable: unavailable)
    }
}
