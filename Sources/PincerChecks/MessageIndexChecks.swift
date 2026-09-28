import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

func allTrue(_ values: Bool...) -> Bool { values.allSatisfy { $0 } }

@MainActor
func checkAsync(_ condition: () async -> Bool, _ label: String, line: UInt = #line) async {
    let passed = await condition()
    check(passed, label, line: line)
}

/// Runs `body` with a fresh scratch cache root, which it passes to every cache and index call.
/// The root is closed down (indexes closed, writes drained) before its folder is deleted.
@MainActor
func withScratchCache(_ body: (URL) async -> Void) async {
    let root = FileManager.default.temporaryDirectory.appending(path: "pincer-checks-index-\(UUID().uuidString)")
    await body(root)
    await TranscriptCache.shutdown(root: root)
    try? FileManager.default.removeItem(at: root)
}

/// Runs `body` with `PINCER_CACHE_DIR` pointing at `root` (a path, or "off"). Only for checks that
/// build a `GatewayStore`, which reads `TranscriptCache.root` itself and takes no root parameter.
@MainActor
func withCacheEnvironment(_ root: String, _ body: () async -> Void) async {
    let previous = ProcessInfo.processInfo.environment["PINCER_CACHE_DIR"]
    setenv("PINCER_CACHE_DIR", root, 1)
    await body()
    if let previous { setenv("PINCER_CACHE_DIR", previous, 1) } else { unsetenv("PINCER_CACHE_DIR") }
}

func indexHits(_ gatewayId: UUID, _ query: String, root: URL?) async -> [MessageSearch.Hit] {
    (try? await MessageIndex.shared(gatewayId: gatewayId, root: root).search(query)) ?? []
}

func indexResults(_ gatewayId: UUID, _ query: String, keys: Set<String>, root: URL?) async -> [MessageSearch.ChatGroup] {
    MessageSearch.collect(await indexHits(gatewayId, query, root: root), query: query, allowed: keys)
}

/// Integers from one query against an index file, opened separately from `MessageIndex`.
func sqliteInts(_ url: URL?, _ sql: String) -> [Int64] {
    guard let url else { return [] }
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return [] }
    defer { sqlite3_close_v2(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    var values: [Int64] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        for column in 0..<sqlite3_column_count(statement) { values.append(sqlite3_column_int64(statement, column)) }
    }
    return values
}

