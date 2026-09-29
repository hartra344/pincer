import Foundation

// Skills (`skills.status/search/detail/install/update`). Browsing needs `operator.read`; installs,
// updates and skill config (enable/disable, API key, env) need `operator.admin` (Full Management).
// The Gateway sends no event when skills change, so every mutation re-runs `skills.status`.

// MARK: Constants and pure logic

public enum Skills {
    public static let statusMethod = "skills.status"
    public static let searchMethod = "skills.search"
    public static let detailMethod = "skills.detail"
    public static let installMethod = "skills.install"
    public static let updateMethod = "skills.update"
    public static let forceRequiredCode = "force_required"

    public static let needsAdminMessage = "You can view skills. Turn on Full Management under Connection, then approve this device on the Gateway host."
    public static let unsupportedMessage = "This Gateway can't manage skills. Update OpenClaw to install and configure skills here."
    public static let installWarning = "This downloads the skill into the default agent's workspace on the Gateway host. Skills can run commands and read files with the agent's permissions. Only install skills you trust."

    /// Ready, Needs Setup, Blocked, Disabled, each sorted by name; empty sections are left out.
    /// `filter` matches the name, description or key, ignoring case.
    public static func sections(_ skills: [SkillStatusEntry], filter: String = "") -> [SkillSection] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? skills : skills.filter { $0.matches(query) }
        return SkillState.allCases.compactMap { state in
            let members = matching.filter { $0.state == state }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return members.isEmpty ? nil : SkillSection(state: state, skills: members)
        }
    }

    /// The installed skill a registry result refers to, matched by ClawHub slug (and owner when both know it).
    public static func installedSkill(for result: ClawHubSearchResult, in skills: [SkillStatusEntry]) -> SkillStatusEntry? {
        skills.first { skill in
            guard let link = skill.clawhub, link.slug == result.slug else { return false }
            if let owner = result.ownerHandle, let linked = link.ownerHandle { return owner.caseInsensitiveCompare(linked) == .orderedSame }
            return true
        }
    }

    /// Whether a registry result is installed, and whether ClawHub has a newer version.
    public static func installState(for result: ClawHubSearchResult, in skills: [SkillStatusEntry]) -> ClawHubInstallState {
        guard let skill = self.installedSkill(for: result, in: skills) else { return .notInstalled }
        let installed = skill.clawhub?.installedVersion
        if let installed, let latest = result.version, self.isNewer(latest, than: installed) {
            return .updateAvailable(installed: installed, latest: latest)
        }
        return .installed(version: installed)
    }

    /// The ClawHub install confirmation's message; `agentName` nil (or the default agent) keeps "the default agent's".
    public static func installMessage(agentName: String? = nil) -> String {
        guard let agentName else { return self.installWarning }
        return self.installWarning.replacingOccurrences(of: "the default agent's workspace", with: "\(agentName)'s workspace")
    }

    /// The installer confirmation's title.
    public static func installerTitle(_ option: SkillInstallOption) -> String { "Run installer “\(option.label)” on the Gateway host?" }
    public static func clawHubInstallTitle(_ name: String) -> String { "Install “\(name)” from ClawHub?" }
    public static func updateTitle(_ name: String) -> String { "Update “\(name)”?" }
    public static func forceReplaceMessage(_ name: String) -> String { "\(name) was changed locally since it was installed. Replace it anyway?" }
    public static func reinstallTitle(_ name: String) -> String { "Reinstall “\(name)”?" }
    public static func reinstallMessage(_ name: String) -> String {
        "This replaces the installed copy of “\(name)”, including any changes made on the Gateway."
    }
    /// `skills.update` config mode writes the Gateway-wide `skills.entries.<key>`, not per agent.
    public static let settingsScopeFooter = "Enabled, API key and environment values apply to every agent on this Gateway."

    /// ClawHub trust warnings in a successful `skills.install` (`warning`) or `skills.update`
    /// (`config.results[].warning`) response.
    public static func trustWarnings(response: JSONValue) -> [String] {
        var warnings: [String] = []
        if let warning = response["warning"]?.text { warnings.append(warning) }
        for result in response["config"]?["results"]?.array ?? [] {
            if let warning = result["warning"]?.text { warnings.append(warning) }
        }
        return Self.unique(warnings)
    }

    /// ClawHub trust warnings in a failed install (`details.warning`) or update (`details.warnings`,
    /// `details.results[].warning`).
    public static func trustWarnings(error: Error) -> [String] {
        guard case let GatewayError.rpc(_, _, details) = error, let details else { return [] }
        var warnings: [String] = []
        if let warning = details["warning"]?.text { warnings.append(warning) }
        warnings += (details["warnings"]?.array ?? []).compactMap(\.text)
        for result in details["results"]?.array ?? [] {
            if let warning = result["warning"]?.text { warnings.append(warning) }
        }
        return Self.unique(warnings)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// Semver-ish comparison ("1.10.0" > "1.9.2"); falls back to string inequality.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            let core = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first ?? ""
            let numbers = core.split(separator: ".").map { Int($0) }
            return numbers.contains(where: { $0 == nil }) || numbers.isEmpty ? nil : numbers.compactMap(\.self)
        }
        guard let lhs = parts(candidate), let rhs = parts(current) else { return candidate != current }
        for index in 0 ..< max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Whether an install or update failed because the skill was changed locally and needs `force`.
    public static func forceRequired(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(_, message, details) = error else { return false }
        if details?["code"]?.text == forceRequiredCode { return true }
        if details?["details"]?["code"]?.text == forceRequiredCode { return true }
        let results = details?["results"]?.array ?? details?["details"]?["results"]?.array ?? []
        if results.contains(where: { $0["code"]?.text == forceRequiredCode }) { return true }
        return message.contains(forceRequiredCode)
    }

    /// A readable OS name for requirement text ("darwin" → "macOS").
    public static func osName(_ os: String) -> String {
        switch os.lowercased() {
        case "darwin", "macos": "macOS"
        case "linux": "Linux"
        case "win32", "windows": "Windows"
        default: os
        }
    }
}

