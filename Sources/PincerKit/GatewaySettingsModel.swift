import Foundation
import Observation

/// Gateway Settings for one Gateway: the loaded config and schema, one draft of unsaved edits
/// shared by every settings page, and the plugins. Config edits are saved together as one
/// `config.patch`; plugin lifecycle actions (enable, install, remove) run immediately.
@MainActor
@Observable
public final class GatewaySettingsModel {
    public private(set) var snapshot: ConfigSnapshot?
    public private(set) var schema: ConfigSchema?
    public private(set) var plugins: [PluginInfo] = []
    public private(set) var pluginsSupported = true
    /// False when the Gateway doesn't serve `config.get` to this client at all.
    public private(set) var configSupported = true
    public private(set) var credentials: [String: [PluginCredential]] = [:]
    public private(set) var loadState = OperationState.idle

    /// Unsaved edits to the whole config.
    public private(set) var edits = ConfigEdits()
    /// Edits whose value also changed on the Gateway; Save waits until each is resolved.
    public private(set) var conflicts: [ConfigEdits.Conflict] = []
    /// Problems from the last rejected write, matched to fields by path.
    public private(set) var writeIssues: [ConfigIssue] = []
    public private(set) var saveState = OperationState.idle
    /// The last successful save, for a brief confirmation.
    public private(set) var lastSave: (outcome: ConfigApplyOutcome, id: UUID)?

    /// Plugin actions in flight or failed, by plugin id (`Self.installKey` for installs).
    public private(set) var pluginOperations: [String: OperationState] = [:]
    public var pendingConfirmation: PluginConfirmation?
    /// Where an open settings window should go next (e.g. "Edit Connection…" from the sidebar).
    public var requestedDestination: SettingsDestination?
    /// Pages to push on top of `requestedDestination` (e.g. a session's usage from its chat).
    public var requestedRoutes: [SettingsRoute] = []

    public static let installKey = "__install__"

    /// Told when a change is saved but only takes effect after a Gateway restart.
    @ObservationIgnored var onRestartRequired: (@MainActor (String) -> Void)?

    @ObservationIgnored private let client: GatewayConfigClient
    @ObservationIgnored private let scopes: () -> [String]
    @ObservationIgnored private var searchCache: (key: String, fields: [ConfigField])?
    @ObservationIgnored private var schemaGeneration = 0

    init(connection: GatewayConnection, scopes: @escaping () -> [String]) {
        self.client = GatewayConfigClient(connection: connection)
        self.scopes = scopes
    }

    /// The Gateway granted `operator.admin`, which every config and plugin write needs.
    public var canEdit: Bool { self.scopes().contains(GatewayConnection.adminScope) }
    public var hasLoaded: Bool { self.snapshot != nil }
    public var isSaving: Bool { self.saveState.isRunning }
    public var config: JSONValue { self.edits.current }
    public var pluginsNeedingAttention: Int { self.plugins.count(where: { $0.needsSetup || $0.hasError }) }

    // MARK: Loading

    public func load() async {
        guard !self.loadState.isRunning else { return }
        self.loadState = .running
        async let config: Void = self.reloadConfig()
        async let schema = self.client.schema()
        async let plugins: Void = self.reloadPlugins()
        let loadedSchema = await schema
        _ = await (config, plugins)
        if let loadedSchema {
            self.schema = loadedSchema
            self.schemaGeneration += 1
        }
        if self.loadState.isRunning { self.loadState = .idle }
    }

    func reloadConfig() async {
        do {
            self.apply(try await self.client.snapshot())
            self.configSupported = true
        } catch GatewayConfigClient.Unsupported.method {
            self.configSupported = false
        } catch {
            self.loadState = .failed(error.localizedDescription)
        }
    }

