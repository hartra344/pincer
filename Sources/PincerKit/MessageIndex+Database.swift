import Compression
import Foundation
import SQLite3
import Synchronization

extension MessageIndex {
    // MARK: Database

    nonisolated var isRemoved: Bool { self.removed.withLock { $0 } }

    /// Runs `body` on the open database. A failure returns nil and never surfaces as an error;
    /// if the index turned out unreadable it's deleted (and rebuilt from the transcripts).
    @discardableResult
    func withRecovery<T>(_ body: (OpaquePointer) throws -> T) -> T? {
        guard self.location != nil, !self.isRemoved else { return nil }
        do {
            return try body(try self.open())
        } catch {
            self.recover(from: error)
            return nil
        }
    }

    /// Deletes the index after an error showing it's unreadable or gone; anything else leaves it be.
    func recover(from error: Error) {
        switch error {
        case IndexError.corrupt, IndexError.vanished: self.reset()
        default: break
        }
    }

    func open() throws -> OpaquePointer {
        guard !self.isRemoved, let location = self.location else { throw IndexError.unavailable }
        if let db, self.openLocation == location {
            // Apple's SQLite reports a deleted file (`vanished`) only once a vnode event has
            // arrived, which can take a while under load; until then the connection keeps
            // serving the deleted file. Checking the path itself notices at once.
            guard case let .file(url) = location, Self.fileID(url) != self.openFileID else { return db }
            self.reset()
        }
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
                    role TEXT, via TEXT, sender TEXT, ts REAL, hash TEXT, body BLOB, pos INTEGER);
                CREATE INDEX docs_session ON docs (session_key, pos);
                CREATE VIRTUAL TABLE messages USING fts5(
                    body, content = '', tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE chats (
                    session_key TEXT PRIMARY KEY, file_mtime REAL, item_count INTEGER, last_item_id TEXT, digest TEXT, token TEXT);
                PRAGMA user_version = \(Self.userVersion);
                """)
        } else {
            try self.exec(handle, "PRAGMA journal_mode = WAL")
        }
        if case let .file(url) = location { self.openFileID = Self.fileID(url) }
        return handle
    }

    /// Deletes the index; the next use recreates it empty, and `reconcile` refills it.
    private func reset() {
        self.close()
        if case let .file(url) = self.location, !self.isRemoved { Self.deleteFiles(url) }
    }

    struct FileID: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    /// Which file is at `url` now; nil when there's none.
    private static func fileID(_ url: URL) -> FileID? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }

    private static func deleteFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
        }
    }

    struct ChatRow {
        var mtime: Double
        var itemCount: Int
        var lastItemId: String?
        var digest: String?
        var token: String?
    }

    func chatRow(_ sessionKey: String, db: OpaquePointer) throws -> ChatRow? {
        let statement = try self.prepare(db, "SELECT file_mtime, item_count, last_item_id, digest, token FROM chats WHERE session_key = ?")
        defer { sqlite3_finalize(statement) }
        try self.bind(statement, [.text(sessionKey)])
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return ChatRow(mtime: sqlite3_column_double(statement, 0), itemCount: Int(sqlite3_column_int64(statement, 1)),
                           lastItemId: Self.text(statement, 2), digest: Self.text(statement, 3), token: Self.text(statement, 4))
        case SQLITE_DONE:
            return nil
        default:
            throw self.error(db)
        }
    }

    /// Changes whenever anything the indexed messages are built from does: which items there
    /// are, how they group into rows, and their text, sender and date.
    static func digest(_ items: [ChatItem]) -> String {
        var hasher = StableHasher()
        for item in items {
            hasher.add(item.id)
            hasher.add(item.role.rawValue)
            hasher.add(item.runId ?? "")
            hasher.add(item.via ?? "")
            hasher.add(Self.encodedSender(item.sender) ?? "")
            hasher.add(item.isPending ? "p" : "")
            hasher.add(item.timestamp.map { String($0.timeIntervalSinceReferenceDate) } ?? "")
            for block in item.blocks {
                if case let .text(text) = block { hasher.add(text) } else { hasher.add("·") }
            }
        }
        return "\(items.count):\(String(hasher.value, radix: 36))"
    }

    /// Changes whenever the message's text, sender or date does.
    static func hash(_ document: MessageSearch.Document) -> String {
        var hasher = StableHasher()
        hasher.add(document)
        return String(hasher.value, radix: 36)
    }

    static func encodedSender(_ sender: MessageSender?) -> String? {
        sender.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    static func decodedSender(_ text: String?) -> MessageSender? {
        text.flatMap { try? JSONDecoder().decode(MessageSender.self, from: Data($0.utf8)) }
    }

    // MARK: SQLite helpers

    enum Value {
        case text(String?)
        case int(Int)
        case double(Double?)
        case blob(Data)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw self.error(db) }
        return statement
    }

    func bind(_ statement: OpaquePointer, _ values: [Value]) throws {
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

    func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        let statement = try self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try self.bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw self.error(db) }
    }

    func step(_ statement: OpaquePointer, _ values: [Value], db: OpaquePointer) throws {
        try self.bind(statement, values)
        let result = sqlite3_step(statement)
        sqlite3_reset(statement)
        guard result == SQLITE_DONE else { throw self.error(db) }
    }

    func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw self.error(db) }
    }

    private func int(_ db: OpaquePointer, _ sql: String) throws -> Int32 {
        let statement = try self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw self.error(db) }
        return sqlite3_column_int(statement, 0)
    }

    nonisolated func error(_ db: OpaquePointer) -> IndexError {
        Self.error(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    /// Only a file that isn't a database, or a damaged one, counts as corrupt, and one deleted
    /// while open as vanished. Busy, full, other I/O, can't-open and auth errors (a
    /// file-protected index while the device is locked) may pass.
    /// Apple's SQLite `SQLITE_IOERR_VNODE`: the file was unlinked or replaced while open. It stays
    /// so until reopened.
    private static let ioerrVnode: Int32 = SQLITE_IOERR | (27 << 8)

    static func error(code: Int32, message: String) -> IndexError {
        switch code & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB: .corrupt(message)
        case SQLITE_IOERR where code == Self.ioerrVnode: .vanished(message)
        default: .sqlite("\(message) (\(code))")
        }
    }

    /// Message text as stored: plain UTF-8 after a 0 byte, or, when smaller, a 1 byte, the
    /// UTF-8 length (4 bytes, little-endian) and the zlib-compressed UTF-8. Compression keeps
    /// the index smaller than the transcripts. No Foundation bridging, so nothing piles up in
    /// autorelease pools while a chat is indexed.
    static func packed(_ text: String) -> Data {
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

    static func unpacked(_ statement: OpaquePointer, _ column: Int32) -> String? {
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

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}

/// FNV-1a over UTF-8, stable across launches (unlike `Hasher`).
private struct StableHasher {
    mutating func add(_ document: MessageSearch.Document) {
        self.add(document.role.rawValue)
        self.add(document.via ?? "")
        if let sender = document.sender { self.add("\(sender.kind.rawValue):\(sender.sessionKey ?? ""):\(sender.label ?? "")") }
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
