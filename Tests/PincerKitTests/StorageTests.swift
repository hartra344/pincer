import Foundation
import Testing
@testable import PincerKit

func item(_ id: String, pending: Bool = false) -> ChatItem {
    ChatItem(id: id, role: .user, blocks: [.text("message \(id)")], timestamp: Date(timeIntervalSince1970: 1_000),
             isPending: pending)
}

@Suite("Transcript cache")
struct TranscriptCacheTests {
    let gateway = UUID()
    let key = "agent:main:main"

    @Test func roundTripWithMeta() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let snapshot = TranscriptCache.Snapshot(items: [item("a"), item("b")], complete: true, activityMs: 1234)
        await TranscriptCache.save(snapshot, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        let loaded = try #require(await TranscriptCache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(loaded.items == snapshot.items && loaded.complete && loaded.activityMs == 1234)
        let meta = try #require(await TranscriptCache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(meta.complete && meta.activityMs == 1234)

        let file = try #require(TranscriptCache.file(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        #expect(file.deletingLastPathComponent().lastPathComponent == self.gateway.uuidString)
        #expect(temp.exists(file) && temp.exists(file.appendingPathExtension("meta")))
        #expect(await TranscriptCache.load(gatewayId: self.gateway, sessionKey: "agent:main:other", root: temp.url) == nil)
    }

