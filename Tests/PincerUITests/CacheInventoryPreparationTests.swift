#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Actual cache inventory preparation", .timeLimit(.minutes(2)))
struct CacheInventoryPreparationTests {
    @Test
    func actualReconciliationEnumeratesOffMainAndPreservesLiveOwners() async throws {
        let suite = "cache-inventory-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.appIsActive = false
        gateway.start()
        defer {
            gateway.stop()
            Task.detached { try? FileManager.default.removeItem(at: root) }
        }
        while !gateway.bootstrapProbeIsTerminal { try await Task.sleep(for: .milliseconds(10)) }
        await gateway.bootstrapMainTask?.value
        await gateway.bootstrapLastBackgroundTask?.value
        let listedResult = await gateway.completeSessionKeys()
        let listed = try #require(listedResult)
        let listedKey = try #require(listed.sorted().first)
        let currentKey = "agent:main:inventory-current"
        let queuedKey = "agent:main:inventory-outbox"
        let orphanKey = "agent:main:inventory-orphan"
        _ = gateway.chat(for: currentKey)
        gateway.outbox.enqueue(OutboxEntry(id: "inventory-send", sessionKey: queuedKey, text: "retained intent",
                                         createdAt: Date(), state: .failed(.init(message: "fixture held", retryable: true))))
        let keys = [listedKey, currentKey, queuedKey, orphanKey]
        let id = gateway.id
        try await Task.detached {
            let directory = try #require(TranscriptCache.directory(gatewayId: id, root: root))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = try JSONEncoder().encode(TranscriptCache.Snapshot(items: [], complete: true))
            for key in keys {
                let file = try #require(TranscriptCache.file(gatewayId: id, sessionKey: key, root: root))
                try payload.write(to: file, options: .atomic)
            }
            try Data().write(to: directory.appending(path: "not-a-cache.json"))
        }.value
        gateway.cacheRoot = root
        let probe = CacheInventoryProbe()
        gateway.cacheInventoryProbe = probe
        await gateway.reconcileOrphanedTranscripts(epoch: gateway.connectionEpoch)
        let counts = probe.snapshot()
        #expect(counts.main == 0 && counts.offMain > 0)
        #expect(counts.main + counts.offMain > 0)
        let remaining = await Task.detached { Set(TranscriptCache.cachedDigests(gatewayId: id, root: root)) }.value
        let expected = await Task.detached { Set([listedKey, currentKey, queuedKey].map(TranscriptCache.digest(of:))) }.value
        #expect(remaining == expected)
        #expect(gateway.outbox.entries(for: queuedKey).count == 1)
        #expect(gateway.chats[currentKey] != nil)
        let unrelatedRetained = await Task.detached {
            let directory = TranscriptCache.directory(gatewayId: id, root: root)!
            return FileManager.default.fileExists(atPath: directory.appending(path: "not-a-cache.json").path)
        }.value
        #expect(unrelatedRetained)
    }
}
#endif
