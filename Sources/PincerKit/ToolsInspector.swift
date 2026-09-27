import Foundation

// The effective tools inspector (`tools.catalog`, `tools.effective`, both `operator.read`).
// `tools.catalog` lists every tool an agent could have, with the profiles that include it;
// `tools.effective` needs a session and reports what survives policy for it, with `toolAccess`
// explaining why each excluded tool was dropped.

// MARK: Constants and wording

public enum ToolsPolicy {
    public static let catalogMethod = "tools.catalog"
    public static let effectiveMethod = "tools.effective"
    public static let unsupportedMessage = "This gateway can't report tool policy. Update OpenClaw to see it here."
    public static let policyFootnote = "Change tool policy on the Tools & Skills settings page or in Raw Config."

    /// "Live policy from “Main”." — which chat an agent's inspector read `tools.effective` for.
    public static func livePolicyNote(chatTitle: String) -> String { "Live policy from “\(chatTitle)”." }

    /// A plain-words reason for one exclusion.
    public static func reasonText(_ reason: ToolAccessReason) -> String {
        switch reason.kind {
        case "profile":
            if let profile = reason.profile { return "Not in profile '\(profile)'" }
            return reason.label.isEmpty ? "Not in the selected profile" : "Not in \(reason.label)"
        case "session":
            return reason.label.isEmpty ? "Denied for this session" : reason.label
        default:
            return reason.label.isEmpty ? "Denied by policy" : reason.label
        }
    }

    /// A plain-words banner for an upstream notice.
    public static func noticeText(_ notice: ToolNotice) -> String {
        switch notice.id {
        case "mcp-not-yet-connected": "MCP servers haven't connected yet, so their tools may be missing."
        case "mcp-not-yet-listed": "MCP servers are still listing their tools, so some may be missing."
        case "mcp-stale-catalog": "MCP tools are from an earlier listing and may be out of date."
        default: notice.message
        }
    }
}

public enum ToolSourceKind: Hashable, Sendable {
    case core, plugin, channel, mcp
    case other(String)

    public init(_ raw: String?) {
        switch raw {
        case "core", nil: self = .core
        case "plugin": self = .plugin
        case "channel": self = .channel
        case "mcp": self = .mcp
        case let raw?: self = .other(raw)
        }
    }

    public var label: String {
        switch self {
        case .core: "Core"
        case .plugin: "Plugin"
        case .channel: "Channel"
        case .mcp: "MCP"
        case let .other(raw): raw
        }
    }
}

// MARK: tools.catalog

public struct ToolProfileOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
}

public struct ToolCatalogEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let source: ToolSourceKind
    public let pluginId: String?
    public let optional: Bool
    public let risk: String?
    public let tags: [String]
    public let defaultProfiles: [String]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.label = json["label"]?.text ?? id
        self.description = json["description"]?.text ?? ""
        self.source = ToolSourceKind(json["source"]?.text)
        self.pluginId = json["pluginId"]?.text
        self.optional = json["optional"]?.bool ?? false
        self.risk = json["risk"]?.text
        self.tags = json["tags"]?.array?.compactMap(\.text) ?? []
        self.defaultProfiles = json["defaultProfiles"]?.array?.compactMap(\.text) ?? []
    }

    /// Whether `profile` includes the tool by default ("full" includes everything).
    public func isIn(profile: String) -> Bool {
        profile == "full" || self.defaultProfiles.contains(profile)
    }
}

public struct ToolCatalogGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let source: ToolSourceKind
    public let pluginId: String?
    public let tools: [ToolCatalogEntry]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.label = json["label"]?.text ?? id
        self.source = ToolSourceKind(json["source"]?.text)
        self.pluginId = json["pluginId"]?.text
        self.tools = json["tools"]?.array?.compactMap(ToolCatalogEntry.init) ?? []
    }
}