    @Test func versionMismatchIsIgnored() async {
        let temp = TempDir()
        defer { temp.remove() }
        let old = TranscriptCache.Snapshot(version: TranscriptCache.Snapshot.currentVersion - 1, items: [item("a")], complete: true)
        await TranscriptCache.save(old, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(await TranscriptCache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func corruptFilesAreIgnored() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let file = try #require(TranscriptCache.file(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":4,\"items\":[".utf8).write(to: file)
        try Data("garbage".utf8).write(to: file.appendingPathExtension("meta"))
        #expect(await TranscriptCache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        #expect(await TranscriptCache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func removeAllIsScopedToOneGateway() async {
        let temp = TempDir()
        defer { temp.remove() }
        let other = UUID()
        let snapshot = TranscriptCache.Snapshot(items: [item("a")], complete: false)
        await TranscriptCache.save(snapshot, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        await TranscriptCache.save(snapshot, gatewayId: other, sessionKey: self.key, root: temp.url)
        TranscriptCache.removeAll(gatewayId: self.gateway, root: temp.url)
        #expect(await TranscriptCache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        #expect(await TranscriptCache.load(gatewayId: other, sessionKey: self.key, root: temp.url)?.items.map(\.id) == ["a"])
    }

    @Test func laterWriteWins() async {
        let temp = TempDir()
        defer { temp.remove() }
        await TranscriptCache.save(.init(items: [item("A")], complete: false, activityMs: 1),
                                   gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        await TranscriptCache.save(.init(items: [item("B")], complete: true, activityMs: 2),
                                   gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        let loaded = await TranscriptCache.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(loaded?.items.map(\.id) == ["B"] && loaded?.complete == true)
        #expect(await TranscriptCache.meta(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)?.activityMs == 2)
    }

    @Test func disabledRootIsANoOp() async {
        await TranscriptCache.save(.init(items: [item("a")], complete: true), gatewayId: self.gateway, sessionKey: self.key, root: nil)
        #expect(await TranscriptCache.load(gatewayId: self.gateway, sessionKey: self.key, root: nil) == nil)
        #expect(TranscriptCache.file(gatewayId: self.gateway, sessionKey: self.key, root: nil) == nil)
    }
}

@Suite("Transcript snapshot limits")
struct SnapshotLimitTests {
    @Test func keepsNewestCommittedItems() {
        let items = (1...5).map { item("\($0)") } + [item("pending", pending: true)]
        let snapshot = ChatStore.snapshot(items: items, hasMoreHistory: false, activityMs: 9, maxItems: 3)
        #expect(snapshot.items.map(\.id) == ["3", "4", "5"])
        #expect(!snapshot.complete)
        #expect(snapshot.activityMs == 9 && snapshot.version == TranscriptCache.Snapshot.currentVersion)
    }

    @Test func completeOnlyWhenNothingIsMissing() {
        let items = (1...3).map { item("\($0)") }
        #expect(ChatStore.snapshot(items: items, hasMoreHistory: false, activityMs: nil, maxItems: 3).complete)
        #expect(!ChatStore.snapshot(items: items, hasMoreHistory: true, activityMs: nil, maxItems: 3).complete)
        let withPending = items + [item("p", pending: true)]
        let snapshot = ChatStore.snapshot(items: withPending, hasMoreHistory: false, activityMs: nil, maxItems: 3)
        #expect(snapshot.complete && snapshot.items.map(\.id) == ["1", "2", "3"])
    }

    @Test func defaultLimit() {
        #expect(TranscriptCache.maxItems == 20000)
        let snapshot = ChatStore.snapshot(items: [item("a")], hasMoreHistory: false, activityMs: nil)
        #expect(snapshot.items.count == 1 && snapshot.complete)
    }
}

@Suite("Draft store")
struct DraftStoreTests {
    let gateway = UUID()
    let key = "agent:main:alpha"
    let photo = OutgoingAttachment(fileName: "photo.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    let notes = OutgoingAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("hello".utf8))

    func folder(_ temp: TempDir) throws -> URL {
        try #require(DraftStore.directory(gatewayId: self.gateway, sessionKey: self.key, root: temp.url))
    }

    @Test func roundTrip() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let draft = ComposerDraft(text: "half-written", attachments: [self.photo, self.notes])
        await DraftStore.save(draft, gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == draft)
        #expect(temp.contents(of: try self.folder(temp))
            == ["draft.json", "\(self.photo.id.uuidString).bin", "\(self.notes.id.uuidString).bin"])
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: "agent:main:beta", root: temp.url) == nil)
    }

    @Test func emptyDraftDeletesFolder() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await DraftStore.save(ComposerDraft(text: "x"), gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(temp.exists(try self.folder(temp)))
        await DraftStore.save(ComposerDraft(), gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(!temp.exists(try self.folder(temp)))
        await DraftStore.save(ComposerDraft(text: "y"), gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        await DraftStore.remove(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(!temp.exists(try self.folder(temp)))
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func staleAttachmentsArePruned() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let stray = try self.folder(temp).appending(path: "leftover.tmp")
        await DraftStore.save(ComposerDraft(text: "t", attachments: [self.photo, self.notes]),
                              gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        try Data().write(to: stray)
        await DraftStore.save(ComposerDraft(text: "t", attachments: [self.notes]),
                              gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        #expect(temp.contents(of: try self.folder(temp)) == ["draft.json", "\(self.notes.id.uuidString).bin"])
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)?.attachments == [self.notes])
    }

    @Test func manifestVersionMismatchIsRejected() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let folder = try self.folder(temp)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":99,"text":"from the future","attachments":[]}"#.utf8).write(to: folder.appending(path: "draft.json"))
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        try Data(#"{"version":1,"text":"current","attachments":[]}"#.utf8).write(to: folder.appending(path: "draft.json"))
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)?.text == "current")
        try Data("{broken".utf8).write(to: folder.appending(path: "draft.json"))
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func missingAttachmentIsDropped() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        await DraftStore.save(ComposerDraft(text: "t", attachments: [self.photo, self.notes]),
                              gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        try FileManager.default.removeItem(at: try self.folder(temp).appending(path: "\(self.photo.id.uuidString).bin"))
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
            == ComposerDraft(text: "t", attachments: [self.notes]))

        // Nothing left to restore: no draft at all.
        await DraftStore.save(ComposerDraft(attachments: [self.photo]), gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        try FileManager.default.removeItem(at: try self.folder(temp).appending(path: "\(self.photo.id.uuidString).bin"))
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
    }

    @Test func removeAllIsScopedToOneGateway() async {
        let temp = TempDir()
        defer { temp.remove() }
        let other = UUID()
        await DraftStore.save(ComposerDraft(text: "a"), gatewayId: self.gateway, sessionKey: self.key, root: temp.url)
        await DraftStore.save(ComposerDraft(text: "b"), gatewayId: other, sessionKey: self.key, root: temp.url)
        DraftStore.removeAll(gatewayId: self.gateway, root: temp.url)
        #expect(await DraftStore.load(gatewayId: self.gateway, sessionKey: self.key, root: temp.url) == nil)
        #expect(await DraftStore.load(gatewayId: other, sessionKey: self.key, root: temp.url)?.text == "b")
    }
}