public enum SkillState: String, CaseIterable, Hashable, Sendable {
    case ready, needsSetup, blocked, disabled

    public var title: String {
        switch self {
        case .ready: "Ready"
        case .needsSetup: "Needs Setup"
        case .blocked: "Blocked"
        case .disabled: "Disabled"
        }
    }
}

public enum SkillSourceKind: Hashable, Sendable {
    case bundled, workspace, managed, clawhub, extra
    case other(String)

    public var label: String {
        switch self {
        case .bundled: "Bundled"
        case .workspace: "Workspace"
        case .managed: "Managed"
        case .clawhub: "ClawHub"
        case .extra: "Extra"
        case let .other(raw): raw.hasPrefix("openclaw-") ? String(raw.dropFirst("openclaw-".count)).capitalized : raw
        }
    }
}

public struct SkillRequirements: Hashable, Sendable {
    public var bins: [String]
    public var anyBins: [String]
    public var env: [String]
    public var config: [String]
    public var os: [String]

    public init(bins: [String] = [], anyBins: [String] = [], env: [String] = [], config: [String] = [], os: [String] = []) {
        self.bins = bins
        self.anyBins = anyBins
        self.env = env
        self.config = config
        self.os = os
    }

    public init(_ json: JSONValue?) {
        func list(_ key: String) -> [String] { json?[key]?.array?.compactMap(\.text) ?? [] }
        self.init(bins: list("bins"), anyBins: list("anyBins"), env: list("env"), config: list("config"), os: list("os"))
    }

    public var isEmpty: Bool {
        self.bins.isEmpty && self.anyBins.isEmpty && self.env.isEmpty && self.config.isEmpty && self.os.isEmpty
    }
}

public struct SkillConfigCheck: Hashable, Sendable {
    public let path: String
    public let satisfied: Bool
}

