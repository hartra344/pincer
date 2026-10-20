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

