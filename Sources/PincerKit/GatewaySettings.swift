import Foundation
import Observation

/// One plugin from `plugins.list`.
public struct PluginInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let version: String?
    public let origin: String?
    public let packageName: String?
    public let installed: Bool
    public let enabled: Bool
    /// `enabled`, `disabled`, `needs-setup`, `not-installed` or `error`.
    public let state: String
    /// Observed runtime state: `active`, `disabled`, `unloaded` or `service-failed`.
    public let runtimeState: String?
    public let error: String?
    public let removable: Bool
    public let kinds: [String]

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.name = json["name"]?.text ?? id
        self.description = json["description"]?.text
        self.version = json["version"]?.text
        self.origin = json["origin"]?.text
        self.packageName = json["packageName"]?.text
        self.installed = json["installed"]?.bool ?? true
        self.enabled = json["enabled"]?.bool ?? false
        self.state = json["state"]?.text ?? (self.enabled ? "enabled" : "disabled")
        self.runtimeState = json["runtime"]?["state"]?.text
        self.error = json["error"]?.text ?? json["runtime"]?["error"]?.text
        self.removable = json["removable"]?.bool ?? (self.origin != "bundled")
        self.kinds = json["kind"]?.array?.compactMap(\.text) ?? []
    }

    public var needsSetup: Bool { self.state == "needs-setup" }
    public var hasError: Bool { self.state == "error" || self.runtimeState == "service-failed" || self.error != nil }

    public var statusLabel: String {
        if self.hasError { return "Error" }
        switch self.state {
        case "needs-setup": return "Needs setup"
        case "not-installed": return "Not installed"
        case "enabled": return self.runtimeState == "active" || self.runtimeState == nil ? "On" : "Starting…"
        default: return "Off"
        }
    }

    /// Where this plugin's own settings live in the config.
    public var configPath: [String] { ["plugins", "entries", self.id, "config"] }
}

/// A credential a plugin says it needs (from `plugins.inspect`).
public struct PluginCredential: Identifiable, Hashable, Sendable {
    public let path: [String]
    public let label: String
    public let envVars: [String]
    public let placeholder: String?
    public let signupURL: URL?
    public let isRequired: Bool
    public var id: String { ConfigPath.string(self.path) }

    public init?(_ json: JSONValue) {
        let parts = json["path"]?.array ?? []
        // Paths through arrays can't be written with a merge patch; leave those to the raw editor.
        let path = parts.compactMap(\.string)
        guard !path.isEmpty, path.count == parts.count, let label = json["label"]?.text else { return nil }
        self.path = path
        self.label = label
        self.envVars = json["envVars"]?.array?.compactMap(\.text) ?? []
        self.placeholder = json["placeholder"]?.text
        self.signupURL = json["signupUrl"]?.text.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        self.isRequired = json["requiresCredential"]?.bool ?? false
    }
}

/// Where to install a plugin from.
public enum PluginSource: String, CaseIterable, Identifiable, Sendable {
    case clawhub
    case npm
    case official
    case git

    public var id: String { self.rawValue }
    public var label: String {
        switch self {
        case .clawhub: "ClawHub"
        case .npm: "npm"
        case .official: "Official"
        case .git: "Git"
        }
    }

    public var prompt: String {
        switch self {
        case .clawhub: "Package name, e.g. @openclaw/weather"
        case .npm: "npm spec, e.g. openclaw-plugin-foo@1.2.0"
        case .official: "Plugin ID, e.g. memory-lancedb"
        case .git: "Git URL, e.g. github:owner/repo"
        }
    }

    func params(_ spec: String) -> [String: JSONValue] {
        let spec = JSONValue.string(spec)
        switch self {
        case .clawhub: return ["source": "clawhub", "packageName": spec]
        case .npm: return ["source": "npm", "spec": spec]
        case .official: return ["source": "official", "pluginId": spec]
        case .git: return ["source": "git", "spec": spec]
        }
    }
}