/// One ✓/✗ row of a skill's requirements checklist.
public struct SkillRequirementCheck: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case bin, anyBins, env, config, os }
    public let kind: Kind
    public let name: String
    public let satisfied: Bool
    public var id: String { "\(self.kind.rawValue):\(self.name)" }

    /// "Binary ffmpeg", "Environment GITHUB_TOKEN"…
    public var label: String {
        switch self.kind {
        case .bin: "Binary \(self.name)"
        case .anyBins: "One of \(self.name)"
        case .env: "Environment \(self.name)"
        case .config: "Config \(self.name)"
        case .os: "Platform \(self.name)"
        }
    }
}

/// A gateway-side installer for a skill's dependencies (`install[]`, run by `skills.install {name, installId}`).
public struct SkillInstallOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let label: String
    public let bins: [String]

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.kind = json["kind"]?.text ?? ""
        self.label = json["label"]?.text ?? id
        self.bins = json["bins"]?.array?.compactMap(\.text) ?? []
    }

    public init(id: String, kind: String, label: String, bins: [String] = []) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bins = bins
    }
}

/// Where a skill came from on ClawHub (`clawhub` on a status entry).
public struct SkillClawHubLink: Hashable, Sendable {
    public let valid: Bool
    public let status: String?
    public let registry: String?
    public let slug: String?
    public let ownerHandle: String?
    public let installedVersion: String?
    /// Milliseconds since 1970.
    public let installedAt: Double?
    /// Why the link is invalid.
    public let reason: String?

    init(_ json: JSONValue) {
        self.status = json["status"]?.text
        self.valid = json["valid"]?.bool ?? (self.status == "linked")
        self.registry = json["registry"]?.text
        self.slug = json["slug"]?.text
        self.ownerHandle = json["ownerHandle"]?.text
        self.installedVersion = json["installedVersion"]?.text ?? json["version"]?.text
        self.installedAt = json["installedAt"]?.double
        self.reason = json["reason"]?.text
    }
}