/// `tools.catalog` for one agent.
public struct ToolCatalog: Hashable, Sendable {
    public let agentId: String?
    public let profiles: [ToolProfileOption]
    public let groups: [ToolCatalogGroup]

    public init(_ json: JSONValue) {
        self.agentId = json["agentId"]?.text
        self.profiles = json["profiles"]?.array?.compactMap { profile in
            profile["id"]?.text.map { ToolProfileOption(id: $0, label: profile["label"]?.text ?? $0) }
        } ?? []
        self.groups = json["groups"]?.array?.compactMap(ToolCatalogGroup.init) ?? []
    }
}

// MARK: tools.effective

public struct EffectiveTool: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let source: ToolSourceKind
    public let pluginId: String?
    public let channelId: String?
    public let mcpServer: String?
    public let deniedBySession: Bool
    public let risk: String?

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.label = json["label"]?.text ?? id
        self.description = json["description"]?.text ?? json["rawDescription"]?.text ?? ""
        self.source = ToolSourceKind(json["source"]?.text)
        self.pluginId = json["pluginId"]?.text
        self.channelId = json["channelId"]?.text
        self.mcpServer = json["mcpServer"]?.text
        self.deniedBySession = json["deniedBySession"]?.bool ?? false
        self.risk = json["risk"]?.text
    }
}

public struct EffectiveToolGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let source: ToolSourceKind
    public let tools: [EffectiveTool]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text ?? json["source"]?.text else { return nil }
        self.id = id
        self.label = json["label"]?.text ?? id
        self.source = ToolSourceKind(json["source"]?.text ?? id)
        self.tools = json["tools"]?.array?.compactMap(EffectiveTool.init) ?? []
    }
}

public struct ToolNotice: Identifiable, Hashable, Sendable {
    public let id: String
    /// `info` or `warning`.
    public let severity: String
    public let message: String
    public let servers: [String]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.severity = json["severity"]?.text ?? "info"
        self.message = json["message"]?.text ?? ""
        self.servers = json["servers"]?.array?.compactMap(\.text) ?? []
    }

    public var isWarning: Bool { self.severity == "warning" }
}

public struct ToolAccessReason: Hashable, Sendable {
    /// `profile`, `deny`, `allowlist`, `session` or `runtime`.
    public let kind: String
    public let label: String
    public let source: String?
    public let profile: String?

    public init(kind: String, label: String, source: String? = nil, profile: String? = nil) {
        self.kind = kind
        self.label = label
        self.source = source
        self.profile = profile
    }

    init(_ json: JSONValue) {
        self.init(kind: json["kind"]?.text ?? "", label: json["label"]?.text ?? "",
                  source: json["source"]?.text, profile: json["profile"]?.text)
    }
}

public enum ToolAccessStatus: Hashable, Sendable {
    case allowed, excluded, available, unavailable
    case other(String)

    public init(_ raw: String?) {
        switch raw {
        case "allowed": self = .allowed
        case "excluded": self = .excluded
        case "available": self = .available
        case "unavailable": self = .unavailable
        default: self = .other(raw ?? "")
        }
    }

    /// Allowed by policy (and, for `available`, present in the live session).
    public var isAllowed: Bool {
        switch self {
        case .allowed, .available: true
        default: false
        }
    }
}

public struct ToolAccess: Identifiable, Hashable, Sendable {
    public let id: String
    public let status: ToolAccessStatus
    public let reasons: [ToolAccessReason]
    public let alsoAllowPath: String?

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.status = ToolAccessStatus(json["status"]?.text)
        self.reasons = json["reasons"]?.array?.map(ToolAccessReason.init) ?? []
        self.alsoAllowPath = json["alsoAllowPath"]?.text
    }
}

public struct ToolAccessProfile: Hashable, Sendable {
    public let profile: String
    public let source: String
    public let active: Bool
}