    /// Takes a fresh snapshot, keeping unsaved edits on top of it.
    private func apply(_ snapshot: ConfigSnapshot) {
        let first = self.snapshot == nil
        self.snapshot = snapshot
        if first {
            self.edits = ConfigEdits(base: snapshot.config)
            return
        }
        let fresh = self.edits.rebase(onto: snapshot.config)
        let freshPaths = Set(fresh.map(\.path))
        self.conflicts = (self.conflicts.filter { !freshPaths.contains($0.path) && self.edits.isChanged($0.path) } + fresh)
            .sorted { $0.id < $1.id }
    }

    func reloadPlugins() async {
        do {
            self.plugins = try await self.client.plugins()
            self.pluginsSupported = true
        } catch GatewayConfigClient.Unsupported.method {
            self.pluginsSupported = false
        } catch {
            // Plugins are optional; the config still loads.
        }
    }

    public func loadCredentials(for plugin: PluginInfo) async {
        if let credentials = await self.client.credentials(for: plugin.id) { self.credentials[plugin.id] = credentials }
    }

    func handlePluginsChanged() {
        guard self.hasLoaded else { return }
        Task {
            await self.reloadPlugins()
            await self.reloadConfig()
        }
    }

    public func plugin(_ id: String) -> PluginInfo? { self.plugins.first { $0.id == id } }

    // MARK: Reading

    /// The value at `path`, including unsaved edits.
    public func value(at path: [String]) -> JSONValue? { self.edits.value(at: path) }
    public func savedValue(at path: [String]) -> JSONValue? { self.edits.baseValue(at: path) }
    public func isChanged(_ path: [String]) -> Bool { self.edits.isChanged(path) }
    public func changeCount(under path: [String]) -> Int { self.edits.changeCount(under: path) }
    public var changeCount: Int { self.edits.changes.count }
    public var hasChanges: Bool { self.edits.hasChanges }

    public func field(at path: [String]) -> ConfigField? {
        (self.schema ?? .open).field(at: path, value: self.value(at: path))
    }

    public func fields(at path: [String]) -> [ConfigField] {
        (self.schema ?? .open).fields(at: path, value: self.value(at: path))
    }

    /// Gateway-reported problems (validation, rejected writes) at or under `path`.
    public func issues(under path: [String]) -> [ConfigIssue] {
        let prefix = ConfigPath.string(path)
        return (self.writeIssues + (self.snapshot?.issues ?? [])).filter { ConfigEdits.key($0.path, isUnder: prefix) }
    }

    /// Changed values that won't pass the schema, by dotted path.
    public var validationProblems: [String: String] {
        var problems: [String: String] = [:]
        let schema = self.schema ?? .open
        for change in self.edits.changes {
            guard let field = schema.field(at: change.path, value: change.new), field.kind != .object else { continue }
            if let problem = field.validate(change.new) { problems[field.id] = problem }
        }
        return problems
    }

    /// Why Save is unavailable, if it is.
    public var saveBlocker: String? {
        if !self.canEdit { return ConfigWriteError.adminRequired.message }
        if !self.conflicts.isEmpty { return "Some values also changed on the Gateway. Choose which to keep." }
        let invalid = self.edits.inputErrors.count + self.validationProblems.count
        if invalid > 0 { return invalid == 1 ? "Fix the highlighted value first." : "Fix the \(invalid) highlighted values first." }
        return nil
    }

    /// Every setting, for search. Rebuilt when the schema or the config changes.
    public var searchIndex: [ConfigField] {
        let key = "\(self.schemaGeneration)|\(self.snapshot?.hash ?? "")"
        if let cache = self.searchCache, cache.key == key { return cache.fields }
        let fields = (self.schema ?? .open).searchIndex(config: self.edits.base)
        self.searchCache = (key, fields)
        return fields
    }

    // MARK: Editing

    public func set(_ path: [String], _ value: JSONValue?) {
        self.edits.set(path, value)
        self.edits.texts.removeValue(forKey: ConfigPath.string(path))
        self.edits.inputErrors.removeValue(forKey: ConfigPath.string(path))
        self.clearIssue(at: path)
    }

