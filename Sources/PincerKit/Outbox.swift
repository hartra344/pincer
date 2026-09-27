import Foundation

/// Where an outgoing user message is in its delivery lifecycle.
public enum OutboxState: Codable, Equatable, Sendable {
    /// Waiting for a connection (or its turn in the session queue).
    case queued
    /// `chat.send` is in flight.
    case sending
    /// Delivery failed; the message stays inline until the user retries or deletes it.
    case failed(OutboxFailure)
}

public struct OutboxFailure: Codable, Equatable, Sendable {
    public var message: String
    /// Retrying may succeed (transient failure, revoked auth after re-pairing). False when the
    /// Gateway rejected the message itself.
    public var retryable: Bool

    public init(message: String, retryable: Bool) {
        self.message = message
        self.retryable = retryable
    }
}

/// A user message that hasn't landed in the transcript yet.
public struct OutboxEntry: Codable, Equatable, Identifiable, Sendable {
    /// The `chat.send` idempotency key; stable across retries so the Gateway dedupes resends.
    public var id: String
    public var sessionKey: String
    public var agentId: String?
    public var text: String
    public var replyToId: String?
    public var replyPreview: ReplyPreview?
    public var createdAt: Date
    public var state: OutboxState
    public var attempts: Int
    /// Sends carrying attachments aren't persisted (the bytes stay in memory), so they live for
    /// the current launch only.
    public var hasAttachments: Bool

    public var idempotencyKey: String { self.id }

    public init(
        id: String = UUID().uuidString,
        sessionKey: String,
        agentId: String? = nil,
        text: String,
        replyToId: String? = nil,
        replyPreview: ReplyPreview? = nil,
        createdAt: Date,
        state: OutboxState = .queued,
        attempts: Int = 0,
        hasAttachments: Bool = false)
    {
        self.id = id
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.text = text
        self.replyToId = replyToId
        self.replyPreview = replyPreview
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.hasAttachments = hasAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionKey, agentId, text, replyToId, replyPreview, createdAt, state, attempts, hasAttachments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.sessionKey = try c.decode(String.self, forKey: .sessionKey)
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        self.text = try c.decode(String.self, forKey: .text)
        self.replyToId = try c.decodeIfPresent(String.self, forKey: .replyToId)
        self.replyPreview = try c.decodeIfPresent(ReplyPreview.self, forKey: .replyPreview)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.state = try c.decode(OutboxState.self, forKey: .state)
        self.attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        self.hasAttachments = try c.decodeIfPresent(Bool.self, forKey: .hasAttachments) ?? false
    }

    public var isFailed: Bool {
        if case .failed = self.state { return true }
        return false
    }
}

/// How a failed `chat.send` should be treated.
public enum SendFailureKind: Equatable, Sendable {
    /// Network drop, timeout, not connected, or a Gateway error flagged `retryable`.
    case transient
    /// The Gateway answered with a non-retryable error: don't auto-retry.
    case rejected(String)
    /// Auth, pairing or scope failure: needs the user before it can succeed.
    case authRevoked
}

public enum SendFailure {
    /// `ErrorCodes` (openclaw `packages/gateway-protocol/src/gateway-error-details.ts`) meaning
    /// the operator lost access rather than the message being bad.
    static let authCodes: Set<String> = ["NOT_PAIRED", "NOT_LINKED", "FORBIDDEN"]

    public static func classify(_ error: Error) -> SendFailureKind {
        guard let gateway = error as? GatewayError else { return .transient }
        switch gateway {
        case let .rpc(code, message, _):
            if self.authCodes.contains(code) || gateway.detailCode == "MISSING_SCOPE" { return .authRevoked }
            if gateway.isRetryable { return .transient }
            return .rejected(message)
        case .notConnected, .timeout, .closed:
            return .transient
        case .invalidURL, .insecureURL, .protocolViolation:
            return .rejected(gateway.localizedDescription)
        }
    }
}

/// Pure outgoing-message queue for one Gateway. Entries span sessions and keep insertion order.
///
/// Ordering: within a session, messages go out strictly in order. An entry isn't eligible to
/// send while an earlier entry in the same session is `.sending` or `.failed` — a failed head
/// blocks the rest of that session's queue until the user retries or deletes it, so the agent
/// never sees messages out of order.
public struct Outbox: Codable, Equatable, Sendable {
    public private(set) var entries: [OutboxEntry]

