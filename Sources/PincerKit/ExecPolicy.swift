import Foundation

// MARK: Fields

/// One of the four policy settings shared by `defaults` and each agent in the Gateway's exec
/// approvals file. Values stay as `JSONValue` so ones Pincer doesn't know survive a save.
public enum ExecPolicyField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case security
    case ask
    case askFallback
    case autoAllowSkills

    public struct Option: Hashable, Sendable {
        public let value: JSONValue
        public let label: String

        public init(_ value: JSONValue, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public var id: String { self.rawValue }

    /// The key in the file.
    public var key: String { self.rawValue }

    public var label: String {
        switch self {
        case .security: "Commands"
        case .ask: "Ask for approval"
        case .askFallback: "If no one answers"
        case .autoAllowSkills: "Trust skill commands"
        }
    }

    public var help: String {
        switch self {
        case .security: "What an agent may run without asking."
        case .ask: "When Pincer and other clients get an approval request."
        case .askFallback: "Used when an approval times out or no reviewer is connected."
        case .autoAllowSkills: "Commands provided by installed skills run without an allowlist entry."
        }
    }

    public var isToggle: Bool { self == .autoAllowSkills }

    /// Known values, safest first.
    public var options: [Option] {
        switch self {
        case .security:
            [Option("deny", "Block all"), Option("allowlist", "Only allowlisted"), Option("full", "Allow any command")]
        case .ask:
            [Option("always", "Every time"), Option("on-miss", "When not on the allowlist"), Option("off", "Never")]
        case .askFallback:
            [Option("deny", "Block"), Option("allowlist", "Allow only allowlisted"), Option("full", "Run anyway")]
        case .autoAllowSkills:
            [Option(false, "Off"), Option(true, "On")]
        }
    }

    /// The label for a value: the known one, else the raw value humanized (`on-request` → "On request").
    public func label(for value: JSONValue) -> String {
        if let option = self.options.first(where: { $0.value == value }) { return option.label }
        switch value {
        case let .string(text): return ExecPolicy.humanized(text)
        case let .bool(flag): return flag ? "On" : "Off"
        default: return value.compactString()
        }
    }

    /// Position from safest (0) to loosest; nil for a value Pincer doesn't know (or no value).
    public func rank(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        return self.options.firstIndex { $0.value == value }
    }

    /// Whether moving from `old` to `new` makes this setting less safe. Unknown or missing new
    /// values count as loosening. From an unknown (or missing) old value, moving to the loosest
    /// known option counts too.
    public func isLoosening(from old: JSONValue?, to new: JSONValue?) -> Bool {
        guard old != new else { return false }
        guard let newRank = self.rank(new) else { return true }
        guard let oldRank = self.rank(old) else { return newRank == self.options.count - 1 }
        return newRank > oldRank
    }

    /// The short phrase for an agent override in its row: "Asks every time", "Allows any command"…
    public func overridePhrase(_ value: JSONValue) -> String {
        switch (self, value) {
        case (.security, "deny"): "Blocks all commands"
        case (.security, "allowlist"): "Allowlist only"
        case (.security, "full"): "Allows any command"
        case (.ask, "always"): "Asks every time"
        case (.ask, "on-miss"): "Asks when not allowlisted"
        case (.ask, "off"): "Never asks"
        case (.autoAllowSkills, true): "Trusts skill commands"
        case (.autoAllowSkills, false): "Doesn't trust skill commands"
        default: "\(self.label): \(self.label(for: value))"
        }
    }
}

/// The effective mode for a security/ask pair, as the Gateway projects it (`resolveExecModeFromPolicy`).
public enum ExecPolicyMode: String, Hashable, Sendable {
    case deny
    case allowlist
    case full
    case ask

    public init(security: JSONValue?, ask: JSONValue?) {
        let security = security?.string
        let ask = ask?.string
        if security == "deny" {
            self = .deny
        } else if security == "allowlist", ask == "off" {
            self = .allowlist
        } else if security == "full", ask == "off" || ask == "on-miss" {
            self = .full
        } else {
            self = .ask
        }
    }

    public var summary: String {
        switch self {
        case .deny: "Commands are blocked"
        case .allowlist: "Allowlist only, never asks"
        case .full: "Any command runs"
        case .ask: "Asks before running unlisted commands"
        }
    }
}

// MARK: File

/// `security`, `ask`, `askFallback` and `autoAllowSkills` from `defaults`, an agent, or `resolvedDefaults`.
public struct ExecPolicySettings: Hashable, Sendable {
    public var values: [ExecPolicyField: JSONValue]

    public init(_ json: JSONValue?) {
        var values: [ExecPolicyField: JSONValue] = [:]
        for field in ExecPolicyField.allCases {
            if let value = json?[field.key], !value.isNull { values[field] = value }
        }
        self.values = values
    }

    public init(values: [ExecPolicyField: JSONValue] = [:]) {
        self.values = values
    }

    public subscript(field: ExecPolicyField) -> JSONValue? { self.values[field] }

    public var isEmpty: Bool { self.values.isEmpty }
}

/// One `allowlist` entry of an agent. `index` is its position in the file, which identifies
/// it (entries from older files may have no `id`).
public struct ExecAllowlistEntry: Identifiable, Hashable, Sendable {
    public let index: Int
    public let entryId: String?
    public let pattern: String
    public let source: String?
    public let commandText: String?
    public let argPattern: String?
    public let lastUsedAt: Date?
    public let lastUsedCommand: String?
    public let lastResolvedPath: String?
    public let raw: JSONValue

    public var id: Int { self.index }

    public init(index: Int, _ json: JSONValue) {
        self.index = index
        self.raw = json
        self.entryId = json["id"]?.text
        self.pattern = json["pattern"]?.string ?? ""
        self.source = json["source"]?.text
        self.commandText = json["commandText"]?.text
        self.argPattern = json["argPattern"]?.text
        self.lastUsedAt = json["lastUsedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.lastUsedCommand = json["lastUsedCommand"]?.text
        self.lastResolvedPath = json["lastResolvedPath"]?.text
    }

    /// Added by choosing Always allow on an approval (rather than by hand).
    public var isAllowAlways: Bool { self.source == "allow-always" }
}

/// One `mcpTools` grant of an agent.
public struct ExecMcpToolGrant: Identifiable, Hashable, Sendable {
    public let index: Int
    public let server: String
    public let tool: String
    public let source: String?
    public let addedAt: Date?
    public let lastUsedAt: Date?
    public let raw: JSONValue

    public var id: Int { self.index }

    public init(index: Int, _ json: JSONValue) {
        self.index = index
        self.raw = json
        self.server = json["server"]?.string ?? ""
        self.tool = json["tool"]?.string ?? ""
        self.source = json["source"]?.text
        self.addedAt = json["addedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        self.lastUsedAt = json["lastUsedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// "github › create_issue".
    public var title: String { "\(self.server) › \(self.tool)" }
}

/// The Gateway's exec approvals file, kept as JSON so keys and entry fields Pincer doesn't
/// know survive a save. Edits change only what they touch.
public struct ExecApprovalsFile: Hashable, Sendable {
    public private(set) var raw: JSONValue

    /// The agent key that applies to every agent.
    public static let wildcardAgent = "*"

    public init(_ raw: JSONValue?) {
        if let raw, case .object = raw { self.raw = raw } else { self.raw = ["version": 1] }
    }

    public var defaults: ExecPolicySettings { ExecPolicySettings(self.raw["defaults"]) }

    /// Agent keys in the file.
    public var agentIds: [String] { self.raw["agents"]?.object.map { Array($0.keys) } ?? [] }

    public func agentJSON(_ id: String) -> JSONValue? { self.raw["agents"]?[id] }

    /// An agent's own overrides (not what it inherits).
    public func overrides(_ agentId: String) -> ExecPolicySettings { ExecPolicySettings(self.agentJSON(agentId)) }

    public func allowlist(_ agentId: String) -> [ExecAllowlistEntry] {
        (self.agentJSON(agentId)?["allowlist"]?.array ?? []).enumerated().map { ExecAllowlistEntry(index: $0, $1) }
    }

    public func mcpTools(_ agentId: String) -> [ExecMcpToolGrant] {
        (self.agentJSON(agentId)?["mcpTools"]?.array ?? []).enumerated().map { ExecMcpToolGrant(index: $0, $1) }
    }

    /// A saved value: of `defaults` when `agent` is nil, else of that agent.
    public func value(_ field: ExecPolicyField, agent: String?) -> JSONValue? {
        agent.map { self.overrides($0)[field] } ?? self.defaults[field]
    }

    // MARK: Edits

    /// Sets or (with nil) removes a value in `defaults` or an agent, creating the object if needed.
    public mutating func set(_ field: ExecPolicyField, _ value: JSONValue?, agent: String?) {
        if let agent {
            self.updateAgent(agent) { $0[field.key] = value }
        } else {
            var defaults = self.raw["defaults"]?.object ?? [:]
            defaults[field.key] = value
            self.setKey("defaults", .object(defaults))
        }
    }

    /// Removes the agent's four policy overrides, keeping its allowlist and tools.
    public mutating func clearOverrides(agent: String) {
        guard self.agentJSON(agent) != nil else { return }
        self.updateAgent(agent) { object in
            for field in ExecPolicyField.allCases { object[field.key] = nil }
        }
    }

    public mutating func removeAllowlistEntry(agent: String, at index: Int) {
        self.removeArrayItem("allowlist", agent: agent, at: index)
    }

    public mutating func removeMcpTool(agent: String, at index: Int) {
        self.removeArrayItem("mcpTools", agent: agent, at: index)
    }

    private mutating func removeArrayItem(_ key: String, agent: String, at index: Int) {
        guard var items = self.agentJSON(agent)?[key]?.array, items.indices.contains(index) else { return }
        items.remove(at: index)
        self.updateAgent(agent) { $0[key] = .array(items) }
    }

    private mutating func updateAgent(_ id: String, _ change: (inout [String: JSONValue]) -> Void) {
        var agents = self.raw["agents"]?.object ?? [:]
        var agent = agents[id]?.object ?? [:]
        change(&agent)
        agents[id] = .object(agent)
        self.setKey("agents", .object(agents))
    }

    private mutating func setKey(_ key: String, _ value: JSONValue?) {
        var object = self.raw.object ?? [:]
        object[key] = value
        self.raw = .object(object)
    }
}

/// `exec.approvals.get` / `exec.approvals.set`'s result.
public struct ExecApprovalsSnapshot: Hashable, Sendable {
    public let path: String?
    public let exists: Bool
    public let hash: String?
    public let file: ExecApprovalsFile
    /// What the Gateway resolves `defaults` to (built-in values filled in); nil when it didn't say.
    public let resolvedDefaults: ExecPolicySettings?

    public init(_ json: JSONValue) {
        self.path = json["path"]?.text
        self.exists = json["exists"]?.bool ?? true
        self.hash = json["hash"]?.text
        self.file = ExecApprovalsFile(json["file"])
        self.resolvedDefaults = json["resolvedDefaults"]?.object != nil ? ExecPolicySettings(json["resolvedDefaults"]) : nil
    }
}

// MARK: Rows

/// One row of the Agents section.
public struct ExecAgentRow: Identifiable, Hashable, Sendable {
    public let id: String
    /// "Scout", "All agents", or the id for an agent the Gateway doesn't know.
    public let name: String
    public let emoji: String?
    public let isWildcard: Bool
    /// In `agents.list` (or the wildcard).
    public let isCurrentAgent: Bool
    public let inFile: Bool
    /// "Uses defaults", or its overrides and counts: "Asks every time · 3 allowed commands".
    public let summary: String
    /// Allowlist entries plus tool grants.
    public let badgeCount: Int

    /// "🔭 Scout".
    public var title: String { self.emoji.map { "\($0) \(self.name)" } ?? self.name }
}

/// An allowlist entry with the agent it belongs to (Recently allowed).
public struct ExecRecentEntry: Identifiable, Hashable, Sendable {
    public let agentId: String
    public let entry: ExecAllowlistEntry

    public var id: String { "\(self.agentId)#\(self.entry.index)" }
}

// MARK: Errors

/// What an `exec.approvals.*` failure means for the page.
public enum ExecPolicyError: Equatable, Sendable {
    /// Needs `operator.admin` (Full Management).
    case needsAdmin
    /// The Gateway doesn't have the method.
    case unsupported
    /// The file changed since it was loaded (or a base hash was required): reload.
    case conflict
    /// The Gateway rejected the file (`INVALID_REQUEST`).
    case validation(String)
    case other(String)

    public static func classify(_ error: Error) -> ExecPolicyError {
        guard case let GatewayError.rpc(code, message, details) = error else {
            return .other(error.localizedDescription)
        }
        let lower = message.lowercased()
        if code == "MISSING_SCOPE" || details?["code"]?.text == "MISSING_SCOPE"
            || lower.contains("missing scope") || lower.contains("operator.admin")
        {
            return .needsAdmin
        }
        if code == "UNKNOWN_METHOD" || code == "METHOD_NOT_FOUND" || lower.contains("unknown method") { return .unsupported }
        if lower.contains("changed since last load") || lower.contains("base hash required") { return .conflict }
        if code == "INVALID_REQUEST" { return .validation(message) }
        return .other(message)
    }
}

// MARK: Pure logic

public enum ExecPolicy {
    public static let getMethod = "exec.approvals.get"
    public static let setMethod = "exec.approvals.set"

    public static let conflictMessage =
        "The command policy changed on the Gateway, so your changes weren't saved. The latest version is shown. Make your changes again."
    public static let needsAdminMessage =
        "Viewing and changing the command policy needs Full Management access. Turn it on under Connection, then approve this device on the Gateway host."

    /// The Gateway's default for a field, from `resolvedDefaults`, when the saved file doesn't set it.
    /// (Once `defaults` sets a field, `resolvedDefaults` echoes that value, not the built-in one.)
    public static func gatewayDefault(_ field: ExecPolicyField, saved: ExecApprovalsFile,
                                      resolvedDefaults: ExecPolicySettings?) -> JSONValue?
    {
        saved.defaults[field] == nil ? resolvedDefaults?[field] : nil
    }

    /// The value every agent inherits in `file`: its `defaults`, else the Gateway's default.
    public static func effectiveDefault(_ field: ExecPolicyField, in file: ExecApprovalsFile, saved: ExecApprovalsFile,
                                        resolvedDefaults: ExecPolicySettings?) -> JSONValue?
    {
        file.defaults[field] ?? self.gatewayDefault(field, saved: saved, resolvedDefaults: resolvedDefaults)
    }

    /// What an agent gets when it doesn't override a field: the `*` agent's value, else the
    /// default (the Gateway resolves agent → `*` → defaults → built-in). For `*` itself, the default.
    public static func inheritedValue(_ field: ExecPolicyField, agent: String, in file: ExecApprovalsFile,
                                      saved: ExecApprovalsFile, resolvedDefaults: ExecPolicySettings?) -> JSONValue?
    {
        self.wildcardValue(field, agent: agent, in: file)
            ?? self.effectiveDefault(field, in: file, saved: saved, resolvedDefaults: resolvedDefaults)
    }

    /// The `*` agent's value that `agent` inherits, if any.
    public static func wildcardValue(_ field: ExecPolicyField, agent: String, in file: ExecApprovalsFile) -> JSONValue? {
        agent == ExecApprovalsFile.wildcardAgent ? nil : file.overrides(ExecApprovalsFile.wildcardAgent)[field]
    }

    /// The value that applies: of the agent (its override, else `*`'s, else the default) or of
    /// `defaults` when `agent` is nil.
    public static func effectiveValue(_ field: ExecPolicyField, agent: String?, in file: ExecApprovalsFile,
                                      saved: ExecApprovalsFile, resolvedDefaults: ExecPolicySettings?) -> JSONValue?
    {
        guard let agent else {
            return self.effectiveDefault(field, in: file, saved: saved, resolvedDefaults: resolvedDefaults)
        }
        return file.overrides(agent)[field]
            ?? self.inheritedValue(field, agent: agent, in: file, saved: saved, resolvedDefaults: resolvedDefaults)
    }

    /// Changes from `saved` to `draft` that make an effective setting less safe, as sentences:
    /// "Scout: Commands → Allow any command", "Defaults: Trust skill commands → On". A default
    /// (or `*` value) that loosens is listed once, under Defaults (or All agents), not for every
    /// agent that inherits it.
    public static func looseningChanges(from saved: ExecApprovalsFile, to draft: ExecApprovalsFile,
                                        resolvedDefaults: ExecPolicySettings?,
                                        agentNames: [String: String] = [:]) -> [String]
    {
        var sentences: [String] = []
        func sentence(_ subject: String, _ field: ExecPolicyField, _ value: JSONValue?) -> String {
            "\(subject): \(field.label) → \(value.map(field.label(for:)) ?? "Gateway default")"
        }
        for field in ExecPolicyField.allCases {
            let old = self.effectiveDefault(field, in: saved, saved: saved, resolvedDefaults: resolvedDefaults)
            let new = self.effectiveDefault(field, in: draft, saved: saved, resolvedDefaults: resolvedDefaults)
            if field.isLoosening(from: old, to: new) { sentences.append(sentence("Defaults", field, new)) }
        }
        let agents = Set(saved.agentIds).union(draft.agentIds)
        for agent in self.sortedAgentIds(Array(agents), names: agentNames) {
            let name = self.agentName(agent, names: agentNames)
            for field in ExecPolicyField.allCases {
                guard saved.overrides(agent)[field] != nil || draft.overrides(agent)[field] != nil else { continue }
                let old = self.effectiveValue(field, agent: agent, in: saved, saved: saved, resolvedDefaults: resolvedDefaults)
                let new = self.effectiveValue(field, agent: agent, in: draft, saved: saved, resolvedDefaults: resolvedDefaults)
                if field.isLoosening(from: old, to: new) { sentences.append(sentence(name, field, new)) }
            }
        }
        return sentences
    }

    /// The file to send: `draft` with `socket.token` removed, `version: 1`, and agents left with
    /// no keys by the edits dropped. Everything else is sent as loaded.
    public static func outgoingFile(_ draft: ExecApprovalsFile, base: ExecApprovalsFile?) -> JSONValue {
        var object = draft.raw.object ?? [:]
        object["version"] = 1
        if var socket = object["socket"]?.object {
            socket["token"] = nil
            object["socket"] = socket.isEmpty ? nil : .object(socket)
        }
        let baseAgents = base?.raw["agents"]?.object
        if var agents = object["agents"]?.object {
            for (id, value) in agents where value.object?.isEmpty == true && baseAgents?[id]?.object?.isEmpty != true {
                agents[id] = nil
            }
            object["agents"] = agents.isEmpty && baseAgents == nil ? nil : .object(agents)
        }
        if object["defaults"]?.object?.isEmpty == true, base?.raw["defaults"] == nil {
            object["defaults"] = nil
        }
        return .object(object)
    }

    /// `exec.approvals.set`'s params. `baseHash` is sent whenever the snapshot has one.
    public static func setParams(draft: ExecApprovalsFile, snapshot: ExecApprovalsSnapshot?) -> JSONValue {
        var params: [String: JSONValue] = ["file": self.outgoingFile(draft, base: snapshot?.file)]
        if let hash = snapshot?.hash { params["baseHash"] = .string(hash) }
        return .object(params)
    }

    /// Whether `draft` would change anything if saved over `saved`.
    public static func hasChanges(_ draft: ExecApprovalsFile, comparedTo saved: ExecApprovalsFile) -> Bool {
        self.outgoingFile(draft, base: saved) != self.outgoingFile(saved, base: saved)
    }

    /// One row per agent in the file or in `agents.list`: the wildcard first, then by name.
    public static func agentRows(file: ExecApprovalsFile, agents: [AgentSummary]) -> [ExecAgentRow] {
        let known = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inFile = Set(file.agentIds)
        let ids = inFile.union(known.keys)
        let names = known.mapValues(\.name)
        return self.sortedAgentIds(Array(ids), names: names).map { id in
            let agent = known[id]
            let wildcard = id == ExecApprovalsFile.wildcardAgent
            return ExecAgentRow(
                id: id,
                name: wildcard ? "All agents" : agent?.name ?? id,
                emoji: wildcard ? nil : agent?.emoji,
                isWildcard: wildcard,
                isCurrentAgent: wildcard || agent != nil,
                inFile: inFile.contains(id),
                summary: self.agentSummary(id, in: file),
                badgeCount: file.allowlist(id).count + file.mcpTools(id).count)
        }
    }

    /// "Uses defaults" (no overrides of its own), or "Asks every time · 3 allowed commands".
    public static func agentSummary(_ agentId: String, in file: ExecApprovalsFile) -> String {
        let overrides = file.overrides(agentId)
        var parts = ExecPolicyField.allCases.compactMap { field in overrides[field].map(field.overridePhrase) }
        if parts.isEmpty { parts.append("Uses defaults") }
        let commands = file.allowlist(agentId).count
        if commands > 0 { parts.append("\(commands) allowed command\(commands == 1 ? "" : "s")") }
        let tools = file.mcpTools(agentId).count
        if tools > 0 { parts.append("\(tools) allowed tool\(tools == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The most recently used allowlist entries across agents, newest first.
    public static func recentlyAllowed(_ file: ExecApprovalsFile, limit: Int = 5) -> [ExecRecentEntry] {
        let entries = file.agentIds.flatMap { agent in
            file.allowlist(agent).filter { $0.lastUsedAt != nil }.map { ExecRecentEntry(agentId: agent, entry: $0) }
        }
        return Array(entries.sorted {
            ($0.entry.lastUsedAt!, $1.id) > ($1.entry.lastUsedAt!, $0.id)
        }.prefix(limit))
    }

    /// The name used in sentences: "All agents" for `*`, the agent's name when known, else the id.
    public static func agentName(_ id: String, names: [String: String]) -> String {
        id == ExecApprovalsFile.wildcardAgent ? "All agents" : names[id] ?? id
    }

    static func sortedAgentIds(_ ids: [String], names: [String: String]) -> [String] {
        ids.sorted { lhs, rhs in
            if lhs == ExecApprovalsFile.wildcardAgent { return rhs != lhs }
            if rhs == ExecApprovalsFile.wildcardAgent { return false }
            let order = self.agentName(lhs, names: names).localizedStandardCompare(self.agentName(rhs, names: names))
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    /// `on-request` → "On request".
    public static func humanized(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return raw }
        return first.uppercased() + spaced.dropFirst()
    }
}

// MARK: Model

/// The result of `ExecPolicyModel.save`.
public enum ExecPolicySaveResult: Equatable, Sendable {
    case saved
    case noChanges
    /// Loosening changes to confirm first; call `save(allowLoosening: true)`.
    case needsConfirmation([String])
    /// Someone changed the file: it was reloaded and the draft discarded.
    case conflict
    case failed(ExecPolicyError)
}

/// A message shown at the top of the Command Policy page.
public enum ExecPolicyBanner: Equatable, Sendable {
    /// T5: the save hit a newer file; the latest one is shown.
    case conflict
    /// T4: `INVALID_REQUEST` on set; the draft is kept.
    case rejected(String)
    /// T8: anything else. `retrySave` says whether Try Again saves (else it reloads).
    case failed(String, retrySave: Bool)
    /// A save that can't work as things are (no Full Management, no `exec.approvals.set`); no Try Again.
    case notice(String)

    public var message: String {
        switch self {
        case .conflict: ExecPolicy.conflictMessage
        case let .rejected(message): "The Gateway rejected the change: \(message)"
        case let .failed(message, _), let .notice(message): message
        }
    }
}

/// Command Policy for one Gateway: the exec approvals file (`exec.approvals.get/set`) and a draft
/// of edits, kept while moving between pages. Separate from the config draft.
@MainActor
@Observable
public final class ExecPolicyModel {
    public private(set) var snapshot: ExecApprovalsSnapshot?
    /// The file with the user's edits; equal to the snapshot's file when there are none.
    public private(set) var draft = ExecApprovalsFile(nil)
    /// False when the Gateway has no `exec.approvals.get`.
    public private(set) var supported = true
    /// Reading the policy needs Full Management (`operator.admin`).
    public private(set) var needsAdmin = false
    public private(set) var hasLoaded = false
    public private(set) var loadState = OperationState.idle
    public private(set) var saveState = OperationState.idle
    public private(set) var banner: ExecPolicyBanner?
    /// Set when a save found loosening changes to confirm ("Loosen command policy?").
    public var pendingLoosening: [String]?
    /// Changes on every successful save, for the "Command policy saved" toast.
    public private(set) var lastSave: UUID?

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private var setRejectedAsUnknown = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, allowsWritesWithoutAdmin: Bool) {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    /// For checks and previews. `methods` is the advertised method list (nil or empty when
    /// unknown), `scopes` the connection's scopes; `allowsWritesWithoutAdmin` is the demo's
    /// exception to needing `operator.admin` to save.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                allowsWritesWithoutAdmin: Bool = false,
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    // MARK: State

    public var hasChanges: Bool {
        guard let snapshot else { return false }
        return ExecPolicy.hasChanges(self.draft, comparedTo: snapshot.file)
    }

    public var isSaving: Bool { self.saveState.isRunning }

    /// Whether edits can be saved: Full Management (or the demo) and a Gateway with `exec.approvals.set`.
    public var canWrite: Bool {
        guard self.allowsWritesWithoutAdmin || self.scopes().contains(GatewayConnection.adminScope) else { return false }
        if self.setRejectedAsUnknown { return false }
        if let methods = self.methods(), !methods.isEmpty, !methods.contains(ExecPolicy.setMethod) { return false }
        return true
    }

    /// Why the page is read-only, nil when it isn't.
    public var readOnlyReason: String? {
        if !self.allowsWritesWithoutAdmin, !self.scopes().contains(GatewayConnection.adminScope) {
            return "This device can view the command policy but not change it. Open Connection to request Full Management."
        }
        if !self.canWrite {
            return "This gateway can't change its command policy. Update OpenClaw to manage it here."
        }
        return nil
    }

    public var resolvedDefaults: ExecPolicySettings? { self.snapshot?.resolvedDefaults }

    private var saved: ExecApprovalsFile { self.snapshot?.file ?? ExecApprovalsFile(nil) }

    /// The value of `defaults` or an agent in the draft.
    public func value(_ field: ExecPolicyField, agent: String?) -> JSONValue? {
        self.draft.value(field, agent: agent)
    }

    /// The value of `defaults` or an agent as last loaded from the Gateway.
    public func savedValue(_ field: ExecPolicyField, agent: String?) -> JSONValue? {
        self.saved.value(field, agent: agent)
    }

    /// See `ExecPolicy.gatewayDefault`.
    public func gatewayDefault(_ field: ExecPolicyField) -> JSONValue? {
        ExecPolicy.gatewayDefault(field, saved: self.saved, resolvedDefaults: self.resolvedDefaults)
    }

    /// What agents inherit in the draft.
    public func effectiveDefault(_ field: ExecPolicyField) -> JSONValue? {
        ExecPolicy.effectiveDefault(field, in: self.draft, saved: self.saved, resolvedDefaults: self.resolvedDefaults)
    }

    /// What the agent gets when it doesn't override `field` (from `*` or the defaults).
    public func inheritedValue(_ field: ExecPolicyField, agent: String) -> JSONValue? {
        ExecPolicy.inheritedValue(field, agent: agent, in: self.draft, saved: self.saved,
                                  resolvedDefaults: self.resolvedDefaults)
    }

    /// Whether the agent inherits `field` from the `*` agent rather than the defaults.
    public func inheritsFromWildcard(_ field: ExecPolicyField, agent: String) -> Bool {
        ExecPolicy.wildcardValue(field, agent: agent, in: self.draft) != nil
    }

    public func effectiveValue(_ field: ExecPolicyField, agent: String?) -> JSONValue? {
        ExecPolicy.effectiveValue(field, agent: agent, in: self.draft, saved: self.saved,
                                  resolvedDefaults: self.resolvedDefaults)
    }

    /// The Defaults summary line (D1).
    public var defaultsMode: ExecPolicyMode {
        ExecPolicyMode(security: self.effectiveDefault(.security), ask: self.effectiveDefault(.ask))
    }

    public func mode(agent: String) -> ExecPolicyMode {
        ExecPolicyMode(security: self.effectiveValue(.security, agent: agent), ask: self.effectiveValue(.ask, agent: agent))
    }

    public func agentRows(agents: [AgentSummary]) -> [ExecAgentRow] {
        ExecPolicy.agentRows(file: self.draft, agents: agents)
    }

    public var recentlyAllowed: [ExecRecentEntry] { ExecPolicy.recentlyAllowed(self.draft) }

    public func looseningChanges(agentNames: [String: String] = [:]) -> [String] {
        ExecPolicy.looseningChanges(from: self.saved, to: self.draft, resolvedDefaults: self.resolvedDefaults,
                                    agentNames: agentNames)
    }

    // MARK: Editing

    /// Sets a value of `defaults` (agent nil) or an agent; nil removes it (inherit).
    public func set(_ field: ExecPolicyField, _ value: JSONValue?, agent: String?) {
        self.edit { $0.set(field, value, agent: agent) }
    }

    /// Clears the agent's four overrides; its allowlist and tools stay.
    public func useDefaults(agent: String) {
        self.edit { $0.clearOverrides(agent: agent) }
    }

    public func removeAllowlistEntry(agent: String, at index: Int) {
        self.edit { $0.removeAllowlistEntry(agent: agent, at: index) }
    }

    public func removeMcpTool(agent: String, at index: Int) {
        self.edit { $0.removeMcpTool(agent: agent, at: index) }
    }

    /// Drops the draft.
    public func revert() {
        self.draft = self.saved
        self.pendingLoosening = nil
        if case .rejected = self.banner { self.banner = nil }
    }

    private func edit(_ change: (inout ExecApprovalsFile) -> Void) {
        guard self.snapshot != nil else { return }
        change(&self.draft)
        if self.banner == .conflict { self.banner = nil }
    }

    // MARK: Loading

    /// Loads the file unless it's loaded already (or a draft is being edited).
    public func loadIfNeeded() async {
        guard !self.hasLoaded || (self.snapshot == nil && !self.needsAdmin && self.supported) else { return }
        await self.load()
    }

    /// Fetches the file. With a draft, nothing changes unless `discardingDraft`.
    public func load(discardingDraft: Bool = false) async {
        if self.hasChanges, !discardingDraft { return }
        if let methods = self.methods(), !methods.isEmpty, !methods.contains(ExecPolicy.getMethod) {
            self.markUnsupported()
            return
        }
        self.generation += 1
        let generation = self.generation
        let draftBefore = self.draft
        self.loadState = .running
        do {
            let result = try await self.request(ExecPolicy.getMethod, [:])
            guard generation == self.generation else { return }
            // Edits made while the request was in flight win: keep them and the snapshot they're based on.
            if !discardingDraft, self.draft != draftBefore {
                self.loadState = .idle
                self.hasLoaded = true
                return
            }
            self.apply(ExecApprovalsSnapshot(result))
            self.supported = true
            self.needsAdmin = false
            self.loadState = .idle
            if case .failed(_, retrySave: false) = self.banner { self.banner = nil }
        } catch {
            guard generation == self.generation else { return }
            switch ExecPolicyError.classify(error) {
            case .needsAdmin:
                self.needsAdmin = true
                self.loadState = .idle
            case .unsupported:
                self.markUnsupported()
            case let .validation(message), let .other(message):
                self.loadState = .failed(message)
                if self.snapshot != nil { self.banner = .failed(message, retrySave: false) }
            case .conflict:
                self.loadState = .failed(ExecPolicy.conflictMessage)
            }
        }
        self.hasLoaded = true
    }

    private func apply(_ snapshot: ExecApprovalsSnapshot) {
        self.snapshot = snapshot
        self.draft = snapshot.file
        self.pendingLoosening = nil
    }

    private func markUnsupported() {
        self.supported = false
        self.snapshot = nil
        self.draft = ExecApprovalsFile(nil)
        self.loadState = .idle
        self.hasLoaded = true
    }

    /// An approval was resolved (maybe Always allow): reload when there's no draft.
    func handleApprovalResolved() { self.scheduleRefresh() }

    /// Reconnected: reload when there's no draft.
    func handleReconnect() { self.scheduleRefresh(reconnected: true) }

    private func scheduleRefresh(reconnected: Bool = false) {
        // A reconnect may bring new scopes or a newer Gateway, so it retries those states too.
        guard self.hasLoaded, !self.hasChanges, reconnected || (self.supported && !self.needsAdmin) else { return }
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !self.hasChanges, !self.isSaving else { return }
            await self.load()
        }
    }

    // MARK: Saving

    /// Saves the draft with `exec.approvals.set`. Loosening changes aren't sent until confirmed:
    /// the first call returns `.needsConfirmation` (and sets `pendingLoosening`).
    @discardableResult
    public func save(allowLoosening: Bool = false, agentNames: [String: String] = [:]) async -> ExecPolicySaveResult {
        guard let snapshot = self.snapshot, self.hasChanges else { return .noChanges }
        guard !self.isSaving else { return .noChanges }
        guard self.canWrite else {
            self.banner = .notice(self.readOnlyReason ?? "This device can't change the command policy.")
            return .failed(.needsAdmin)
        }
        let loosening = self.looseningChanges(agentNames: agentNames)
        if !loosening.isEmpty, !allowLoosening {
            self.pendingLoosening = loosening
            return .needsConfirmation(loosening)
        }
        self.pendingLoosening = nil
        self.banner = nil
        self.saveState = .running
        let draft = self.draft
        do {
            let result = try await self.request(ExecPolicy.setMethod, ExecPolicy.setParams(draft: draft, snapshot: snapshot))
            self.generation += 1
            self.saveState = .idle
            if result["file"]?.object != nil {
                self.apply(ExecApprovalsSnapshot(result))
            } else {
                self.draft = draft
                await self.load(discardingDraft: true)
            }
            self.lastSave = UUID()
            return .saved
        } catch {
            let kind = ExecPolicyError.classify(error)
            self.saveState = .idle
            switch kind {
            case .conflict:
                await self.load(discardingDraft: true)
                self.draft = self.saved
                if let message = self.loadState.error {
                    // The reload failed, so the latest version isn't shown.
                    self.banner = .failed(
                        "The command policy changed on the Gateway, so your changes weren't saved, and the latest version couldn't be loaded: \(message)",
                        retrySave: false)
                } else {
                    self.banner = .conflict
                }
                return .conflict
            case let .validation(message):
                self.saveState = .failed(message)
                self.banner = .rejected(message)
            case .needsAdmin:
                self.saveState = .failed(ExecPolicy.needsAdminMessage)
                self.banner = .notice(ExecPolicy.needsAdminMessage)
            case .unsupported:
                self.setRejectedAsUnknown = true
                let message = "This gateway can't change its command policy. Update OpenClaw to manage it here."
                self.saveState = .failed(message)
                self.banner = .notice(message)
            case let .other(message):
                self.saveState = .failed(message)
                self.banner = .failed(message, retrySave: true)
            }
            return .failed(kind)
        }
    }

    public func dismissBanner() { self.banner = nil }
}
