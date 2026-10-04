#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private final class CacheRestoreCheckGate {
    var entered = false, open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { if open || Task.isCancelled { $0.resume() } else { held = $0 } }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor private func checkCacheRestorePublication(source: [ChatItem]) async {
    let (defaults, suite) = scratchDefaults()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-restore-owner-\(UUID())", isDirectory: true)
    let gateway = GatewayStore(profile: GatewayProfile(name: "Offline cache", url: "ws://127.0.0.1:1", authMode: .none), defaults: defaults)
    gateway.cacheRoot = root; gateway.outboxRoot = nil; gateway.notifier = nil
    let key = "agent:main:restore", chat = gateway.chat(for: "agent:main:restore"), gate = CacheRestoreCheckGate()
    defer { chat.stopCaching(); gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    guard let file = TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: root) else { check(false, "owned cache path exists"); return }
    let writer = TranscriptCache.Writer(writeOptions: .atomic)
    let stats = await writer.write(.init(items: source, complete: true, forwardedSenderRefreshPending: true), to: file)
    await writer.drain()
    let disk = await TranscriptCache.load(gatewayId: gateway.id, sessionKey: key, root: root)
    let seeded = (stats.modified != nil || stats.unchanged) && !source.isEmpty && disk?.items == source && disk?.complete == true
    check(seeded, "real nonempty cache contains exact source messages and complete coverage")
    guard seeded else { await Task.detached { try? FileManager.default.removeItem(at: root) }.value; return }
    chat.exportCacheCompletionGate = { await gate.hold() }
    let restore = Task { await chat.restoreFromCache() }
    defer { gate.release(); restore.cancel() }
    let entered = await waitFor("actual completed cache delivery") { gate.entered }
    check(entered, "actual disk read reaches the pre-publication gate")
    guard entered else { gate.release(); restore.cancel(); await restore.value; await Task.detached { try? FileManager.default.removeItem(at: root) }.value; return }
    await chat.reloadAfterHistoryChange(clearingCache: { await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: root) })
    let rows = chat.items, outcome = chat.cacheOutcome, offset = chat.olderOffset
    let older = chat.olderInCache, more = chat.hasMoreHistory, paged = chat.hasPagedOlder
    let loaded = chat.hasLoaded, forwarded = chat.forwardedSenderRefreshPending, unreadable = chat.cacheUnreadable
    check(rows.isEmpty && !older && !more && !loaded, "actual history reset cleared rows and paging before old completion")
    gate.release(); await restore.value
    check(chat.items == rows, "completed old cache cannot resurrect reset transcript rows")
    check(chat.cacheOutcome == outcome && chat.olderOffset == offset && chat.olderInCache == older && chat.hasMoreHistory == more
          && chat.hasPagedOlder == paged && chat.hasLoaded == loaded && chat.forwardedSenderRefreshPending == forwarded && chat.cacheUnreadable == unreadable,
          "old cache cannot republish outcome, paging or forwarded state after reset")
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
@MainActor func runCacheRestorePublicationOwnershipChecks() async {
    var row = ChatItem(id: "cached", role: .assistant, blocks: [.text("Saved reply")]); row.transcriptId = row.id
    await checkCacheRestorePublication(source: [row])
}
@MainActor func runDemoCacheRestorePublicationOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("cache restore Demo source", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "genuine Demo source connection is ready")
    guard ready else { return }
    let chat = gateway.chat(for: DemoBookmarks.tripSessionKey)
    defer { chat.stopCaching() }
    await chat.load()
    let source = chat.items.filter { !$0.isPending }
    check(chat.hasLoaded && !source.isEmpty, "actual seeded Demo history supplies nonempty cache source")
    guard chat.hasLoaded && !source.isEmpty else { return }
    // Exact genuine history is persisted locally; reset acts on this owned cache, not the server.
    await checkCacheRestorePublication(source: source)
}
#endif