/// One discovered skill (`skills.status` → `skills[]`).
public struct SkillStatusEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let source: String
    public let skillKey: String
    public let filePath: String?
    public let baseDir: String?
    public let primaryEnv: String?
    public let emoji: String?
    public let homepage: String?
    public let bundled: Bool
    public let always: Bool
    public let disabled: Bool
    public let blockedByAllowlist: Bool
    public let blockedByAgentFilter: Bool
    public let eligible: Bool
    public let platformIncompatible: Bool
    public let modelVisible: Bool
    public let userInvocable: Bool
    public let requirements: SkillRequirements
    public let missing: SkillRequirements
    public let configChecks: [SkillConfigCheck]
    public let install: [SkillInstallOption]
    public let clawhub: SkillClawHubLink?

    public var id: String { self.skillKey }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let key = json["skillKey"]?.text ?? json["name"]?.text else { return nil }
        self.skillKey = key
        self.name = json["name"]?.text ?? key
        self.description = json["description"]?.text ?? ""
        self.source = json["source"]?.text ?? ""
        self.filePath = json["filePath"]?.text
        self.baseDir = json["baseDir"]?.text
        self.primaryEnv = json["primaryEnv"]?.text
        self.emoji = json["emoji"]?.text
        self.homepage = json["homepage"]?.text
        self.bundled = json["bundled"]?.bool ?? (self.source == "openclaw-bundled")
        self.always = json["always"]?.bool ?? false
        self.disabled = json["disabled"]?.bool ?? false
        self.blockedByAllowlist = json["blockedByAllowlist"]?.bool ?? false
        self.blockedByAgentFilter = json["blockedByAgentFilter"]?.bool ?? false
        self.eligible = json["eligible"]?.bool ?? false
        self.platformIncompatible = json["platformIncompatible"]?.bool ?? false
        self.modelVisible = json["modelVisible"]?.bool ?? true
        self.userInvocable = json["userInvocable"]?.bool ?? false
        self.requirements = SkillRequirements(json["requirements"])
        self.missing = SkillRequirements(json["missing"])
        self.configChecks = json["configChecks"]?.array?.compactMap { check in
            check["path"]?.text.map { SkillConfigCheck(path: $0, satisfied: check["satisfied"]?.bool ?? false) }
        } ?? []
        self.install = json["install"]?.array?.compactMap(SkillInstallOption.init) ?? []
        self.clawhub = json["clawhub"].flatMap { $0.object == nil ? nil : SkillClawHubLink($0) }
    }

    public var state: SkillState {
        if self.disabled { return .disabled }
        if self.blockedByAllowlist || self.blockedByAgentFilter { return .blocked }
        if self.eligible { return .ready }
        return .needsSetup
    }

    public var sourceKind: SkillSourceKind {
        if self.clawhub != nil { return .clawhub }
        if self.bundled { return .bundled }
        switch self.source {
        case "openclaw-bundled": return .bundled
        case "openclaw-workspace": return .workspace
        case "openclaw-managed": return .managed
        case "openclaw-extra": return .extra
        default: return .other(self.source.isEmpty ? "Other" : self.source)
        }
    }

    /// Tracked on ClawHub, so `skills.update {source: clawhub}` can refresh it.
    public var isClawHubTracked: Bool { self.clawhub?.valid == true && self.clawhub?.slug != nil }

    /// Why the skill isn't ready, most important first. Empty when ready.
    public var reasons: [String] {
        var reasons: [String] = []
        if self.disabled { reasons.append("Disabled") }
        if self.blockedByAllowlist { reasons.append("Blocked by skills allowlist") }
        if self.blockedByAgentFilter { reasons.append("Blocked by agent skill filter") }
        reasons += self.missing.bins.map { "Missing binary: \($0)" }
        if !self.missing.anyBins.isEmpty { reasons.append("Needs one of: \(self.missing.anyBins.joined(separator: ", "))") }
        reasons += self.missing.env.map { "Needs env \($0)" }
        reasons += self.missing.config.map { "Needs config \($0)" }
        if !self.missing.os.isEmpty {
            reasons.append("Only on \(self.missing.os.map(Skills.osName).joined(separator: ", "))")
        } else if self.platformIncompatible {
            reasons.append("Not available on this platform")
        }
        if reasons.isEmpty, !self.eligible { reasons.append("Requirements not met") }
        if let link = self.clawhub, !link.valid, let reason = link.reason { reasons.append("ClawHub link invalid: \(reason)") }
        return reasons
    }

    /// The row subtitle for a skill that isn't ready.
    public var primaryReason: String? { self.state == .ready ? nil : self.reasons.first }

    /// The ✓/✗ checklist: every requirement, satisfied unless it's in `missing`.
    public var requirementChecks: [SkillRequirementCheck] {
        var checks: [SkillRequirementCheck] = []
        checks += self.requirements.bins.map { .init(kind: .bin, name: $0, satisfied: !self.missing.bins.contains($0)) }
        if !self.requirements.anyBins.isEmpty {
            checks.append(.init(kind: .anyBins, name: self.requirements.anyBins.joined(separator: ", "),
                                satisfied: self.missing.anyBins.isEmpty))
        }
        checks += self.requirements.env.map { .init(kind: .env, name: $0, satisfied: !self.missing.env.contains($0)) }
        let configSatisfied = Dictionary(self.configChecks.map { ($0.path, $0.satisfied) }, uniquingKeysWith: { a, _ in a })
        checks += self.requirements.config.map {
            .init(kind: .config, name: $0, satisfied: configSatisfied[$0] ?? !self.missing.config.contains($0))
        }
        checks += self.requirements.os.map {
            .init(kind: .os, name: Skills.osName($0), satisfied: self.missing.os.isEmpty && !self.platformIncompatible)
        }
        return checks
    }

    /// The env var the API key field sets (`primaryEnv`), or nil when the skill takes none.
    public var apiKeyEnv: String? { self.primaryEnv }

    /// Whether the API key's env var is currently satisfied (never the value itself).
    public var apiKeyIsSet: Bool {
        guard let env = self.primaryEnv else { return false }
        return !self.missing.env.contains(env)
    }

    func matches(_ query: String) -> Bool {
        self.name.localizedCaseInsensitiveContains(query) || self.description.localizedCaseInsensitiveContains(query)
            || self.skillKey.localizedCaseInsensitiveContains(query)
    }
}

