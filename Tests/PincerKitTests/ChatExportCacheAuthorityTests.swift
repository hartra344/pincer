#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private actor ExportCacheGate {
    var entered = false
    var open = false
    var held: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { if open { $0.resume() } else { held = $0 } } }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor @Suite(.timeLimit(.minutes(2)))
struct ChatExportCacheAuthorityTests {
    @Test(arguments: [false, true])
    func rejectedOrResetCacheCannotAuthorizeExport(reset: Bool) async throws {
        let scratch = ScratchDefaults(), temp = TempDir(), gate = ExportCacheGate()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = temp.url; gateway.outboxRoot = nil
        let key = "agent:main:authority", chat = gateway.chat(for: "agent:main:authority")
        defer { chat.stopCaching(); gateway.stop(); temp.remove(); scratch.remove() }
        var cached = ChatItem(id: "cached", role: .assistant, blocks: [.text("Cached reply")]); cached.transcriptId = cached.id
        let file = try #require(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: temp.url))
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        let stats = await writer.write(.init(items: [cached], complete: true), to: file)
        await writer.drain(); try #require(stats.modified != nil || stats.unchanged)
        if !reset {
            var unrelated = ChatItem(id: "unrelated", role: .assistant, blocks: [.text("Unrelated loaded slice")]); unrelated.transcriptId = unrelated.id
            chat.items = [unrelated]
            await chat.restoreFromCache()
            try #require(chat.items == [unrelated])
        } else {
            chat.exportCacheCompletionGate = { await gate.hold() }
            let old = Task { await chat.restoreFromCache() }
            await withTaskCancellationHandler {
                while !(await gate.entered) && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            } onCancel: { Task { await gate.release() } }
            if Task.isCancelled { await gate.release(); await old.value; throw CancellationError() }
            await chat.reloadAfterHistoryChange(clearingCache: { await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: temp.url) })
            await gate.release(); await old.value
            chat.exportCacheCompletionGate = nil
        }
        #expect(!chat.exportCacheComplete)
        let result = await chat.exportItems()
        #expect(result == nil)
    }
}
#endif