/// `toolAccess`: which candidate tools policy kept, and why the rest were dropped.
public struct ToolAccessDiagnostics: Hashable, Sendable {
    /// `local-config` or `live-session`.
    public let checked: String?
    public let profiles: [ToolAccessProfile]
    public let tools: [ToolAccess]

    init(_ json: JSONValue) {
        self.checked = json["checked"]?.text
        self.profiles = json["profiles"]?.array?.compactMap { profile in
            profile["profile"]?.text.map {
                ToolAccessProfile(profile: $0, source: profile["source"]?.text ?? "", active: profile["active"]?.bool ?? false)
            }
        } ?? []
        self.tools = json["tools"]?.array?.compactMap(ToolAccess.init) ?? []
    }
}

/// `tools.effective` for one session.
public struct EffectiveTools: Hashable, Sendable {
    public let agentId: String?
    public let profile: String?
    public let groups: [EffectiveToolGroup]
    public let notices: [ToolNotice]
    public let access: ToolAccessDiagnostics?

    public init(_ json: JSONValue) {
        self.agentId = json["agentId"]?.text
        self.profile = json["profile"]?.text
        self.groups = json["groups"]?.array?.compactMap(EffectiveToolGroup.init) ?? []
        self.notices = json["notices"]?.array?.compactMap(ToolNotice.init) ?? []
        self.access = json["toolAccess"].flatMap { $0.object == nil ? nil : ToolAccessDiagnostics($0) }
    }
}

// MARK: Merged view

/// One row of the inspector.
public struct InspectedTool: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let source: ToolSourceKind
    /// The plugin id, channel or MCP server.
    public let sourceDetail: String?
    public let isAllowed: Bool
    /// Why it's denied; empty when allowed.
    public let reasons: [String]
    public let risk: String?

    /// "Core", "Plugin github", "MCP linear".
    public var sourceLabel: String {
        guard let detail = self.sourceDetail, !detail.isEmpty else { return self.source.label }
        return "\(self.source.label) \(detail)"
    }

    /// "Allowed", or the first reason.
    public var statusText: String { self.isAllowed ? "Allowed" : (self.reasons.first ?? "Denied") }

    func matches(_ query: String) -> Bool {
        self.label.localizedCaseInsensitiveContains(query) || self.id.localizedCaseInsensitiveContains(query)
            || self.description.localizedCaseInsensitiveContains(query)
    }
}

public struct InspectedToolGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let tools: [InspectedTool]
}

public enum ToolFilter: String, CaseIterable, Hashable, Sendable {
    case all, allowed, denied

    public var title: String {
        switch self {
        case .all: "All"
        case .allowed: "Allowed"
        case .denied: "Denied"
        }
    }
}

/// The catalog and effective policy merged into grouped rows.
public struct ToolsInspection: Hashable, Sendable {
    public let profile: String?
    /// From a live session (`tools.effective`) rather than the catalog's profile membership alone.
    public let isLive: Bool
    public let groups: [InspectedToolGroup]
    public let notices: [ToolNotice]

    public var allTools: [InspectedTool] { self.groups.flatMap(\.tools) }
    public var totalCount: Int { self.allTools.count }
    public var allowedCount: Int { self.allTools.filter(\.isAllowed).count }

    /// "Profile: coding · 18 of 24 tools allowed".
    public var summary: String {
        let counts = "\(self.allowedCount) of \(self.totalCount) tool\(self.totalCount == 1 ? "" : "s") allowed"
        guard let profile = self.profile else { return counts }
        return "Profile: \(profile) · \(counts)"
    }

    public func filtered(_ filter: ToolFilter, search: String = "") -> [InspectedToolGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.groups.compactMap { group in
            let tools = group.tools.filter { tool in
                switch filter {
                case .all: break
                case .allowed: guard tool.isAllowed else { return false }
                case .denied: guard !tool.isAllowed else { return false }
                }
                return query.isEmpty || tool.matches(query)
            }
            return tools.isEmpty ? nil : InspectedToolGroup(id: group.id, label: group.label, tools: tools)
        }
    }