/// How a saved change took effect.
public enum ConfigApplyOutcome: Equatable, Sendable {
    case noChange
    case applied
    case restarting

    public var message: String {
        switch self {
        case .noChange: "Nothing changed."
        case .applied: "Saved and applied. No restart needed."
        case .restarting: "Saved. The Gateway is restarting to apply it."
        }
    }

    public init(configWrite response: JSONValue) {
        if response["noop"]?.bool == true {
            self = .noChange
        } else if let restart = response["restart"], !restart.isNull, restart.bool != false {
            self = .restarting
        } else if response["sentinel"]?["payload"]?["stats"]?["requiresRestart"]?.bool == true {
            self = .restarting
        } else {
            self = .applied
        }
    }

    public init(pluginChange response: JSONValue) {
        self = response["restartRequired"]?.bool == true ? .restarting : .applied
    }
}

/// A plugin change the Gateway wants confirmed before it goes ahead.
public struct PluginConfirmation: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// The plugin asks for new capabilities; retried with `acknowledgeCapabilities`.
        case capabilities(reviewToken: String)
        /// The install policy flagged the package; retried with `acknowledgeInstallPolicyWarning`.
        case installPolicy
    }

    public let id = UUID()
    public let kind: Kind
    public let message: String
    let retry: @MainActor @Sendable (_ acknowledgement: [String: JSONValue]) async -> Void

    public var acknowledgement: [String: JSONValue] {
        switch self.kind {
        case let .capabilities(token): ["acknowledgeCapabilities": ["reviewToken": .string(token)]]
        case .installPolicy: ["acknowledgeInstallPolicyWarning": true]
        }
    }
}

/// Gateway configuration and plugins, read and written over the Gateway protocol
/// (`config.get` / `config.schema` / `config.patch` / `config.apply` and `plugins.*`).
/// Nothing is written to files directly: the Gateway validates, persists and hot-applies
/// (or restarts) itself.
@MainActor
@Observable
public final class GatewaySettingsStore {
    public private(set) var config: JSONValue = .object([:])
    public private(set) var raw: String?
    public private(set) var path: String?
    public private(set) var hash: String?
    public private(set) var isValid = true
    public private(set) var issues: [ConfigIssue] = []
    public private(set) var warnings: [ConfigIssue] = []
    public private(set) var schema: ConfigSchema?
    public private(set) var plugins: [PluginInfo] = []
    public private(set) var pluginsSupported = true
    public private(set) var credentials: [String: [PluginCredential]] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    /// Problems from the last failed write, matched to fields by path.
    public private(set) var writeIssues: [ConfigIssue] = []
    public private(set) var lastError: String?
    public private(set) var lastOutcome: ConfigApplyOutcome?
    public var pendingConfirmation: PluginConfirmation?

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let scopes: () -> [String]

    init(connection: GatewayConnection, scopes: @escaping () -> [String]) {
        self.connection = connection
        self.scopes = scopes
    }

    /// The Gateway granted `operator.admin`, which every config and plugin write needs.
    public var canEdit: Bool { self.scopes().contains(GatewayConnection.adminScope) }

    public var pluginsNeedingAttention: Int { self.plugins.filter { $0.needsSetup || $0.hasError }.count }

    // MARK: Loading

    public func load() async {
        self.isLoading = true
        defer { self.isLoading = false }
        async let config = self.loadConfig()
        async let schema = self.loadSchema()
        async let plugins = self.loadPlugins()
        _ = await (config, schema, plugins)
        self.hasLoaded = true
    }

    @discardableResult
    func loadConfig() async -> Bool {
        do {
            let result = try await self.connection.request("config.get", [:], timeout: 20)
            self.applySnapshot(result)
            return true
        } catch {
            self.lastError = error.localizedDescription
            return false
        }
    }

