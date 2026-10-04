import Foundation
@testable import PincerKit

@MainActor func runChatExportEmptyCacheChecks() async {
    for complete in [false, true] {
        let (defaults, suite) = scratchDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-empty-cache-\(UUID().uuidString)")
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: defaults)
        gateway.cacheRoot = root; gateway.outboxRoot = nil; gateway.notifier = nil
        let key = "agent:main:empty-cache", chat = gateway.chat(for: "agent:main:empty-cache")
        defer { chat.stopCaching(); gateway.stop(); defaults.removePersistentDomain(forName: suite) }
        guard let file = TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: root) else { check(false, "owned cache path exists"); return }
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        let stats = await writer.write(.init(items: [], complete: complete), to: file)
        await writer.drain()
        check(stats.modified != nil || stats.unchanged, "actual empty cache was persisted")
        guard stats.modified != nil || stats.unchanged else {
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            return
        }
        let result = await chat.exportItems()
        check(chat.cacheOutcome == .loaded && !chat.hasLoaded && chat.items.isEmpty, "actual empty cache metadata loaded without network history")
        check(complete ? result == [] : result == nil, "only complete empty cache proves export coverage")
        await chat.reloadAfterHistoryChange(clearingCache: { await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: root) })
        let cleared = await chat.exportItems()
        check(cleared == nil, "history reset cannot reuse cleared cache coverage")
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
