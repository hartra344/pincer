#if DEBUG
import Foundation
@testable import PincerKit

@MainActor func runCacheRestoreFreshPublicationChecks() async {
    let (defaults, suite) = scratchDefaults()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-restore-fresh-\(UUID())", isDirectory: true)
    let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: defaults)
    gateway.cacheRoot = root; gateway.outboxRoot = nil; gateway.notifier = nil
    let key = "agent:main:fresh", chat = gateway.chat(for: "agent:main:fresh")
    defer { chat.stopCaching(); gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    guard let file = TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: root) else { check(false, "fresh owned cache path exists"); return }
    var row = ChatItem(id: "fresh", role: .assistant, blocks: [.text("Current cached reply")]); row.transcriptId = row.id
    let writer = TranscriptCache.Writer(writeOptions: .atomic)
    let stats = await writer.write(.init(items: [row], complete: true), to: file)
    await writer.drain()
    let seeded = stats.modified != nil || stats.unchanged
    check(seeded, "fresh current cache persisted exact source")
    if seeded {
        let pending = ChatItem(id: "pending", role: .user, blocks: [.text("Unsent input")], isPending: true)
        chat.items = [pending]
        await chat.restoreFromCache()
        check(chat.items == [row, pending], "current ordinary restore retains exact cached and pending rows")
        check(chat.cacheOutcome == .loaded && !chat.hasOlderItems && chat.hasPagedOlder && chat.olderOffset == 1,
              "current ordinary restore publishes valid paging and outcome")
    }
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
#endif
