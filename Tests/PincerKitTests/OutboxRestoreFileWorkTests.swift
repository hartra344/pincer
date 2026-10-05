#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct OutboxRestoreFileWorkTests {
    actor Delivery {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test func actualRestoredAttachmentsAreValidatedOffMainAndRetainNewComposition() async throws {
        let scratch = ScratchDefaults()
        let root = FileManager.default.temporaryDirectory.appending(path: "pincer-outbox-restore-" + UUID().uuidString, directoryHint: .isDirectory)
        let profile = GatewayProfile(name: "Offline restore", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = root; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        let key = "agent:main:main", date = Date(timeIntervalSince1970: 1_800_000_000)
        let present = OutboxAttachmentRef(id: UUID(), fileName: "note.txt", mimeType: "text/plain", byteCount: 4)
        let missing = OutboxAttachmentRef(id: UUID(), fileName: "missing.txt", mimeType: "text/plain", byteCount: 4)
        let queued = OutboxEntry(id: "restore-queued", sessionKey: key, text: "queued", createdAt: date, attachments: [present])
        let absent = OutboxEntry(id: "restore-missing", sessionKey: key, text: "missing", createdAt: date, attachments: [missing])
        let interrupted = OutboxEntry(id: "restore-sending", sessionKey: key, text: "interrupted", createdAt: date, state: .sending, attempts: 2)
        var saved = Outbox(); saved.enqueue(queued); saved.enqueue(absent); saved.enqueue(interrupted)
        let savedFixture = saved
        do {
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(OutboxStore.Envelope(version: OutboxStore.currentVersion, outbox: savedFixture))
            try data.write(to: OutboxStore.file(gatewayId: profile.id, root: root)!, options: .atomic)
            let file = OutboxAttachmentStore.fileURL(gatewayId: profile.id, entryId: queued.id, attachmentId: present.id, root: root)!
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("note".utf8).write(to: file, options: .atomic)
        }.value
        } catch {
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        let fixtureRead = await OutboxStore.load(gatewayId: profile.id, root: root)
        do {
            try #require(fixtureRead.outcome == .loaded && fixtureRead.outbox == savedFixture)
        } catch {
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        let delivery = Delivery(), probe = OutboxRestoreFileScanProbe()
        gateway.outboxRestoreReadDelivery = { await delivery.hold() }
        gateway.outboxRestoreFileScan = { probe.record(onMain: $0) }
        let loading = Task { await gateway.loadOutbox() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await delivery.entered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(gateway.outbox.isEmpty)
            let newEntry = OutboxEntry(id: "composed-during-read", sessionKey: key, text: "new", createdAt: date.addingTimeInterval(1))
            gateway.injectOutboxEntry(newEntry)
            await delivery.release(); await loading.value
            #expect(gateway.outbox.entries.map(\.id) == [queued.id, absent.id, interrupted.id, newEntry.id])
            #expect(gateway.outbox.entry(id: queued.id) == queued)
            #expect(gateway.outbox.entry(id: newEntry.id) == newEntry)
            var recovered = interrupted; recovered.state = .queued
            #expect(gateway.outbox.entry(id: interrupted.id) == recovered)
            let expectedFailure = "Couldn’t send: the attachments are no longer available. Delete this message and attach them again."
            var rejected = absent; rejected.state = .failed(OutboxFailure(message: expectedFailure, retryable: false))
            #expect(gateway.outbox.entry(id: absent.id) == rejected)
            let counts = probe.counts()
            #expect(counts.main == 0 && counts.worker == 2, "actual filesystem validation belongs off Main")
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
        } catch {
            loading.cancel(); await delivery.release(); await loading.value
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        gateway.outboxRestoreReadDelivery = nil; gateway.outboxRestoreFileScan = nil
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
#endif