public struct SkillSection: Identifiable, Hashable, Sendable {
    public let state: SkillState
    public let skills: [SkillStatusEntry]
    public var id: SkillState { self.state }
}

/// `skills.status` for one agent.
public struct SkillStatusReport: Hashable, Sendable {
    public let workspaceDir: String?
    public let managedSkillsDir: String?
    public let agentId: String?
    public let agentSkillFilter: [String]?
    public let skills: [SkillStatusEntry]

    public init(_ json: JSONValue) {
        self.workspaceDir = json["workspaceDir"]?.text
        self.managedSkillsDir = json["managedSkillsDir"]?.text
        self.agentId = json["agentId"]?.text
        self.agentSkillFilter = json["agentSkillFilter"]?.array?.compactMap(\.text)
        self.skills = json["skills"]?.array?.compactMap(SkillStatusEntry.init) ?? []
    }
}

// MARK: ClawHub

/// One `skills.search` result. `installRef` is what install and detail take as `slug`.
public struct ClawHubSearchResult: Identifiable, Hashable, Sendable {
    public let slug: String
    public let registry: String?
    public let ownerHandle: String?
    public let installRef: String
    /// ClawHub can't show details for it; offer install directly.
    public let installOnly: Bool
    public let trustState: String?
    public let displayName: String
    public let summary: String?
    public let version: String?
    /// Milliseconds since 1970.
    public let updatedAt: Double?
    public let score: Double

    public var id: String { self.installRef }

    public init?(_ json: JSONValue) {
        guard let slug = json["slug"]?.text else { return nil }
        self.slug = slug
        self.registry = json["registry"]?.text
        self.ownerHandle = json["ownerHandle"]?.text
        self.installRef = json["installRef"]?.text ?? slug
        self.installOnly = json["installOnly"]?.bool ?? false
        self.trustState = json["trustState"]?.text
        self.displayName = json["displayName"]?.text ?? slug
        self.summary = json["summary"]?.text
        self.version = json["version"]?.text
        self.updatedAt = json["updatedAt"]?.double
        self.score = json["score"]?.double ?? 0
    }

    /// ClawHub hasn't scanned the source (`trustState`).
    public var isUnscanned: Bool { self.trustState != nil }
}

/// `skills.detail`.
public struct ClawHubSkillDetail: Hashable, Sendable {
    public let slug: String?
    public let displayName: String?
    public let summary: String?
    public let isOfficial: Bool
    public let tags: [String: String]
    /// Milliseconds since 1970.
    public let updatedAt: Double?
    public let latestVersion: String?
    public let changelog: String?
    public let os: [String]
    public let ownerHandle: String?
    public let ownerName: String?

    public init(_ json: JSONValue) {
        let skill = json["skill"]
        self.slug = skill?["slug"]?.text
        self.displayName = skill?["displayName"]?.text
        self.summary = skill?["summary"]?.text
        self.isOfficial = skill?["isOfficial"]?.bool ?? json["owner"]?["isOfficial"]?.bool ?? json["owner"]?["official"]?.bool ?? false
        self.tags = (skill?["tags"]?.object ?? [:]).compactMapValues(\.text)
        self.updatedAt = skill?["updatedAt"]?.double
        self.latestVersion = json["latestVersion"]?["version"]?.text
        self.changelog = json["latestVersion"]?["changelog"]?.text
        self.os = json["metadata"]?["os"]?.array?.compactMap(\.text) ?? []
        self.ownerHandle = json["owner"]?["handle"]?.text
        self.ownerName = json["owner"]?["displayName"]?.text
    }
}

