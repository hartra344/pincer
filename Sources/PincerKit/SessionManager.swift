import Foundation

// Session manager (Gateway Settings → Sessions): every session with Active/Archived/All filters,
// previews (`sessions.preview`), details (`sessions.describe`), bulk archive (`sessions.patchMany`,
// falling back to `sessions.patch`) and delete (`sessions.delete`), plus branch tools
// (`sessions.branches.list/switch`, `sessions.rewind`) and `sessions.recover` for sessions a Gateway
// restart left tombstoned.
//
// Scopes: listing, previews, details and branches need `operator.read`; archive, recover and deleting
// an archived session (`archivedOnly: true`) need `operator.write`; deleting a live session,
// switching branches and rewinding need `operator.admin` (Full Management).

// MARK: Constants and pure logic

public enum SessionManager {
    public static let listMethod = "sessions.list"
    public static let previewMethod = "sessions.preview"
    public static let describeMethod = "sessions.describe"
    public static let branchesListMethod = "sessions.branches.list"
    public static let branchesSwitchMethod = "sessions.branches.switch"
    public static let rewindMethod = "sessions.rewind"
    public static let recoverMethod = "sessions.recover"
    public static let deleteMethod = "sessions.delete"
    public static let patchMethod = "sessions.patch"
    public static let patchManyMethod = "sessions.patchMany"
    public static let historyMethod = "chat.history"
    /// `SESSIONS_PATCH_MANY_MAX_TARGETS` in the Gateway protocol.
    public static let patchManyMaxTargets = 100
    public static let listLimit = 500
    public static let previewItemLimit = 8
    public static let previewMaxChars = 240
    public static let rewindHistoryLimit = 60

    public static var needsAdminMessage: String { L("Turn on Full Management under Connection, then approve this device on the Gateway host.") }
    public static var unsupportedMessage: String { L("Session Management Isn't Available. Update OpenClaw to manage sessions here.") }
    public static var branchesUnsupportedMessage: String { L("Branches need a newer Gateway.") }
    public static var deleteMessage: String { L("This permanently deletes the transcript on the Gateway and can't be undone.") }
    public static func deleteMessage(unsentCount: Int, sessionCount: Int = 1) -> String {
        guard unsentCount > 0 else { return self.deleteMessage }
        let count = unsentCount.formatted()
        let extra: String
        switch (sessionCount > 1, unsentCount == 1) {
        case (false, true): extra = L("The 1 unsent message in this chat will be discarded too.")
        case (false, false): extra = L("The \(count) unsent messages in this chat will be discarded too.")
        case (true, true): extra = L("1 unsent message in these chats will be discarded too.")
        case (true, false): extra = L("\(count) unsent messages in these chats will be discarded too.")
        }
        return self.deleteMessage + " " + extra
    }

    public static var mixedDeleteMessage: String { L("Only archived sessions can be deleted without Full Management.") }

    public static func deleteTitle(count: Int) -> String {
        count == 1 ? "Delete 1 session?" : "Delete \(count) sessions?"
    }

    /// Names the session when there's one: "Delete “Garden planner”?".
    public static func deleteTitle(count: Int, title: String?) -> String {
        guard count == 1, let title, !title.isEmpty else { return self.deleteTitle(count: count) }
        return "Delete “\(title)”?"
    }

    public static func rewindTitle(_ sessionTitle: String) -> String { "Rewind “\(sessionTitle)”?" }
    public static var rewindMessage: String { L("Messages after this point move to a new branch. The message you rewind to goes back into the composer.") }
    public static func switchTitle(_ branch: String) -> String { "Switch to branch “\(branch)”?" }
    public static var switchMessage: String { L("The chat continues from that branch. The current branch is kept and you can switch back.") }

    /// Rows for `filter` whose title, key, label, agent or channel contain `search` (ignoring case),
    /// most recently active first.
    public static func filtered(_ rows: [SessionRow], filter: SessionManagerFilter, search: String = "") -> [SessionRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows
            .filter { filter.includes($0) }
            .filter { query.isEmpty || self.matches($0, query) }
            .sorted { lhs, rhs in
                lhs.activityMs != rhs.activityMs ? lhs.activityMs > rhs.activityMs : lhs.key < rhs.key
            }
    }