func sqliteExec(_ url: URL, _ sql: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db
    else { return false }
    defer { sqlite3_close_v2(db) }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

func fileExists(_ url: URL?) -> Bool {
    url.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
}

/// Writes a transcript cache file without going through `TranscriptCache.save` (so it isn't indexed).
func writeCacheFile(_ snapshot: TranscriptCache.Snapshot, gatewayId: UUID, sessionKey: String, root: URL?) -> Bool {
    guard let url = TranscriptCache.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root),
          (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
          let data = try? JSONEncoder().encode(snapshot)
    else { return false }
    return (try? data.write(to: url)) != nil
}

actor StatusLog {
    private(set) var statuses: [MessageIndex.Status] = []
    private(set) var times: [ContinuousClock.Instant] = []
    func add(_ status: MessageIndex.Status) {
        self.statuses.append(status)
        self.times.append(.now)
    }
}

/// The SQLite message index, each part in its own scratch cache.
@MainActor
func checkMessageIndex() async {
    await checkMessageSearchSmoke()

    await withScratchCache { root in
        let gatewayId = UUID()
        let index = MessageIndex.shared(gatewayId: gatewayId, root: root)
        await checkAsync({ await (index.status == .ready) }, "status is ready with a cache")
        var items = [
            messageItem("u1", .user, "Planning a café visit in Tokyo", at: 1000),
            messageItem("a1", .assistant, "The Café is open. We go on a trip to Japan.", at: 2000),
        ]
        await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gatewayId, sessionKey: "k", root: root)
        let keys: Set<String> = ["k"]
        await checkAsync({ await (indexResults(gatewayId, "tokyo", keys: keys, root: root).first?.hits.map(\.entryId) == ["u-u1"]) }, "saved text is found")
        await checkAsync({ await (indexResults(gatewayId, "CAFE", keys: keys, root: root).first?.hits.map(\.entryId) == ["a-a1", "u-u1"]) },
              "CAFE finds café and Café, newest first")
        await checkAsync({ await (indexResults(gatewayId, "cafe", keys: keys, root: root).first?.hits.contains { $0.entryId == "a-a1" } == true) }, "cafe finds Café")
        await checkAsync({ await (indexResults(gatewayId, "tok", keys: keys, root: root).first?.hits.map(\.entryId) == ["u-u1"]) }, "a word's start matches")
        await checkAsync({ await (indexHits(gatewayId, "kyo", root: root).isEmpty) }, "a word's middle doesn't")
        await checkAsync({ await (indexResults(gatewayId, "japan trip", keys: keys, root: root).isEmpty) }, "words out of order don't match a phrase")
        await checkAsync({ await (indexResults(gatewayId, "trip to japan", keys: keys, root: root).first?.hits.map(\.entryId) == ["a-a1"]) }, "the phrase does")
        await checkAsync({ await (indexHits(gatewayId, "a", root: root).isEmpty) }, "one letter searches nothing")
        do {
            let hostile = try await index.search(#"foo AND "bar" NEAR( -x* café)"#)
            check(hostile.isEmpty, "FTS syntax in a query is harmless")
        } catch {
            check(false, "FTS syntax in a query throws \(error)")
        }
        await checkAsync({ await allTrue(indexHits(gatewayId, "tokyo", root: root).count == 1, fileExists(MessageIndex.url(gatewayId: gatewayId, root: root))) },
              "index intact after a hostile query")

        items.append(messageItem("u2", .user, "Appending a walrus note", at: 3000))
        await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gatewayId, sessionKey: "k", root: root)
        await checkAsync({ await (indexHits(gatewayId, "walrus", root: root).map(\.entryId) == ["u-u2"]) }, "an appended message is found")
        items[1] = messageItem("a1", .assistant, "Changed plans: Kyoto instead.", at: 2000)
        await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gatewayId, sessionKey: "k", root: root)
        await checkAsync({ await allTrue(indexHits(gatewayId, "japan", root: root).isEmpty, indexHits(gatewayId, "kyoto", root: root).map(\.entryId) == ["a-a1"]) },
              "a replaced message stops matching its old text")
        let url = MessageIndex.url(gatewayId: gatewayId, root: root)
        let rowsBefore = sqliteInts(url, "SELECT count(*), max(id), sum(id) FROM docs")
        let infoBefore = await index.chatInfo(sessionKey: "k")
        await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gatewayId, sessionKey: "k", root: root)
        let infoAfter = await index.chatInfo(sessionKey: "k")
        check(rowsBefore.count == 3 && rowsBefore[0] == 3 && sqliteInts(url, "SELECT count(*), max(id), sum(id) FROM docs") == rowsBefore
              && infoBefore?.digest == infoAfter?.digest && infoBefore?.itemCount == 3 && infoAfter?.lastItemId == "u2",
              "saving an unchanged transcript rewrites no rows (\(rowsBefore))")
        await checkAsync({ await allTrue(index.isIndexed(sessionKey: "k"), !(index.isIndexed(sessionKey: "other"))) }, "isIndexed")
        let stale = TranscriptCache.Snapshot(items: [messageItem("s1", .user, "stale snapshot porcupine", at: 1)], complete: true)
        await index.index(sessionKey: "k", snapshot: stale, fileMtime: .distantPast)
        await checkAsync({ await allTrue(indexHits(gatewayId, "porcupine", root: root).isEmpty, indexHits(gatewayId, "walrus", root: root).count == 1) },
              "an older snapshot than the one indexed is ignored")
        check(sqliteInts(url, "SELECT count(*) FROM messages WHERE messages MATCH 'japan'") == [0]
              && sqliteInts(url, "SELECT count(*) FROM messages WHERE messages MATCH 'kyoto'") == [1],
              "the FTS table has no leftover terms for replaced text")
        let integrity = sqliteExec(url!, "INSERT INTO messages(messages) VALUES('integrity-check')")
        check(integrity, "FTS integrity-check passes after updates")

        let other = UUID()
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("n1", .user, "Only narwhal here", at: 5)], complete: true),
                                   gatewayId: other, sessionKey: "k", root: root)
        await checkAsync({ await allTrue(indexHits(gatewayId, "narwhal", root: root).isEmpty, indexHits(other, "narwhal", root: root).count == 1, indexHits(other, "walrus", root: root).isEmpty) }, "gateways have separate indexes")
        check(MessageIndex.url(gatewayId: gatewayId, root: root) != MessageIndex.url(gatewayId: other, root: root), "one index file per gateway")

        TranscriptCache.removeAll(gatewayId: other, root: root)
        await checkAsync({ await allTrue(!fileExists(MessageIndex.url(gatewayId: other, root: root)), indexHits(other, "narwhal", root: root).isEmpty) },
              "removeAll deletes the index; searching after is empty")
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("n2", .user, "Narwhal returns", at: 6)], complete: true),
                                   gatewayId: other, sessionKey: "k", root: root)
        await checkAsync({ await allTrue(indexHits(other, "narwhal", root: root).map(\.entryId) == ["u-n2"], fileExists(MessageIndex.url(gatewayId: other, root: root))) },
              "saving after removeAll rebuilds the index")
        TranscriptCache.removeAll(gatewayId: other, root: root)

        // Garbage and old-version files are replaced.
        let garbage = UUID()
        if let garbageURL = MessageIndex.url(gatewayId: garbage, root: root) {
            try? FileManager.default.createDirectory(at: garbageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: 8192).write(to: garbageURL)
        }
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("g1", .user, "Garbage replaced by gazelle", at: 7)], complete: true),
                                   gatewayId: garbage, sessionKey: "k", root: root)
        await checkAsync({ await (indexHits(garbage, "gazelle", root: root).count == 1) }, "a garbage index file is rebuilt")
        let oldVersion = UUID()
        if let oldURL = MessageIndex.url(gatewayId: oldVersion, root: root) {
            try? FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = sqliteExec(oldURL, "CREATE TABLE docs (x); PRAGMA user_version = 1;")
        }
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("o1", .user, "Old version ocelot", at: 8)], complete: true),
                                   gatewayId: oldVersion, sessionKey: "k", root: root)
        let version = sqliteInts(MessageIndex.url(gatewayId: oldVersion, root: root), "PRAGMA user_version").first ?? 0
        await checkAsync({ await allTrue(indexHits(oldVersion, "ocelot", root: root).count == 1, version > 1) }, "an index with a lower user_version is rebuilt (\(version))")
        // Corrupted while open: the failing search reports an error once, the index recovers from the transcripts.
        let corrupt = UUID()
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("c1", .user, "Corrupt cheetah", at: 9)], complete: true),
                                   gatewayId: corrupt, sessionKey: "k", root: root)
        if let corruptURL = MessageIndex.url(gatewayId: corrupt, root: root) {
            await MessageIndex.shared(gatewayId: corrupt, root: root).close()
            try? Data(repeating: 0x42, count: 8192).write(to: corruptURL)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(filePath: corruptURL.path(percentEncoded: false) + suffix)) }
        }
        _ = try? await MessageIndex.shared(gatewayId: corrupt, root: root).search("cheetah")
        await MessageIndex.shared(gatewayId: corrupt, root: root).reconcile(sessionKeys: ["k"])
        await checkAsync({ await (indexHits(corrupt, "cheetah", root: root).count == 1) }, "a corrupted index is refilled by reconcile")

        // Reconcile picks up transcripts cached while there was no index.
        let fresh = UUID()
        let written = writeCacheFile(TranscriptCache.Snapshot(items: [messageItem("r1", .user, "Reconciled raccoon", at: 10)], complete: true),
                                     gatewayId: fresh, sessionKey: "r1", root: root)
            && writeCacheFile(TranscriptCache.Snapshot(items: [messageItem("r2", .assistant, "Another raccoon", at: 11)], complete: true),
                              gatewayId: fresh, sessionKey: "r2", root: root)
        await checkAsync({ await allTrue(written, indexHits(fresh, "raccoon", root: root).isEmpty) }, "cache files written without indexing")
        let log = StatusLog()
        await MessageIndex.shared(gatewayId: fresh, root: root).reconcile(sessionKeys: ["r1", "r2", "missing", "r1"]) { await log.add($0) }
        let statuses = await log.statuses
        await checkAsync({ await (indexHits(fresh, "raccoon", root: root).map(\.entryId) == ["a-r2", "u-r1"]) }, "reconcile indexes cached transcripts")
        check(statuses.first == .building(done: 0, total: 2) && statuses.last == .ready, "reconcile reports progress (\(statuses))")
        let quiet = StatusLog()
        let freshRows = sqliteInts(MessageIndex.url(gatewayId: fresh, root: root), "SELECT count(*), max(id) FROM docs")
        await MessageIndex.shared(gatewayId: fresh, root: root).reconcile(sessionKeys: ["r1", "r2"]) { await quiet.add($0) }
        await checkAsync({ await allTrue(quiet.statuses == [.ready], sqliteInts(MessageIndex.url(gatewayId: fresh, root: root), "SELECT count(*), max(id) FROM docs") == freshRows) },
              "reconcile skips chats already indexed")

        await checkMessageIndexRemoval(root: root)
        await checkMessageIndexCancellation(gatewayId: gatewayId, root: root)
        await checkMessageIndexPerfSmoke(root: root)
    }

    await withScratchCache { root in
        // Cache off: a nil root, so nothing may be written anywhere (the scratch folder stays absent).
        let gatewayId = UUID()
        let index = MessageIndex.shared(gatewayId: gatewayId, root: nil)
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("x", .user, "Nowhere to go", at: 1)], complete: true),
                                   gatewayId: gatewayId, sessionKey: "k", root: nil)
        let hits = try? await index.search("nowhere")
        await index.reconcile(sessionKeys: ["k"])
        await checkAsync({ await allTrue(index.status == .unavailable, hits == [], MessageIndex.url(gatewayId: gatewayId, root: nil) == nil) },
              "cache off: index unavailable, search empty")
        // GatewayStore reads TranscriptCache.root itself, so these need the environment switched off.
        await withCacheEnvironment("off") {
            let store = GatewayStore(profile: GatewayProfile(name: "Off", url: "ws://127.0.0.1:1", authMode: .none))
            check(store.messageIndexProgress == .unavailable, "cache off: the gateway reports search unavailable")
            let empty = (try? await store.searchMessages("nowhere")) ?? MessageSearch.Results(query: "x", failed: true)
            check(empty.isEmpty && !empty.failed, "cache off: searchMessages is empty, not failed")
            check(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) && !fileExists(URL(filePath: "off")),
                  "cache off: no files written")
            let demo = GatewayStore(profile: .demo())
            await checkMessageIndexRemovalInMemory(gatewayId: demo.id, root: nil)
        }
    }
}