    /// Text typed into a field: kept as typed, and applied once it parses.
    public func setText(_ text: String, for field: ConfigField) {
        self.edits.texts[field.id] = text
        self.clearIssue(at: field.path)
        if field.kind == .secret, text.isEmpty {
            // An empty secret box keeps the saved secret.
            self.edits.set(field.path, self.savedValue(at: field.path))
            self.edits.inputErrors.removeValue(forKey: field.id)
            return
        }
        do {
            self.edits.set(field.path, try field.value(fromText: text))
            self.edits.inputErrors.removeValue(forKey: field.id)
        } catch {
            self.edits.inputErrors[field.id] = error.localizedDescription
        }
    }

    public func text(for field: ConfigField) -> String {
        if let text = self.edits.texts[field.id] { return text }
        if field.kind == .secret { return "" }
        return field.text(for: self.value(at: field.path))
    }

    public func inputError(for field: ConfigField) -> String? { self.edits.inputErrors[field.id] }

    public func revert(_ path: [String]) {
        self.edits.revert(path)
        self.conflicts.removeAll { $0.path.starts(with: path) }
    }

    public func discardChanges() {
        self.edits.discardAll()
        self.conflicts = []
        self.writeIssues = []
        self.saveState = .idle
    }

    /// Resolves a conflict by keeping this draft's value or taking the Gateway's.
    public func resolve(_ conflict: ConfigEdits.Conflict, keepMine: Bool) {
        if !keepMine { self.edits.revert(conflict.path) }
        self.conflicts.removeAll { $0.id == conflict.id }
    }

    private func clearIssue(at path: [String]) {
        let id = ConfigPath.string(path)
        self.writeIssues.removeAll { $0.path == id }
    }

    public func clearSaveError() {
        if self.saveState.error != nil { self.saveState = .idle }
    }

    // MARK: Saving

    /// Sends every unsaved edit as one `config.patch`. When the config changed on the Gateway
    /// meanwhile, the edits move onto the new config and are sent again unless they clash.
    @discardableResult
    public func save(note: String = "Pincer: Gateway Settings") async -> Bool {
        if let blocker = self.saveBlocker {
            self.saveState = .failed(blocker)
            return false
        }
        guard self.edits.patch != nil else {
            self.edits.discardAll()
            return true
        }
        self.saveState = .running
        self.writeIssues = []
        for attempt in 0..<2 {
            guard let patch = self.edits.patch else { break }
            do {
                let result = try await self.client.patch(patch, replacePaths: self.edits.replacePaths,
                                                         baseHash: self.snapshot?.hash, note: note)
                await self.finishWrite(ConfigApplyOutcome(configWrite: result), touchedPlugins: patch["plugins"] != nil)
                return true
            } catch .staleHash where attempt == 0 {
                await self.reloadConfig()
                if !self.conflicts.isEmpty {
                    self.saveState = .failed("Some values also changed on the Gateway. Choose which to keep, then save again.")
                    return false
                }
            } catch {
                return await self.fail(error, touchedPlugins: patch["plugins"] != nil)
            }
        }
        self.saveState = .failed(ConfigWriteError.staleHash.message + " Try saving again.")
        return false
    }

    /// Replaces the whole config with `config.apply`. Redacted secrets left as they are are kept.
    @discardableResult
    public func saveRaw(_ text: String) async -> Bool {
        if !self.canEdit {
            self.saveState = .failed(ConfigWriteError.adminRequired.message)
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.saveState = .failed("The config can't be empty.")
            return false
        }
        self.saveState = .running
        self.writeIssues = []
        do {
            let result = try await self.client.apply(text, baseHash: self.snapshot?.hash)
            await self.finishWrite(ConfigApplyOutcome(configWrite: result), touchedPlugins: true)
            return true
        } catch {
            return await self.fail(error, touchedPlugins: true)
        }
    }

    private func finishWrite(_ outcome: ConfigApplyOutcome, touchedPlugins: Bool) async {
        await self.reloadAfterWrite(touchedPlugins: touchedPlugins)
        self.saveState = .idle
        self.record(outcome)
    }

    private func record(_ outcome: ConfigApplyOutcome) {
        self.lastSave = (outcome, UUID())
        if outcome.needsManualRestart { self.onRestartRequired?(outcome.message) }
    }