    static func matches(_ row: SessionRow, _ query: String) -> Bool {
        let fields = [row.title, row.key, row.raw["label"]?.text, row.agentId, row.channel].compactMap(\.self)
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// What deleting `rows` does: archived rows go with `archivedOnly` (write scope); live rows need admin.
    public static func deletePlan(_ rows: [SessionRow], hasAdmin: Bool) -> SessionDeletePlan {
        if hasAdmin { return SessionDeletePlan(deletable: rows.map(\.key), blocked: []) }
        return SessionDeletePlan(deletable: rows.filter(\.isArchived).map(\.key),
                                 blocked: rows.filter { !$0.isArchived }.map(\.key))
    }

    /// `sessions.delete` params. Archived rows send `archivedOnly: true` so `operator.write` is enough.
    public static func deleteParams(_ row: SessionRow) -> JSONValue {
        var params: [String: JSONValue] = ["key": .string(row.key), "deleteTranscript": true]
        if let agentId = row.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        if let sessionId = row.sessionId { params["expectedSessionId"] = .string(sessionId) }
        if row.isArchived { params["archivedOnly"] = true }
        return .object(params)
    }

    /// `sessions.patchMany` targets in batches the Gateway accepts.
    public static func patchManyBatches(_ rows: [SessionRow]) -> [[SessionRow]] {
        stride(from: 0, to: rows.count, by: self.patchManyMaxTargets).map {
            Array(rows[$0 ..< min($0 + self.patchManyMaxTargets, rows.count)])
        }
    }

    static func patchManyParams(_ rows: [SessionRow], archived: Bool) -> JSONValue {
        let targets: [JSONValue] = rows.map { row in
            var target: [String: JSONValue] = ["key": .string(row.key)]
            if let agentId = row.raw["agentId"]?.text { target["agentId"] = .string(agentId) }
            if let sessionId = row.sessionId { target["expectedSessionId"] = .string(sessionId) }
            return .object(target)
        }
        return ["targets": .array(targets), "patch": ["archived": .bool(archived)]]
    }

    static func patchParams(_ row: SessionRow, archived: Bool) -> JSONValue {
        var params: [String: JSONValue] = ["key": .string(row.key), "archived": .bool(archived)]
        if let sessionId = row.sessionId { params["expectedSessionId"] = .string(sessionId) }
        return .object(params)
    }

    /// How long the latest run took (`runtimeMs`, else `endedAt - startedAt`), or has been running so far.
    public static func runDuration(_ row: SessionRow, now: Date) -> TimeInterval? {
        if let ms = row.raw["runtimeMs"]?.double, ms >= 0, !SessionRunState(row: row).isActive { return ms / 1000 }
        guard let started = row.raw["startedAt"]?.double, started > 0 else {
            return row.raw["runtimeMs"]?.double.flatMap { $0 >= 0 ? $0 / 1000 : nil }
        }
        if let ended = row.raw["endedAt"]?.double, ended >= started { return (ended - started) / 1000 }
        guard SessionRunState(row: row).isActive else { return row.raw["runtimeMs"]?.double.map { $0 / 1000 } }
        return max(0, now.timeIntervalSince1970 - started / 1000)
    }

    /// Shared actual row accessibility formatter, using the same numeric bounds as visual labels.
    package static func spokenDuration(_ seconds: TimeInterval) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        return Duration.seconds(Self.boundedDurationSeconds(seconds)).formatted(style)
    }

    /// Localized short units: "4 sec", "2 min 5 sec", "1 hr 3 min".
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Self.boundedDurationSeconds(seconds)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 { return minutes > 0 ? L("\(String(hours)) hr \(String(minutes)) min") : L("\(String(hours)) hr") }
        if minutes > 0 { return secs > 0 ? L("\(String(minutes)) min \(String(secs)) sec") : L("\(String(minutes)) min") }
        return L("\(String(secs)) sec")
    }

    private static func boundedDurationSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(saturating: seconds, rounding: .down) ?? 0
    }

    /// "Archived 3 sessions", "Deleted 1 session; 2 failed".
    public static func bulkSummary(verb: String, _ outcome: SessionBulkOutcome) -> String {
        let count = outcome.succeeded.count
        var text = "\(verb) \(count) \(count == 1 ? "session" : "sessions")"
        if !outcome.failed.isEmpty { text += "; \(outcome.failed.count) failed" }
        return text
    }

    /// Formats a bulk failure row, using the session key until a known title is available.
    public static func bulkFailureSummary(_ failure: SessionBulkOutcome.Failure,
                                          sessionTitle: String?) -> String {
        let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? failure.key
        return "\(displayedTitle): \(failure.message)"
    }

    /// Whether `sessions.recover` applies: a Gateway restart tombstoned the session.
    public static func isRecoverable(_ row: SessionRow) -> Bool {
        row.raw["restartRecoveryStatus"]?.text == "tombstoned"
    }

    /// `sessions.changed` reasons after which a session's cached transcript no longer matches.
    public static let transcriptChangingReasons: Set<String> = ["rewind", "branch-switch", "recovery", "reset", "new"]
}

public enum SessionManagerFilter: String, CaseIterable, Hashable, Sendable, Identifiable {
    case active
    case archived
    case all

    public var id: String { self.rawValue }

    public var title: String {
        switch self {
        case .active: "Active"
        case .archived: "Archived"
        case .all: "All"
        }
    }