    func applySnapshot(_ result: JSONValue) {
        // `resolved` is the authored config after includes and env substitution; `config` also
        // carries runtime defaults, which would be written back as if the user set them.
        self.config = result["resolved"] ?? result["sourceConfig"] ?? result["parsed"] ?? result["config"] ?? .object([:])
        self.raw = result["raw"]?.string
        self.path = result["path"]?.text
        self.hash = result["hash"]?.text
        self.isValid = result["valid"]?.bool ?? true
        self.issues = ConfigIssue.list(result["issues"])
        self.warnings = ConfigIssue.list(result["warnings"])
    }

    private func loadSchema() async {
        guard let result = try? await self.connection.request("config.schema", [:], timeout: 30) else { return }
        self.schema = ConfigSchema(response: result)
    }

    func loadPlugins() async {
        do {
            let result = try await self.connection.request("plugins.list", [:], timeout: 20)
            self.plugins = (result["plugins"]?.array ?? []).compactMap(PluginInfo.init)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.pluginsSupported = true
        } catch let GatewayError.rpc(code, _, _) where code == "UNKNOWN_METHOD" || code == "METHOD_NOT_FOUND" {
            self.pluginsSupported = false
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    public func loadCredentials(for plugin: PluginInfo) async {
        guard let result = try? await self.connection.request("plugins.inspect", ["pluginId": .string(plugin.id)]) else {
            return
        }
        self.credentials[plugin.id] = (result["credentials"]?.array ?? []).compactMap(PluginCredential.init)
    }

    public func plugin(_ id: String) -> PluginInfo? { self.plugins.first { $0.id == id } }

    public func value(at path: [String]) -> JSONValue? { self.config.value(at: path) }

    public func issues(under path: [String]) -> [ConfigIssue] {
        let prefix = ConfigPath.string(path)
        return (self.writeIssues + self.issues).filter {
            prefix.isEmpty || $0.path == prefix || $0.path.hasPrefix(prefix + ".")
        }
    }

    public func clearFeedback() {
        self.lastError = nil
        self.lastOutcome = nil
        self.writeIssues = []
    }

    // MARK: Config writes

    /// Sends a merge patch with `config.patch`. Returns true when the Gateway accepted it.
    @discardableResult
    public func save(_ patch: JSONValue, note: String? = nil) async -> Bool {
        guard !patch.isEmptyObject else {
            self.lastOutcome = .noChange
            return true
        }
        var params: [String: JSONValue] = ["raw": .string(patch.compactString())]
        let arrays = Self.arrayPaths(in: patch)
        if !arrays.isEmpty { params["replacePaths"] = JSONValue(arrays) }
        if let note { params["note"] = .string(note) }
        return await self.write("config.patch", params)
    }

    /// Replaces the whole config with `config.apply`. Redacted secrets left as-is are kept.
    @discardableResult
    public func saveRaw(_ text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.writeIssues = [ConfigIssue(path: "", message: "The config can't be empty.")]
            return false
        }
        return await self.write("config.apply", ["raw": .string(text)])
    }

    private func write(_ method: String, _ params: [String: JSONValue]) async -> Bool {
        self.clearFeedback()
        guard self.canEdit else {
            self.lastError = Self.adminRequired
            return false
        }
        self.isSaving = true
        defer { self.isSaving = false }
        if self.hash == nil { await self.loadConfig() }
        var params = params
        if let hash = self.hash { params["baseHash"] = .string(hash) }
        do {
            let result = try await self.connection.request(method, .object(params), timeout: 30)
            self.lastOutcome = ConfigApplyOutcome(configWrite: result)
            if let hash = result["hash"]?.text { self.hash = hash }
            await self.loadConfig()
            // Plugin settings decide whether a plugin still needs setup.
            if self.pluginsSupported { await self.loadPlugins() }
            return true
        } catch {
            if Self.isStaleHash(error) {
                await self.loadConfig()
                self.lastError = "The config changed on the Gateway since it was loaded. Review the latest values and save again."
            } else {
                self.writeIssues = ConfigIssue.from(error)
                if self.writeIssues.isEmpty { self.lastError = error.localizedDescription }
            }
            return false
        }
    }

    static let adminRequired = "Changing Gateway settings needs admin access. Turn on “Manage Gateway settings” for this connection and approve the device again."

    static func isStaleHash(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(_, message, _) = error else { return false }
        let text = message.lowercased()
        return text.contains("base hash") || text.contains("config changed since last load")
    }

    /// Arrays in a patch replace the whole list (and are allowed to drop entries).
    static func arrayPaths(in patch: JSONValue, prefix: [String] = []) -> [String] {
        switch patch {
        case let .object(values):
            return values.sorted { $0.key < $1.key }.flatMap { key, value in Self.arrayPaths(in: value, prefix: prefix + [key]) }
        case .array:
            return prefix.isEmpty ? [] : [ConfigPath.string(prefix)]
        default:
            return []
        }
    }

    // MARK: Plugins

    public func setEnabled(_ plugin: PluginInfo, _ enabled: Bool) async {
        await self.pluginChange("plugins.setEnabled", ["pluginId": .string(plugin.id), "enabled": .bool(enabled)])
    }

    public func uninstall(_ plugin: PluginInfo) async {
        await self.pluginChange("plugins.uninstall", ["pluginId": .string(plugin.id)])
    }

    public func install(from source: PluginSource, spec: String, enable: Bool = true) async -> Bool {
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            self.lastError = "Enter what to install."
            return false
        }
        var params = source.params(spec)
        params["enable"] = .bool(enable)
        return await self.pluginChange("plugins.install", params, timeout: 180)
    }

