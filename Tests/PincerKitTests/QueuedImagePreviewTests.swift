import Foundation
import Testing
@testable import PincerKit

private final class PreviewPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let heldCall: Int
    private var calls = 0
    private var wasMain = false
    init(heldCall: Int = 1) { self.heldCall = heldCall }
    var ranOnMain: Bool { lock.withLock { wasMain } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func open() { release.signal() }
    func probe() {
        let hold = lock.withLock {
            calls += 1
            wasMain = wasMain || Thread.isMainThread
            return calls == heldCall
        }
        if hold {
            entered.signal()
            if !Thread.isMainThread { release.wait() }
        }
    }
}

@MainActor
@Suite("Queued image preview")
struct QueuedImagePreviewTests {
    let scratch = ScratchDefaults()
    let key = "agent:main:main"

    var pngData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
    }

    func restoredRow(state: OutboxState) -> (GatewayStore, ChatStore) {
        let gateway = GatewayStore(profile: GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.outboxRoot = nil
        let data = pngData
        let ref = OutboxAttachmentRef(id: UUID(), fileName: "photo.png", mimeType: "image/png", byteCount: data.count)
        let entry = OutboxEntry(id: "queued-image", sessionKey: key, text: "Look", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                state: state, attachments: [ref])
        gateway.outboxAttachments[entry.id] = [OutgoingAttachment(id: ref.id, fileName: ref.fileName, mimeType: ref.mimeType, data: data)]
        let chat = gateway.chat(for: key)
        gateway.outbox = Outbox(entries: [entry])
        chat.syncOutbox([entry])
        return (gateway, chat)
    }

    func hasImage(_ chat: ChatStore) -> Bool {
        chat.items.contains { item in
            item.idempotencyKey == "queued-image" && item.blocks.contains { block in
                if case .image = block { return true }
                return false
            }
        }
    }

    @Test func queuedRestoredImageHasPreview() async {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        await chat.waitForOutboxImagePreviews()
        #expect(hasImage(chat), "a restored queued image must have an image preview instead of only a file chip")
    }

    @Test func failedRestoredImageKeepsPreview() async {
        let (gateway, chat) = restoredRow(state: .failed(OutboxFailure(message: "Try again", retryable: true)))
        defer { gateway.stop(); scratch.remove() }
        await chat.waitForOutboxImagePreviews()
        #expect(hasImage(chat), "failed attachment rows still need an image preview")
    }

    @Test func persistedAttachmentRestoresPreviewWithoutMemoryBytes() async throws {
        let temp = TempDir()
        let profile = GatewayProfile(name: "Persisted", url: "ws://127.0.0.1:9", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.outboxRoot = temp.url
        defer { gateway.stop(); temp.remove(); scratch.remove() }
        let data = pngData
        let attachment = OutgoingAttachment(fileName: "photo.png", mimeType: "image/png", data: data)
        let entry = OutboxEntry(id: "queued-image", sessionKey: key, text: "Saved", createdAt: Date(),
                                attachments: OutboxAttachmentStore.refs(for: [attachment]))
        #expect(OutboxAttachmentStore.enqueueWrite([attachment], entryId: entry.id, gatewayId: profile.id, root: temp.url))
        await OutboxStore.flushWrites(gatewayId: profile.id, root: temp.url)
        // Exercise attachment persistence independently of the encrypted outbox JSON writer,
        // which is covered by OutboxAttachmentPersistenceTests and requires an unlocked host.
        let saved = await Task.detached {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let envelope = OutboxStore.Envelope(version: OutboxStore.currentVersion, outbox: Outbox(entries: [entry]))
            return (try? encoder.encode(envelope)).flatMap { OutboxStore.decode($0).outbox }
        }.value
        let restored = try #require(saved)
        let chat = gateway.chat(for: key)
        gateway.outbox = restored
        await chat.waitForOutboxImagePreviews()
        #expect(gateway.outboxAttachments[entry.id] == nil, "the image comes from the persisted attachment")
        #expect(hasImage(chat))
    }

    @Test func previewSurvivesFailureAndIsRemovedOnDelete() async {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        await chat.waitForOutboxImagePreviews()
        #expect(hasImage(chat))
        gateway.updateOutbox { $0.markFailed(id: "queued-image", kind: .transient) }
        await chat.waitForOutboxImagePreviews()
        #expect(hasImage(chat))
        gateway.updateOutbox { $0.delete(id: "queued-image") }
        await chat.waitForOutboxImagePreviews()
        #expect(!chat.items.contains { $0.idempotencyKey == "queued-image" })
    }

    @Test func evictionReleasesImageSourcesHeldByRowsWithIdenticalFileNames() async throws {
        let gateway = GatewayStore(profile: GatewayProfile(name: "Budget", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.outboxRoot = nil
        defer { gateway.stop(); scratch.remove() }
        let first = OutgoingAttachment(fileName: "photo.png", mimeType: "image/png", data: pngData)
        let second = OutgoingAttachment(fileName: "photo.png", mimeType: "image/png", data: pngData)
        let sample = try #require(await OutboxImagePreviewWorker.shared.prepare(first, probe: nil))
        let chat = gateway.chat(for: key)
        chat.outboxImagePreviews = OutboxImagePreviewCache(byteLimit: sample.encodedBytes)
        let entries = [first, second].enumerated().map { index, attachment in
            OutboxEntry(id: "budget-\(index)", sessionKey: key, text: "", createdAt: Date(),
                        attachments: OutboxAttachmentStore.refs(for: [attachment]))
        }
        gateway.outboxAttachments = [entries[0].id: [first], entries[1].id: [second]]
        gateway.outbox = Outbox(entries: entries)
        await chat.waitForOutboxImagePreviews()
        let rows = chat.items.filter { $0.outboxState != nil }
        let sources = rows.flatMap(\.blocks).compactMap { block -> String? in
            if case let .image(image) = block { return image.base64 }
            return nil
        }
        #expect(sources.count == 1, "the encoded source budget includes references held by visible rows")
        #expect(sources.reduce(0) { $0 + $1.utf8.count } <= sample.encodedBytes)
        #expect(rows.first { $0.idempotencyKey == entries[0].id }?.blocks.contains {
            if case let .file(file) = $0 { return file.name == "photo.png" }
            return false
        } == true, "eviction restores the correct entry's original file chip")
    }

    @Test func missingPersistedImageRetainsFileFallback() async {
        let temp = TempDir()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Missing", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.outboxRoot = temp.url
        defer { gateway.stop(); temp.remove(); scratch.remove() }
        let ref = OutboxAttachmentRef(id: UUID(), fileName: "missing.png", mimeType: "image/png", byteCount: 100)
        let entry = OutboxEntry(id: "queued-image", sessionKey: key, text: "", createdAt: Date(), attachments: [ref])
        let chat = gateway.chat(for: key)
        gateway.outbox = Outbox(entries: [entry])
        await chat.waitForOutboxImagePreviews()
        #expect(!hasImage(chat))
        #expect(chat.items.first?.blocks.contains {
            if case let .file(file) = $0 { return file.name == "missing.png" }
            return false
        } == true)
        chat.syncOutbox([entry])
        #expect(chat.outboxPreviewTask == nil, "unchanged missing files do not start a decode retry loop")
    }

    @Test func newlyQueuedImageUsesTheSameBoundedPreviewPipeline() async {
        let temp = TempDir()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.outboxRoot = temp.url
        defer { gateway.stop(); temp.remove(); scratch.remove() }
        let chat = gateway.chat(for: key)
        let outcome = await chat.sendMessage("Photo", attachments: [
            OutgoingAttachment(fileName: "new.png", mimeType: "image/png", data: pngData),
        ])
        #expect(outcome == .queued)
        await chat.waitForOutboxImagePreviews()
        #expect(chat.items.contains { item in
            item.outboxState == .queued && item.blocks.contains {
                if case let .image(image) = $0 { return image.alt == "new.png" }
                return false
            }
        })
    }

    @Test func acceptedPendingImageRetainsPreviewUntilTranscriptCommit() async throws {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        await chat.waitForOutboxImagePreviews()
        #expect(hasImage(chat))
        let index = try #require(chat.items.firstIndex { $0.idempotencyKey == "queued-image" })
        chat.items[index].outboxState = nil
        gateway.updateOutbox { $0.markSent(id: "queued-image") }
        #expect(chat.items[index].isPending)
        #expect(hasImage(chat), "Gateway acceptance must not replace the image with a file chip while transcript commit is delayed")
        chat.items[index].isPending = false
        chat.items[index].blocks = [.text("Committed")]
        chat.syncOutbox([])
        #expect(chat.outboxImagePreviews.retainedBytes == 0, "the outbox preview releases its source after transcript commit")
    }

    @Test(arguments: [false, true])
    func cancelledPreviewCannotApplyAfterStopOrDeletion(deleteEntry: Bool) async {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        let gate = PreviewPreparationGate()
        defer { gate.open() }
        chat.outboxImagePreviewProbe = gate.probe
        let task = chat.outboxPreviewTask
        let entered = await Task.detached { gate.waitForEntry() }.value
        #expect(entered)
        #expect(!gate.ranOnMain, "reading and decoding previews cannot occupy the transcript's main actor")
        if deleteEntry {
            gateway.updateOutbox { $0.delete(id: "queued-image") }
        } else {
            chat.stopCaching()
        }
        gate.open()
        await task?.value
        #expect(!hasImage(chat), "a completed obsolete decode cannot repopulate the stopped or deleted preview")
        #expect(chat.outboxImagePreviews.retainedBytes == 0)
        #expect(chat.outboxPreviewTask == nil)
        if deleteEntry { #expect(chat.items.isEmpty) }
    }

    @Test func acceptedPendingPreviewIsEvictedWithinTheSharedRowBudget() async throws {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        await chat.waitForOutboxImagePreviews()
        let image = try #require(chat.items.flatMap(\.blocks).compactMap { block -> ImageRef? in
            if case let .image(image) = block { return image }
            return nil
        }.first)
        let budget = try #require(image.base64?.utf8.count)
        let original = try #require(gateway.outbox.entries.first)
        chat.outboxImagePreviews = OutboxImagePreviewCache(byteLimit: budget)
        chat.outboxImagePreviews.insert(image, encodedBytes: budget, for:
            OutboxImagePreviewKey(entryId: original.id, attachmentId: original.attachments[0].id))
        let index = try #require(chat.items.firstIndex { $0.idempotencyKey == original.id })
        chat.items[index].outboxState = nil
        gateway.updateOutbox { $0.markSent(id: original.id) }
        #expect(hasImage(chat), "acceptance retains the preview while it fits")
        let next = OutgoingAttachment(fileName: "next.png", mimeType: "image/png", data: pngData)
        let entry = OutboxEntry(id: "next-image", sessionKey: key, text: "", createdAt: Date(),
                                attachments: OutboxAttachmentStore.refs(for: [next]))
        gateway.outboxAttachments[entry.id] = [next]
        gateway.outbox = Outbox(entries: [entry])
        await chat.waitForOutboxImagePreviews()
        #expect(!hasImage(chat), "an accepted row cannot retain an image evicted from the shared budget")
        #expect(chat.items.first { $0.idempotencyKey == original.id }?.blocks.contains {
            if case let .file(file) = $0 { return file.name == "photo.png" }
            return false
        } == true)
        let rowBytes = chat.items.filter(\.isPending).flatMap(\.blocks).reduce(0) { sum, block in
            if case let .image(image) = block { return sum + (image.base64?.utf8.count ?? 0) }
            return sum
        }
        #expect(rowBytes > 0 && rowBytes <= budget)
    }

    @Test func transientPreviewSourcesStayWithinTwoBudgetsDuringBatchEviction() async throws {
        let (gateway, chat) = restoredRow(state: .queued)
        defer { gateway.stop(); scratch.remove() }
        await chat.waitForOutboxImagePreviews()
        let firstImage = try #require(chat.items.flatMap(\.blocks).compactMap { block -> ImageRef? in
            if case let .image(image) = block { return image }
            return nil
        }.first)
        let budget = try #require(firstImage.base64?.utf8.count)
        chat.outboxImagePreviews = OutboxImagePreviewCache(byteLimit: budget)
        let original = try #require(gateway.outbox.entries.first)
        chat.outboxImagePreviews.insert(firstImage, encodedBytes: budget, for:
            OutboxImagePreviewKey(entryId: original.id, attachmentId: original.attachments[0].id))
        let gate = PreviewPreparationGate(heldCall: 2)
        defer { gate.open() }
        chat.outboxImagePreviewProbe = gate.probe
        let additions = (0..<2).map { index -> OutboxEntry in
            let attachment = OutgoingAttachment(fileName: "batch-\(index).png", mimeType: "image/png", data: pngData)
            let entry = OutboxEntry(id: "batch-\(index)", sessionKey: key, text: "", createdAt: Date(),
                                    attachments: OutboxAttachmentStore.refs(for: [attachment]))
            gateway.outboxAttachments[entry.id] = [attachment]
            return entry
        }
        gateway.outbox = Outbox(entries: [original] + additions)
        let entered = await Task.detached { gate.waitForEntry() }.value
        #expect(entered)
        let rowBytes = chat.items.flatMap(\.blocks).reduce(0) { sum, block in
            if case let .image(image) = block { return sum + (image.base64?.utf8.count ?? 0) }
            return sum
        }
        #expect(rowBytes == budget, "the old applied source remains while the second source is prepared")
        #expect(rowBytes + chat.outboxImagePreviews.retainedBytes <= 2 * budget,
                "the transient bound includes old row references and the incoming bounded cache")
        gate.open()
        await chat.waitForOutboxImagePreviews()
        let settledRowBytes = chat.items.flatMap(\.blocks).reduce(0) { sum, block in
            if case let .image(image) = block { return sum + (image.base64?.utf8.count ?? 0) }
            return sum
        }
        #expect(settledRowBytes <= budget)
    }
}