    /// `sessions.list`'s `archived`: false (active), true (archived only) or "all".
    public var listParam: JSONValue {
        switch self {
        case .active: false
        case .archived: true
        case .all: "all"
        }
    }

    public func includes(_ row: SessionRow) -> Bool {
        switch self {
        case .active: !row.isArchived
        case .archived: row.isArchived
        case .all: true
        }
    }

    public var emptyMessage: String {
        switch self {
        case .active: "No sessions"
        case .archived: "No archived sessions"
        case .all: "No sessions"
        }
    }
}

public struct SessionDeletePlan: Equatable, Sendable {
    /// Keys that can be deleted with the connection's scopes.
    public let deletable: [String]
    /// Live (non-archived) keys that need Full Management to delete.
    public let blocked: [String]

    public init(deletable: [String], blocked: [String]) {
        self.deletable = deletable
        self.blocked = blocked
    }

    public var canDelete: Bool { self.blocked.isEmpty && !self.deletable.isEmpty }
    public var needsAdmin: Bool { !self.blocked.isEmpty }
}

/// A session's latest run, from the row's `status` and `hasActiveRun`.
public enum SessionRunState: String, Sendable {
    case idle
    case queued
    case running
    case done
    case failed
    case killed
    case timeout

    public init(row: SessionRow) {
        if row.hasActiveRun {
            self = row.status == "queued" ? .queued : .running
            return
        }
        self = row.status.flatMap(SessionRunState.init(rawValue:)) ?? .idle
        if self == .running || self == .queued { self = .idle }
    }

    public var isActive: Bool { self == .running || self == .queued }
    public var isError: Bool { self == .failed || self == .killed || self == .timeout }

    public var title: String {
        switch self {
        case .idle: L("Idle")
        case .queued: L("Queued")
        case .running: L("Running")
        case .done: L("Done")
        case .failed: L("Error")
        case .killed: L("Stopped")
        case .timeout: L("Timed Out")
        }
    }
}

/// A few recent messages of one session (`sessions.preview`).
public struct SessionPreview: Equatable, Sendable {
    public enum Status: String, Sendable {
        case ok, empty, missing, cold, error, unknown
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: Int
        /// `user`, `assistant`, `tool`, `system` or `other`.
        public let role: String
        public let text: String
    }

    public let key: String
    public let status: Status
    public let items: [Item]

    public init(key: String, status: Status, items: [Item]) {
        self.key = key
        self.status = status
        self.items = items
    }

    public init?(_ json: JSONValue) {
        guard let key = json["key"]?.text else { return nil }
        self.key = key
        self.status = json["status"]?.text.flatMap(Status.init(rawValue:)) ?? .unknown
        self.items = (json["items"]?.array ?? []).enumerated().compactMap { index, item in
            guard let text = item["text"]?.string else { return nil }
            return Item(id: index, role: item["role"]?.text ?? "other", text: text)
        }
    }

    /// Why there's nothing to show, or nil when there are items.
    public var emptyReason: String? {
        guard self.items.isEmpty else { return nil }
        switch self.status {
        case .ok, .empty: return "No messages yet"
        case .missing: return "This session is gone"
        case .cold: return "The transcript isn't loaded on the Gateway yet"
        case .error: return "The Gateway couldn't read this transcript"
        case .unknown: return "No preview"
        }
    }
}

/// One transcript tip (`sessions.branches.list`).
public struct SessionBranch: Identifiable, Equatable, Sendable {
    public let leafEntryId: String
    public let headline: String
    public let messageCount: Int
    public let updatedAt: Date?
    public let active: Bool

    public var id: String { self.leafEntryId }

    public init(leafEntryId: String, headline: String, messageCount: Int, updatedAt: Date? = nil, active: Bool) {
        self.leafEntryId = leafEntryId
        self.headline = headline
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.active = active
    }

    public init?(_ json: JSONValue) {
        guard let leaf = json["leafEntryId"]?.text else { return nil }
        self.leafEntryId = leaf
        self.headline = json["headline"]?.string ?? ""
        self.messageCount = max(0, json["messageCount"]?.int ?? 0)
        self.updatedAt = json["updatedAt"].flatMap(Self.date)
        self.active = json["active"]?.bool ?? false
    }

    /// The branch's name in the UI: its headline, else a short id.
    public var title: String {
        let line = self.headline.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "Branch \(self.leafEntryId.prefix(8))" : line
    }

