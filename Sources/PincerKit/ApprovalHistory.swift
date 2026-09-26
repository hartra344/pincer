import Foundation

// MARK: Records

/// One approval from the Gateway's durable ledger (`approval.history` / `approval.get`): what was
/// asked, by which agent and chat, how it ended and who decided. Decoding is tolerant: only `id`
/// is required, and unknown kinds, statuses and reasons are kept as they came.
public struct ApprovalRecord: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case exec
        case plugin
        case systemAgent
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "exec": self = .exec
            case "plugin": self = .plugin
            case "system-agent", "system": self = .systemAgent
            default: self = .other(raw)
            }
        }

        public var rawValue: String {
            switch self {
            case .exec: "exec"
            case .plugin: "plugin"
            case .systemAgent: "system-agent"
            case let .other(raw): raw
            }
        }

        public var label: String {
            switch self {
            case .exec: "Command"
            case .plugin: "Plugin"
            case .systemAgent: "System change"
            case let .other(raw): ApprovalRecord.humanized(raw)
            }
        }
    }

    public enum Status: Hashable, Sendable {
        case allowed
        case denied
        case expired
        case cancelled
        case pending
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "allowed": self = .allowed
            case "denied": self = .denied
            case "expired": self = .expired
            case "cancelled", "canceled": self = .cancelled
            case "pending": self = .pending
            default: self = .other(raw)
            }
        }

        public var rawValue: String {
            switch self {
            case .allowed: "allowed"
            case .denied: "denied"
            case .expired: "expired"
            case .cancelled: "cancelled"
            case .pending: "pending"
            case let .other(raw): raw
            }
        }

        public var label: String {
            switch self {
            case .allowed: "Allowed"
            case .denied: "Denied"
            case .expired: "Expired"
            case .cancelled: "Cancelled"
            case .pending: "Pending"
            case let .other(raw): ApprovalRecord.humanized(raw)
            }
        }
    }

    public enum Decision: Hashable, Sendable {
        case allowOnce
        case allowAlways
        case deny
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "allow-once": self = .allowOnce
            case "allow-always": self = .allowAlways
            case "deny": self = .deny
            default: self = .other(raw)
            }
        }

        public var rawValue: String {
            switch self {
            case .allowOnce: "allow-once"
            case .allowAlways: "allow-always"
            case .deny: "deny"
            case let .other(raw): raw
            }
        }

        public var label: String {
            switch self {
            case .allowOnce: "Allowed once"
            case .allowAlways: "Always allowed"
            case .deny: "Denied"
            case let .other(raw): ApprovalRecord.humanized(raw)
            }
        }
    }

    public enum Reason: Hashable, Sendable {
        case user
        case timeout
        case malformedVerdict
        case noRoute
        case runAborted
        case gatewayRestart
        case storageCorrupt
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "user": self = .user
            case "timeout": self = .timeout
            case "malformed-verdict": self = .malformedVerdict
            case "no-route": self = .noRoute
            case "run-aborted": self = .runAborted
            case "gateway-restart": self = .gatewayRestart
            case "storage-corrupt": self = .storageCorrupt
            default: self = .other(raw)
            }
        }

        public var rawValue: String {
            switch self {
            case .user: "user"
            case .timeout: "timeout"
            case .malformedVerdict: "malformed-verdict"
            case .noRoute: "no-route"
            case .runAborted: "run-aborted"
            case .gatewayRestart: "gateway-restart"
            case .storageCorrupt: "storage-corrupt"
            case let .other(raw): raw
            }
        }

        /// A few words, for the status capsule ("Denied · No reviewer").
        public var shortLabel: String {
            switch self {
            case .user: "Reviewer"
            case .timeout: "Timed out"
            case .malformedVerdict: "Invalid response"
            case .noRoute: "No reviewer"
            case .runAborted: "Run stopped"
            case .gatewayRestart: "Gateway restarted"
            case .storageCorrupt: "Storage error"
            case let .other(raw): ApprovalRecord.humanized(raw)
            }
        }

        /// A sentence, for the detail view.
        public var explanation: String {
            switch self {
            case .user: "Someone decided."
            case .timeout: "No one answered in time."
            case .malformedVerdict: "The reviewer's response couldn't be understood, so it was denied."
            case .noRoute: "There was no one to ask, so it was denied."
            case .runAborted: "The run that asked was stopped."
            case .gatewayRestart: "The Gateway restarted before anyone answered."
            case .storageCorrupt: "The Gateway's approval storage was damaged, so it was denied."
            case let .other(raw): ApprovalRecord.humanized(raw)
            }
        }
    }

    /// Who recorded the decision.
    public struct Resolver: Hashable, Sendable {
        public let kind: String
        public let id: String?

        public init(kind: String, id: String? = nil) {
            self.kind = kind
            self.id = id
        }
    }

    /// How the status capsule is colored.
    public enum Tone: Hashable, Sendable {
        case allowed
        case denied
        case neutral
    }

    public let id: String
    public let urlPath: String?
    public let kind: Kind
    public let status: Status
    public let decision: Decision?
    public let reason: Reason?
    public let createdAt: Date?
    public let expiresAt: Date?
    public let resolvedAt: Date?
    public let agentId: String?
    public let sessionKey: String?
    public let resolver: Resolver?
    // Exec
    public let commandText: String?
    public let commandPreview: String?
    public let warningText: String?
    public let host: String?
    public let nodeId: String?
    // Plugin and system-agent
    public let title: String?
    public let description: String?
    public let detail: String?
    public let severity: String?
    public let pluginId: String?
    public let toolName: String?

    public init?(_ json: JSONValue) {
        guard json.object != nil, let id = json["id"]?.text, !id.isEmpty else { return nil }
        let presentation = json["presentation"]?.object != nil ? json["presentation"]! : json
        func field(_ key: String) -> String? {
            let value = presentation[key]?.text ?? json[key]?.text
            return value?.isEmpty == false ? value : nil
        }
        func date(_ keys: String...) -> Date? {
            for key in keys {
                if let ms = json[key]?.double { return Date(timeIntervalSince1970: ms / 1000) }
            }
            return nil
        }
        self.id = id
        self.urlPath = json["urlPath"]?.text
        let decision = json["decision"]?.text.map(Decision.init)
        self.decision = decision
        let hasCommand = presentation["commandText"]?.text != nil || json["command"]?.text != nil
        self.kind = Kind(presentation["kind"]?.text ?? json["kind"]?.text ?? (hasCommand ? "exec" : "unknown"))
        if let status = json["status"]?.text {
            self.status = Status(status)
        } else {
            switch decision {
            case .allowOnce, .allowAlways: self.status = .allowed
            case .deny: self.status = .denied
            default: self.status = .other("unknown")
            }
        }
        self.reason = json["reason"]?.text.map(Reason.init)
        self.createdAt = date("createdAtMs", "requestedAtMs")
        self.expiresAt = date("expiresAtMs")
        self.resolvedAt = date("resolvedAtMs", "decidedAtMs")
        self.agentId = json["source"]?["agentId"]?.text ?? presentation["agentId"]?.text ?? json["agentId"]?.text
        self.sessionKey = json["source"]?["sessionKey"]?.text ?? json["sourceSessionKey"]?.text ?? json["sessionKey"]?.text
        if let resolver = json["resolver"], let kind = resolver["kind"]?.text {
            self.resolver = Resolver(kind: kind, id: resolver["id"]?.text)
        } else {
            self.resolver = nil
        }
        self.commandText = field("commandText") ?? field("command")
        self.commandPreview = field("commandPreview")
        self.warningText = field("warningText")
        self.host = field("host")
        self.nodeId = field("nodeId")
        self.title = field("title")
        self.description = field("description")
        self.detail = field("detail")
        self.severity = field("severity")
        self.pluginId = field("pluginId")
        self.toolName = field("toolName")
    }

    /// The row's headline: the command, else the title, else the kind.
    public var displayTitle: String {
        self.commandText ?? self.commandPreview ?? self.title ?? self.description ?? self.kind.label
    }

    /// The status capsule: "Allowed once", "Always allowed", "Denied · No reviewer", "Expired"…
    public var statusLabel: String {
        switch self.status {
        case .allowed:
            switch self.decision {
            case .allowAlways: return Decision.allowAlways.label
            case .allowOnce: return Decision.allowOnce.label
            default: return Status.allowed.label
            }
        case .denied:
            if let reason = self.reason, reason != .user { return "Denied · \(reason.shortLabel)" }
            return Status.denied.label
        default:
            return self.status.label
        }
    }

    public var tone: Tone {
        switch self.status {
        case .allowed: .allowed
        case .denied: .denied
        default: .neutral
        }
    }

    /// Who decided, in plain words. `localDeviceId` is this install's `DeviceIdentity.deviceId`.
    public func decidedBy(localDeviceId: String?) -> String {
        Self.decidedBy(self.resolver, localDeviceId: localDeviceId)
    }

    public static func decidedBy(_ resolver: Resolver?, localDeviceId: String?) -> String {
        guard let resolver else { return "Unknown" }
        switch resolver.kind {
        case "device":
            guard let id = resolver.id else { return "Another device" }
            if let localDeviceId, id == localDeviceId { return "This device" }
            return "Another device (\(id.prefix(6))…)"
        case "channel":
            return resolver.id.map { "Channel · \($0)" } ?? "Channel"
        case "runtime":
            return "Runtime"
        case "system":
            return "OpenClaw (automatic)"
        default:
            let kind = Self.humanized(resolver.kind)
            return resolver.id.map { "\(kind) · \($0)" } ?? kind
        }
    }

    /// `malformed-verdict` → "Malformed verdict".
    static func humanized(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return raw }
        return first.uppercased() + spaced.dropFirst()
    }
}

