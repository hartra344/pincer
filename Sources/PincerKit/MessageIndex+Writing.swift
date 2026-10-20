import Compression
import Foundation
import SQLite3
import Synchronization

extension MessageIndex {
    // MARK: Writing

    /// What's recorded about an indexed chat's transcript.
    private struct ChatState: Sendable {
        var mtime: Double
        var itemCount: Int
        var lastItemId: String?
        var digest: String
        var token: String?
    }

    /// What the last `index` call did, for tests and benchmarks.
    struct IndexStats: Equatable, Sendable {
        enum Path: Equatable, Sendable { case full, tail, unchanged, skipped }

        var path: Path
        var documentsBuilt = 0
        var rowsRead = 0
        var rowsWritten = 0
    }


    nonisolated var lastIndexStats: IndexStats { self.stats.withLock { $0 } }

    /// A message ready to write: its change hash and the folded text the full-text index gets.
    private struct Prepared: Sendable {
        var document: MessageSearch.Document
        /// Index of the message's first item in the transcript.
        var pos: Int
        var hash: String
        var folded: String
    }

    private enum WriteResult {
        case done
        /// The messages changed; call again with them.
        case needsDocuments
        /// A tail can't be applied to what's indexed; index the whole transcript.
        case needsFull
    }

    /// Indexes a chat's saved transcript. Does nothing when its messages haven't changed, and
    /// ignores a snapshot older than the one already indexed.
    public nonisolated func index(sessionKey: String, snapshot: TranscriptCache.Snapshot, fileMtime: Date,
                                  change: IndexChange = .full(token: nil)) async
    {
        self.inFlight.begin()
        defer { self.inFlight.end() }
        guard !self.isRemoved else { return }
        let items = snapshot.items
        let mtime = fileMtime.timeIntervalSinceReferenceDate
        var token: String?
        switch change {
        case let .full(value):
            token = value
        case let .tail(prefix, baseToken, newToken):
            token = newToken
            if prefix >= 0, prefix <= items.count {
                let start = MessageSearch.rowBoundary(items: items, before: prefix)
                if await self.indexTail(sessionKey: sessionKey, items: items, offset: 0, start: start, prefix: prefix,
                                        baseToken: baseToken, token: newToken, mtime: mtime) != .fallback { return }
            }
        }
        // Hashing what the messages are built from is much cheaper than building them, so an
        // unchanged chat costs little.
        let chat = ChatState(mtime: mtime, itemCount: items.count, lastItemId: items.last?.id,
                             digest: Self.digest(items), token: token)
        guard await self.write(sessionKey: sessionKey, chat: chat, documents: nil) == .needsDocuments, !self.isRemoved else { return }
        let documents = Self.prepared(sessionKey: sessionKey, items: items[...])
        await self.write(sessionKey: sessionKey, chat: chat, documents: documents)
    }

    public typealias IndexOutcome = PincerKit.IndexOutcome

    /// Like `index(sessionKey:snapshot:fileMtime:change:)` for a save that has only the newest
    /// items at hand: `items` are the transcript's from index `itemOffset` on, of `totalCount`
    /// in all, and `change`'s `unchangedPrefix` counts from the transcript's start. Only a
    /// `.tail` that can start within `items` is applied; anything else (a `.full`, a tail that
    /// must start earlier, or one that can't be applied to what's indexed) does nothing and
    /// returns `.needsEarlierItems`.
    public nonisolated func index(sessionKey: String, items: [ChatItem], itemOffset: Int, totalCount: Int, fileMtime: Date,
                                  change: IndexChange) async -> IndexOutcome
    {
        self.inFlight.begin()
        defer { self.inFlight.end() }
        guard itemOffset >= 0, itemOffset + items.count == totalCount else { return .needsEarlierItems }
        if itemOffset == 0 {
            await self.index(sessionKey: sessionKey, snapshot: TranscriptCache.Snapshot(items: items, complete: false),
                             fileMtime: fileMtime, change: change)
            return .done
        }
        guard !self.isRemoved else { return .done }
        guard case let .tail(prefix, baseToken, token) = change, prefix > itemOffset, prefix <= totalCount,
              !items.isEmpty
        else { return .needsEarlierItems }
        let start = MessageSearch.rowBoundary(items: items, before: prefix - itemOffset)
        // Without a boundary in reach, the row containing the change may begin before `items`.
        guard MessageSearch.isRowBoundary(items[start]) else { return .needsEarlierItems }
        let result = await self.indexTail(sessionKey: sessionKey, items: items, offset: itemOffset, start: start,
                                          prefix: prefix, baseToken: baseToken, token: token,
                                          mtime: fileMtime.timeIntervalSinceReferenceDate)
        return result == .fallback ? .needsEarlierItems : .done
    }