    public init(entries: [OutboxEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { self.entries.isEmpty }
    public var count: Int { self.entries.count }

    public func entry(id: String) -> OutboxEntry? {
        self.entries.first { $0.id == id }
    }

    public func entries(for sessionKey: String) -> [OutboxEntry] {
        self.entries.filter { $0.sessionKey == sessionKey }
    }

    /// Session keys with at least one entry, in first-entry order.
    public var sessionKeys: [String] {
        var seen = Set<String>()
        return self.entries.compactMap { seen.insert($0.sessionKey).inserted ? $0.sessionKey : nil }
    }

    /// Adds an entry; re-enqueueing an existing id replaces it in place.
    public mutating func enqueue(_ entry: OutboxEntry) {
        if let index = self.index(entry.id) {
            self.entries[index] = entry
        } else {
            self.entries.append(entry)
        }
    }

    /// The oldest `.queued` entry whose session has nothing earlier sending or failed.
    public func nextToSend(sessionKey: String? = nil) -> OutboxEntry? {
        var blocked = Set<String>()
        for entry in self.entries {
            if let sessionKey, entry.sessionKey != sessionKey { continue }
            if blocked.contains(entry.sessionKey) { continue }
            if entry.state == .queued { return entry }
            blocked.insert(entry.sessionKey)
        }
        return nil
    }

    /// Whether a queued entry waits behind an earlier message of its chat.
    public func isBlocked(id: String) -> Bool {
        guard let entry = self.entry(id: id), entry.state == .queued else { return false }
        return self.nextToSend(sessionKey: entry.sessionKey)?.id != id
    }

    public mutating func markSending(id: String) {
        guard let index = self.index(id) else { return }
        self.entries[index].state = .sending
        self.entries[index].attempts += 1
    }

    /// The send landed: drop the entry.
    public mutating func markSent(id: String) {
        self.entries.removeAll { $0.id == id }
    }

    /// Records a failed attempt.
    /// - transient while disconnected → `.queued` (auto-sent on reconnect)
    /// - transient while connected (e.g. an ambiguous timeout) → `.failed(retryable: true)`
    /// - rejected → `.failed(retryable: false)`
    /// - authRevoked → `.failed(retryable: true)`, never auto-sent
    public mutating func markFailed(id: String, kind: SendFailureKind, isConnected: Bool = true, message: String? = nil) {
        guard let index = self.index(id) else { return }
        switch kind {
        case .transient:
            if isConnected {
                self.entries[index].state = .failed(OutboxFailure(message: message ?? "Couldn't send.", retryable: true))
            } else {
                self.entries[index].state = .queued
            }
        case let .rejected(reason):
            self.entries[index].state = .failed(OutboxFailure(message: message ?? reason, retryable: false))
        case .authRevoked:
            self.entries[index].state = .failed(OutboxFailure(
                message: message ?? "Not authorized. Reconnect this gateway, then retry.",
                retryable: true))
        }
    }

    /// Failed → queued, so the next flush sends it again with the same idempotency key.
    public mutating func retry(id: String) {
        guard let index = self.index(id), self.entries[index].state != .sending else { return }
        self.entries[index].state = .queued
    }

    /// Gives an entry a new idempotency key in place, for a resend with different params (the
    /// quoted fallback for Gateways without `replyToId`): a reused key with other params is a
    /// conflict to the Gateway. Later retries reuse the new key.
    public mutating func rekey(id: String, to newId: String) {
        guard let index = self.index(id), self.index(newId) == nil else { return }
        self.entries[index].id = newId
    }

    public mutating func delete(id: String) {
        self.entries.removeAll { $0.id == id }
    }

    /// The socket dropped: in-flight sends go back to the queue (the same key makes the resend safe).
    public mutating func connectionLost() {
        self.requeueSending()
    }

    /// The app was killed mid-send: anything left `.sending` goes back to the queue. Attachment
    /// entries can't survive a relaunch, so they're dropped.
    public mutating func recoverAfterLaunch() {
        self.entries.removeAll(where: \.hasAttachments)
        self.requeueSending()
    }

    /// Drops entries whose idempotency key already shows in the transcript: the send landed.
    public mutating func reconcile(committedKeys: Set<String>) {
        guard !committedKeys.isEmpty else { return }
        self.entries.removeAll { committedKeys.contains($0.id) }
    }

    /// The session was deleted or archived: its queued messages go with it.
    public mutating func removeSession(_ key: String) {
        self.entries.removeAll { $0.sessionKey == key }
    }

    /// Entries that survive a relaunch (attachment sends are launch-only).
    public var persistable: Outbox {
        Outbox(entries: self.entries.filter { !$0.hasAttachments })
    }

    private mutating func requeueSending() {
        for index in self.entries.indices where self.entries[index].state == .sending {
            self.entries[index].state = .queued
        }
    }

    private func index(_ id: String) -> Int? {
        self.entries.firstIndex { $0.id == id }
    }
}