// MARK: Model

/// Approval History for one Gateway: the last 30 days of terminal approvals, newest first,
/// paged with the Gateway's opaque cursor.
@MainActor
@Observable
public final class ApprovalHistoryModel {
    /// The segmented filter; sent as `approval.history`'s `kind`.
    public enum KindFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
        case all
        case exec
        case plugin
        case systemAgent = "system-agent"

        public var id: String { self.rawValue }

        public var label: String {
            switch self {
            case .all: "All"
            case .exec: "Commands"
            case .plugin: "Plugins"
            case .systemAgent: "System"
            }
        }

        /// The `kind` param, nil for All.
        public var wireValue: String? { self == .all ? nil : self.rawValue }

        /// Empty-state text for a filtered list, nil for All.
        public var emptyMessage: String? {
            switch self {
            case .all: nil
            case .exec: "No command approvals in the last 30 days."
            case .plugin: "No plugin approvals in the last 30 days."
            case .systemAgent: "No system approvals in the last 30 days."
            }
        }
    }

    public private(set) var items: [ApprovalRecord] = []
    public private(set) var nextCursor: String?
    /// False when the Gateway has no `approval.history`.
    public private(set) var supported = true
    public private(set) var hasLoaded = false
    public private(set) var loadState = OperationState.idle
    public private(set) var loadMoreState = OperationState.idle
    public private(set) var kindFilter = KindFilter.all
    /// Full records from `approval.get`, by id.
    public private(set) var details: [String: ApprovalRecord] = [:]
    public private(set) var detailState: [String: OperationState] = [:]
    /// Items per page. Tests lower it to page through small fixtures.
    public var pageSize = ApprovalHistoryModel.defaultPageSize
    /// This install's device id, for "Decided by: This device".
    public let localDeviceId: String?

    public nonisolated static let defaultPageSize = 50

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var usedCursors: Set<String> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, localDeviceId: String?) {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.localDeviceId = localDeviceId
    }

    /// For checks and previews: `methods` is the Gateway's advertised method list (nil or empty
    /// when unknown), `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil }, localDeviceId: String? = nil,
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.localDeviceId = localDeviceId
    }

    public var hasMore: Bool { self.nextCursor != nil }

    /// The fullest record known for an id: `approval.get`'s, else the list row.
    public func record(_ id: String?) -> ApprovalRecord? {
        guard let id else { return nil }
        return self.details[id] ?? self.items.first { $0.id == id }
    }

    public func decidedBy(_ record: ApprovalRecord) -> String { record.decidedBy(localDeviceId: self.localDeviceId) }

    // MARK: Loading

    /// Loads the first page for the current filter, replacing what's shown.
    public func load() async {
        if let methods = self.methods(), !methods.isEmpty, !methods.contains("approval.history") {
            self.markUnsupported()
            return
        }
        self.generation += 1
        let generation = self.generation
        self.loadState = .running
        self.loadMoreState = .idle
        do {
            let page = try await self.fetch(cursor: nil)
            guard generation == self.generation else { return }
            self.items = Self.deduplicated(page.items)
            self.usedCursors = []
            self.nextCursor = page.nextCursor
            self.supported = true
            self.loadState = .idle
            self.loadMoreState = .idle
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            guard generation == self.generation else { return }
            self.markUnsupported()
        } catch {
            guard generation == self.generation else { return }
            self.loadState = .failed(Self.message(for: error))
        }
        self.hasLoaded = true
    }

    public func refresh() async { await self.load() }

    /// Appends the next page, skipping ids already shown.
    public func loadMore() async {
        guard self.supported, let cursor = self.nextCursor, !self.loadMoreState.isRunning, !self.loadState.isRunning
        else { return }
        let generation = self.generation
        self.loadMoreState = .running
        do {
            let page = try await self.fetch(cursor: cursor)
            guard generation == self.generation else { return }
            self.usedCursors.insert(cursor)
            let known = Set(self.items.map(\.id))
            let fresh = Self.deduplicated(page.items).filter { !known.contains($0.id) }
            self.items += fresh
            if page.items.isEmpty || page.nextCursor.map(self.usedCursors.contains) == true {
                self.nextCursor = nil
            } else {
                self.nextCursor = page.nextCursor
            }
            self.loadMoreState = .idle
        } catch let error where Self.isInvalidCursor(error) {
            guard generation == self.generation else { return }
            // The cursor went stale (e.g. the Gateway restarted): start over once.
            self.loadMoreState = .idle
            await self.load()
        } catch {
            guard generation == self.generation else { return }
            self.loadMoreState = .failed(Self.message(for: error))
        }
    }

    /// Switches the filter and loads its first page.
    public func setKindFilter(_ filter: KindFilter) async {
        guard filter != self.kindFilter else { return }
        self.kindFilter = filter
        self.items = []
        self.nextCursor = nil
        self.usedCursors = []
        self.loadMoreState = .idle
        await self.load()
    }

    /// `approval.get`: the full record for the detail view. Failing keeps the row's data.
    public func loadDetail(_ id: String) async {
        guard self.detailState[id]?.isRunning != true else { return }
        if let methods = self.methods(), !methods.isEmpty, !methods.contains("approval.get") { return }
        self.detailState[id] = .running
        do {
            let result = try await self.request("approval.get", ["id": .string(id)])
            if let record = ApprovalRecord(result["approval"] ?? result) {
                self.details[id] = record
            }
            self.detailState[id] = .idle
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            self.detailState[id] = .idle
        } catch {
            self.detailState[id] = .failed(Self.message(for: error))
        }
    }

    /// An exec approval was resolved somewhere: once the history is showing, pick up the new
    /// entry without dropping pages already loaded.
    func handleApprovalResolved() {
        guard self.hasLoaded, self.supported else { return }
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.mergeLatest()
        }
    }

    /// Fetches page 1 and puts entries not shown yet on top, keeping pages already loaded.
    /// Loads from scratch when nothing is shown yet.
    public func mergeLatest() async {
        guard self.hasLoaded, self.supported, !self.loadState.isRunning, !self.loadMoreState.isRunning else { return }
        guard !self.items.isEmpty, !self.usedCursors.isEmpty else { return await self.load() }
        let generation = self.generation
        guard let page = try? await self.fetch(cursor: nil), generation == self.generation else { return }
        let known = Set(self.items.map(\.id))
        let fresh = Self.deduplicated(page.items).filter { !known.contains($0.id) }
        self.items = fresh + self.items
        self.loadState = .idle
    }

    private func markUnsupported() {
        self.supported = false
        self.items = []
        self.nextCursor = nil
        self.loadState = .idle
        self.loadMoreState = .idle
        self.hasLoaded = true
    }

    private func fetch(cursor: String?) async throws -> (items: [ApprovalRecord], nextCursor: String?) {
        var params: [String: JSONValue] = ["limit": JSONValue(max(1, min(100, self.pageSize)))]
        if let cursor { params["cursor"] = .string(cursor) }
        if let kind = self.kindFilter.wireValue { params["kind"] = .string(kind) }
        let result = try await self.request("approval.history", .object(params))
        let raw = result["items"]?.array ?? result["approvals"]?.array ?? result["entries"]?.array ?? result.array ?? []
        let next = result["nextCursor"]?.text
        return (raw.compactMap(ApprovalRecord.init), next?.isEmpty == false ? next : nil)
    }

    private static func deduplicated(_ records: [ApprovalRecord]) -> [ApprovalRecord] {
        var seen: Set<String> = []
        return records.filter { seen.insert($0.id).inserted }
    }

    static func isInvalidCursor(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, details) = error, code == "INVALID_REQUEST" else { return false }
        return message.lowercased().contains("cursor") || details?["reason"]?.text?.lowercased().contains("cursor") == true
    }

    public nonisolated static let missingScopeMessage =
        "Approval History needs the operator.approvals scope. Approve it for this device on the Gateway host, then try again."

    static func message(for error: Error) -> String {
        guard case let GatewayError.rpc(code, message, details) = error else { return error.localizedDescription }
        if code == "MISSING_SCOPE" || details?["code"]?.text == "MISSING_SCOPE"
            || message.lowercased().contains("operator.approvals")
        {
            return Self.missingScopeMessage
        }
        if details?["reason"]?.text == "APPROVAL_NOT_FOUND" {
            return "This approval is no longer on the Gateway."
        }
        return message
    }
}