    private enum TailResult { case done, fallback }

    /// Applies a tail whose rows start at `items[start]`, item `offset + start` of the transcript.
    private nonisolated func indexTail(sessionKey: String, items: [ChatItem], offset: Int, start: Int, prefix: Int,
                                       baseToken: String, token: String, mtime: Double) async -> TailResult
    {
        let chat = ChatState(mtime: mtime, itemCount: offset + items.count, lastItemId: items.last?.id,
                             digest: "t:\(token)", token: token)
        let tail = TailWrite(start: offset + start, prefix: prefix, baseToken: baseToken)
        guard await self.canTail(sessionKey: sessionKey, tail: tail, mtime: mtime) else { return .fallback }
        var documents = Self.prepared(sessionKey: sessionKey, items: items[start...])
        if offset > 0 { for index in documents.indices { documents[index].pos += offset } }
        guard !self.isRemoved else { return .done }
        return await self.write(sessionKey: sessionKey, chat: chat, documents: documents, tail: tail) == .needsFull ? .fallback : .done
    }

    private static func prepared(sessionKey: String, items: ArraySlice<ChatItem>) -> [Prepared] {
        MessageSearch.positionedDocuments(sessionKey: sessionKey, items: items).map { pos, document in
            Prepared(document: document, pos: pos, hash: Self.hash(document), folded: MessageSearch.folded(document.text))
        }
    }

    /// What a tail write is restricted to: messages of rows starting at or after `start`.
    private struct TailWrite: Sendable {
        var start: Int
        var prefix: Int
        var baseToken: String
    }

    /// Whether a tail can be applied: the chat is indexed from the save it's based on, with at
    /// least as many items as are said to be unchanged.
    private func canTail(sessionKey: String, tail: TailWrite, mtime: Double) -> Bool {
        self.withRecovery { db in
            guard let row = try self.chatRow(sessionKey, db: db) else { return false }
            return Self.allows(tail, row: row, mtime: mtime)
        } ?? false
    }

    private static func allows(_ tail: TailWrite, row: ChatRow, mtime: Double) -> Bool {
        row.token == tail.baseToken && row.mtime <= mtime && tail.prefix <= row.itemCount
    }

