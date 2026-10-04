#if DEBUG
import Foundation
@testable import PincerKit

@MainActor
func runCacheInventoryPreparationChecks() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "inventory-control-\(UUID())")
    let id = UUID(), key = "agent:main:inventory-control"
    let probe = CacheInventoryProbe()
    do {
        let valid = try await Task.detached {
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = TranscriptCache.directory(gatewayId: id, root: root)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = TranscriptCache.digest(of: key)
            try Data().write(to: directory.appending(path: digest + ".json"))
            try Data().write(to: directory.appending(path: "unrecognized.json"))
            let inventory = TranscriptCache.cachedDigests(gatewayId: id, root: root, beforeEnumeration: { probe.record() })
            return inventory == [digest]
        }.value
        check(valid, "actual cache inventory recognizes only valid manifest digest names")
        let counts = probe.snapshot()
        check(counts.main == 0 && counts.offMain == 1, "per-owner scalar probe observes actual off-main directory enumeration")
    } catch { check(false, "scratch cache inventory setup succeeds") }
}

@MainActor
func runDemoCacheInventoryPreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appending(path: "demo-inventory-\(UUID())")
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.appIsActive = false
    gateway.start()
    defer { gateway.stop(); Task.detached { try? FileManager.default.removeItem(at: root) } }
    let connected = await waitFor("inventory complete Demo bootstrap", timeout: 30) { gateway.bootstrapProbeIsTerminal }
    check(connected, "genuine Demo bootstrap tasks finish before scratch inventory setup")
    guard connected else { return }
    await gateway.bootstrapMainTask?.value
    await gateway.bootstrapLastBackgroundTask?.value
    guard let listed = await gateway.completeSessionKeys(), let listedKey = listed.sorted().first else {
        check(false, "genuine Demo supplies complete authoritative session keys"); return
    }
    let currentKey = "agent:main:inventory-current", queuedKey = "agent:main:inventory-outbox"
    let orphanKey = "agent:main:inventory-orphan"
    _ = gateway.chat(for: currentKey)
    gateway.outbox.enqueue(OutboxEntry(id: "inventory-send", sessionKey: queuedKey, text: "retained intent",
                                     createdAt: Date(), state: .failed(.init(message: "fixture held", retryable: true))))
    let id = gateway.id
    do {
        try await Task.detached {
            let directory = TranscriptCache.directory(gatewayId: id, root: root)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = try JSONEncoder().encode(TranscriptCache.Snapshot(items: [], complete: true))
            for key in [listedKey, currentKey, queuedKey, orphanKey] {
                try payload.write(to: TranscriptCache.file(gatewayId: id, sessionKey: key, root: root)!, options: .atomic)
            }
        }.value
    } catch { check(false, "scratch recognized cache manifest setup succeeds"); return }
    gateway.cacheRoot = root
    let probe = CacheInventoryProbe(); gateway.cacheInventoryProbe = probe
    await gateway.reconcileOrphanedTranscripts(epoch: gateway.connectionEpoch)
    let counts = probe.snapshot()
    check(counts.main == 0 && counts.offMain > 0, "actual complete-list reconciliation inventories cache files off Main")
    check(counts.main + counts.offMain > 0, "bounded per-store probe observes actual directory enumeration")
    let preserved = await Task.detached {
        Set(TranscriptCache.cachedDigests(gatewayId: id, root: root))
            == Set([listedKey, currentKey, queuedKey].map(TranscriptCache.digest(of:)))
    }.value
    check(preserved, "actual reconciliation deletes orphan and preserves listed, current-chat and outbox manifests")
    check(gateway.chats[currentKey] != nil && gateway.outbox.entries(for: queuedKey).count == 1,
          "reconciliation preserves actual local chat and pending failed-send owners")

    let lateKey = "agent:main:inventory-late-outbox"
    do {
        try await Task.detached {
            let payload = try JSONEncoder().encode(TranscriptCache.Snapshot(items: [], complete: true))
            try payload.write(to: TranscriptCache.file(gatewayId: id, sessionKey: lateKey, root: root)!, options: .atomic)
        }.value
    } catch { check(false, "completed inventory ownership fixture is created"); return }
    let entered = Scripted(false), gate = InventoryCompletionGate()
    gateway.cacheInventoryDidPrepare = {
        await MainActor.run { entered.value = true }
        await gate.hold()
    }
    defer { gateway.cacheInventoryDidPrepare = nil; Task { await gate.release() } }
    let actual = Task { await gateway.reconcileOrphanedTranscripts(epoch: gateway.connectionEpoch) }
    await withTaskCancellationHandler {
        let prepared = await waitFor("actual completed inventory", timeout: 30) { entered.value }
        check(prepared, "actual inventory worker reaches completed-result gate")
        if prepared {
            gateway.outbox.enqueue(OutboxEntry(id: "late-inventory-send", sessionKey: lateKey, text: "retained intent",
                createdAt: Date(), state: .failed(.init(message: "fixture held", retryable: true))))
        }
        await gate.release()
        await actual.value
        let exists = await Task.detached {
            FileManager.default.fileExists(atPath: TranscriptCache.file(gatewayId: id, sessionKey: lateKey, root: root)!.path)
        }.value
        check(prepared && exists, "new outbox owner admitted after inventory completion keeps its manifest")
    } onCancel: { actual.cancel(); Task { await gate.release() } }
}

private actor InventoryCompletionGate {
    private var open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async { if !self.open { await withCheckedContinuation { self.held = $0 } } }
    func release() { self.open = true; self.held?.resume(); self.held = nil }
}
#endif
