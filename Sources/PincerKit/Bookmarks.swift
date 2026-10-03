import Foundation
import Observation

/// A starred message (#42). OpenClaw has no bookmark or pin API for messages, so bookmarks are
/// kept per gateway, on this device and synced through the gateway's `users.prefs` (#382).
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

    /// Label for a bookmarked chat whose session may not be loaded on this device.
    public static func chatTitle(_ loadedTitle: String?, sessionKey: String) -> String {
        loadedTitle ?? L("Saved chat")
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

extension Bookmark {
    /// The synced entry value: compact JSON `{"p":preview,"r":role,"m":messageDateMs?,"c":createdAtMs}`.
    var syncedValue: String {
        struct Wire: Encodable { let p: String; let r: String; let m: Int64?; let c: Int64 }
        let wire = Wire(p: Self.syncedPreview(self.preview), r: self.role, m: self.messageDate.map(Self.ms), c: Self.ms(self.createdAt))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(wire)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// A bookmark from a synced entry, or nil when the key or value can't be decoded.
    init?(syncedKey key: String, value: String) {
        struct Wire: Decodable { let p: String; let r: String; let m: Int64?; let c: Int64 }
        let parts = key.components(separatedBy: "\u{1F}")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              let wire = try? JSONDecoder().decode(Wire.self, from: Data(value.utf8)) else { return nil }
        self.init(sessionKey: parts[0], messageId: parts[1], preview: wire.p, role: wire.r,
                  messageDate: wire.m.map(Self.date), createdAt: Self.date(wire.c))
    }

    /// Bookmarks sync in this many `users.prefs` values (`pincer.bookmarks.0`…), since the gateway caps each at 4 KiB.
    public static let shardCount = 8

    /// The pref key for `shard`.
    public static func prefKey(shard: Int) -> String { "pincer.bookmarks.\(shard)" }

    /// The shard of an entry key: FNV-1a (32-bit) over its UTF-8 bytes, which is stable across launches and devices.
    public static func shard(ofKey key: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(Self.shardCount))
    }

    /// Synced previews are short.
    static let syncedPreviewLength = 60

    private static func syncedPreview(_ preview: String) -> String {
        preview.count > Self.syncedPreviewLength ? String(preview.prefix(Self.syncedPreviewLength - 1)) + "…" : preview
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// One gateway's bookmarks, newest first, saved in `UserDefaults`.
@MainActor
@Observable
public final class BookmarkStore {
    public let gatewayId: UUID
    public private(set) var bookmarks: [Bookmark] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var index: Set<String> = []
    @ObservationIgnored private var persistenceRevision = 0
    @ObservationIgnored var previewPreparationQueue = BookmarkPreviewPreparationQueue.shared
    @ObservationIgnored private var previewOperations: [String: UUID] = [:]
#if DEBUG
    /// Causal probe for the actual item-toggle preview preparation, never for removal.
    @ObservationIgnored var previewPreparationProbe: (@Sendable (String, Bool) -> Void)?
    func waitForPreviewPreparation() async { await self.previewPreparationQueue.waitUntilIdle() }
#endif

    /// Most bookmarks kept per gateway; adding beyond drops the oldest.
    public static let limit = 150
    /// Byte budget for one shard's synced map: the gateway rejects a pref value over 4 KiB.
    public static let syncedByteBudget = 3800
    /// How many bookmarks the last `add` dropped to stay within the limits.
    public private(set) var droppedCount = 0
    /// Counts the adds that dropped bookmarks, so a view can react with `.onChange`.
    public private(set) var dropNotice = 0
    /// Called with the synced entry changes (`nil` = delete) after a local edit, never for `apply(synced:)`
    /// or `removeAll()`.
    @ObservationIgnored public var onChange: (([String: String?]) -> Void)?

    private static var stores: [UUID: BookmarkStore] = [:]

    /// The shared store for `gatewayId`.
    public static func shared(gatewayId: UUID, defaults: UserDefaults = .standard) -> BookmarkStore {
        if let store = self.stores[gatewayId] { return store }
        let store = BookmarkStore(gatewayId: gatewayId, defaults: defaults)
        self.stores[gatewayId] = store
        return store
    }

    /// Clears the bookmarks without pushing, and drops the shared instance.
    static func forget(gatewayId: UUID) {
        let store = self.shared(gatewayId: gatewayId)
        store.onChange = nil
        store.removeAll()
        self.stores[gatewayId] = nil
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
        self.invalidatePreview(bookmark.id)
        guard !self.index.contains(bookmark.id) else { return }
        var changes: [String: String?] = [bookmark.id: bookmark.syncedValue]
        self.bookmarks.insert(bookmark, at: 0)
        self.index.insert(bookmark.id)
        self.droppedCount = 0
        let dropped = self.trim(shard: Bookmark.shard(ofKey: bookmark.id))
        self.droppedCount = dropped.count
        if !dropped.isEmpty { self.dropNotice += 1 }
        for victim in dropped { changes[victim.id] = .some(nil) }
        self.save()
        self.onChange?(changes)
    }

    public func remove(sessionKey: String, messageId: String) {
        let id = Bookmark.id(sessionKey: sessionKey, messageId: messageId)
        self.invalidatePreview(id)
        guard self.index.remove(id) != nil else { return }
        self.bookmarks.removeAll { $0.id == id }
        self.save()
        self.onChange?([id: nil])
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
        self.toggle(item, sessionKey: sessionKey, messageId: item.transcriptId ?? item.id)
    }

    /// Applies the star immediately. A text-only worker fills its preview afterward; removing
    /// a star skips admission and preparation entirely. An explicit id preserves the action's
    /// transcript locator even when its original item is no longer loaded.
    @discardableResult
    public func toggle(_ item: ChatItem?, sessionKey: String, messageId: String,
                       onPreviewPrepared: (@MainActor @Sendable (Int) -> Void)? = nil) -> Bool {
        let id = Bookmark.id(sessionKey: sessionKey, messageId: messageId)
        if self.index.contains(id) {
            self.remove(sessionKey: sessionKey, messageId: messageId)
            return false
        }
        self.add(Bookmark(sessionKey: sessionKey, messageId: messageId, preview: "",
                          role: item?.role.rawValue ?? "assistant", messageDate: item?.timestamp))
        guard self.index.contains(id),
              let input = BookmarkPreviewInput.capture(item, sessionKey: sessionKey, messageId: messageId) else { return true }
        let token = UUID()
        self.previewOperations[id] = token
#if DEBUG
        let probe = self.previewPreparationProbe
#else
        let probe: (@Sendable (String, Bool) -> Void)? = nil
#endif
        let admitted = self.previewPreparationQueue.submit(token: token, id: id, input: input, probe: probe) { [weak self] preview in
            guard let self, self.previewOperations[id] == token,
                  let index = self.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            self.previewOperations[id] = nil
            self.bookmarks[index].preview = preview
            let bookmark = self.bookmarks[index]
            let dropped = self.trim(shard: Bookmark.shard(ofKey: id))
            self.droppedCount = dropped.count
            if !dropped.isEmpty { self.dropNotice += 1 }
            self.save()
            var changes: [String: String?] = [:]
            if self.index.contains(id) { changes[id] = bookmark.syncedValue }
            for victim in dropped { changes[victim.id] = .some(nil) }
            self.onChange?(changes)
            onPreviewPrepared?(dropped.count)
        }
        if !admitted { self.previewOperations[id] = nil }
        return true
    }

    private func invalidatePreview(_ id: String) {
        guard let token = self.previewOperations.removeValue(forKey: id) else { return }
        self.previewPreparationQueue.cancel(token)
    }

    public func removeAll(sessionKey: String) {
        let removed = self.bookmarks.filter { $0.sessionKey == sessionKey }
        guard !removed.isEmpty else { return }
        for bookmark in removed { self.invalidatePreview(bookmark.id) }
        self.bookmarks.removeAll { $0.sessionKey == sessionKey }
        self.index = Set(self.bookmarks.map(\.id))
        self.save()
        self.onChange?(Dictionary(uniqueKeysWithValues: removed.map { ($0.id, String?.none) }))
    }

    /// Gateway-confirmed deletion: apply the bounded in-memory edit immediately, then encode the
    /// remaining bookmarks off-main. A newer local edit wins while that encoding is in flight.
    func removeConfirmedSessions(_ sessionKeys: Set<String>) async {
        let removed = self.bookmarks.filter { sessionKeys.contains($0.sessionKey) }
        guard !removed.isEmpty else { return }
        for bookmark in removed { self.invalidatePreview(bookmark.id) }
        self.bookmarks.removeAll { sessionKeys.contains($0.sessionKey) }
        for bookmark in removed { self.index.remove(bookmark.id) }
        self.persistenceRevision += 1
        let revision = self.persistenceRevision
        let remaining = self.bookmarks
        self.onChange?(Dictionary(uniqueKeysWithValues: removed.map { ($0.id, String?.none) }))
        let data = await Task.detached { try? JSONEncoder().encode(remaining) }.value
        guard revision == self.persistenceRevision, let data else { return }
        self.defaults.set(data, forKey: self.defaultsKey)
    }

    /// Drops the oldest bookmarks over the cap, then the oldest in `shard` until its synced map fits.
    private func trim(shard: Int) -> [Bookmark] {
        let oldest: (Bookmark, Bookmark) -> Bool = { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var dropped: [Bookmark] = []
        while self.bookmarks.count > Self.limit, let victim = self.bookmarks.min(by: oldest) {
            dropped.append(victim)
            self.remove(victim)
        }
        while self.bookmarks.filter({ Bookmark.shard(ofKey: $0.id) == shard }).count > 1,
              Self.syncedSize(self.syncedEntries(shard: shard)) > Self.syncedByteBudget,
              let victim = self.bookmarks.filter({ Bookmark.shard(ofKey: $0.id) == shard }).min(by: oldest)
        {
            dropped.append(victim)
            self.remove(victim)
        }
        return dropped
    }

    /// Applies the cap and shard budgets to bookmarks saved before they existed, without pushing,
    /// so their first sync can be written.
    func enforceLimits() {
        var dropped = false
        for shard in 0..<Bookmark.shardCount where !self.trim(shard: shard).isEmpty { dropped = true }
        if dropped {
            self.index = Set(self.bookmarks.map(\.id))
            self.save()
        }
    }

    private func remove(_ bookmark: Bookmark) {
        self.invalidatePreview(bookmark.id)
        self.bookmarks.removeAll { $0.id == bookmark.id }
        self.index.remove(bookmark.id)
    }

    /// Replaces the bookmarks in `shard` with the pulled entries (newest first), skipping undecodable
    /// ones and leaving other shards alone. Doesn't fire `onChange`.
    func apply(synced: [String: String], shard: Int) {
        let local = Dictionary(self.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let decoded = synced.compactMap { Bookmark(syncedKey: $0.key, value: $0.value) }
            .filter { Bookmark.shard(ofKey: $0.id) == shard }
        let remote = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A wire-identical echo of our immediate placeholder must preserve its preparation.
        // Compare canonical wire values (including millisecond dates and shortened previews),
        // rather than Date equality. A missing or genuinely changed value supersedes it.
        let superseded = Set(self.previewOperations.keys.filter { id in
            guard Bookmark.shard(ofKey: id) == shard else { return false }
            guard let known = local[id], let incoming = remote[id] else { return true }
            return known.syncedValue != incoming.syncedValue
        })
        for id in superseded { self.invalidatePreview(id) }
        // Synced previews are shortened; keep the full one when this device has it.
        let merged = decoded.map { remote -> Bookmark in
                guard !superseded.contains(remote.id), let known = local[remote.id] else { return remote }
                var merged = remote
                merged.preview = known.preview
                return merged
            }
        let next = (self.bookmarks.filter { Bookmark.shard(ofKey: $0.id) != shard } + merged)
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        guard next != self.bookmarks else { return }
        self.bookmarks = next
        self.index = Set(next.map(\.id))
        self.save()
    }

    /// The encoded size of a shard's synced map, which is one gateway pref value.
    static func syncedSize(_ entries: [String: String]) -> Int {
        (try? JSONEncoder().encode(entries).count) ?? 0
    }

    /// The synced entries in `shard`.
    func syncedEntries(shard: Int) -> [String: String] {
        Dictionary(self.bookmarks.filter { Bookmark.shard(ofKey: $0.id) == shard }.map { ($0.id, $0.syncedValue) },
                   uniquingKeysWith: { first, _ in first })
    }

    public func removeAll() {
        for id in Array(self.previewOperations.keys) { self.invalidatePreview(id) }
        self.persistenceRevision += 1
        self.bookmarks = []
        self.index = []
        self.defaults.removeObject(forKey: self.defaultsKey)
    }

    private func save() {
        self.persistenceRevision += 1
        if let data = try? JSONEncoder().encode(self.bookmarks) { self.defaults.set(data, forKey: self.defaultsKey) }
    }
}
