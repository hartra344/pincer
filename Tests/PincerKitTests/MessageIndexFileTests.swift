import Foundation
import Testing
@testable import PincerKit

/// The file-backed message index offline (#153): discarding while files are deleted, an index
/// deleted from under an open connection, removing one chat, and not re-adding a removed chat.
/// The index lives under `TranscriptCache.root` and has no root of its own, so each test uses a
/// fresh Gateway id there and deletes its folder afterwards.
@Suite("Message index files", .serialized, .enabled(if: TranscriptCache.root != nil))
struct MessageIndexFileTests {
    let gateway = UUID()

    static func message(_ id: String, _ text: String, at seconds: Double) -> ChatItem {
        var item = ChatItem(id: id, role: .user, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: seconds))
        item.transcriptId = id
        return item
    }

    static func snapshot(_ id: String, _ text: String, at seconds: Double = 1) -> TranscriptCache.Snapshot {
        TranscriptCache.Snapshot(items: [self.message(id, text, at: seconds)], complete: true)
    }

    var index: MessageIndex { MessageIndex.shared(gatewayId: self.gateway) }

    func hits(_ query: String) async throws -> [String] {
        try await self.index.search(query).map(\.sessionKey).sorted()
    }

    func cleanUp() {
        TranscriptCache.removeAll(gatewayId: self.gateway)
    }

    func indexFiles() throws -> [URL] {
        let url = try #require(MessageIndex.url(gatewayId: self.gateway))
        return ["", "-wal", "-shm", "-journal"].map { URL(filePath: url.path(percentEncoded: false) + $0) }
    }

    // MARK: (a) discard

    @Test func discardHandsOutAnInertStandInWhileFilesAreDeleted() async throws {
        defer { self.cleanUp() }
        await TranscriptCache.save(Self.snapshot("a1", "aardvark before"), gatewayId: self.gateway, sessionKey: "before")
        #expect(try await self.hits("aardvark") == ["before"])
        let original = self.index
        let url = try #require(MessageIndex.url(gatewayId: self.gateway))
        var handedOut: MessageIndex?
        MessageIndex.whileDeleting {
            MessageIndex.discard(gatewayId: self.gateway)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            handedOut = MessageIndex.shared(gatewayId: self.gateway)
        }
        let standIn = try #require(handedOut)
        #expect(standIn !== original)
        // The stand-in does nothing, and in particular doesn't create an index file.
        await standIn.index(sessionKey: "during", snapshot: Self.snapshot("d1", "aardvark during"), fileMtime: Date())
        #expect(await standIn.isIndexed(sessionKey: "during") == false)
        #expect(await standIn.isIndexed(sessionKey: "before") == false)
        #expect(try await standIn.search("aardvark").isEmpty)
        await standIn.remove(sessionKey: "before")
        await standIn.reconcile(sessionKeys: ["before", "during"])
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "no index file while deleting")
        // The discarded instance can't recreate it either.
        await original.index(sessionKey: "late", snapshot: Self.snapshot("l1", "aardvark late"), fileMtime: Date())
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        // Afterwards a real index opens again and saves are searchable.
        let fresh = self.index
        #expect(fresh !== original && fresh !== standIn && self.index === fresh)
        await TranscriptCache.save(Self.snapshot("a2", "aardvark after"), gatewayId: self.gateway, sessionKey: "after")
        #expect(try await self.hits("aardvark") == ["after"])
        #expect(await fresh.isIndexed(sessionKey: "after"))
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: (b) vanished

    @Test func indexDeletedWhileOpenIsResetAndRebuilt() async throws {
        defer { self.cleanUp() }
        await TranscriptCache.save(Self.snapshot("v1", "vicuna one"), gatewayId: self.gateway, sessionKey: "one")
        #expect(try await self.hits("vicuna") == ["one"])
        for file in try self.indexFiles() { try? FileManager.default.removeItem(at: file) }
        #expect(try !FileManager.default.fileExists(atPath: self.indexFiles()[0].path(percentEncoded: false)))

        // The open connection now points at a deleted file. The next operations notice, reset,
        // and succeed rather than failing every call after it.
        await TranscriptCache.save(Self.snapshot("v2", "vicuna two"), gatewayId: self.gateway, sessionKey: "two")
        #expect(try await self.hits("vicuna") == ["two"])
        await self.index.reconcile(sessionKeys: ["one", "two"])
        #expect(try await self.hits("vicuna") == ["one", "two"])
        let one = await self.index.isIndexed(sessionKey: "one"), two = await self.index.isIndexed(sessionKey: "two")
        #expect(one && two)
        #expect(try FileManager.default.fileExists(atPath: self.indexFiles()[0].path(percentEncoded: false)))
        await TranscriptCache.save(Self.snapshot("v3", "vicuna three"), gatewayId: self.gateway, sessionKey: "three")
        #expect(try await self.hits("vicuna") == ["one", "three", "two"])
    }

    @Test func searchRightAfterTheFileVanishesDoesNotFailForever() async throws {
        defer { self.cleanUp() }
        await TranscriptCache.save(Self.snapshot("w1", "wombat"), gatewayId: self.gateway, sessionKey: "w")
        #expect(try await self.hits("wombat") == ["w"])
        for file in try self.indexFiles() { try? FileManager.default.removeItem(at: file) }
        // The very next call notices the file is gone and works on a fresh, empty index rather
        // than serving the deleted file until SQLite's own vnode notice arrives (#240).
        #expect(try await self.index.search("wombat").isEmpty)
        #expect(try await self.index.search("wombat").isEmpty)
        await self.index.reconcile(sessionKeys: ["w"])
        #expect(try await self.hits("wombat") == ["w"])
    }

    // MARK: (c) remove

    @Test func removeDeletesTheChatsRowsAndChatRow() async throws {
        defer { self.cleanUp() }
        await TranscriptCache.save(Self.snapshot("r1", "raccoon gone"), gatewayId: self.gateway, sessionKey: "gone")
        await TranscriptCache.save(Self.snapshot("r2", "raccoon kept"), gatewayId: self.gateway, sessionKey: "kept")
        #expect(try await self.hits("raccoon") == ["gone", "kept"])
        #expect(await self.index.chatInfo(sessionKey: "gone")?.itemCount == 1)

        await self.index.remove(sessionKey: "gone")
        #expect(await self.index.isIndexed(sessionKey: "gone") == false)
        #expect(await self.index.chatInfo(sessionKey: "gone") == nil)
        #expect(try await self.hits("raccoon") == ["kept"])
        #expect(try await self.hits("gone").isEmpty)
        #expect(await self.index.isIndexed(sessionKey: "kept"))
        // Idempotent, and harmless for a chat that was never indexed.
        await self.index.remove(sessionKey: "gone")
        await self.index.remove(sessionKey: "never")
        #expect(try await self.hits("raccoon") == ["kept"])
        // The transcript is still cached, so it can be indexed again.
        await self.index.reconcile(sessionKeys: ["gone"])
        #expect(try await self.hits("raccoon") == ["gone", "kept"])
    }

    @Test func transcriptCacheRemoveDropsTheFileAndTheIndexRows() async throws {
        defer { self.cleanUp() }
        await TranscriptCache.save(Self.snapshot("t1", "tapir gone"), gatewayId: self.gateway, sessionKey: "gone")
        await TranscriptCache.save(Self.snapshot("t2", "tapir kept"), gatewayId: self.gateway, sessionKey: "kept")
        let file = try #require(TranscriptCache.file(gatewayId: self.gateway, sessionKey: "gone"))
        await TranscriptCache.remove(gatewayId: self.gateway, sessionKey: "gone")
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("meta").path(percentEncoded: false)))
        #expect(await self.index.isIndexed(sessionKey: "gone") == false)
        #expect(try await self.hits("tapir") == ["kept"])
        await self.index.reconcile(sessionKeys: ["gone", "kept"])
        #expect(try await self.hits("tapir") == ["kept"], "reconcile doesn't bring a removed chat back")
    }

    // MARK: Not re-adding a removed chat

    @Test func indexingAChatWhoseTranscriptIsGoneDoesNothing() async throws {
        defer { self.cleanUp() }
        await TranscriptCache.save(Self.snapshot("k1", "koala kept"), gatewayId: self.gateway, sessionKey: "kept")
        // Never cached: a direct index() is skipped.
        await self.index.index(sessionKey: "uncached", snapshot: Self.snapshot("u1", "koala uncached"), fileMtime: Date())
        #expect(await self.index.isIndexed(sessionKey: "uncached") == false)

        // Cached, removed, then a save that was racing the removal indexes it: still not indexed.
        await TranscriptCache.save(Self.snapshot("g1", "koala gone"), gatewayId: self.gateway, sessionKey: "gone")
        #expect(await self.index.isIndexed(sessionKey: "gone"))
        await TranscriptCache.remove(gatewayId: self.gateway, sessionKey: "gone")
        await self.index.index(sessionKey: "gone", snapshot: Self.snapshot("g2", "koala racing"), fileMtime: Date())
        #expect(await self.index.isIndexed(sessionKey: "gone") == false)
        #expect(try await self.hits("koala") == ["kept"])

        // A chat whose file is deleted without going through the cache isn't updated either.
        let keptFile = try #require(TranscriptCache.file(gatewayId: self.gateway, sessionKey: "kept"))
        try FileManager.default.removeItem(at: keptFile)
        await self.index.index(sessionKey: "kept", snapshot: Self.snapshot("k2", "koala changed"), fileMtime: Date())
        #expect(try await self.index.search("changed").isEmpty)

        // Saved again, the chat is indexed again.
        await TranscriptCache.save(Self.snapshot("g3", "koala back"), gatewayId: self.gateway, sessionKey: "gone")
        #expect(await self.index.isIndexed(sessionKey: "gone"))
        #expect(try await self.index.search("back").map(\.sessionKey) == ["gone"])
    }
}
