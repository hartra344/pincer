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
    /// Ownership only for outstanding plugin credential inspections, never completed plugin IDs.
    @ObservationIgnored private var credentialLoadOwners: [String: UUID] = [:]
    @ObservationIgnored private let scopes: () -> [String]
    @ObservationIgnored private let fieldSearchPreparation = SettingsFieldSearchPreparation()
    package struct FieldSearchSourceRevision: Hashable, Sendable {
        let schema: Int
        let snapshot: Int
    }
    private struct FieldSearchPublication {
        let token: UUID
        let source: FieldSearchSourceRevision
        let fields: [ConfigField]
    }
    private var fieldSearchPublication: FieldSearchPublication?
    @ObservationIgnored private var fieldSearchOwner: UUID?
    package var fieldSearchSourceRevision: FieldSearchSourceRevision {
        // Observe source replacement without comparing or hashing either payload.
        _ = self.schema
        _ = self.snapshot
        return FieldSearchSourceRevision(schema: self.schemaGeneration, snapshot: self.snapshotRevision)
    }
    #if DEBUG
    @ObservationIgnored package var fieldSearchProbe: SettingsFieldSearchProbe?
    @ObservationIgnored package var fieldSearchBeforeWork: (@Sendable () -> Void)?
    #endif
    @ObservationIgnored private var schemaGeneration = 0
    @ObservationIgnored private var editRevision = 0
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var snapshotRequest = 0
    @ObservationIgnored private var snapshotAppliedRequest = 0
    @ObservationIgnored private var writeInFlight = false
    @ObservationIgnored private var writeSubmitted: ConfigEdits?
    @ObservationIgnored private var writeIntent = ConfigEdits.LocalIntent()

    /// A top-level key the demo may save without `operator.admin` (its MCP servers).
    @ObservationIgnored private let rootWritableWithoutAdmin: String?

    init(connection: GatewayConnection, scopes: @escaping () -> [String], rootWritableWithoutAdmin: String? = nil) {
        self.client = GatewayConfigClient(connection: connection)
        self.scopes = scopes
        self.rootWritableWithoutAdmin = rootWritableWithoutAdmin
    }

    init(request: @escaping GatewayConfigClient.Request, scopes: @escaping () -> [String], rootWritableWithoutAdmin: String? = nil) {
        self.client = GatewayConfigClient(request: request)
        self.scopes = scopes
        self.rootWritableWithoutAdmin = rootWritableWithoutAdmin
    }

    /// The Gateway granted `operator.admin`, which every config and plugin write needs.
    public var canEdit: Bool { self.scopes().contains(GatewayConnection.adminScope) }

    /// Whether edits under the top-level `root` may be saved: with `operator.admin`, or the demo's MCP servers.
    public func canEdit(root: String) -> Bool { self.canEdit || root == self.rootWritableWithoutAdmin }

    /// Whether the unsaved edits may be saved (every change is somewhere this client may write).
    public var canSave: Bool {
        self.canEdit || (self.rootWritableWithoutAdmin != nil
            && self.edits.changes.allSatisfy { $0.path.first == self.rootWritableWithoutAdmin })
    }
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
        self.snapshotRequest += 1
        let request = self.snapshotRequest
        do {
            let snapshot = try await self.client.snapshot()
            guard request >= self.snapshotAppliedRequest else { return }
            self.snapshotAppliedRequest = request
            self.apply(snapshot)
            self.configSupported = true
        } catch GatewayConfigClient.Unsupported.method {
            if request >= self.snapshotAppliedRequest { self.configSupported = false }
        } catch {
            if request >= self.snapshotAppliedRequest { self.loadState = .failed(error.localizedDescription) }
        }
    }

    /// Takes a fresh snapshot, keeping unsaved edits on top of it.
    private func apply(_ snapshot: ConfigSnapshot) {
        self.snapshotRevision += 1
        self.editRevision += 1
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
        guard !Task.isCancelled else { return }
        let owner = UUID()
        self.credentialLoadOwners[plugin.id] = owner
        defer {
            if self.credentialLoadOwners[plugin.id] == owner { self.credentialLoadOwners[plugin.id] = nil }
        }
        if let credentials = await self.client.credentials(for: plugin.id) {
            guard !Task.isCancelled, self.credentialLoadOwners[plugin.id] == owner else { return }
            self.credentials[plugin.id] = credentials
        }
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
        if !self.canSave { return ConfigWriteError.adminRequired.message }
        if !self.conflicts.isEmpty { return "Some values also changed on the Gateway. Choose which to keep." }
        let invalid = self.edits.inputErrors.count + self.validationProblems.count
        if invalid > 0 { return invalid == 1 ? "Fix the highlighted value first." : "Fix the \(invalid) highlighted values first." }
        return nil
    }

    /// The prepared index, if it fits the bounded cache and belongs to the current source.
    public var searchIndex: [ConfigField] {
        self.fieldSearchPreparation.cachedFields(for: self.fieldSearchSourceRevision)
    }

    /// Main only captures COW inputs and local ownership; the worker does all text work.
    package func prepareFieldSearch(matching query: String, token: UUID) async {
        guard !Task.isCancelled else { return }
        let source = self.fieldSearchSourceRevision
        self.fieldSearchOwner = token
        #if DEBUG
        let ticket = self.fieldSearchPreparation.enqueue(.init(token: token, source: source,
            schema: self.schema ?? .open, config: self.snapshot?.config ?? self.edits.base, query: query,
            probe: self.fieldSearchProbe, beforeWork: self.fieldSearchBeforeWork))
        #else
        let ticket = self.fieldSearchPreparation.enqueue(.init(token: token, source: source,
            schema: self.schema ?? .open, config: self.snapshot?.config ?? self.edits.base, query: query))
        #endif
        guard let fields = await self.fieldSearchPreparation.wait(ticket), !Task.isCancelled,
              self.fieldSearchOwner == token, self.fieldSearchSourceRevision == source else { return }
        self.fieldSearchPublication = FieldSearchPublication(token: token, source: source, fields: fields)
    }
    package func fieldSearchResults(token: UUID, source: FieldSearchSourceRevision) -> [ConfigField] {
        guard self.ownsFieldSearch(token: token, source: source) else { return [] }
        return self.fieldSearchPublication?.fields ?? []
    }
    package func ownsFieldSearch(token: UUID, source: FieldSearchSourceRevision) -> Bool {
        self.fieldSearchOwner == token && self.fieldSearchPublication?.token == token
            && self.fieldSearchPublication?.source == source && self.fieldSearchSourceRevision == source
    }
    #if DEBUG
    package var fieldSearchBudget: SettingsFieldSearchPreparation.BudgetSnapshot { self.fieldSearchPreparation.budgetSnapshot }
    package func waitForFieldSearchPreparation() async { await self.fieldSearchPreparation.drain() }
    #endif

    // MARK: Editing

    public func set(_ path: [String], _ value: JSONValue?) {
        self.editRevision += 1
        self.edits.set(path, value)
        if self.writeSubmitted != nil { self.writeIntent.set(path, value) }
        self.edits.texts.removeValue(forKey: path)
        self.edits.inputErrors.removeValue(forKey: path)
        self.clearIssue(at: path)
    }

    /// Text typed into a field: kept as typed, and applied once it parses.
    public func setText(_ text: String, for field: ConfigField) {
        self.editRevision += 1
        self.edits.texts[field.path] = text
        self.clearIssue(at: field.path)
        if field.kind == .secret, text.isEmpty {
            // An empty secret box keeps the saved secret.
            let value = self.savedValue(at: field.path)
            self.edits.set(field.path, value)
            if self.writeSubmitted != nil { self.writeIntent.set(field.path, value) }
            self.edits.inputErrors.removeValue(forKey: field.path)
            return
        }
        do {
            let value = try field.value(fromText: text)
            self.edits.set(field.path, value)
            if self.writeSubmitted != nil { self.writeIntent.set(field.path, value) }
            self.edits.inputErrors.removeValue(forKey: field.path)
        } catch {
            self.edits.inputErrors[field.path] = error.localizedDescription
        }
    }

    public func text(for field: ConfigField) -> String {
        if let text = self.edits.texts[field.path] { return text }
        if field.kind == .secret { return "" }
        return field.text(for: self.value(at: field.path))
    }

    public func inputError(for field: ConfigField) -> String? { self.edits.inputErrors[field.path] }

    public func revert(_ path: [String]) {
        self.editRevision += 1
        if self.writeSubmitted != nil { self.writeIntent.set(path, self.savedValue(at: path)) }
        self.edits.revert(path)
        self.conflicts.removeAll { $0.path.starts(with: path) }
    }

    public func discardChanges() {
        self.editRevision += 1
        if let submitted = self.writeSubmitted {
            // Capture only affected paths, not a full-config diff; values remain COW references.
            let paths = Set(submitted.edits.keys).union(self.edits.edits.keys).union(self.writeIntent.values.keys)
            for path in paths.sorted(by: { $0.count < $1.count }) {
                self.writeIntent.set(path, self.savedValue(at: path))
            }
        }
        self.edits.discardAll()
        self.conflicts = []
        self.writeIssues = []
        if !self.writeInFlight { self.saveState = .idle }
    }

    /// Resolves a conflict by keeping this draft's value or taking the Gateway's.
    public func resolve(_ conflict: ConfigEdits.Conflict, keepMine: Bool) {
        self.editRevision += 1
        if self.writeSubmitted != nil {
            self.writeIntent.set(conflict.path, keepMine ? self.value(at: conflict.path) : self.savedValue(at: conflict.path))
        }
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
        guard !self.writeInFlight else { return false }
        if let blocker = self.saveBlocker {
            self.saveState = .failed(blocker)
            return false
        }
        self.writeInFlight = true
        defer { self.writeInFlight = false; self.writeSubmitted = nil; self.writeIntent = .init() }
        self.saveState = .running
        self.writeIssues = []
        for attempt in 0..<2 {
            let submitted = self.edits
            self.writeSubmitted = submitted
            self.writeIntent = .init()
            let revision = self.editRevision
            let snapshotAtAdmission = self.snapshotRevision
            let requestAtAdmission = self.snapshotRequest
            let baseHash = self.snapshot?.hash
            let prepared = await Task.detached(priority: .userInitiated) {
                (submitted.patch, submitted.replacePaths)
            }.value
            guard let patch = prepared.0 else { self.saveState = .idle; return true }
            do {
                let result = try await self.client.patch(patch, replacePaths: prepared.1,
                                                         baseHash: baseHash, note: note)
                await self.finishWrite(ConfigApplyOutcome(configWrite: result), touchedPlugins: patch["plugins"] != nil)
                return true
            } catch .staleHash where attempt == 0 {
                await self.reloadConfig()
                if !self.conflicts.isEmpty {
                    self.saveState = .failed("Some values also changed on the Gateway. Choose which to keep, then save again.")
                    return false
                }
            } catch {
                return await self.fail(error, touchedPlugins: patch["plugins"] != nil, revision: revision, snapshotAtAdmission: snapshotAtAdmission, requestAtAdmission: requestAtAdmission)
            }
        }
        self.saveState = .failed(ConfigWriteError.staleHash.message + " Try saving again.")
        return false
    }

    /// Writes one channel's reaction level straight away with `config.patch`, leaving any other unsaved
    /// edits in place. Returns an error message, or nil when saved.
    public func saveReactionLevel(channel: String, account: String?, level: ReactionLevel?) async -> String? {
        guard !self.writeInFlight else { return L("A settings save is already in progress.") }
        self.writeInFlight = true
        defer { self.writeInFlight = false; self.writeSubmitted = nil; self.writeIntent = .init() }
        if !self.canEdit { return ConfigWriteError.adminRequired.message }
        if self.snapshot == nil { await self.reloadConfig() }
        guard self.snapshot != nil else { return "Gateway Settings hasn't loaded yet." }
        let patch = ReactionLevels.patch(channel: channel, account: account, level: level)
        for attempt in 0..<2 {
            do {
                let result = try await self.client.patch(patch, replacePaths: [], baseHash: self.snapshot?.hash,
                                                         note: "Pincer: Reaction level")
                await self.reloadConfig()
                self.record(ConfigApplyOutcome(configWrite: result))
                return nil
            } catch .staleHash where attempt == 0 {
                await self.reloadConfig()
            } catch {
                return error.message
            }
        }
        return ConfigWriteError.staleHash.message + " Try again."
    }

    /// Replaces the whole config with `config.apply`. Redacted secrets left as they are are kept.
    @discardableResult
    public func saveRaw(_ text: String) async -> Bool {
        guard !self.writeInFlight else { return false }
        self.writeInFlight = true
        defer { self.writeInFlight = false; self.writeSubmitted = nil; self.writeIntent = .init() }
        if !self.canEdit {
            self.saveState = .failed(ConfigWriteError.adminRequired.message)
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.saveState = .failed("The config can't be empty.")
            return false
        }
        self.writeSubmitted = self.edits
        self.writeIntent = .init()
        let revision = self.editRevision
        let snapshotAtAdmission = self.snapshotRevision
        let requestAtAdmission = self.snapshotRequest
        self.saveState = .running
        self.writeIssues = []
        do {
            let result = try await self.client.apply(text, baseHash: self.snapshot?.hash)
            await self.finishWrite(ConfigApplyOutcome(configWrite: result), touchedPlugins: true)
            return true
        } catch {
            return await self.fail(error, touchedPlugins: true, revision: revision, snapshotAtAdmission: snapshotAtAdmission, requestAtAdmission: requestAtAdmission)
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

    /// One worker per active write; edits during its computation cause a fresh capture, never
    /// another queued job per keystroke. Captures retain COW payloads; edits can fork their
    /// buffers, so the admitted/latest/acknowledged snapshots still have a memory cost.
    /// Main only swaps finished state after verifying its revisions.
    private func acknowledge(_ snapshot: ConfigSnapshot) async {
        while true {
            let revision = self.editRevision
            let snapshotRevision = self.snapshotRevision
            let latest = self.edits
            let intent = self.writeIntent
            let hasAdmission = self.writeSubmitted != nil
            let base = self.snapshotRevision > 0 ? (self.snapshot?.config ?? snapshot.config) : snapshot.config
            let merged = await Task.detached(priority: .userInitiated) {
                if hasAdmission { return ConfigEdits.acknowledging(intent: intent, latest: latest, base: base) }
                // Immediate plugin writes keep the existing structured draft.
                var edits = latest
                _ = edits.rebase(onto: base)
                return edits
            }.value
            guard revision == self.editRevision, snapshotRevision == self.snapshotRevision else { continue }
            self.edits = merged
            self.conflicts = []
            self.editRevision += 1
            return
        }
    }

    private func reloadAfterWrite(touchedPlugins: Bool) async {
        self.snapshotRequest += 1
        let request = self.snapshotRequest
        if let snapshot = try? await self.client.snapshot() {
            if request >= self.snapshotAppliedRequest {
                self.snapshotAppliedRequest = request
                self.snapshot = snapshot
                self.snapshotRevision += 1
            }
            await self.acknowledge(snapshot)
        }
        if touchedPlugins, self.pluginsSupported { await self.reloadPlugins() }
    }

    private func fail(_ error: ConfigWriteError, touchedPlugins: Bool, revision: Int? = nil, snapshotAtAdmission: Int? = nil, requestAtAdmission: Int? = nil) async -> Bool {
        switch error {
        case let .invalid(issues):
            self.writeIssues = revision == nil || revision == self.editRevision ? issues : []
            self.saveState = .failed(error.message)
        case let .notApplied(message, persisted, hash):
            // Persisted but not applied: this is now the saved config.
            if let persisted, snapshotAtAdmission == nil || snapshotAtAdmission == self.snapshotRevision {
                let snapshot = ConfigSnapshot(config: persisted, hash: hash, previous: self.snapshot)
                // This provenance belongs to the admitted write, not its later error arrival.
                self.snapshotAppliedRequest = max(self.snapshotAppliedRequest, requestAtAdmission ?? self.snapshotAppliedRequest)
                self.snapshot = snapshot
                self.snapshotRevision += 1
                await self.acknowledge(snapshot)
            } else {
                // A snapshot observed during the write may predate or postdate persistence.
                // Fetch current authority rather than guessing that the older response is newer.
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