/// A newer search stops the one still running; its result is the one that counts.
@MainActor
func checkMessageIndexCancellation(gatewayId: UUID, root: URL?) async {
    let index = MessageIndex.shared(gatewayId: gatewayId, root: root)
    let many = (0..<3000).map { messageItem("c\($0)", $0.isMultiple(of: 2) ? .user : .assistant, "common words number \($0) and more common", at: Double(10_000 + $0)) }
    await TranscriptCache.save(TranscriptCache.Snapshot(items: many + [messageItem("uniq", .user, "the unique quokka", at: 99_999)], complete: true),
                               gatewayId: gatewayId, sessionKey: "busy", root: root)
    for round in 0..<5 {
        let older = Task { @MainActor in
            try await withTaskCancellationHandler {
                try await index.search("common", candidateLimit: 1_000_000)
            } onCancel: {
                index.interrupt()
            }
        }
        // Deliberate: varies how far the older search has got when it is cancelled (the race under test).
        if round > 0 { try? await Task.sleep(for: .milliseconds(round)) }
        older.cancel()
        let latest = (try? await index.search("quokka")) ?? []
        let outcome = await older.result
        var olderOK = false
        switch outcome {
        case .success(let hits): olderOK = hits.count == 3000
        case .failure(let error): olderOK = error is CancellationError
        }
        check(latest.map(\.entryId) == ["u-uniq"] && olderOK, "back-to-back searches: the latest wins (round \(round))")
    }
    // Cancelling one search mustn't stop another that wasn't cancelled (e.g. a second window's).
    var bystanderOK = 0
    for _ in 0..<5 {
        let bystander = Task { @MainActor in try await index.search("common", candidateLimit: 1_000_000) }
        // Deliberate: lets the bystander search start before the other is cancelled.
        try? await Task.sleep(for: .milliseconds(1))
        let cancelled = Task { @MainActor in
            try await withTaskCancellationHandler { try await index.search("quokka") } onCancel: { index.interrupt() }
        }
        cancelled.cancel()
        _ = await cancelled.result
        if case let .success(hits) = await bystander.result, hits.count == 3000 { bystanderOK += 1 }
    }
    check(bystanderOK == 5, "cancelling one search doesn't interrupt another (\(bystanderOK)/5 survived)")
    await checkAsync({ await allTrue(indexHits(gatewayId, "quokka", root: root).count == 1, indexHits(gatewayId, "common", root: root).count == 2000, fileExists(MessageIndex.url(gatewayId: gatewayId, root: root))) }, "interrupting a search leaves the index intact")
}
