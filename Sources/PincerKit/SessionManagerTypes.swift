import Foundation

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
        return GatewayDates.iso(text) ?? Double(text).map { Date(timeIntervalSince1970: $0 / 1000) }
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
