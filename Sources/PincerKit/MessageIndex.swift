import Compression
import Foundation
import SQLite3
import Synchronization

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

    public enum IndexError: Error {
        case unavailable
        /// A failure that may pass; the index is kept.
        case sqlite(String)
        /// Not a readable index of this version; it's deleted and rebuilt.
        case corrupt(String)
    }

    /// Bump when the schema or what's indexed changes; the old index is then rebuilt.
    static let schemaVersion: Int32 = 2
    static var userVersion: Int32 { self.schemaVersion * 1000 + Int32(TranscriptCache.Snapshot.currentVersion) }

    public nonisolated let gatewayId: UUID
    private var db: OpaquePointer?
    private var openLocation: Location?
    private nonisolated let removed: Mutex<Bool>
    private nonisolated let interrupter = Interrupter()

    private struct Registry {
        var indexes: [UUID: MessageIndex] = [:]
        /// Gateways removed from the app: their indexes are never recreated.
        var removed: Set<UUID> = []
        /// Gateways whose index is kept in memory while the transcript cache is off (the demo).
        var inMemory: Set<UUID> = []
    }

    /// Where an index lives: next to the transcript cache, or in memory.
    public enum Location: Equatable, Sendable {
        case file(URL)
        case memory
    }

    private static let registry = Mutex(Registry())

    /// The index for a Gateway. One per Gateway, shared by everything that reads or writes it.
    public static func shared(gatewayId: UUID) -> MessageIndex {
        self.registry.withLock { registry in
            if let index = registry.indexes[gatewayId] { return index }
            let index = MessageIndex(gatewayId: gatewayId, removed: registry.removed.contains(gatewayId))
            registry.indexes[gatewayId] = index
            return index
        }
    }

    /// Forgets the Gateway's index (its files are deleted with the transcript cache). Anything
    /// still running on the old instance can't recreate the file. `permanently` (the Gateway was
    /// removed from the app): no later instance can either.
    static func discard(gatewayId: UUID, permanently: Bool = false) {
        let index = self.registry.withLock { registry in
            if permanently { registry.removed.insert(gatewayId) }
            return registry.indexes.removeValue(forKey: gatewayId)
        }
        guard let index else { return }
        index.removed.withLock { $0 = true }
        index.interrupter.interruptAny()
        Task { await index.close() }
    }

    /// The Gateway was removed from the app, so nothing may be cached for it again.
    static func isDiscardedPermanently(gatewayId: UUID) -> Bool {
        self.registry.withLock { $0.removed.contains(gatewayId) }
    }

    init(gatewayId: UUID, removed: Bool = false) {
        self.gatewayId = gatewayId
        self.removed = Mutex(removed)
    }

    /// `search-index.sqlite` in the Gateway's transcript cache folder; nil when the cache is off.
    public static func url(gatewayId: UUID) -> URL? {
        TranscriptCache.directory(gatewayId: gatewayId)?.appending(path: "search-index.sqlite")
    }

    /// Keeps the Gateway's index in memory while the transcript cache is off, so search still
    /// works (the demo, whose chats are always at hand). Saved transcripts are indexed directly.
    static func allowInMemory(gatewayId: UUID) {
        self.registry.withLock { _ = $0.inMemory.insert(gatewayId) }
    }

    /// The index file when the transcript cache is on; memory when it's off and allowed; else nil.
    public static func location(gatewayId: UUID) -> Location? {
        if let url = self.url(gatewayId: gatewayId) { return .file(url) }
        return self.registry.withLock { $0.inMemory.contains(gatewayId) } ? .memory : nil
    }

    /// Ready, or unavailable when there's nowhere to keep the index.
    public static func status(gatewayId: UUID) -> Status {
        self.location(gatewayId: gatewayId) == nil ? .unavailable : .ready
    }

    public var status: Status { Self.status(gatewayId: self.gatewayId) }

    private nonisolated var location: Location? { Self.location(gatewayId: self.gatewayId) }

    // MARK: Writing

    /// What's recorded about an indexed chat's transcript.
    private struct ChatState: Sendable {
        var mtime: Double
        var itemCount: Int
        var lastItemId: String?
        var digest: String
    }

    /// A message ready to write: its change hash and the folded text the full-text index gets.
    private struct Prepared: Sendable {
        var document: MessageSearch.Document
        var hash: String
        var folded: String
    }

    private enum WriteResult {
        case done
        /// The messages changed; call again with them.
        case needsDocuments
    }

    /// Indexes a chat's saved transcript. Does nothing when its messages haven't changed, and
    /// ignores a snapshot older than the one already indexed.
    public nonisolated func index(sessionKey: String, snapshot: TranscriptCache.Snapshot, fileMtime: Date) async {
        let items = snapshot.items
        // Hashing what the messages are built from is much cheaper than building them, so an
        // unchanged chat costs little.
        let chat = ChatState(mtime: fileMtime.timeIntervalSinceReferenceDate, itemCount: items.count,
                             lastItemId: items.last?.id, digest: Self.digest(items))
        guard !self.isRemoved,
              await self.write(sessionKey: sessionKey, chat: chat, documents: nil) == .needsDocuments,
              !self.isRemoved
        else { return }
        let documents = MessageSearch.documents(sessionKey: sessionKey, items: items).map { document in
            Prepared(document: document, hash: Self.hash(document), folded: MessageSearch.folded(document.text))
        }
        await self.write(sessionKey: sessionKey, chat: chat, documents: documents)
    }

    /// Records `chat`: only its file date when its messages are unchanged, otherwise its
    /// messages too, which needs `documents`.
    @discardableResult
    private func write(sessionKey: String, chat: ChatState, documents: [Prepared]?) -> WriteResult {
        self.withRecovery { db -> WriteResult in
            let existing = try self.chatRow(sessionKey, db: db)
            if let existing, existing.mtime > chat.mtime { return .done }
            let unchanged = existing?.digest == chat.digest
            guard unchanged || documents != nil else { return .needsDocuments }
            try self.exec(db, "BEGIN IMMEDIATE")
            do {
                if unchanged {
                    try self.run(db, "UPDATE chats SET file_mtime = ?, item_count = ?, last_item_id = ? WHERE session_key = ?",
                                 [.double(chat.mtime), .int(chat.itemCount), .text(chat.lastItemId), .text(sessionKey)])
                } else {
                    try self.replace(sessionKey: sessionKey, with: documents ?? [], db: db)
                    try self.run(db, """
                        INSERT OR REPLACE INTO chats (session_key, file_mtime, item_count, last_item_id, digest)
                        VALUES (?, ?, ?, ?, ?)
                        """, [.text(sessionKey), .double(chat.mtime), .int(chat.itemCount), .text(chat.lastItemId),
                              .text(chat.digest)])
                }
                try self.exec(db, "COMMIT")
            } catch {
                try? self.exec(db, "ROLLBACK")
                throw error
            }
            return .done
        } ?? .done
    }

    /// Brings a chat's rows in line with `documents`, touching only messages that were added,
    /// changed or removed, so a new message costs one insert rather than rewriting the chat.
    private func replace(sessionKey: String, with documents: [Prepared], db: OpaquePointer) throws {
        var existing: [String: (id: Int64, hash: String)] = [:]
        let select = try self.prepare(db, "SELECT id, entry_id, section, hash FROM docs WHERE session_key = ?")
        defer { sqlite3_finalize(select) }
        try self.bind(select, [.text(sessionKey)])
        while true {
            let result = sqlite3_step(select)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw self.error(db) }
            let key = "\(Self.text(select, 1) ?? "")#\(sqlite3_column_int64(select, 2))"
            existing[key] = (sqlite3_column_int64(select, 0), Self.text(select, 3) ?? "")
        }
        var removed: [Int64] = []
        var added: [Prepared] = []
        var seen: Set<String> = []
        for prepared in documents {
            let key = "\(prepared.document.entryId)#\(prepared.document.section)"
            guard seen.insert(key).inserted else { continue }
            if let old = existing.removeValue(forKey: key) {
                if old.hash == prepared.hash { continue }
                removed.append(old.id)
            }
            added.append(prepared)
        }
        removed += existing.values.map(\.id)

        if !removed.isEmpty {
            let body = try self.prepare(db, "SELECT body FROM docs WHERE id = ?")
            defer { sqlite3_finalize(body) }
            let unindex = try self.prepare(db, "INSERT INTO messages (messages, rowid, body) VALUES ('delete', ?, ?)")
            defer { sqlite3_finalize(unindex) }
            let delete = try self.prepare(db, "DELETE FROM docs WHERE id = ?")
            defer { sqlite3_finalize(delete) }
            for id in removed {
                try self.bind(body, [.int(Int(id))])
                guard sqlite3_step(body) == SQLITE_ROW else { throw self.error(db) }
                // The index holds folded text; deleting needs the same text it was given.
                let folded = MessageSearch.folded(Self.unpacked(body, 0) ?? "")
                sqlite3_reset(body)
                try self.step(unindex, [.int(Int(id)), .text(folded)], db: db)
                try self.step(delete, [.int(Int(id))], db: db)
            }
        }
        if !added.isEmpty {
            let insert = try self.prepare(db, """
                INSERT INTO docs (session_key, entry_id, section, role, via, ts, hash, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            let index = try self.prepare(db, "INSERT INTO messages (rowid, body) VALUES (?, ?)")
            defer { sqlite3_finalize(index) }
            for prepared in added {
                let document = prepared.document
                try self.step(insert, [
                    .text(sessionKey), .text(document.entryId), .int(document.section), .text(document.role.rawValue),
                    .text(document.via), .double(document.timestamp?.timeIntervalSinceReferenceDate), .text(prepared.hash),
                    .blob(Self.packed(document.text)),
                ], db: db)
                let id = sqlite3_last_insert_rowid(db)
                try self.step(index, [.int(Int(id)), .text(prepared.folded)], db: db)
            }
        }
    }

    /// Indexes every cached transcript of `sessionKeys` written since it was last indexed, one
    /// chat at a time, reporting progress. Transcripts are read and decoded off the actor.
    public nonisolated func reconcile(sessionKeys: [String], progress: (@Sendable (Status) async -> Void)? = nil) async {
        guard self.location != nil else {
            await progress?(.unavailable)
            return
        }
        var files: [(key: String, url: URL, mtime: Date)] = []
        for key in Set(sessionKeys).sorted() {
            guard let url = TranscriptCache.file(gatewayId: self.gatewayId, sessionKey: key),
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            files.append((key, url, mtime))
        }
        let indexed = await self.indexedMtimes(files.map(\.key))
        let stale = files.filter { file in
            indexed[file.key].map { $0 < file.mtime.timeIntervalSinceReferenceDate } ?? true
        }
        guard !stale.isEmpty else {
            await progress?(.ready)
            return
        }
        for (done, chat) in stale.enumerated() {
            if Task.isCancelled || self.isRemoved { break }
            await progress?(.building(done: done, total: stale.count))
            guard let data = try? Data(contentsOf: chat.url),
                  let snapshot = try? JSONDecoder().decode(TranscriptCache.Snapshot.self, from: data),
                  snapshot.version == TranscriptCache.Snapshot.currentVersion
            else { continue }
            await self.index(sessionKey: chat.key, snapshot: snapshot, fileMtime: chat.mtime)
        }
        await self.truncateLog()
        await progress?(.ready)
    }

    /// Folds the write-ahead log into the index and empties it, so a big build doesn't leave
    /// a large WAL file behind.
    private func truncateLog() {
        self.withRecovery { db in try self.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    /// When each of these chats' transcripts was last indexed; chats never indexed are left out.
    private func indexedMtimes(_ sessionKeys: [String]) -> [String: Double] {
        var mtimes: [String: Double] = [:]
        for key in sessionKeys {
            if let mtime = self.withRecovery({ db in try self.chatRow(key, db: db)?.mtime }) ?? nil { mtimes[key] = mtime }
        }
        return mtimes
    }

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
                SELECT d.session_key, d.entry_id, d.section, d.role, d.via, d.ts, d.body
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
                    text: Self.unpacked(statement, 6) ?? ""))
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

    /// Whether the chat has been indexed.
    public func isIndexed(sessionKey: String) -> Bool {
        self.withRecovery { db in try self.chatRow(sessionKey, db: db) != nil } ?? false
    }

    /// The chat's row in the `chats` table, for checks: what was indexed and when.
    public func chatInfo(sessionKey: String) -> (itemCount: Int, lastItemId: String?, digest: String?, fileMtime: Date)? {
        guard let row = self.withRecovery({ db in try self.chatRow(sessionKey, db: db) }) ?? nil else { return nil }
        return (row.itemCount, row.lastItemId, row.digest, Date(timeIntervalSinceReferenceDate: row.mtime))
    }

    public func close() {
        // Once this returns no interrupt is in flight, and none can reach the freed connection.
        self.interrupter.end()
        if let db { sqlite3_close_v2(db) }
        self.db = nil
        self.openLocation = nil
    }

    // MARK: Database

    private nonisolated var isRemoved: Bool { self.removed.withLock { $0 } }

    /// Runs `body` on the open database. A failure returns nil and never surfaces as an error;
    /// if the index turned out unreadable it's deleted (and rebuilt from the transcripts).
    @discardableResult
    private func withRecovery<T>(_ body: (OpaquePointer) throws -> T) -> T? {
        guard self.location != nil, !self.isRemoved else { return nil }
        do {
            return try body(try self.open())
        } catch {
            self.recover(from: error)
            return nil
        }
    }

    /// Deletes the index after an error showing it's unreadable; anything else leaves it be.
    private func recover(from error: Error) {
        guard case IndexError.corrupt = error else { return }
        self.reset()
    }

    private func open() throws -> OpaquePointer {
        guard !self.isRemoved, let location = self.location else { throw IndexError.unavailable }
        if let db, self.openLocation == location { return db }
        self.close()
        do {
            return try self.connect(location)
        } catch IndexError.corrupt {
            // Unreadable or from another version: start over.
            self.close()
            if case let .file(url) = location { Self.deleteFiles(url) }
            return try self.connect(location)
        } catch {
            self.close()
            throw error
        }
    }

    private func connect(_ location: Location) throws -> OpaquePointer {
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let path: String
        switch location {
        case let .file(url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS) || os(visionOS) || os(watchOS) || os(tvOS)
            flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETE
            #endif
            path = url.path(percentEncoded: false)
        case .memory:
            // One connection per index, so a private in-memory database is all it needs.
            path = ":memory:"
        }
        let opened = sqlite3_open_v2(path, &handle, flags, nil)
        guard opened == SQLITE_OK, let handle else {
            let error = handle.map(self.error) ?? Self.error(code: opened, message: "open failed")
            if let handle { sqlite3_close_v2(handle) }
            throw error
        }
        self.db = handle
        self.openLocation = location
        sqlite3_busy_timeout(handle, 2000)
        // Checkpoints shrink the WAL back to this rather than leaving it at its largest.
        try self.exec(handle, "PRAGMA journal_size_limit = 4194304")
        let version = try self.int(handle, "PRAGMA user_version")
        if version != Self.userVersion {
            let tables = try self.int(handle, "SELECT count(*) FROM sqlite_master")
            guard tables == 0 else { throw IndexError.corrupt("version \(version)") }
            try self.exec(handle, "PRAGMA journal_mode = WAL")
            // `docs` holds each message's Markdown once, compressed; `messages` indexes its folded
            // text without storing it (contentless). `chats` records what was indexed.
            try self.exec(handle, """
                CREATE TABLE docs (
                    id INTEGER PRIMARY KEY, session_key TEXT NOT NULL, entry_id TEXT NOT NULL, section INTEGER NOT NULL,
                    role TEXT, via TEXT, ts REAL, hash TEXT, body BLOB);
                CREATE INDEX docs_session ON docs (session_key);
                CREATE VIRTUAL TABLE messages USING fts5(
                    body, content = '', tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE chats (
                    session_key TEXT PRIMARY KEY, file_mtime REAL, item_count INTEGER, last_item_id TEXT, digest TEXT);
                PRAGMA user_version = \(Self.userVersion);
                """)
        } else {
            try self.exec(handle, "PRAGMA journal_mode = WAL")
        }
        return handle
    }

    /// Deletes the index; the next use recreates it empty, and `reconcile` refills it.
    private func reset() {
        self.close()
        if case let .file(url) = self.location, !self.isRemoved { Self.deleteFiles(url) }
    }

    private static func deleteFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
        }
    }

    private struct ChatRow {
        var mtime: Double
        var itemCount: Int
        var lastItemId: String?
        var digest: String?
    }

    private func chatRow(_ sessionKey: String, db: OpaquePointer) throws -> ChatRow? {
        let statement = try self.prepare(db, "SELECT file_mtime, item_count, last_item_id, digest FROM chats WHERE session_key = ?")
        defer { sqlite3_finalize(statement) }
        try self.bind(statement, [.text(sessionKey)])
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return ChatRow(mtime: sqlite3_column_double(statement, 0), itemCount: Int(sqlite3_column_int64(statement, 1)),
                           lastItemId: Self.text(statement, 2), digest: Self.text(statement, 3))
        case SQLITE_DONE:
            return nil
        default:
            throw self.error(db)
        }
    }

    /// Changes whenever anything the indexed messages are built from does: which items there
    /// are, how they group into rows, and their text, sender and date.
    private static func digest(_ items: [ChatItem]) -> String {
        var hasher = StableHasher()
        for item in items {
            hasher.add(item.id)
            hasher.add(item.role.rawValue)
            hasher.add(item.runId ?? "")
            hasher.add(item.via ?? "")
            hasher.add(item.isPending ? "p" : "")
            hasher.add(item.timestamp.map { String($0.timeIntervalSinceReferenceDate) } ?? "")
            for block in item.blocks {
                if case let .text(text) = block { hasher.add(text) } else { hasher.add("·") }
            }
        }
        return "\(items.count):\(String(hasher.value, radix: 36))"
    }

    /// Changes whenever the message's text, sender or date does.
    private static func hash(_ document: MessageSearch.Document) -> String {
        var hasher = StableHasher()
        hasher.add(document)
        return String(hasher.value, radix: 36)
    }

    // MARK: SQLite helpers

    private enum Value {
        case text(String?)
        case int(Int)
        case double(Double?)
        case blob(Data)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw self.error(db) }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case let .text(text?): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .int(number): sqlite3_bind_int64(statement, index, Int64(number))
            case let .double(number?): sqlite3_bind_double(statement, index, number)
            case let .blob(data):
                data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .text(nil), .double(nil): sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw IndexError.sqlite("bind \(result)") }
        }
    }

    private func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        let statement = try self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try self.bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw self.error(db) }
    }

    private func step(_ statement: OpaquePointer, _ values: [Value], db: OpaquePointer) throws {
        try self.bind(statement, values)
        let result = sqlite3_step(statement)
        sqlite3_reset(statement)
        guard result == SQLITE_DONE else { throw self.error(db) }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw self.error(db) }
    }

    private func int(_ db: OpaquePointer, _ sql: String) throws -> Int32 {
        let statement = try self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw self.error(db) }
        return sqlite3_column_int(statement, 0)
    }

    private nonisolated func error(_ db: OpaquePointer) -> IndexError {
        Self.error(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    /// Only a file that isn't a database, or a damaged one, counts as corrupt. Busy, full, I/O,
    /// can't-open and auth errors (a file-protected index while the device is locked) may pass.
    private static func error(code: Int32, message: String) -> IndexError {
        switch code & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB: .corrupt(message)
        default: .sqlite("\(message) (\(code))")
        }
    }

    /// Message text as stored: plain UTF-8 after a 0 byte, or, when smaller, a 1 byte, the
    /// UTF-8 length (4 bytes, little-endian) and the zlib-compressed UTF-8. Compression keeps
    /// the index smaller than the transcripts. No Foundation bridging, so nothing piles up in
    /// autorelease pools while a chat is indexed.
    private static func packed(_ text: String) -> Data {
        let raw = Array(text.utf8)
        if raw.count > 64 {
            var output = [UInt8](repeating: 0, count: raw.count)
            let size = compression_encode_buffer(&output, output.count, raw, raw.count, nil, COMPRESSION_ZLIB)
            if size > 0, size + 5 < raw.count {
                var data = Data([1])
                withUnsafeBytes(of: UInt32(raw.count).littleEndian) { data.append(contentsOf: $0) }
                data.append(contentsOf: output[..<size])
                return data
            }
        }
        return Data([0] + raw)
    }

    private static func unpacked(_ statement: OpaquePointer, _ column: Int32) -> String? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: count)
        switch bytes[0] {
        case 0:
            return String(decoding: bytes[1...], as: UTF8.self)
        case 1 where count > 5:
            let length = Int(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24)
            let payload = UnsafeRawBufferPointer(rebasing: bytes[5...])
            var output = [UInt8](repeating: 0, count: length)
            let size = compression_decode_buffer(&output, length, payload.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
            guard size == length else { return nil }
            return String(decoding: output, as: UTF8.self)
        default:
            return nil
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
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

/// FNV-1a over UTF-8, stable across launches (unlike `Hasher`).
private struct StableHasher {
    mutating func add(_ document: MessageSearch.Document) {
        self.add(document.role.rawValue)
        self.add(document.via ?? "")
        self.add(document.timestamp.map { String($0.timeIntervalSinceReferenceDate) } ?? "")
        self.add(document.text)
    }

    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ string: String) {
        for byte in string.utf8 {
            self.value ^= UInt64(byte)
            self.value = self.value &* 0x100_0000_01b3
        }
        self.value ^= 0xff
        self.value = self.value &* 0x100_0000_01b3
    }
}
