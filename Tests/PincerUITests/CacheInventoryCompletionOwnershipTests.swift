#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Completed cache inventory ownership", .timeLimit(.minutes(2)))
struct CacheInventoryCompletionOwnershipTests {
    enum Change: Sendable { case currentChat, outbox, reconnect, cancel }
    actor Gate {
        var entered = false, open = false
        var entry: CheckedContinuation<Void, Never>?
        var held: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; entry?.resume(); entry = nil
            if !open { await withCheckedContinuation { held = $0 } }
        }
        func wait() async {
            if !entered, !open { await withCheckedContinuation { entry = $0 } }
        }
        func release() { open = true; entry?.resume(); entry = nil; held?.resume(); held = nil }
    }

    @Test(arguments: [Change.currentChat, .outbox, .reconnect, .cancel])
    func completedInventoryCannotDeleteNewOwnerOrPublishAcrossEpoch(change: Change) async throws {
        let suite = "inventory-completion-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.appIsActive = false
        let gate = Gate()
        gateway.start()
        defer {
            Task { await gate.release() }
            gateway.stop()
            Task.detached { try? FileManager.default.removeItem(at: root) }
        }
        while !gateway.bootstrapProbeIsTerminal { try await Task.sleep(for: .milliseconds(10)) }
        await gateway.bootstrapMainTask?.value
        await gateway.bootstrapLastBackgroundTask?.value
        let id = gateway.id, key = "agent:main:inventory-new-owner"
        try await Task.detached {
            let directory = TranscriptCache.directory(gatewayId: id, root: root)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = try JSONEncoder().encode(TranscriptCache.Snapshot(items: [], complete: true))
            try payload.write(to: TranscriptCache.file(gatewayId: id, sessionKey: key, root: root)!, options: .atomic)
        }.value
        gateway.cacheRoot = root
        let probe = CacheInventoryProbe(); gateway.cacheInventoryProbe = probe
        gateway.cacheInventoryDidPrepare = { await gate.hold() }
        let epoch = gateway.connectionEpoch
        let actual = Task { await gateway.reconcileOrphanedTranscripts(epoch: epoch) }
        try await withTaskCancellationHandler {
            await gate.wait()
            #expect(probe.snapshot().offMain == 1)
            switch change {
            case .currentChat: _ = gateway.chat(for: key)
            case .outbox:
                gateway.outbox.enqueue(OutboxEntry(id: "new-owner", sessionKey: key, text: "retained intent", createdAt: Date(),
                                                  state: .failed(.init(message: "fixture held", retryable: true))))
            case .reconnect:
                gateway.cacheRoot = nil // The new epoch must not legitimately clean this scratch inventory itself.
                await gateway.connection.stop()
                await gateway.connection.start()
                while gateway.connectionEpoch == epoch || !gateway.bootstrapProbeIsTerminal {
                    try await Task.sleep(for: .milliseconds(10))
                }
                await gateway.bootstrapMainTask?.value
                await gateway.bootstrapLastBackgroundTask?.value
                #expect(gateway.connectionEpoch > epoch)
            case .cancel: actual.cancel()
            }
            await gate.release()
            await actual.value
            let exists = await Task.detached {
                FileManager.default.fileExists(atPath: TranscriptCache.file(gatewayId: id, sessionKey: key, root: root)!.path)
            }.value
            #expect(exists)
            #expect(probe.snapshot().main == 0)
        } onCancel: {
            actual.cancel()
            Task { await gate.release() }
        }
    }
}
#endif
