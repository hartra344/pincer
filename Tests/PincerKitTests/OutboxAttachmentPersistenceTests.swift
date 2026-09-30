import Foundation
import Testing
@testable import PincerKit

/// #215: a message queued with attachments keeps them on disk and survives a relaunch.
@MainActor
@Suite("Outbox attachment persistence")
struct OutboxAttachmentPersistenceTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let key = "agent:main:main"
    let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)
    let bytes = Data((0..<2048).map { UInt8($0 % 251) })

    func store() -> GatewayStore {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        store.outboxRoot = self.temp.url // before `start()`'s load runs
        return store
    }

    /// Runs the load `start()` kicks off, waiting on it rather than on a clock (#458).
    func started(_ store: GatewayStore) async -> Bool {
        store.start()
        await store.outboxLoadTask?.value
        return await eventually(timeout: .seconds(1)) { store.outboxRestored }
    }

    func settle(_ store: GatewayStore) async {
        await OutboxStore.flushWrites(gatewayId: store.id, root: self.temp.url)
        OutboxAttachmentStore.drain(gatewayId: store.id, root: self.temp.url)
    }

    func attachment(fileName: String = "photo.png", mimeType: String = "image/png") -> OutgoingAttachment {
        OutgoingAttachment(fileName: fileName, mimeType: mimeType, data: self.bytes)
    }

    func dir(_ store: GatewayStore, _ entryId: String) throws -> URL {
        try #require(OutboxAttachmentStore.directory(gatewayId: store.id, entryId: entryId, root: self.temp.url))
    }

    /// Queues a send with one attachment while offline and returns the entry.
    func queue(_ store: GatewayStore, text: String = "look", mimeType: String = "image/png",
               fileName: String = "photo.png") async throws -> OutboxEntry {
        let outcome = await store.chat(for: self.key).sendMessage(
            text, attachments: [self.attachment(fileName: fileName, mimeType: mimeType)])
        if case .sent = outcome { Issue.record("offline send shouldn't go out") }
        let entry = try #require(store.outbox.entries.last)
        await self.settle(store)
        return entry
    }

    func finish(_ stores: GatewayStore...) {
        for store in stores { store.stop() }
        self.temp.remove()
        self.scratch.remove()
    }

    // MARK: Pure outbox rules

    @Test func persistedAttachmentEntriesBehaveLikeText() {
        let ref = OutboxAttachmentRef(id: UUID(), fileName: "a.png", mimeType: "image/png", byteCount: 10)
        var box = Outbox()
        box.enqueue(OutboxEntry(id: "p", sessionKey: "a", text: "pic", createdAt: Date(), attachments: [ref]))
        #expect(box.entry(id: "p")?.hasAttachments == true)
        #expect(box.persistable.entries.map(\.id) == ["p"])
        #expect(box.nextToSend()?.id == "p", "auto-sends like text")
        box.markSending(id: "p")
        box.connectionLost()
        #expect(box.entry(id: "p")?.state == .queued)
        box.markSending(id: "p")
        box.markFailed(id: "p", kind: .transient, isConnected: false)
        #expect(box.entry(id: "p")?.state == .queued, "a drop keeps it queued")
        box.recoverAfterLaunch()
        #expect(box.entry(id: "p") != nil, "survives a relaunch")
    }

    @Test func memoryOnlyAttachmentEntriesKeepTheOldRules() {
        var box = Outbox()
        box.enqueue(OutboxEntry(id: "m", sessionKey: "a", text: "pic", createdAt: Date(), hasAttachments: true))
        #expect(box.persistable.isEmpty)
        #expect(box.nextToSend() == nil, "never auto-sent")
        box.markSending(id: "m")
        box.connectionLost()
        #expect(box.entry(id: "m")?.isFailed == true)
        box.recoverAfterLaunch()
        #expect(box.isEmpty, "dropped on relaunch")
    }

    @Test func entriesWithoutRefsDecodeFromOlderFiles() throws {
        let plain = OutboxEntry(id: "x", sessionKey: "a", text: "t", createdAt: Date())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let old = try JSONDecoder().decode(OutboxEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.attachments.isEmpty && !old.hasAttachments)
        let ref = OutboxAttachmentRef(id: UUID(), fileName: "a.png", mimeType: "image/png", byteCount: 10)
        let entry = OutboxEntry(id: "x", sessionKey: "a", text: "t", createdAt: Date(), attachments: [ref])
        let round = try JSONDecoder().decode(OutboxEntry.self, from: JSONEncoder().encode(entry))
        #expect(round.attachments == [ref] && round.hasAttachments)
    }

    // MARK: Relaunch

    @Test func attachmentSurvivesRelaunchAsFilesNotJSONBytes() async throws {
        defer { self.finish() }
        let first = self.store()
        #expect(await self.started(first))
        let entry = try await self.queue(first)
        #expect(entry.attachments.count == 1 && entry.attachments[0].byteCount == self.bytes.count)
        #expect(first.outboxAttachmentBytes == self.bytes.count)
        let file = try #require(OutboxAttachmentStore.fileURL(
            gatewayId: first.id, entryId: entry.id, attachmentId: entry.attachments[0].id, root: self.temp.url))
        #expect(try Data(contentsOf: file) == self.bytes, "raw bytes on disk")

        first.saveOutboxNow()
        first.stop()
        let json = try Data(contentsOf: #require(OutboxStore.file(gatewayId: first.id, root: self.temp.url)))
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("photo.png") && text.contains(entry.id))
        #expect(!text.contains(self.bytes.base64EncodedString().prefix(64)), "JSON holds refs, not base64 bytes")

        let second = self.store()
        defer { second.stop() }
        #expect(await self.started(second))
        let restored = try #require(second.outbox.entry(id: entry.id))
        #expect(restored.attachments == entry.attachments && restored.text == "look")
        #expect(restored.state == .queued)
        #expect(second.outbox.nextToSend()?.id == entry.id, "it will go out on reconnect")
        let loaded = await second.attachmentBytes(for: restored)
        #expect(loaded.map(\.data) == [self.bytes], "the original bytes come back, with the same idempotency key \(entry.id)")
        #expect(loaded.map(\.fileName) == ["photo.png"])
        #expect(second.chat(for: self.key).items.contains { $0.idempotencyKey == entry.id }, "shows in the chat")
    }

    @Test func queuesBehindAnEarlierMessage() async throws {
        defer { self.finish() }
        let store = self.store()
        #expect(await self.started(store))
        _ = await store.chat(for: self.key).sendMessage("first")
        let entry = try await self.queue(store, text: "second")
        #expect(store.outbox.entries.map(\.text) == ["first", "second"])
        #expect(!entry.attachments.isEmpty)
    }

    @Test func overTheCapStaysMemoryOnlyAndIsDroppedOnRelaunch() async throws {
        defer { self.finish() }
        let first = self.store()
        #expect(await self.started(first))
        let full = OutboxAttachmentRef(id: UUID(), fileName: "big.bin", mimeType: "application/octet-stream",
                                       byteCount: OutboxAttachmentStore.maxTotalBytes - 10)
        first.injectOutboxEntry(OutboxEntry(id: "big", sessionKey: self.key, text: "big", createdAt: Date(), attachments: [full]))
        #expect(!first.canPersistAttachments(bytes: 11))
        #expect(first.canPersistAttachments(bytes: 10))
        first.injectOutboxEntry(OutboxEntry(id: "mem", sessionKey: "agent:other:main", text: "mem", createdAt: Date(), hasAttachments: true))
        first.saveOutboxNow()
        first.stop()

        let second = self.store()
        defer { second.stop() }
        #expect(await self.started(second))
        #expect(second.outbox.entry(id: "mem") == nil, "the memory-only one is gone")
    }

    @Test func storeOffKeepsAttachmentsInMemoryOnly() async throws {
        defer { self.finish() }
        let store = self.store()
        store.outboxRoot = nil
        #expect(!store.canPersistAttachments(bytes: 1))
    }

    @Test func missingFilesFailTheEntryInsteadOfLosingIt() async throws {
        defer { self.finish() }
        let first = self.store()
        #expect(await self.started(first))
        let entry = try await self.queue(first)
        first.saveOutboxNow()
        first.stop()
        try FileManager.default.removeItem(at: self.dir(first, entry.id))

        let second = self.store()
        defer { second.stop() }
        #expect(await self.started(second))
        let restored = try #require(second.outbox.entry(id: entry.id), "not silently dropped")
        guard case let .failed(failure) = restored.state else {
            Issue.record("expected failed, got \(restored.state)")
            return
        }
        #expect(!failure.retryable, "it can only be deleted")
        #expect(failure.message.contains("no longer available"))
        #expect(second.outbox.nextToSend() == nil)
    }

    // MARK: Cleanup

    @Test func filesGoWhenTheEntryIsSent() async throws {
        defer { self.finish() }
        let store = self.store()
        #expect(await self.started(store))
        let entry = try await self.queue(store)
        let dir = try self.dir(store, entry.id)
        #expect(self.temp.exists(dir))
        store.outbox.markSending(id: entry.id)
        store.outbox.markSent(id: entry.id)
        await self.settle(store)
        #expect(!self.temp.exists(dir))
    }

    @Test func filesGoWhenTheEntryIsDeleted() async throws {
        defer { self.finish() }
        let store = self.store()
        #expect(await self.started(store))
        let entry = try await self.queue(store)
        let dir = try self.dir(store, entry.id)
        store.chat(for: self.key).discardUnsent(entry.id)
        await self.settle(store)
        #expect(!self.temp.exists(dir))
    }

    @Test func filesGoWhenTheChatIsRemoved() async throws {
        defer { self.finish() }
        let store = self.store()
        #expect(await self.started(store))
        let entry = try await self.queue(store)
        let dir = try self.dir(store, entry.id)
        store.outbox.removeSession(self.key)
        await self.settle(store)
        #expect(!self.temp.exists(dir))
    }

    @Test func filesGoWhenTheOutboxIsDiscarded() async throws {
        defer { self.finish() }
        let store = self.store()
        #expect(await self.started(store))
        let entry = try await self.queue(store)
        let dir = try self.dir(store, entry.id)
        store.discardOutbox()
        await self.settle(store)
        #expect(!self.temp.exists(dir))
        #expect(store.outboxAttachmentBytes == 0)
    }

    @Test func rekeyingMovesTheFiles() async throws {
        defer { self.finish() }
        let store = self.store()
        #expect(await self.started(store))
        let entry = try await self.queue(store)
        store.moveOutboxAttachments(from: entry.id, to: "new-key")
        await self.settle(store)
        #expect(!self.temp.exists(try self.dir(store, entry.id)))
        #expect(self.temp.exists(try self.dir(store, "new-key")))
    }

    @Test func orphanDirectoriesAreSweptAtLoad() async throws {
        defer { self.finish() }
        let store = self.store()
        let orphan = try self.dir(store, "orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try self.bytes.write(to: orphan.appending(path: UUID().uuidString))
        #expect(await self.started(store))
        await self.settle(store)
        #expect(!self.temp.exists(orphan))
    }

    @Test func unsafeEntryIdsCantBeDirectories() {
        let gateway = UUID()
        for id in ["", ".", "..", "a/b"] {
            #expect(OutboxAttachmentStore.directory(gatewayId: gateway, entryId: id, root: self.temp.url) == nil, "\(id)")
            #expect(!OutboxAttachmentStore.enqueueWrite([self.attachment()], entryId: id, gatewayId: gateway, root: self.temp.url))
        }
        self.temp.remove()
    }

    @Test func restoredEntriesShowFileChipsAndAppAggregatesBytes() async throws {
        defer { self.finish() }
        let app = AppModel(defaults: self.scratch.defaults)
        let first = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none), secret: nil)
        first.outboxRoot = self.temp.url
        #expect(await self.restored(first))
        let entry = try await self.queue(first, mimeType: "application/pdf", fileName: "doc.pdf")
        #expect(app.outboxAttachmentBytes == self.bytes.count)
        let chips = first.chat(for: self.key).items.last?.blocks.compactMap { block -> String? in
            if case let .file(ref) = block { ref.name } else { nil }
        }
        #expect(chips == ["doc.pdf"])
        first.saveOutboxNow()
        first.stop()

        let second = GatewayStore(profile: first.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        second.outboxRoot = self.temp.url
        defer { second.stop() }
        #expect(await self.started(second))
        let restoredChips = second.chat(for: self.key).items.first { $0.idempotencyKey == entry.id }?.blocks.compactMap { block -> String? in
            if case let .file(ref) = block { ref.name } else { nil }
        }
        #expect(restoredChips == ["doc.pdf"])
    }

    func restored(_ store: GatewayStore) async -> Bool {
        await store.outboxLoadTask?.value
        return await eventually(timeout: .seconds(1)) { store.outboxRestored }
    }
}