    private func reloadAfterWrite(touchedPlugins: Bool) async {
        if let snapshot = try? await self.client.snapshot() {
            self.snapshot = snapshot
            self.edits = ConfigEdits(base: snapshot.config)
            self.conflicts = []
        }
        // Plugin settings decide whether a plugin still needs setup.
        if touchedPlugins, self.pluginsSupported { await self.reloadPlugins() }
    }

    private func fail(_ error: ConfigWriteError, touchedPlugins: Bool) async -> Bool {
        switch error {
        case let .invalid(issues):
            self.writeIssues = issues
            self.saveState = .failed(error.message)
        case let .notApplied(message, persisted, hash):
            // Persisted but not applied: this is now the saved config.
            if let persisted {
                self.snapshot = ConfigSnapshot(config: persisted, hash: hash, previous: self.snapshot)
                self.edits = ConfigEdits(base: persisted)
                self.conflicts = []
            } else {
                await self.reloadAfterWrite(touchedPlugins: touchedPlugins)
            }
            self.saveState = .idle
            self.record(.savedNotApplied(message))
            return true
        case .staleHash:
            await self.reloadConfig()
            self.saveState = .failed(error.message + " Review the latest values and save again.")
        default:
            self.saveState = .failed(error.message)
        }
        return false
    }

    // MARK: Plugins

    public func setEnabled(_ plugin: PluginInfo, _ enabled: Bool) async {
        await self.pluginChange(plugin.id, "plugins.setEnabled", ["pluginId": .string(plugin.id), "enabled": .bool(enabled)])
    }

    @discardableResult
    public func uninstall(_ plugin: PluginInfo) async -> Bool {
        await self.pluginChange(plugin.id, "plugins.uninstall", ["pluginId": .string(plugin.id)])
    }

    @discardableResult
    public func install(from source: PluginSource, spec: String, enable: Bool = true) async -> Bool {
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            self.pluginOperations[Self.installKey] = .failed("Enter what to install.")
            return false
        }
        var params = source.params(spec)
        params["enable"] = .bool(enable)
        return await self.pluginChange(Self.installKey, "plugins.install", params, timeout: 180)
    }

    public func operation(for pluginId: String) -> OperationState { self.pluginOperations[pluginId] ?? .idle }

    public func clearOperation(_ pluginId: String) { self.pluginOperations[pluginId] = nil }

    @discardableResult
    private func pluginChange(_ key: String, _ method: String, _ params: [String: JSONValue],
                              timeout: TimeInterval = 60) async -> Bool {
        guard self.canEdit else {
            self.pluginOperations[key] = .failed(ConfigWriteError.adminRequired.message)
            return false
        }
        self.pluginOperations[key] = .running
        do {
            let result = try await self.client.pluginChange(method, params, timeout: timeout)
            self.pluginOperations[key] = nil
            self.record(ConfigApplyOutcome(pluginChange: result))
            await self.reloadPlugins()
            await self.reloadConfig()
            return true
        } catch {
            if let confirmation = self.confirmation(for: error, key: key, method: method, params: params, timeout: timeout) {
                self.pluginOperations[key] = nil
                self.pendingConfirmation = confirmation
            } else {
                self.pluginOperations[key] = .failed(ConfigWriteError(error).message)
            }
            return false
        }
    }

    private func confirmation(for error: Error, key: String, method: String, params: [String: JSONValue],
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
            guard let self else { return false }
            return await self.pluginChange(key, method, params.merging(acknowledgement) { _, new in new }, timeout: timeout)
        }
    }

    @discardableResult
    public func confirm(_ confirmation: PluginConfirmation) async -> Bool {
        self.pendingConfirmation = nil
        return await confirmation.retry(confirmation.acknowledgement)
    }
}

public extension ConfigSchema {
    /// Used when the Gateway doesn't serve a schema: fields come from the values alone.
    static let open = ConfigSchema(schema: ["type": "object", "additionalProperties": .object([:])])
}