    /// Records `chat`: only its file date when its messages are unchanged, otherwise its
    /// messages too, which needs `documents`.
    @discardableResult
    private func write(sessionKey: String, chat: ChatState, documents: [Prepared]?, tail: TailWrite? = nil) -> WriteResult {
        // A save indexes after writing its transcript; if the chat was removed from the cache
        // since, its file is gone and indexing it would bring it back into search.
        if case .file = self.location,
           let file = TranscriptCache.file(gatewayId: self.gatewayId, sessionKey: sessionKey, root: self.root),
           !FileManager.default.fileExists(atPath: file.path)
        { return .done }
        return self.withRecovery { db -> WriteResult in
            let existing = try self.chatRow(sessionKey, db: db)
            if let existing, existing.mtime > chat.mtime { return .done }
            if let tail, !(existing.map { Self.allows(tail, row: $0, mtime: chat.mtime) } ?? false) { return .needsFull }
            let unchanged = tail == nil && existing?.digest == chat.digest
            guard unchanged || documents != nil else { return .needsDocuments }
            var stats = IndexStats(path: unchanged ? .unchanged : tail == nil ? .full : .tail, documentsBuilt: documents?.count ?? 0)
            try self.exec(db, "BEGIN IMMEDIATE")
            do {
                if unchanged {
                    try self.run(db, """
                        UPDATE chats SET file_mtime = ?, item_count = ?, last_item_id = ?, token = ? WHERE session_key = ?
                        """, [.double(chat.mtime), .int(chat.itemCount), .text(chat.lastItemId), .text(chat.token),
                              .text(sessionKey)])
                } else {
                    try self.replace(sessionKey: sessionKey, with: documents ?? [], from: tail?.start, stats: &stats, db: db)
                    try self.run(db, """
                        INSERT OR REPLACE INTO chats (session_key, file_mtime, item_count, last_item_id, digest, token)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, [.text(sessionKey), .double(chat.mtime), .int(chat.itemCount), .text(chat.lastItemId),
                              .text(chat.digest), .text(chat.token)])
                }
                self.stats.withLock { $0 = stats }
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
    /// With `start`, `documents` are those of rows starting at or after item `start`, and only
    /// such rows are compared.
    private func replace(sessionKey: String, with documents: [Prepared], from start: Int? = nil,
                         stats: inout IndexStats, db: OpaquePointer) throws
    {
        var existing: [String: (id: Int64, hash: String, pos: Int)] = [:]
        let select = try self.prepare(db, """
            SELECT id, entry_id, section, hash, pos FROM docs WHERE session_key = ? AND COALESCE(pos, -1) >= ?
            """)
        defer { sqlite3_finalize(select) }
        try self.bind(select, [.text(sessionKey), .int(start ?? -1)])
        while true {
            let result = sqlite3_step(select)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw self.error(db) }
            let key = "\(Self.text(select, 1) ?? "")#\(sqlite3_column_int64(select, 2))"
            existing[key] = (sqlite3_column_int64(select, 0), Self.text(select, 3) ?? "", Int(sqlite3_column_int64(select, 4)))
            stats.rowsRead += 1
        }
        var removed: [Int64] = []
        var added: [Prepared] = []
        var moved: [(id: Int64, pos: Int)] = []
        var seen: Set<String> = []
        for prepared in documents {
            let key = "\(prepared.document.entryId)#\(prepared.document.section)"
            guard seen.insert(key).inserted else { continue }
            if let old = existing.removeValue(forKey: key) {
                if old.hash == prepared.hash {
                    if old.pos != prepared.pos { moved.append((old.id, prepared.pos)) }
                    continue
                }
                removed.append(old.id)
            }
            added.append(prepared)
        }
        removed += existing.values.map(\.id)
        stats.rowsWritten += removed.count + added.count + moved.count
        if !moved.isEmpty {
            let update = try self.prepare(db, "UPDATE docs SET pos = ? WHERE id = ?")
            defer { sqlite3_finalize(update) }
            for (id, pos) in moved { try self.step(update, [.int(pos), .int(Int(id))], db: db) }
        }

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
                INSERT INTO docs (session_key, entry_id, section, role, via, sender, ts, hash, body, pos)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            let index = try self.prepare(db, "INSERT INTO messages (rowid, body) VALUES (?, ?)")
            defer { sqlite3_finalize(index) }
            for prepared in added {
                let document = prepared.document
                try self.step(insert, [
                    .text(sessionKey), .text(document.entryId), .int(document.section), .text(document.role.rawValue),
                    .text(document.via), .text(Self.encodedSender(document.sender)),
                    .double(document.timestamp?.timeIntervalSinceReferenceDate), .text(prepared.hash),
                    .blob(Self.packed(document.text)), .int(prepared.pos),
                ], db: db)
                let id = sqlite3_last_insert_rowid(db)
                try self.step(index, [.int(Int(id)), .text(prepared.folded)], db: db)
            }
        }
    }

    /// Drops a chat's messages from the index. Call after deleting its transcript file, so a save
    /// still indexing it afterwards finds the file gone and doesn't add it back.
    public func remove(sessionKey: String) {
        guard !self.isRemoved else { return }
        self.withRecovery { db in
            try self.exec(db, "BEGIN IMMEDIATE")
            do {
                var stats = IndexStats(path: .full)
                try self.replace(sessionKey: sessionKey, with: [], stats: &stats, db: db)
                try self.run(db, "DELETE FROM chats WHERE session_key = ?", [.text(sessionKey)])
                try self.exec(db, "COMMIT")
            } catch {
                try? self.exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// Indexes every cached transcript of `sessionKeys` written since it was last indexed, one
    /// chat at a time, reporting progress. Transcripts are read and decoded off the actor.
    public nonisolated func reconcile(sessionKeys: [String], progress: (@Sendable (Status) async -> Void)? = nil) async {
        self.inFlight.begin()
        defer { self.inFlight.end() }
        guard self.location != nil else {
            await progress?(.unavailable)
            return
        }
        var files: [(key: String, url: URL, mtime: Date)] = []
        for key in Set(sessionKeys).sorted() {
            guard let url = TranscriptCache.file(gatewayId: self.gatewayId, sessionKey: key, root: self.root),
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
            // Read as opening the chat would: migrated transcripts are indexed (and saved back),
            // unusable ones quarantined or deleted.
            let (snapshot, outcome) = await TranscriptCache.read(chat.url, gatewayId: self.gatewayId, root: self.root, priority: .utility)
            guard let snapshot else { continue }
            var rewritten = chat.url
            rewritten.removeAllCachedResourceValues()
            let mtime = outcome == .loaded ? chat.mtime
                : (try? rewritten.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? chat.mtime
            await self.index(sessionKey: chat.key, snapshot: snapshot, fileMtime: mtime)
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

}
