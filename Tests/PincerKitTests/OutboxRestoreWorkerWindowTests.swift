#if DEBUG
import Foundation
import Testing
@testable import PincerKit
private final class RestoreWorkerHold: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events = AsyncStream<Bool>.makeStream()
    func scan(onMain: Bool) {
        events.continuation.yield(!onMain)
        guard !onMain else { return }
        _ = release.wait(timeout: .now() + 15)
    }
    func entered() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await value in self.events.stream { return value }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return false }
            let value = await group.next() ?? false
            group.cancelAll()
            return value
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct OutboxRestoreWorkerWindowTests {
    @Test func compositionCannotPersistOverSavedQueueWhileActualWorkerIsHeld() async throws {
        let scratch = ScratchDefaults(); defer { scratch.remove() }
        let defaults = scratch.defaults, identity = Fixtures.identity()
        let root = FileManager.default.temporaryDirectory.appending(path: "outbox-worker-window-" + UUID().uuidString, directoryHint: .isDirectory)
        let profile = GatewayProfile(name: "Worker window", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: defaults, identity: identity)
        defer { gateway.stop() }
        gateway.cacheRoot = nil; gateway.outboxRoot = root; gateway.notifier = nil
        let ref = OutboxAttachmentRef(id: UUID(), fileName: "note.txt", mimeType: "text/plain", byteCount: 4)
        let old = OutboxEntry(id: "saved", sessionKey: "agent:main:main", text: "saved", createdAt: Date(timeIntervalSince1970: 1800000000), attachments: [ref])
        let new = OutboxEntry(id: "new", sessionKey: old.sessionKey, text: "new", createdAt: old.createdAt.addingTimeInterval(1))
        var saved = Outbox(); saved.enqueue(old)
        let initial = saved
        let hold = RestoreWorkerHold()
        var loading: Task<Void, Never>?
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(OutboxStore.Envelope(version: OutboxStore.currentVersion, outbox: initial)).write(to: OutboxStore.file(gatewayId: profile.id, root: root)!, options: .atomic)
                let file = OutboxAttachmentStore.fileURL(gatewayId: profile.id, entryId: old.id, attachmentId: ref.id, root: root)!
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("note".utf8).write(to: file, options: .atomic)
            }.value
            gateway.outboxRestoreFileScan = { hold.scan(onMain: $0) }
            let task = Task { await gateway.loadOutbox() }; loading = task
            let entered = await hold.entered()
            try #require(entered, "actual off-main file scan entered")
            try Task.checkCancellation()
            gateway.injectOutboxEntry(new)
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            let during = await OutboxStore.load(gatewayId: profile.id, root: root)
            #expect(during.outcome == .loaded && during.outbox == initial)
            #expect(gateway.outbox.entries == [new])
            hold.release.signal(); await task.value
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            let after = await OutboxStore.load(gatewayId: profile.id, root: root)
            var expected = initial; expected.enqueue(new)
            #expect(after.outcome == .loaded && after.outbox == expected)
            #expect(gateway.outbox == expected)
        } catch {
            loading?.cancel(); hold.release.signal(); if let loading { await loading.value }
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        gateway.outboxRestoreFileScan = nil; gateway.stop()
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
#endif