    @discardableResult
    private func pluginChange(_ method: String, _ params: [String: JSONValue], timeout: TimeInterval = 60) async -> Bool {
        self.clearFeedback()
        guard self.canEdit else {
            self.lastError = Self.adminRequired
            return false
        }
        self.isSaving = true
        defer { self.isSaving = false }
        do {
            let result = try await self.connection.request(method, .object(params), timeout: timeout)
            self.lastOutcome = ConfigApplyOutcome(pluginChange: result)
            if let warnings = result["warnings"]?.array?.compactMap(\.text), !warnings.isEmpty {
                self.warnings = warnings.map { ConfigIssue(path: "plugins", message: $0) }
            }
            await self.loadPlugins()
            await self.loadConfig()
            return true
        } catch {
            if let confirmation = self.confirmation(for: error, method: method, params: params, timeout: timeout) {
                self.pendingConfirmation = confirmation
            } else {
                self.lastError = error.localizedDescription
            }
            return false
        }
    }

    private func confirmation(for error: Error, method: String, params: [String: JSONValue],
                              timeout: TimeInterval) -> PluginConfirmation? {
        guard case let GatewayError.rpc(_, message, details) = error, let details else { return nil }
        let kind: PluginConfirmation.Kind
        if details["capabilityConsentCode"]?.string == "PLUGIN_CAPABILITY_CONSENT_REQUIRED",
           let token = details["reviewToken"]?.text
        {
            kind = .capabilities(reviewToken: token)
        } else if details["installPolicyCode"]?.string == "install_policy_warning_acknowledgement_required" {
            kind = .installPolicy
        } else {
            return nil
        }
        return PluginConfirmation(kind: kind, message: message) { [weak self] acknowledgement in
            guard let self else { return }
            await self.pluginChange(method, params.merging(acknowledgement) { _, new in new }, timeout: timeout)
        }
    }

    public func confirm(_ confirmation: PluginConfirmation) async {
        self.pendingConfirmation = nil
        await confirmation.retry(confirmation.acknowledgement)
    }

    func handlePluginsChanged() {
        guard self.hasLoaded else { return }
        Task { await self.loadPlugins() }
    }
}