    static func date(_ value: JSONValue) -> Date? {
        if let ms = value.double, value.string == nil { return Date(timeIntervalSince1970: ms / 1000) }
        guard let text = value.string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? Double(text).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// A persisted user message `sessions.rewind` can cut back to (its `__openclaw.id`).
public struct SessionRewindPoint: Identifiable, Equatable, Sendable {
    public let entryId: String
    public let text: String
    public let timestamp: Date?

    public var id: String { self.entryId }

    public init(entryId: String, text: String, timestamp: Date? = nil) {
        self.entryId = entryId
        self.text = text
        self.timestamp = timestamp
    }

    /// User messages with a transcript id, newest first.
    static func points(history: JSONValue) -> [SessionRewindPoint] {
        let messages = history["messages"]?.array ?? []
        return messages.enumerated().compactMap { index, message -> SessionRewindPoint? in
            guard let item = ChatItem(message, fallbackIndex: index), item.role == .user, !item.isPending,
                  let id = item.transcriptId ?? message["messageId"]?.text
            else { return nil }
            let text = item.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return SessionRewindPoint(entryId: id, text: text.isEmpty ? "(attachment)" : text, timestamp: item.timestamp)
        }
        .reversed()
    }
}

/// What happened to a session's transcript, for the transcript cache and open chats.
public enum SessionTranscriptChange: Equatable, Sendable {
    /// Rewound, branch-switched or recovered; a rewind's cut message text, for the composer.
    case changed(editorText: String?)
    case deleted
}

/// Which keys a bulk action changed, and which failed and why.
public struct SessionBulkOutcome: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let key: String
        public let message: String

        public init(key: String, message: String) {
            self.key = key
            self.message = message
        }
    }

    public var succeeded: [String] = []
    public var failed: [Failure] = []

    public init(succeeded: [String] = [], failed: [Failure] = []) {
        self.succeeded = succeeded
        self.failed = failed
    }
}

/// `sessions.recover`: the session that continues the tombstoned one.
public struct SessionRecoverResult: Equatable, Sendable {
    public let key: String
    public let sessionId: String
    public let continuationStarted: Bool
    public let continuationError: String?

    public init?(_ json: JSONValue) {
        guard let key = json["key"]?.text, let sessionId = json["sessionId"]?.text else { return nil }
        self.key = key
        self.sessionId = sessionId
        let continuation = json["continuation"]
        self.continuationStarted = continuation?["status"]?.text == "started"
        self.continuationError = continuation?["status"]?.text == "rejected"
            ? continuation?["error"]?["message"]?.text ?? "The recovered session couldn't resume its run."
            : nil
    }
}

// MARK: Model

