#if DEBUG
import Foundation
@testable import PincerKit
private final class RestoreWorkerHold: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var expired = false
    var didExpire: Bool { lock.withLock { expired } }
    let events = AsyncStream<Bool>.makeStream()
    func scan(onMain: Bool) {
        events.continuation.yield(!onMain)
        guard !onMain else { return }
        if release.wait(timeout: .now() + 15) == .timedOut { lock.withLock { expired = true } }
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

@MainActor func runOutboxRestoreWorkerWindowChecks() async {
        let (defaults, suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let identity = DeviceIdentity(privateKey: .init())
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
            guard entered else { throw CancellationError() }
            check(entered, "actual off-main file scan entered")
            try Task.checkCancellation()
            gateway.injectOutboxEntry(new)
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            let during = await OutboxStore.load(gatewayId: profile.id, root: root)
            check(during.outcome == .loaded && during.outbox == initial, "held worker preserves full persisted queue")
            check(gateway.outbox.entries == [new], "new composition remains in memory during worker")
            hold.release.signal(); await task.value
            check(!hold.didExpire, "actual held worker was explicitly released")
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            let after = await OutboxStore.load(gatewayId: profile.id, root: root)
            var expected = initial; expected.enqueue(new)
            check(after.outcome == .loaded && after.outbox == expected, "completed worker persists exact restored and new queue")
            check(gateway.outbox == expected, "completed worker publishes exact merged queue")
        } catch {
            loading?.cancel(); hold.release.signal(); if let loading { await loading.value }
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            check(false, "actual worker-window setup and completion succeed"); return
        }
        gateway.outboxRestoreFileScan = nil; gateway.stop()
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
#endif
