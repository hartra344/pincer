import Foundation
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// One chat as Spotlight sees it.
public struct SpotlightEntry: Hashable, Sendable {
    /// The chat's `pincer://open?...` URL string; also handed back when a result is tapped.
    public var id: String
    public var gatewayId: UUID
    public var sessionKey: String
    public var title: String
    public var snippet: String?
    /// The user-configured Gateway name, included separately from optional message text.
    public var gatewayName: String?
    public var lastActivity: Date?

    /// The descriptive text Spotlight indexes below the result's title.
    public var contentDescription: String? {
        let parts = [self.gatewayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                     self.snippet?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var domainIdentifier: String { Spotlight.domain(gatewayId) }
}

/// Where Spotlight entries go. Calls are fire-and-forget; a failed call only costs a stale result.
public protocol SpotlightIndexer: Sendable {
    func index(_ entries: [SpotlightEntry]) async
    func delete(ids: [String]) async
    func deleteDomain(gatewayId: UUID) async
    func deleteAll() async
}

public enum Spotlight {
    public static let enabledKey = "pincer.spotlight.enabled"
    public static let includeMessagesKey = "pincer.spotlight.includeMessages"
    public static let enabledDefault = true
    public static let includeMessagesDefault = false
    public static let maxEntries = 200
    /// Core Spotlight drops items after 30 days unless told otherwise.
    public static let expirationDate = Date.distantFuture
    public static let maxSnippetLength = 300
    static let snippetMessages = 3
    /// Transcript items read per chat; enough for three text messages among tool and marker rows.
    static let tailItems = 20

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: self.enabledKey) as? Bool ?? self.enabledDefault
    }

    public static func includesMessages(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: self.includeMessagesKey) as? Bool ?? self.includeMessagesDefault
    }

    /// Whether an async reindex still matches the privacy settings it began with.
    package static func canPublish(includeMessages: Bool, defaults: UserDefaults = .standard) -> Bool {
        Self.isEnabled(defaults) && Self.includesMessages(defaults) == includeMessages
    }

    public static func domain(_ gatewayId: UUID) -> String { "gateway:\(gatewayId.uuidString)" }

    /// The identifier for a chat: its deep link, so a tapped result opens like any `pincer://` URL.
    public static func identifier(gatewayId: UUID, sessionKey: String, gatewayURL: String?, gatewayHost: String?) -> String {
        PincerRoute(gateway: .id(gatewayId), sessionKey: sessionKey, gatewayURL: gatewayURL, gatewayHost: gatewayHost)
            .url.absoluteString
    }

    /// The newest `cap` non-archived, non-placeholder chats. `cachedSnippets` (by session key) are
    /// used only when `includeMessages` is on.
    public static func entries(gatewayId: UUID, gatewayURL: String? = nil, gatewayHost: String? = nil,
                              gatewayName: String? = nil,
                              sessions: [SessionRow], cachedSnippets: [String: String] = [:],
                              includeMessages: Bool, cap: Int = Spotlight.maxEntries) -> [SpotlightEntry]
    {
        let rows = self.candidates(sessions, cap: cap)
        return rows.map { row in
            SpotlightEntry(
                id: self.identifier(gatewayId: gatewayId, sessionKey: row.key, gatewayURL: gatewayURL, gatewayHost: gatewayHost),
                gatewayId: gatewayId, sessionKey: row.key, title: row.title,
                snippet: includeMessages ? cachedSnippets[row.key].flatMap { $0.isEmpty ? nil : $0 } : nil,
                gatewayName: gatewayName,
                lastActivity: row.activityDate)
        }
    }

    /// The chats worth indexing, newest first.
    static func candidates(_ sessions: [SessionRow], cap: Int) -> [SessionRow] {
        let rows = sessions.filter { !$0.isArchived && !$0.isPlaceholder }
            .sorted { ($0.activityMs, $1.key) > ($1.activityMs, $0.key) }
        return Array(rows.prefix(max(0, cap)))
    }

    /// The last few user and assistant messages, each trimmed, joined and capped.
    public static func snippet(from items: [ChatItem], limit: Int = Spotlight.maxSnippetLength) -> String? {
        let texts = items.filter { ($0.role == .user || $0.role == .assistant) && !$0.isPending }
            .compactMap { item -> String? in
                let text = item.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return text.isEmpty ? nil : text
            }
            .suffix(self.snippetMessages)
        let joined = texts.joined(separator: " · ")
        guard !joined.isEmpty else { return nil }
        return joined.count > limit ? String(joined.prefix(limit)) : joined
    }
}

/// Records calls; the indexer tests and checks use instead of Core Spotlight.
public final class FakeSpotlightIndexer: SpotlightIndexer, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: SpotlightEntry] = [:]
    private var log: [String] = []

    public init() {}

    public var entries: [SpotlightEntry] { self.locked { Array(self.items.values) } }
    public var ids: Set<String> { self.locked { Set(self.items.keys) } }
    /// One line per call, e.g. `index:2`, `delete:1`, `domain`, `all`.
    public var calls: [String] { self.locked { self.log } }

    public func index(_ entries: [SpotlightEntry]) async {
        self.locked {
            for entry in entries { self.items[entry.id] = entry }
            self.log.append("index:\(entries.count)")
        }
    }

    public func delete(ids: [String]) async {
        self.locked {
            for id in ids { self.items.removeValue(forKey: id) }
            self.log.append("delete:\(ids.count)")
        }
    }

    public func deleteDomain(gatewayId: UUID) async {
        self.locked {
            self.items = self.items.filter { $0.value.gatewayId != gatewayId }
            self.log.append("domain")
        }
    }

    public func deleteAll() async {
        self.locked {
            self.items = [:]
            self.log.append("all")
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }
}

#if canImport(CoreSpotlight)
public struct CoreSpotlightIndexer: SpotlightIndexer {
    public init() {}

    public func index(_ entries: [SpotlightEntry]) async {
        guard !entries.isEmpty else { return }
        let items = entries.map { entry -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = entry.title
            attributes.displayName = entry.title
            attributes.contentDescription = entry.contentDescription
            attributes.contentModificationDate = entry.lastActivity
            attributes.lastUsedDate = entry.lastActivity
            let item = CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: entry.domainIdentifier,
                                        attributeSet: attributes)
            item.expirationDate = Spotlight.expirationDate
            return item
        }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().indexSearchableItems(items) { _ in continuation.resume() }
        }
    }

    public func delete(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids) { _ in continuation.resume() }
        }
    }

    public func deleteDomain(gatewayId: UUID) async {
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Spotlight.domain(gatewayId)]) { _ in
                continuation.resume()
            }
        }
    }

    public func deleteAll() async {
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteAllSearchableItems { _ in continuation.resume() }
        }
    }
}
#endif