/// Sessions for one Gateway (`GatewayStore.sessionManager`). Keeps its own `sessions.list` (the
/// sidebar's list leaves archived sessions out) and per-key previews, details and branches for the
/// page's lifetime; `sessions.changed` keeps them current.
@MainActor
@Observable
public final class SessionManagerModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public typealias TranscriptChanged = @MainActor (_ key: String, _ change: SessionTranscriptChange) async -> Void

    public private(set) var rows: [SessionRow] = []
    public private(set) var filter: SessionManagerFilter = .active
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var loadError: String?

    public private(set) var previews: [String: SessionPreview] = [:]
    public private(set) var previewErrors: [String: String] = [:]
    public private(set) var details: [String: SessionRow] = [:]
    public private(set) var detailErrors: [String: String] = [:]
    public private(set) var branches: [String: [SessionBranch]] = [:]
    public private(set) var branchErrors: [String: String] = [:]
    public private(set) var rewindPoints: [String: [SessionRewindPoint]] = [:]
    public private(set) var rewindErrors: [String: String] = [:]

    /// Keys with a mutation in flight.
    public private(set) var busy: Set<String> = []
    /// A bulk action is running.
    public private(set) var isWorking = false
    public private(set) var lastMessage: String?
    public private(set) var actionError: String?
    /// Per-key failures of the last bulk action.
    public private(set) var lastFailures: [SessionBulkOutcome.Failure] = []
    /// Titles captured from the bulk action's immutable targets for failed rows.
    public private(set) var lastFailureTitles: [String: String] = [:]
    /// The message `sessions.rewind` cut, for the composer.
    public private(set) var lastEditorText: String?

    /// A call hit a scope error although the connection claimed `operator.admin`.
    public private(set) var deniedAdmin = false
    /// Methods the Gateway answered with unknown-method.
    public private(set) var rejectedMethods: Set<String> = []

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private let onTranscriptChanged: TranscriptChanged
    @ObservationIgnored private let onSessionsChanged: @MainActor () async -> Void
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var previewsInFlight: Set<String> = []
    /// Only active detail requests retain ownership; terminal and invalidated entries are removed.
    @ObservationIgnored private var detailLoadOwners: [String: UUID] = [:]
    /// Bumped whenever a key's preview is dropped, so a reply already in flight is ignored.
    @ObservationIgnored private var previewGenerations: [String: Int] = [:]
    /// Ownership only for currently outstanding rewind loads; completed keys are removed.
    @ObservationIgnored private var rewindLoadOwners: [String: UUID] = [:]
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?, allowsWritesWithoutAdmin: Bool,
         onTranscriptChanged: @escaping TranscriptChanged, onSessionsChanged: @escaping @MainActor () async -> Void)
    {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.onTranscriptChanged = onTranscriptChanged
        self.onSessionsChanged = onSessionsChanged
    }

    /// For checks and previews. `methods` is the advertised list (nil or empty when unknown).
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                allowsWritesWithoutAdmin: Bool = false,
                request: @escaping Request,
                onTranscriptChanged: @escaping TranscriptChanged = { _, _ in },
                onSessionsChanged: @escaping @MainActor () async -> Void = {})
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
        self.onTranscriptChanged = onTranscriptChanged
        self.onSessionsChanged = onSessionsChanged
    }

    // MARK: Capability

    /// Whether the Gateway has `method`: advertised (or the list is unknown) and not rejected.
    public func supports(_ method: String) -> Bool {
        if self.rejectedMethods.contains(method) { return false }
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    public var supportsList: Bool { self.supports(SessionManager.listMethod) }
    public var supportsPreview: Bool { self.supports(SessionManager.previewMethod) }
    public var supportsDescribe: Bool { self.supports(SessionManager.describeMethod) }
    public var supportsBranches: Bool { self.supports(SessionManager.branchesListMethod) }
    public var supportsBranchSwitch: Bool { self.supports(SessionManager.branchesSwitchMethod) }
    public var supportsRewind: Bool { self.supports(SessionManager.rewindMethod) }
    public var supportsRecover: Bool { self.supports(SessionManager.recoverMethod) }
    public var supportsDelete: Bool { self.supports(SessionManager.deleteMethod) }
    public var supportsPatch: Bool { self.supports(SessionManager.patchMethod) }
    public var supportsPatchMany: Bool { self.supports(SessionManager.patchManyMethod) }
    public var supportsArchive: Bool { self.supportsPatchMany || self.supportsPatch }

    /// Full Management (or the demo).
    public var hasAdmin: Bool {
        if self.allowsWritesWithoutAdmin { return true }
        return !self.deniedAdmin && self.scopes().contains(GatewayConnection.adminScope)
    }

    public var canSwitchBranch: Bool { self.hasAdmin && self.supportsBranchSwitch }
    public var canRewind: Bool { self.hasAdmin && self.supportsRewind }
    public func canRecover(_ row: SessionRow) -> Bool { self.supportsRecover && SessionManager.isRecoverable(row) }

    public func deletePlan(_ keys: some Collection<String>) -> SessionDeletePlan {
        SessionManager.deletePlan(self.rows(for: keys), hasAdmin: self.hasAdmin)
    }

    // MARK: Reading

    public func visibleRows(search: String = "") -> [SessionRow] {
        SessionManager.filtered(self.rows, filter: self.filter, search: search)
    }

    public func row(_ key: String) -> SessionRow? {
        self.rows.first { $0.key == key } ?? self.details[key]
    }

    private func rows(for keys: some Collection<String>) -> [SessionRow] {
        let wanted = Set(keys)
        let listed = self.rows.filter { wanted.contains($0.key) }
        let listedKeys = Set(listed.map(\.key))
        return listed + wanted.subtracting(listedKeys).sorted().compactMap { self.details[$0] }
    }

    /// Loads `sessions.list` for `filter`.
    public func load(filter: SessionManagerFilter) async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.filter = filter
        self.isLoading = true
        self.loadError = nil
        defer { if generation == self.loadGeneration { self.isLoading = false } }
        do {
            let params: JSONValue = ["limit": .number(Double(SessionManager.listLimit)), "includeLastMessage": true,
                                     "archived": filter.listParam]
            let result = try await self.call(SessionManager.listMethod, params)
            guard generation == self.loadGeneration else { return }
            let next = result["sessions"]?.array?.compactMap(SessionRow.init) ?? []
            if next != self.rows { self.rows = next }
            self.hasLoaded = true
        } catch {
            guard generation == self.loadGeneration else { return }
            self.loadError = Self.message(error)
        }
    }

    public func loadIfNeeded(filter: SessionManagerFilter) async {
        if self.hasLoaded, self.filter == filter, self.loadError == nil { return }
        await self.load(filter: filter)
    }

    public func reload() async { await self.load(filter: self.filter) }

    /// `sessions.preview` for one key, once per page lifetime (until the session changes).
    public func loadPreview(key: String) async {
        guard self.supportsPreview, self.previews[key] == nil, self.previewsInFlight.insert(key).inserted else { return }
        let generation = self.previewGenerations[key, default: 0]
        defer { if self.previewGenerations[key, default: 0] == generation { self.previewsInFlight.remove(key) } }
        do {
            let result = try await self.call(SessionManager.previewMethod, [
                "keys": [.string(key)],
                "limit": .number(Double(SessionManager.previewItemLimit)),
                "maxChars": .number(Double(SessionManager.previewMaxChars)),
            ])
            // The session changed while this was in flight; a newer load owns the entry.
            guard self.previewGenerations[key, default: 0] == generation else { return }
            let preview = result["previews"]?.array?.compactMap(SessionPreview.init).first { $0.key == key }
                ?? SessionPreview(key: key, status: .missing, items: [])
            if self.previews[key] != preview { self.previews[key] = preview }
            self.previewErrors[key] = nil
        } catch {
            guard self.previewGenerations[key, default: 0] == generation else { return }
            self.previewErrors[key] = Self.message(error)
        }
    }

    /// Drops the cached preview and fetches it again (Refresh).
    public func reloadPreview(key: String) async {
        self.forgetPreview(key)
        await self.loadPreview(key: key)
    }

    /// `sessions.describe` for one key.
    public func loadDetails(key: String) async {
        guard !Task.isCancelled, self.supportsDescribe else { return }
        let owner = UUID()
        self.detailLoadOwners[key] = owner
        defer {
            if self.detailLoadOwners[key] == owner { self.detailLoadOwners[key] = nil }
        }
        var params: [String: JSONValue] = ["key": .string(key), "includeDerivedTitles": true, "includeLastMessage": true]
        if let agentId = self.row(key)?.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        do {
            let result = try await self.call(SessionManager.describeMethod, .object(params))
            guard !Task.isCancelled, self.detailLoadOwners[key] == owner else { return }
            if let row = result["session"].flatMap(SessionRow.init) {
                self.details[key] = row
                self.detailErrors[key] = nil
            } else {
                self.details[key] = nil
                self.detailErrors[key] = "This session is gone."
            }
        } catch {
            guard !Task.isCancelled, self.detailLoadOwners[key] == owner else { return }
            self.detailErrors[key] = Self.message(error)
        }
    }

    /// `sessions.branches.list` for one key.
    public func loadBranches(key: String) async {
        guard self.supportsBranches else { return }
        do {
            let result = try await self.call(SessionManager.branchesListMethod, .object(self.sessionKeyParams(key)))
            self.branches[key] = result["branches"]?.array?.compactMap(SessionBranch.init) ?? []
            self.branchErrors[key] = nil
        } catch {
            self.branchErrors[key] = Self.message(error)
        }
    }

    /// Recent user messages `sessions.rewind` can cut back to (`chat.history`).
    public func loadRewindPoints(key: String) async {
        guard self.supportsRewind, !Task.isCancelled else { return }
        let owner = UUID()
        self.rewindLoadOwners[key] = owner
        defer {
            if self.rewindLoadOwners[key] == owner { self.rewindLoadOwners[key] = nil }
        }
        do {
            let result = try await self.call(SessionManager.historyMethod, [
                "sessionKey": .string(key), "limit": .number(Double(SessionManager.rewindHistoryLimit)),
            ])
            guard self.rewindLoadOwners[key] == owner, !Task.isCancelled else { return }
            self.rewindPoints[key] = SessionRewindPoint.points(history: result)
            self.rewindErrors[key] = nil
        } catch {
            guard self.rewindLoadOwners[key] == owner, !Task.isCancelled else { return }
            self.rewindErrors[key] = Self.message(error)
        }
    }

    // MARK: Mutations

    /// Archives or unarchives `keys` with `sessions.patchMany` (in batches of 100), or one
    /// `sessions.patch` each when the Gateway doesn't have it.
    @discardableResult
    public func setArchived(_ keys: [String], archived: Bool) async -> SessionBulkOutcome {
        let targets = self.rows(for: keys)
        var outcome = SessionBulkOutcome()
        guard !targets.isEmpty else { return outcome }
        self.begin(targets.map(\.key))
        defer { self.end(targets.map(\.key)) }
        var remaining = targets
        if self.supportsPatchMany {
            remaining = []
            for batch in SessionManager.patchManyBatches(targets) {
                do {
                    let result = try await self.call(SessionManager.patchManyMethod,
                                                     SessionManager.patchManyParams(batch, archived: archived))
                    Self.collect(result, batch: batch, into: &outcome)
                } catch where AgentManagementError.classify(error) == .unsupported {
                    remaining += batch
                } catch {
                    let message = Self.message(error)
                    outcome.failed += batch.map { .init(key: $0.key, message: message) }
                }
            }
        }
        for row in remaining {
            do {
                _ = try await self.call(SessionManager.patchMethod, SessionManager.patchParams(row, archived: archived))
                outcome.succeeded.append(row.key)
            } catch {
                outcome.failed.append(.init(key: row.key, message: Self.message(error)))
            }
        }
        self.apply(archived: archived, to: Set(outcome.succeeded))
        let failureTitles = await Self.failureTitles(outcome.failed, targets: targets)
        self.finish(outcome, verb: archived ? "Archived" : "Unarchived", failureTitles: failureTitles)
        await self.onSessionsChanged()
        return outcome
    }

    private static func collect(_ result: JSONValue, batch: [SessionRow], into outcome: inout SessionBulkOutcome) {
        var seen: Set<String> = []
        for entry in result["outcomes"]?.array ?? [] {
            guard let key = entry["key"]?.text else { continue }
            seen.insert(key)
            if entry["ok"]?.bool == true {
                outcome.succeeded.append(key)
            } else {
                outcome.failed.append(.init(key: key, message: entry["error"]?["message"]?.text ?? "Couldn't change this session."))
            }
        }
        for row in batch where !seen.contains(row.key) {
            outcome.failed.append(.init(key: row.key, message: "The Gateway didn't report this session."))
        }
    }

    /// Deletes `keys` and their transcripts. Archived rows go with `archivedOnly` (write scope); live
    /// rows need Full Management and are refused here without it.
    @discardableResult
    public func delete(_ keys: [String]) async -> SessionBulkOutcome {
        let targets = self.rows(for: keys)
        var outcome = SessionBulkOutcome()
        guard !targets.isEmpty else { return outcome }
        self.begin(targets.map(\.key))
        defer { self.end(targets.map(\.key)) }
        let hasAdmin = self.hasAdmin
        for row in targets {
            guard row.isArchived || hasAdmin else {
                outcome.failed.append(.init(key: row.key, message: SessionManager.mixedDeleteMessage))
                continue
            }
            do {
                let result = try await self.call(SessionManager.deleteMethod, SessionManager.deleteParams(row))
                if result["deleted"]?.bool == false {
                    outcome.failed.append(.init(key: row.key, message: "The Gateway didn't delete this session."))
                    continue
                }
                outcome.succeeded.append(row.key)
                self.forget(row.key)
                await self.onTranscriptChanged(row.key, .deleted)
            } catch {
                outcome.failed.append(.init(key: row.key, message: Self.message(error)))
            }
        }
        let failureTitles = await Self.failureTitles(outcome.failed, targets: targets)
        self.finish(outcome, verb: "Deleted", failureTitles: failureTitles)
        await self.onSessionsChanged()
        return outcome
    }

    /// Repoints the active transcript path to `leafEntryId` (admin).
    @discardableResult
    public func switchBranch(key: String, leafEntryId: String) async -> Bool {
        var params = self.sessionKeyParams(key)
        params["leafEntryId"] = .string(leafEntryId)
        return await self.mutateTranscript(key, SessionManager.branchesSwitchMethod, .object(params),
                                           success: "Switched branch") != nil
    }

    /// Cuts the active path back to before user message `entryId` (admin); the cut message's text is
    /// kept in `lastEditorText`.
    @discardableResult
    public func rewind(key: String, entryId: String) async -> Bool {
        var params = self.sessionKeyParams(key)
        params["entryId"] = .string(entryId)
        return await self.mutateTranscript(key, SessionManager.rewindMethod, .object(params),
                                           success: "Rewound the session") != nil
    }

    /// Recovers a restart-tombstoned session into a fresh one (`sessions.recover`, write scope).
    public func recover(key: String) async -> SessionRecoverResult? {
        self.begin([key])
        defer { self.end([key]) }
        var params: [String: JSONValue] = ["key": .string(key)]
        if let agentId = self.row(key)?.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        do {
            let response = try await self.call(SessionManager.recoverMethod, .object(params))
            guard let result = SessionRecoverResult(response) else {
                self.actionError = "The Gateway didn't return the recovered session."
                return nil
            }
            self.lastMessage = "Recovered the session"
            if let error = result.continuationError { self.actionError = error }
            self.forgetCaches(key)
            await self.onTranscriptChanged(key, .changed(editorText: nil))
            await self.onSessionsChanged()
            await self.reload()
            return result
        } catch {
            self.actionError = Self.message(error)
            return nil
        }
    }

    private func mutateTranscript(_ key: String, _ method: String, _ params: JSONValue, success: String) async -> JSONValue? {
        self.begin([key])
        defer { self.end([key]) }
        do {
            let result = try await self.call(method, params)
            self.lastMessage = success
            self.lastEditorText = method == SessionManager.rewindMethod ? result["editorText"]?.string : nil
            self.forgetCaches(key)
            await self.onTranscriptChanged(key, .changed(editorText: self.lastEditorText))
            async let branches: Void = self.loadBranches(key: key)
            async let points: Void = self.loadRewindPoints(key: key)
            async let details: Void = self.loadDetails(key: key)
            _ = await (branches, points, details)
            return result
        } catch {
            self.actionError = Self.message(error)
            return nil
        }
    }

    public func clearMessages() {
        self.lastMessage = nil
        self.actionError = nil
        self.lastFailures = []
        self.lastFailureTitles = [:]
        self.lastEditorText = nil
    }

    // MARK: Events

    /// Keeps the list current from `sessions.changed` while it's loaded.
    func handleSessionsChanged(_ payload: JSONValue) {
        guard self.hasLoaded else { return }
        let reason = payload["reason"]?.text
        let key = payload["session"]?["key"]?.text ?? payload["sessionKey"]?.text ?? payload["key"]?.text
        if let key, reason == "delete" || reason == "deleted" {
            self.forget(key)
            return
        }
        if let key, let reason, SessionManager.transcriptChangingReasons.contains(reason) {
            self.forgetCaches(key)
        }
        guard let row = payload["session"].flatMap(SessionRow.init) else {
            self.scheduleReload()
            return
        }
        if let index = self.rows.firstIndex(where: { $0.key == row.key }) {
            let previous = self.rows[index]
            if previous.activityMs != row.activityMs { self.forgetPreview(row.key) }
            let merged = row.keepingPreview(of: previous)
            if merged != previous { self.rows[index] = merged }
        } else if self.filter.includes(row) {
            self.rows.append(row)
        }
        if self.details[row.key] != nil { self.details[row.key] = row }
    }

    func handleReconnect() {
        self.detailLoadOwners = [:]
        self.deniedAdmin = false
        self.rejectedMethods = []
        for key in Set(self.previews.keys).union(self.previewsInFlight) { self.previewGenerations[key, default: 0] += 1 }
        self.previewsInFlight = []
        self.previews = [:]
        self.previewErrors = [:]
        self.branches = [:]
        self.branchErrors = [:]
        self.rewindLoadOwners = [:]
        self.rewindPoints = [:]
        self.rewindErrors = [:]
        if self.hasLoaded { self.scheduleReload() }
    }

    private func scheduleReload() {
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: Plumbing

    private func sessionKeyParams(_ key: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["sessionKey": .string(key)]
        if let agentId = self.row(key)?.raw["agentId"]?.text { params["agentId"] = .string(agentId) }
        return params
    }

    private func apply(archived: Bool, to keys: Set<String>) {
        guard !keys.isEmpty else { return }
        self.rows = self.rows.compactMap { row in
            guard keys.contains(row.key), case var .object(fields) = row.raw else { return row }
            fields["archived"] = .bool(archived)
            if !archived { fields["archivedAt"] = nil }
            guard let next = SessionRow(.object(fields)) else { return row }
            return self.filter.includes(next) ? next : nil
        }
    }

    private func forget(_ key: String) {
        self.detailLoadOwners[key] = nil
        self.rows.removeAll { $0.key == key }
        self.details[key] = nil
        self.detailErrors[key] = nil
        self.forgetCaches(key)
    }

    private func forgetCaches(_ key: String) {
        self.forgetPreview(key)
        self.rewindLoadOwners[key] = nil
        self.rewindPoints[key] = nil
        self.rewindErrors[key] = nil
    }

    /// Views reload a preview (and rewind points) whenever the entry goes missing.
    private func forgetPreview(_ key: String) {
        self.previewGenerations[key, default: 0] += 1
        self.previewsInFlight.remove(key)
        if self.previews[key] != nil { self.previews[key] = nil }
        if self.previewErrors[key] != nil { self.previewErrors[key] = nil }
    }

    private func begin(_ keys: [String]) {
        self.clearMessages()
        self.busy.formUnion(keys)
        if keys.count > 1 { self.isWorking = true }
    }

    private func end(_ keys: [String]) {
        self.busy.subtract(keys)
        if self.busy.isEmpty { self.isWorking = false }
    }

    private static func failureTitles(_ failures: [SessionBulkOutcome.Failure],
                                      targets: [SessionRow]) async -> [String: String] {
        guard !failures.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let failedKeys = Set(failures.map(\.key))
            var titles: [String: String] = [:]
            for row in targets where failedKeys.contains(row.key) {
                let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { titles[row.key] = title }
            }
            return titles
        }.value
    }

    private func finish(_ outcome: SessionBulkOutcome, verb: String, failureTitles: [String: String]) {
        self.lastFailures = outcome.failed
        self.lastFailureTitles = failureTitles
        if !outcome.succeeded.isEmpty || outcome.failed.isEmpty {
            self.lastMessage = SessionManager.bulkSummary(verb: verb, outcome)
        }
        if let first = outcome.failed.first {
            self.actionError = outcome.failed.count == 1 && outcome.succeeded.isEmpty
                ? first.message
                : "\(outcome.failed.count) \(outcome.failed.count == 1 ? "session" : "sessions") failed: \(first.message)"
        }
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
        case .needsAdmin: SessionManager.needsAdminMessage
        case .unsupported: SessionManager.unsupportedMessage
        case let other: other.message
        }
    }
}
