import Foundation
import Observation

/// A starred message (#42). OpenClaw has no bookmark or pin API for messages, so bookmarks are
/// kept on this device, per gateway.
public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    public var sessionKey: String
    /// The message's transcript id, as Copy Link and message jumps use it.
    public var messageId: String
    /// The start of the message, for the list.
    public var preview: String
    public var role: String
    public var messageDate: Date?
    public var createdAt: Date

    public var id: String { Self.id(sessionKey: self.sessionKey, messageId: self.messageId) }

    public init(sessionKey: String, messageId: String, preview: String, role: String = "assistant",
                messageDate: Date? = nil, createdAt: Date = Date())
    {
        self.sessionKey = sessionKey
        self.messageId = messageId
        self.preview = preview
        self.role = role
        self.messageDate = messageDate
        self.createdAt = createdAt
    }

    static func id(sessionKey: String, messageId: String) -> String { "\(sessionKey)\u{1F}\(messageId)" }

    /// Preview length kept for the list.
    public static let previewLength = 160

    /// A one-line preview of `text`.
    public static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > Self.previewLength ? String(line.prefix(Self.previewLength - 1)) + "…" : line
    }
}

/// One gateway's bookmarks, newest first, saved in `UserDefaults`.
@MainActor
@Observable
public final class BookmarkStore {
    public let gatewayId: UUID
    public private(set) var bookmarks: [Bookmark] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var index: Set<String> = []

    private static var stores: [UUID: BookmarkStore] = [:]

    /// The shared store for `gatewayId`.
    public static func shared(gatewayId: UUID) -> BookmarkStore {
        if let store = self.stores[gatewayId] { return store }
        let store = BookmarkStore(gatewayId: gatewayId)
        self.stores[gatewayId] = store
        return store
    }

    public init(gatewayId: UUID, defaults: UserDefaults = .standard) {
        self.gatewayId = gatewayId
        self.defaults = defaults
        if let data = defaults.data(forKey: self.defaultsKey),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data)
        {
            self.bookmarks = saved
        }
        self.index = Set(self.bookmarks.map(\.id))
    }

    var defaultsKey: String { "pincer.bookmarks.\(self.gatewayId.uuidString)" }

    public func isBookmarked(sessionKey: String, messageId: String) -> Bool {
        self.index.contains(Bookmark.id(sessionKey: sessionKey, messageId: messageId))
    }

    public func bookmarks(in sessionKey: String) -> [Bookmark] {
        self.bookmarks.filter { $0.sessionKey == sessionKey }
    }

    public func add(_ bookmark: Bookmark) {
        guard !self.index.contains(bookmark.id) else { return }
        self.bookmarks.insert(bookmark, at: 0)
        self.index.insert(bookmark.id)
        self.save()
    }

    public func remove(sessionKey: String, messageId: String) {
        let id = Bookmark.id(sessionKey: sessionKey, messageId: messageId)
        guard self.index.remove(id) != nil else { return }
        self.bookmarks.removeAll { $0.id == id }
        self.save()
    }

    /// Stars the message, or un-stars it if it's starred. Returns whether it's now bookmarked.
    @discardableResult
    public func toggle(_ bookmark: Bookmark) -> Bool {
        if self.index.contains(bookmark.id) {
            self.remove(sessionKey: bookmark.sessionKey, messageId: bookmark.messageId)
            return false
        }
        self.add(bookmark)
        return true
    }

    /// Stars `item` (by its transcript id) in `sessionKey`, or un-stars it.
    @discardableResult
    public func toggle(_ item: ChatItem, sessionKey: String) -> Bool {
        self.toggle(Bookmark(sessionKey: sessionKey, messageId: item.transcriptId ?? item.id,
                             preview: Bookmark.preview(item.plainText), role: item.role.rawValue,
                             messageDate: item.timestamp))
    }

    public func removeAll(sessionKey: String) {
        guard self.bookmarks.contains(where: { $0.sessionKey == sessionKey }) else { return }
        self.bookmarks.removeAll { $0.sessionKey == sessionKey }
        self.index = Set(self.bookmarks.map(\.id))
        self.save()
    }

    public func removeAll() {
        self.bookmarks = []
        self.index = []
        self.defaults.removeObject(forKey: self.defaultsKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(self.bookmarks) { self.defaults.set(data, forKey: self.defaultsKey) }
    }
}