public enum ClawHubInstallState: Hashable, Sendable {
    case notInstalled
    case installed(version: String?)
    case updateAvailable(installed: String, latest: String)

    public var label: String? {
        switch self {
        case .notInstalled: nil
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        }
    }
}

/// What a skill mutation did.
public enum SkillActionResult: Equatable, Sendable {
    /// Success, with a short message ("Installed weather").
    case done(String)
    /// The skill changed locally since install; retry with `force` after confirming.
    case forceRequired(String)
    case failed(String)

    public var message: String {
        switch self {
        case let .done(message), let .forceRequired(message), let .failed(message): message
        }
    }
}

// MARK: Model

/// Skills for one Gateway (`GatewayStore.skills`): the per-agent status list, ClawHub search, and
/// installs, updates and config. Every successful mutation reloads `skills.status`.
@MainActor
@Observable
public final class SkillsModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// The agent the list is for; nil is the Gateway's default.
    public private(set) var agentId: String?
    public private(set) var report: SkillStatusReport?
    public private(set) var isLoading = false
    public private(set) var loadError: String?

    public private(set) var searchResults: [ClawHubSearchResult] = []
    /// The query `searchResults` answer; nil before any search.
    public private(set) var searchedQuery: String?
    public private(set) var isSearching = false
    public private(set) var searchError: String?

    /// Skill keys or install refs with a mutation in flight.
    public private(set) var busy: Set<String> = []
    /// The last mutation's success message.
    public private(set) var lastMessage: String?
    /// The last mutation's error.
    public private(set) var actionError: String?
    /// ClawHub trust warnings from the last install or update, success or failure.
    public private(set) var lastWarnings: [String] = []

    /// Set when a call hit a scope error, although the connection claimed `operator.admin`.
    public private(set) var deniedAdmin = false
    /// Methods the Gateway answered with unknown-method.
    public private(set) var rejectedMethods: Set<String> = []

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var inFlightQuery: String?

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, allowsWritesWithoutAdmin: Bool) {
        self.request = { method, params in try await connection.request(method, params, timeout: method == Skills.installMethod || method == Skills.updateMethod ? 180 : 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    /// For checks and previews. `methods` is the advertised method list (nil or empty when
    /// unknown), `scopes` the connection's scopes.
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

    // MARK: Capability

    /// Whether the Gateway has `method`: advertised (or the list is unknown) and not rejected.
    public func supports(_ method: String) -> Bool {
        if self.rejectedMethods.contains(method) { return false }
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    public var supportsStatus: Bool { self.supports(Skills.statusMethod) }
    public var supportsSearch: Bool { self.supports(Skills.searchMethod) }
    public var supportsDetail: Bool { self.supports(Skills.detailMethod) }
    public var supportsInstall: Bool { self.supports(Skills.installMethod) }
    public var supportsUpdate: Bool { self.supports(Skills.updateMethod) }

    /// Full Management (or the demo).
    public var hasAdmin: Bool {
        if self.allowsWritesWithoutAdmin { return true }
        return !self.deniedAdmin && self.scopes().contains(GatewayConnection.adminScope)
    }

    public var canInstall: Bool { self.hasAdmin && self.supportsInstall }
    public var canUpdate: Bool { self.hasAdmin && self.supportsUpdate }

    /// Why install/update/config controls are off, or nil when they're allowed.
    public var readOnlyReason: String? {
        if !self.hasAdmin { return Skills.needsAdminMessage }
        if !self.supportsInstall, !self.supportsUpdate { return Skills.unsupportedMessage }
        return nil
    }

    public var skills: [SkillStatusEntry] { self.report?.skills ?? [] }

    public func sections(filter: String = "") -> [SkillSection] { Skills.sections(self.skills, filter: filter) }

    public func skill(key: String) -> SkillStatusEntry? { self.skills.first { $0.skillKey == key } }

    public func installState(for result: ClawHubSearchResult) -> ClawHubInstallState {
        Skills.installState(for: result, in: self.skills)
    }

    /// The installed skill a ClawHub result tracks, if any.
    public func installedSkill(for result: ClawHubSearchResult) -> SkillStatusEntry? {
        Skills.installedSkill(for: result, in: self.skills)
    }

    // MARK: Loading

    /// Loads `skills.status` for `agentId` (nil: the Gateway default).
    public func load(agentId: String?) async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        if agentId != self.agentId {
            self.report = nil
            self.clearMessages()
        }
        self.agentId = agentId
        self.isLoading = true
        self.loadError = nil
        defer { if generation == self.loadGeneration { self.isLoading = false } }
        do {
            let result = try await self.call(Skills.statusMethod, agentId.map { ["agentId": .string($0)] } ?? [:])
            guard generation == self.loadGeneration else { return }
            self.report = SkillStatusReport(result)
        } catch {
            guard generation == self.loadGeneration else { return }
            self.loadError = Self.message(error)
        }
    }

    /// Loads once per agent; a no-op when that agent's list is already here.
    public func loadIfNeeded(agentId: String?) async {
        if self.report != nil, self.agentId == agentId, self.loadError == nil { return }
        await self.load(agentId: agentId)
    }

    public func reload() async { await self.load(agentId: self.agentId) }

    /// Searches ClawHub. An empty query clears the results.
    public func search(_ query: String, limit: Int = 25) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Submit while the debounced search for the same text is running: don't send it twice.
        if self.isSearching, !trimmed.isEmpty, trimmed == self.inFlightQuery { return }
        self.searchGeneration += 1
        let generation = self.searchGeneration
        guard !trimmed.isEmpty else {
            self.searchResults = []
            self.searchedQuery = nil
            self.searchError = nil
            self.isSearching = false
            self.inFlightQuery = nil
            return
        }
        self.isSearching = true
        self.inFlightQuery = trimmed
        self.searchError = nil
        defer {
            if generation == self.searchGeneration {
                self.isSearching = false
                self.inFlightQuery = nil
            }
        }
        do {
            let result = try await self.call(Skills.searchMethod, ["query": .string(trimmed), "limit": .number(Double(limit))])
            guard generation == self.searchGeneration else { return }
            self.searchResults = result["results"]?.array?.compactMap(ClawHubSearchResult.init) ?? []
            self.searchedQuery = trimmed
        } catch {
            guard generation == self.searchGeneration else { return }
            self.searchResults = []
            self.searchedQuery = trimmed
            self.searchError = Self.message(error)
        }
    }

    public func detail(_ installRef: String) async throws -> ClawHubSkillDetail {
        ClawHubSkillDetail(try await self.call(Skills.detailMethod, ["slug": .string(installRef)]))
    }

    public func clearMessages() {
        self.lastMessage = nil
        self.actionError = nil
        self.lastWarnings = []
    }

    // MARK: Mutations

    /// Installs a ClawHub result into the current agent's workspace.
    public func installFromClawHub(_ result: ClawHubSearchResult, force: Bool = false) async -> SkillActionResult {
        var params: [String: JSONValue] = ["source": "clawhub", "slug": .string(result.installRef)]
        if let agentId = self.agentId { params["agentId"] = .string(agentId) }
        if force { params["force"] = true }
        return await self.mutate(key: result.installRef, Skills.installMethod, .object(params)) { response in
            let version = response["version"]?.text.map { " \($0)" } ?? ""
            return "Installed \(result.displayName)\(version)"
        }
    }

    /// Runs one of the skill's gateway-side installers (`install[]`).
    public func runInstaller(skill: SkillStatusEntry, option: SkillInstallOption) async -> SkillActionResult {
        var params: [String: JSONValue] = ["name": .string(skill.name), "installId": .string(option.id)]
        if let agentId = self.agentId { params["agentId"] = .string(agentId) }
        return await self.mutate(key: skill.skillKey, Skills.installMethod, .object(params)) { response in
            response["message"]?.text ?? "Ran \(option.label)"
        }
    }

    public func setEnabled(_ skill: SkillStatusEntry, _ enabled: Bool) async -> SkillActionResult {
        await self.mutate(key: skill.skillKey, Skills.updateMethod,
                          ["skillKey": .string(skill.skillKey), "enabled": .bool(enabled)]) { _ in
            "\(enabled ? "Enabled" : "Disabled") \(skill.name)"
        }
    }

    /// Sets the skill's API key (write-only; an empty key clears it).
    public func setApiKey(_ skill: SkillStatusEntry, _ key: String) async -> SkillActionResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return await self.mutate(key: skill.skillKey, Skills.updateMethod,
                                 ["skillKey": .string(skill.skillKey), "apiKey": .string(trimmed)]) { _ in
            trimmed.isEmpty ? "Cleared the API key for \(skill.name)" : "Saved the API key for \(skill.name)"
        }
    }

    /// Sets one env var in the skill's config.
    public func setEnv(_ skill: SkillStatusEntry, name: String, value: String) async -> SkillActionResult {
        let env = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !env.isEmpty else { return .failed("Enter a variable name.") }
        return await self.mutate(key: skill.skillKey, Skills.updateMethod,
                                 ["skillKey": .string(skill.skillKey), "env": .object([env: .string(value)])]) { _ in
            "Saved \(env) for \(skill.name)"
        }
    }

    /// Updates a ClawHub-tracked skill. `.forceRequired` means it was changed locally: confirm, then retry with `force`.
    public func updateFromClawHub(_ skill: SkillStatusEntry, force: Bool = false) async -> SkillActionResult {
        guard let slug = skill.clawhub?.slug else { return .failed("\(skill.name) isn't tracked on ClawHub.") }
        var params: [String: JSONValue] = ["source": "clawhub", "slug": .string(slug)]
        if let agentId = self.agentId { params["agentId"] = .string(agentId) }
        if force { params["force"] = true }
        return await self.mutate(key: skill.skillKey, Skills.updateMethod, .object(params)) { response in
            let first = response["config"]?["results"]?.array?.first
            if first?["changed"]?.bool == false { return "\(skill.name) is up to date" }
            let version = first?["version"]?.text.map { " to \($0)" } ?? ""
            return "Updated \(skill.name)\(version)"
        }
    }

    private func mutate(key: String, _ method: String, _ params: JSONValue,
                        message: (JSONValue) -> String) async -> SkillActionResult
    {
        self.busy.insert(key)
        self.clearMessages()
        defer { self.busy.remove(key) }
        do {
            let response = try await self.call(method, params)
            let text = message(response)
            self.lastMessage = text
            self.lastWarnings = Skills.trustWarnings(response: response)
            await self.reload()
            return .done(text)
        } catch {
            let text = Self.message(error)
            self.lastWarnings = Skills.trustWarnings(error: error)
            if Skills.forceRequired(error) { return .forceRequired(text) }
            self.actionError = text
            return .failed(text)
        }
    }

    // MARK: Plumbing

    func handleReconnect() {
        self.deniedAdmin = false
        self.rejectedMethods = []
        self.report = nil
        self.loadError = nil
        self.searchResults = []
        self.searchedQuery = nil
        self.searchError = nil
    }

    private func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        do {
            return try await self.request(method, params)
        } catch {
            switch AgentManagementError.classify(error) {
            case .needsAdmin: self.deniedAdmin = true
            case .unsupported: self.rejectedMethods.insert(method)
            default: break
            }
            throw error
        }
    }

    private static func message(_ error: Error) -> String {
        switch AgentManagementError.classify(error) {
        case .needsAdmin: Skills.needsAdminMessage
        case .unsupported: Skills.unsupportedMessage
        case let other: other.message
        }
    }
}