    public init(profile: String?, isLive: Bool, groups: [InspectedToolGroup], notices: [ToolNotice]) {
        self.profile = profile
        self.isLive = isLive
        self.groups = groups
        self.notices = notices
    }

    /// Merges the two. With `effective`, a tool is allowed when it's in the effective groups (and
    /// not denied for the session) or `toolAccess` says allowed/available; catalog tools missing from
    /// both are denied with `toolAccess`'s reasons. Catalog only: allowed when `profile` includes it.
    public static func build(catalog: ToolCatalog?, effective: EffectiveTools?, profile fallbackProfile: String? = nil) -> ToolsInspection {
        let profile = effective?.profile ?? effective?.access?.profiles.first(where: \.active)?.profile ?? fallbackProfile
        let access = Dictionary((effective?.access?.tools ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var effectiveById: [String: EffectiveTool] = [:]
        for tool in effective?.groups.flatMap(\.tools) ?? [] where effectiveById[tool.id] == nil { effectiveById[tool.id] = tool }

        func deniedReasons(for id: String, entry: ToolCatalogEntry?) -> [String] {
            if effectiveById[id]?.deniedBySession == true { return ["Denied for this session"] }
            if let reasons = access[id]?.reasons, !reasons.isEmpty { return reasons.map(ToolsPolicy.reasonText) }
            if let entry, entry.optional, entry.source == .plugin { return ["Optional plugin tool not enabled"] }
            if let entry, let profile, !entry.isIn(profile: profile) { return ["Not in profile '\(profile)'"] }
            return effective == nil ? [] : ["Not available in this session"]
        }

        func isAllowed(_ id: String, entry: ToolCatalogEntry?) -> Bool {
            if let tool = effectiveById[id] { return !tool.deniedBySession }
            if let state = access[id] { return state.status.isAllowed }
            guard effective == nil else { return false }
            guard let entry else { return true }
            if entry.optional, entry.source == .plugin { return false }
            guard let profile else { return true }
            return entry.isIn(profile: profile)
        }

        func row(_ id: String, catalog entry: ToolCatalogEntry?, effective tool: EffectiveTool?) -> InspectedTool {
            let source = tool?.source ?? entry?.source ?? .core
            let detail = tool?.mcpServer ?? tool?.channelId ?? tool?.pluginId ?? entry?.pluginId
            let allowed = isAllowed(id, entry: entry)
            let reasons = allowed ? [] : deniedReasons(for: id, entry: entry)
            return InspectedTool(id: id, label: tool?.label ?? entry?.label ?? id,
                                 description: tool?.description.isEmpty == false ? tool!.description : (entry?.description ?? ""),
                                 source: source, sourceDetail: detail, isAllowed: allowed,
                                 reasons: allowed ? [] : (reasons.isEmpty ? ["Denied by policy"] : reasons),
                                 risk: tool?.risk ?? entry?.risk)
        }

        var seen = Set<String>()
        var groups: [InspectedToolGroup] = []
        for group in catalog?.groups ?? [] {
            let tools = group.tools.filter { seen.insert($0.id).inserted }.map { row($0.id, catalog: $0, effective: effectiveById[$0.id]) }
            if !tools.isEmpty { groups.append(InspectedToolGroup(id: group.id, label: group.label, tools: tools)) }
        }
        // Effective tools the catalog doesn't list (channel, MCP, plugins when the catalog skipped them).
        for group in effective?.groups ?? [] {
            let tools = group.tools.filter { seen.insert($0.id).inserted }.map { row($0.id, catalog: nil, effective: $0) }
            guard !tools.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index] = InspectedToolGroup(id: group.id, label: groups[index].label, tools: groups[index].tools + tools)
            } else {
                groups.append(InspectedToolGroup(id: group.id, label: group.label, tools: tools))
            }
        }
        // Excluded tools only `toolAccess` knows about.
        let leftovers = (effective?.access?.tools ?? []).filter { seen.insert($0.id).inserted }.map { row($0.id, catalog: nil, effective: nil) }
        if !leftovers.isEmpty { groups.append(InspectedToolGroup(id: "other", label: "Other", tools: leftovers)) }

        return ToolsInspection(profile: profile, isLive: effective != nil, groups: groups, notices: effective?.notices ?? [])
    }
}

