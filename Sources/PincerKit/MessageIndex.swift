import Compression
import Foundation
import SQLite3
import Synchronization

/// How a saved transcript differs from the one last indexed.
public enum IndexChange: Sendable, Equatable {
    /// Nothing is known: index the whole transcript. `token` identifies this save.
    case full(token: String?)
    /// The first `unchangedPrefix` items equal those of the save identified by `baseToken`,
    /// so only what follows is indexed. Falls back to `.full` when that save isn't the one indexed.
    case tail(unchangedPrefix: Int, baseToken: String, token: String)
}

/// What indexing a slice of a transcript came to.
public enum IndexOutcome: Sendable, Equatable {
    case done
    /// The slice doesn't reach back far enough (or the change needs the whole transcript);
    /// call again with all of it.
    case needsEarlierItems
}

/// On-disk full-text index of one Gateway's cached transcripts (SQLite FTS5), next to the
/// transcripts themselves. It's derived data: a file that isn't a readable index of this version
/// (an old version, a corrupt file) is deleted and rebuilt from the transcript cache. Failures
/// that may pass (busy, disk full, I/O, the file locked with the device) only fail that operation.
///
/// `TranscriptCache.save` keeps it current; `reconcile` catches up on transcripts it hasn't
/// seen (caches written before the index existed, or while it was being rebuilt). Decoding
/// transcripts and building what's indexed happen off the actor, so searches don't wait on them.
public actor MessageIndex {
    public enum Status: Hashable, Sendable {
        case ready
        /// Indexing cached chats; results may be incomplete.
        case building(done: Int, total: Int)
        /// The transcript cache is off (and the index isn't kept in memory), so there's nothing to search.
        case unavailable
    }

    public typealias IndexChange = PincerKit.IndexChange

    public enum IndexError: Error {
        case unavailable
        /// A failure that may pass; the index is kept.
        case sqlite(String)
        /// Not a readable index of this version; it's deleted and rebuilt.
        case corrupt(String)
        /// The file was deleted or replaced while open (the cache folder was cleared, or the
        /// system purged it); it's deleted and rebuilt like a corrupt one.
        case vanished(String)
    }

    /// Bump when the schema or what's indexed changes; the old index is then rebuilt.
    static let schemaVersion: Int32 = 4
    static var userVersion: Int32 { self.schemaVersion * 1000 + Int32(TranscriptCache.Snapshot.currentVersion) }

    public nonisolated let gatewayId: UUID
    /// The transcript cache root this index lives under; nil when the cache is off.
    public nonisolated let root: URL?
    var db: OpaquePointer?
    var openLocation: Location?
    /// The open index file's device and inode, to notice it was deleted or replaced.
    var openFileID: FileID?
    nonisolated let removed: Mutex<Bool>
    private nonisolated let interrupter = Interrupter()
    nonisolated let inFlight = InFlight()

    /// An index is per (cache root, Gateway): the same Gateway under two roots (tests, checks)
    /// gets two independent indexes.
    private struct Key: Hashable {
        var root: String?
        var gatewayId: UUID
    }

    private static func rootKey(_ root: URL?) -> String? {
        root?.standardizedFileURL.path(percentEncoded: false)
    }

    private struct Registry {
        var indexes: [Key: MessageIndex] = [:]
        /// Gateways removed from the app: their indexes are never recreated. Not per root: a
        /// Gateway removed from the app is gone wherever it was cached.
        var removed: Set<UUID> = []
        /// Gateways whose index is kept in memory while the transcript cache is off (the demo).
        /// Only consulted for a nil root, so it never affects an index under a real root.
        var inMemory: Set<UUID> = []
        /// Cache folders being deleted (`whileDeleting`), per root, so deleting one root doesn't
        /// stall indexes under another.
        var deleting: [String?: Int] = [:]
        /// A single Gateway's folder being deleted (`whileDeleting(gatewayId:)`): only its own
        /// index is held back, not the other Gateways' under the same root (#458).
        var deletingGateway: [Key: Int] = [:]
        /// Closes started by `discard` and not finished yet, per root.
        var closing: [UUID: (root: String?, task: Task<Void, Never>)] = [:]
    }

    /// Where an index lives: next to the transcript cache, or in memory.
    public enum Location: Equatable, Sendable {
        case file(URL)
        case memory
    }

    private static let registry = Mutex(Registry())

    /// The index for a Gateway under a cache root. One per (root, Gateway), shared by everything
    /// that reads or writes it.
    public static func shared(gatewayId: UUID, root: URL? = TranscriptCache.root) -> MessageIndex {
        let key = Key(root: self.rootKey(root), gatewayId: gatewayId)
        return self.registry.withLock { registry in
            if let index = registry.indexes[key] { return index }
            // A file opened now would be deleted under its connection, leaving search broken
            // until relaunch. Until the deletion is done, hand out an inert index instead.
            if registry.deleting[key.root, default: 0] > 0 || registry.deletingGateway[key, default: 0] > 0 { return MessageIndex(gatewayId: gatewayId, root: root, removed: true) }
            let index = MessageIndex(gatewayId: gatewayId, root: root, removed: registry.removed.contains(gatewayId))
            registry.indexes[key] = index
            return index
        }
    }

    /// Forgets the Gateway's index under `root` (its files are deleted with the transcript
    /// cache). Anything still running on the old instance can't recreate the file. `permanently`
    /// (the Gateway was removed from the app): no later instance can either, under any root, and
    /// indexes it has under other roots are retired too.
    static func discard(gatewayId: UUID, root: URL? = TranscriptCache.root, permanently: Bool = false) {
        let key = Key(root: self.rootKey(root), gatewayId: gatewayId)
        let retired: [(Key, MessageIndex)] = self.registry.withLock { registry in
            var retired: [(Key, MessageIndex)] = []
            if permanently {
                registry.removed.insert(gatewayId)
                for (other, index) in registry.indexes where other.gatewayId == gatewayId { retired.append((other, index)) }
            } else if let index = registry.indexes[key] {
                retired.append((key, index))
            }
            for (other, _) in retired { registry.indexes.removeValue(forKey: other) }
            return retired
        }
        for (retiredKey, index) in retired {
            index.removed.withLock { $0 = true }
            index.interrupter.interruptAny()
            let id = UUID()
            let task = Task {
                await index.close()
                self.registry.withLock { _ = $0.closing.removeValue(forKey: id) }
            }
            self.registry.withLock { $0.closing[id] = (retiredKey.root, task) }
        }
    }

    /// Runs `body`, which discards indexes and deletes their folders under `root`, without
    /// creating an index there meanwhile. Writes in that window are dropped, like the
    /// transcripts they index. With `gatewayId`, `body` deletes only that Gateway's folder, so
    /// only its index is held back: another Gateway's save in the window is indexed, its
    /// transcript being untouched (#458).
    static func whileDeleting(root: URL? = TranscriptCache.root, gatewayId: UUID? = nil, _ body: () -> Void) {
        let key = self.rootKey(root)
        let gatewayKey = gatewayId.map { Key(root: key, gatewayId: $0) }
        self.registry.withLock { registry in
            if let gatewayKey { registry.deletingGateway[gatewayKey, default: 0] += 1 } else { registry.deleting[key, default: 0] += 1 }
        }
        defer {
            self.registry.withLock { registry in
                if let gatewayKey {
                    registry.deletingGateway[gatewayKey, default: 1] -= 1
                    if registry.deletingGateway[gatewayKey] == 0 { registry.deletingGateway.removeValue(forKey: gatewayKey) }
                } else {
                    registry.deleting[key, default: 1] -= 1
                    if registry.deleting[key] == 0 { registry.deleting.removeValue(forKey: key) }
                }
            }
        }
        body()
    }

    /// The Gateway was removed from the app, so nothing may be cached for it again.
    static func isDiscardedPermanently(gatewayId: UUID) -> Bool {
        self.registry.withLock { $0.removed.contains(gatewayId) }
    }

    /// Waits until the index's pending work (saves being indexed, a reconcile, a close started by
    /// `discard`) for the Gateway under `root` is done. Replaces sleeping for it to settle.
    public static func flush(gatewayId: UUID, root: URL? = TranscriptCache.root) async {
        let key = Key(root: self.rootKey(root), gatewayId: gatewayId)
        let index = self.registry.withLock { $0.indexes[key] }
        await index?.inFlight.idle()
        await index?.settle()
        await self.awaitClosing(root: key.root)
    }

    /// Waits for pending work, then closes and forgets every index under `root`. A later
    /// `shared` opens a fresh one. Anything still holding an old instance reopens it on use.
    public static func shutdown(root: URL? = TranscriptCache.root) async {
        let key = self.rootKey(root)
        let indexes = self.registry.withLock { registry in
            let matching = registry.indexes.filter { $0.key.root == key }
            for entry in matching { registry.indexes.removeValue(forKey: entry.key) }
            return Array(matching.values)
        }
        for index in indexes {
            await index.inFlight.idle()
            await index.close()
        }
        await self.awaitClosing(root: key)
    }

    private static func awaitClosing(root: String?) async {
        let tasks = self.registry.withLock { $0.closing.values.filter { $0.root == root }.map(\.task) }
        for task in tasks { await task.value }
    }

    /// Runs after everything queued on the actor.
    private func settle() {}

    init(gatewayId: UUID, root: URL? = TranscriptCache.root, removed: Bool = false) {
        self.gatewayId = gatewayId
        self.root = root
        self.removed = Mutex(removed)
    }

    /// `search-index.sqlite` in the Gateway's transcript cache folder; nil when the cache is off.
    public static func url(gatewayId: UUID, root: URL? = TranscriptCache.root) -> URL? {
        TranscriptCache.directory(gatewayId: gatewayId, root: root)?.appending(path: "search-index.sqlite")
    }

    /// Keeps the Gateway's index in memory while the transcript cache is off, so search still
    /// works (the demo, whose chats are always at hand). Saved transcripts are indexed directly.
    static func allowInMemory(gatewayId: UUID) {
        self.registry.withLock { _ = $0.inMemory.insert(gatewayId) }
    }

    /// The index file when the transcript cache is on; memory when it's off and allowed; else nil.
    public static func location(gatewayId: UUID, root: URL? = TranscriptCache.root) -> Location? {
        if let url = self.url(gatewayId: gatewayId, root: root) { return .file(url) }
        return self.registry.withLock { $0.inMemory.contains(gatewayId) } ? .memory : nil
    }

    /// Ready, or unavailable when there's nowhere to keep the index.
    public static func status(gatewayId: UUID, root: URL? = TranscriptCache.root) -> Status {
        self.location(gatewayId: gatewayId, root: root) == nil ? .unavailable : .ready
    }

    public var status: Status { Self.status(gatewayId: self.gatewayId, root: self.root) }

    nonisolated var location: Location? { Self.location(gatewayId: self.gatewayId, root: self.root) }

    /// Counts operations under way so `flush` can wait for them.
    final class InFlight: Sendable {
        private struct State {
            var count = 0
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func begin() { self.state.withLock { $0.count += 1 } }

        func end() {
            let waiters: [CheckedContinuation<Void, Never>] = self.state.withLock { state in
                state.count -= 1
                guard state.count == 0 else { return [] }
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func idle() async {
            await withCheckedContinuation { continuation in
                let ready = self.state.withLock { state -> Bool in
                    if state.count == 0 { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    nonisolated let stats = Mutex(IndexStats(path: .skipped))
    // MARK: Searching

    /// Messages whose words start with every query word, newest first. Not yet checked against
    /// the text as shown (`MessageSearch.collect` does that). Cancelling the task interrupts it
    /// (it throws `CancellationError`); no other search is affected.
    public func search(_ query: String, candidateLimit: Int = 2000) async throws -> [MessageSearch.Hit] {
        let interrupter = self.interrupter
        let id = interrupter.makeID()
        return try await withTaskCancellationHandler {
            try self.search(query, candidateLimit: candidateLimit, id: id)
        } onCancel: {
            interrupter.cancel(id)
        }
    }

    private func search(_ query: String, candidateLimit: Int, id: UInt64) throws -> [MessageSearch.Hit] {
        guard let fts = MessageSearch.ftsQuery(query) else { return [] }
        guard self.location != nil, !self.isRemoved else { return [] }
        guard !Task.isCancelled else { throw CancellationError() }
        let db: OpaquePointer
        do {
            db = try self.open()
        } catch {
            self.recover(from: error)
            throw error
        }
        self.interrupter.begin(db, id: id)
        defer { self.interrupter.end() }
        // Cancelled before `begin`: the handler found nothing to interrupt.
        guard !Task.isCancelled else { throw CancellationError() }
        do {
            let statement = try self.prepare(db, """
                SELECT d.session_key, d.entry_id, d.section, d.role, d.via, d.ts, d.body, d.sender
                FROM messages JOIN docs d ON d.id = messages.rowid
                WHERE messages MATCH ? ORDER BY d.ts DESC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            try self.bind(statement, [.text(fts), .int(candidateLimit)])
            var hits: [MessageSearch.Hit] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                if result == SQLITE_INTERRUPT || Task.isCancelled { throw CancellationError() }
                guard result == SQLITE_ROW else { throw self.error(db) }
                hits.append(MessageSearch.Hit(
                    sessionKey: Self.text(statement, 0) ?? "",
                    entryId: Self.text(statement, 1) ?? "",
                    section: Int(sqlite3_column_int64(statement, 2)),
                    role: ChatRole(rawValue: Self.text(statement, 3) ?? "") ?? .assistant,
                    via: Self.text(statement, 4),
                    timestamp: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil
                        : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)),
                    text: Self.unpacked(statement, 6) ?? "",
                    sender: Self.decodedSender(Self.text(statement, 7))))
            }
            return hits
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || sqlite3_errcode(db) == SQLITE_INTERRUPT { throw CancellationError() }
            self.recover(from: error)
            throw error
        }
    }

    /// Every chat with rows in the index.
    public func indexedSessionKeys() -> [String] {
        self.withRecovery { db in
            let statement = try self.prepare(db, "SELECT session_key FROM chats")
            defer { sqlite3_finalize(statement) }
            var keys: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { if let key = Self.text(statement, 0) { keys.append(key) } }
            return keys
        } ?? []
    }

    /// Whether the chat has been indexed.
    public func isIndexed(sessionKey: String) -> Bool {
        self.withRecovery { db in try self.chatRow(sessionKey, db: db) != nil } ?? false
    }

    /// The chat's row in the `chats` table, for checks: what was indexed and when.
    public func chatInfo(sessionKey: String) -> (itemCount: Int, lastItemId: String?, digest: String?, fileMtime: Date)? {
        guard let row = self.withRecovery({ db in try self.chatRow(sessionKey, db: db) }) ?? nil else { return nil }
        return (row.itemCount, row.lastItemId, row.digest, Date(timeIntervalSinceReferenceDate: row.mtime))
    }

    /// The chat's message rows as `entry#section@pos:hash`, in index order, for checks.
    func indexedRows(sessionKey: String) -> [String] {
        self.withRecovery { db in
            let statement = try self.prepare(db, "SELECT entry_id, section, pos, hash FROM docs WHERE session_key = ? ORDER BY pos, entry_id, section")
            defer { sqlite3_finalize(statement) }
            try self.bind(statement, [.text(sessionKey)])
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append("\(Self.text(statement, 0) ?? "")#\(sqlite3_column_int64(statement, 1))@\(sqlite3_column_int64(statement, 2)):\(Self.text(statement, 3) ?? "")")
            }
            return rows
        } ?? []
    }

    func chatToken(sessionKey: String) -> String? {
        (self.withRecovery { db in try self.chatRow(sessionKey, db: db) } ?? nil)?.token
    }

    public func close() {
        // Once this returns no interrupt is in flight, and none can reach the freed connection.
        self.interrupter.end()
        if let db { sqlite3_close_v2(db) }
        self.db = nil
        self.openLocation = nil
        self.openFileID = nil
    }

}

/// Lets a cancelled search stop mid-query (`sqlite3_interrupt` is safe from any thread) without
/// touching any other search on the connection.
private final class Interrupter: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    /// The running search, and whether its task was cancelled.
    private var running: UInt64 = 0
    private var cancelled = false
    private var lastID: UInt64 = 0

    func makeID() -> UInt64 {
        self.lock.withLock {
            self.lastID += 1
            return self.lastID
        }
    }

    func begin(_ db: OpaquePointer, id: UInt64) {
        self.lock.withLock {
            self.db = db
            self.running = id
            self.cancelled = false
        }
    }

    /// Once this returns, no interrupt is in flight and none can reach the connection.
    func end() {
        self.lock.withLock {
            self.db = nil
            self.running = 0
            self.cancelled = false
        }
    }

    /// Search `id`'s task was cancelled: interrupt it if it's the one running.
    func cancel(_ id: UInt64) {
        self.lock.withLock {
            guard id == self.running, let db = self.db else { return }
            self.cancelled = true
            sqlite3_interrupt(db)
        }
    }

    func interruptIfCancelled() {
        self.lock.withLock { if self.cancelled, let db = self.db { sqlite3_interrupt(db) } }
    }

    /// The index is going away: stop whatever runs.
    func interruptAny() {
        self.lock.withLock { if let db = self.db { sqlite3_interrupt(db) } }
    }
}

extension MessageIndex {
    /// For a cancellation handler around `search`: stops the running search if its task was
    /// cancelled. A search that wasn't cancelled keeps going, so one caller's cancellation can't
    /// stop another's search. (`search` already stops itself when its task is cancelled.)
    public nonisolated func interrupt() {
        self.interrupter.interruptIfCancelled()
    }
}

