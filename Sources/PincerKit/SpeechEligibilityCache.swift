import Foundation

/// Bounded readiness for Read Aloud. The normalized string is optional because eligibility must
/// remain available even when the speech text is too large to retain in memory.
public struct SpeechEligibilityCache {
    public struct Token: Equatable, Sendable {
        fileprivate let messageID: String
        fileprivate let generation: UInt64
    }

    public struct Value: Equatable, Sendable {
        public let isEligible: Bool
        public let speechText: String?
        /// The store revision at which this result was prepared; callers use it only to prevent
        /// stale explicit playback, not as a global cache key.
        public let sourceRevision: Int

        fileprivate init(isEligible: Bool, speechText: String?, sourceRevision: Int) {
            self.isEligible = isEligible
            self.speechText = speechText
            self.sourceRevision = sourceRevision
        }
    }

    public struct Prepared: Equatable, Sendable {
        public let isEligible: Bool
        public let speechText: String?
        /// Measured by the worker that normalized the text, never by the render lookup.
        public let utf8ByteCount: Int

        public init(isEligible: Bool, speechText: String?, utf8ByteCount: Int) {
            self.isEligible = isEligible
            self.speechText = speechText
            self.utf8ByteCount = max(0, utf8ByteCount)
        }
    }

    private struct Entry {
        var token: Token
        var isPending: Bool
        var value: Value?
        var textCost: Int
    }

    public static let defaultCountLimit = 800
    public static let defaultTextByteLimit = 512 * 1024

    private var entries: BoundedLRUCache<String, Entry>
    private var generation: UInt64 = 0
    public let textByteLimit: Int

    public init(countLimit: Int = Self.defaultCountLimit, textByteLimit: Int = Self.defaultTextByteLimit) {
        self.entries = BoundedLRUCache(countLimit: countLimit, costLimit: max(0, textByteLimit))
        self.textByteLimit = max(0, textByteLimit)
    }

    public var count: Int { self.entries.count }
    public var retainedTextBytes: Int { self.entries.totalCost }

    /// Starts one preparation for an ID, sharing an existing in-flight token when possible.
    /// A previously prepared value remains readable while an explicit tap prepares retained text.
    public mutating func begin(messageID: String) -> Token {
        if let existing = self.entries.value(for: messageID), existing.isPending { return existing.token }
        self.generation &+= 1
        let token = Token(messageID: messageID, generation: self.generation)
        let old = self.entries.value(for: messageID)
        let entry = Entry(token: token, isPending: true, value: old?.value, textCost: old?.textCost ?? 0)
        self.entries.insert(entry, for: messageID, cost: entry.textCost)
        return token
    }

    /// Returns the last completed readiness without inspecting message content.
    public mutating func value(messageID: String) -> Value? {
        self.entries.value(for: messageID)?.value
    }

    public mutating func isPending(messageID: String) -> Bool {
        self.entries.value(for: messageID)?.isPending ?? false
    }

    /// Applies a worker result only if its token is still current. Eligibility survives even
    /// when normalized speech text exceeds the cache's explicit byte budget.
    @discardableResult
    public mutating func complete(_ token: Token, with prepared: Prepared, sourceRevision: Int) -> Bool {
        guard var entry = self.entries.value(for: token.messageID),
              entry.token == token, entry.isPending else { return false }
        let retainText = prepared.isEligible && prepared.utf8ByteCount <= self.textByteLimit
        let speechText = retainText ? prepared.speechText : nil
        entry.isPending = false
        entry.value = Value(isEligible: prepared.isEligible, speechText: speechText, sourceRevision: sourceRevision)
        entry.textCost = speechText == nil ? 0 : prepared.utf8ByteCount
        self.entries.insert(entry, for: token.messageID, cost: entry.textCost)
        return true
    }

    /// Invalidates an edited/deleted message. Any older worker token can no longer complete.
    public mutating func invalidate(messageID: String) {
        self.entries.removeValue(for: messageID)
    }

    public mutating func removeAll() {
        self.entries.removeAll()
    }
}