// MARK: Model

/// Loads the inspector for one session or agent. Created by `GatewayStore.toolsInspector(…)`.
@MainActor
@Observable
public final class ToolsInspectorModel: Identifiable {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public enum Scope: Hashable, Sendable {
        /// A chat: `tools.effective` for it, with the agent's `tools.catalog` for denied tools' names.
        case session(key: String, agentId: String?)
        /// An agent: `tools.catalog`, plus `tools.effective` for `sessionKey` (its main chat) when given.
        case agent(String, sessionKey: String?)

        public var agentId: String? {
            switch self {
            case let .session(_, agentId): agentId
            case let .agent(id, _): id
            }
        }

        public var sessionKey: String? {
            switch self {
            case let .session(key, _): key
            case let .agent(_, key): key
            }
        }
    }

    public let scope: Scope
    public private(set) var inspection: ToolsInspection?
    public private(set) var catalog: ToolCatalog?
    public private(set) var effective: EffectiveTools?
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Why the policy is catalog-only (no session, or `tools.effective` failed), shown as a note.
    public private(set) var effectiveNote: String?

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private var generation = 0

    public init(scope: Scope, methods: @escaping @MainActor () -> Set<String>? = { nil }, request: @escaping Request) {
        self.scope = scope
        self.methods = methods
        self.request = request
    }

    private func supports(_ method: String) -> Bool {
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    public func loadIfNeeded() async {
        if self.inspection == nil, !self.isLoading { await self.load() }
    }

    public func load() async {
        self.generation += 1
        let generation = self.generation
        self.isLoading = true
        self.error = nil
        defer { if generation == self.generation { self.isLoading = false } }

        var catalog: ToolCatalog?
        var effective: EffectiveTools?
        var catalogError: Error?
        var effectiveError: Error?
        var note: String?

        if self.supports(ToolsPolicy.catalogMethod) {
            var params: [String: JSONValue] = [:]
            if let agentId = self.scope.agentId { params["agentId"] = .string(agentId) }
            do { catalog = ToolCatalog(try await self.request(ToolsPolicy.catalogMethod, .object(params))) } catch { catalogError = error }
        }
        if let sessionKey = self.scope.sessionKey, self.supports(ToolsPolicy.effectiveMethod) {
            var params: [String: JSONValue] = ["sessionKey": .string(sessionKey)]
            if let agentId = self.scope.agentId { params["agentId"] = .string(agentId) }
            do { effective = EffectiveTools(try await self.request(ToolsPolicy.effectiveMethod, .object(params))) } catch { effectiveError = error }
        } else if case .agent = self.scope, self.supports(ToolsPolicy.effectiveMethod) {
            note = "Showing profile defaults. Open a chat with this agent to see its live policy."
        }
        guard generation == self.generation else { return }

        if catalog == nil, effective == nil {
            let failure = effectiveError ?? catalogError
            self.error = failure.map { AgentManagementError.classify($0) == .unsupported ? ToolsPolicy.unsupportedMessage : AgentManagementError.classify($0).message }
                ?? ToolsPolicy.unsupportedMessage
            return
        }
        if let effectiveError, catalog != nil {
            note = "Couldn't read this chat's live policy (\(AgentManagementError.classify(effectiveError).message)). Showing profile defaults."
        }
        self.catalog = catalog
        self.effective = effective
        self.effectiveNote = note
        self.inspection = ToolsInspection.build(catalog: catalog, effective: effective)
    }
}
