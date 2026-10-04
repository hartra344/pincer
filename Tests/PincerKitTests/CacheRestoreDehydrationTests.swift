#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private actor RestoreDehydrationGate {
    var entered = false, open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { if open { $0.resume() } else { held = $0 } } }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor @Suite(.timeLimit(.minutes(2)))
struct CacheRestoreDehydrationTests {
    @Test func oldCacheCompletionCannotRehydrateButFreshRestoreCan() async throws {
        let scratch = ScratchDefaults(), temp = TempDir(), gate = RestoreDehydrationGate()
        let root = temp.url
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = root; gateway.outboxRoot = nil
        let key = "agent:main:dehydrate", chat = gateway.chat(for: "agent:main:dehydrate")
        defer { chat.stopCaching(); gateway.stop(); scratch.remove() }
        var actual: Task<Void, Never>?
        do {
            var old = ChatItem(id: "old", role: .assistant, blocks: [.text("Old cached reply")], timestamp: Date(timeIntervalSince1970: 1)); old.transcriptId = old.id
            var fresh = ChatItem(id: "fresh", role: .assistant, blocks: [.text("Current reply")], timestamp: Date(timeIntervalSince1970: 2)); fresh.transcriptId = fresh.id
            let file = try #require(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: root))
            let writer = TranscriptCache.Writer(writeOptions: .atomic)
            let seed = await writer.write(.init(items: [old], complete: true), to: file)
            await writer.drain(); try #require(seed.modified != nil || seed.unchanged)
            chat.exportCacheCompletionGate = { await gate.hold() }
            actual = Task { await chat.restoreFromCache() }
            while !(await gate.entered) { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            let updated = await writer.write(.init(items: [fresh], complete: true), to: file)
            await writer.drain(); try #require(updated.modified != nil || updated.unchanged)
            chat.items = [fresh]; chat.hasLoaded = true
            chat.savedState = chat.currentCacheState // Exact already-persisted current state; no protected-write fixture dependency.
            try #require(chat.isHydrated && !gateway.isChatPinned(key))
            await chat.dehydrate()
            try #require(chat.isDehydrated && !chat.hasLoaded && chat.items.isEmpty)
            let outcome = chat.cacheOutcome
            await gate.release(); await actual?.value
            #expect(chat.items.isEmpty && chat.isDehydrated && !chat.hasLoaded && !chat.hasOlderItems)
            #expect(chat.cacheOutcome == outcome && !chat.hasPagedOlder && chat.olderOffset == nil)
            chat.exportCacheCompletionGate = nil
            await chat.restoreFromCache()
            #expect(chat.items == [fresh] && chat.cacheOutcome == .loaded && chat.exportCacheComplete)
        } catch {
            await gate.release(); await actual?.value
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
#endif
