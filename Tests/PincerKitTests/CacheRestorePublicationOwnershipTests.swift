import Foundation
import Testing
@testable import PincerKit

#if DEBUG
private actor CacheRestoreDeliveryGate {
    var entered = false, open = false
    private var entry: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { if open { $0.resume() } else { held = $0 } }
    }
    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { if entered || Task.isCancelled { $0.resume() } else { entry = $0 } }
        } onCancel: { Task { await self.release() } }
        try Task.checkCancellation()
    }
    func release() { open = true; entry?.resume(); entry = nil; held?.resume(); held = nil }
}
@MainActor @Suite(.timeLimit(.minutes(2)))
struct CacheRestorePublicationOwnershipTests {
    private struct State: Equatable {
        let items: [ChatItem]
        let older: Bool, more: Bool, paged: Bool, loaded: Bool, unreadable: Bool, forwarded: Bool
        let offset: Int?
        let outcome: TranscriptCache.LoadOutcome?
        @MainActor init(_ chat: ChatStore) {
            items = chat.items; older = chat.olderInCache; more = chat.hasMoreHistory
            paged = chat.hasPagedOlder; loaded = chat.hasLoaded; offset = chat.olderOffset
            unreadable = chat.cacheUnreadable; forwarded = chat.forwardedSenderRefreshPending; outcome = chat.cacheOutcome
        }
    }
    private func item(_ id: String) -> ChatItem {
        var item = ChatItem(id: id, role: .assistant, blocks: [.text("Reply \(id)")], timestamp: Date(timeIntervalSince1970: 1_700_000_000)); item.transcriptId = id; return item
    }
    @Test(arguments: [false, true])
    func completedOldCacheCannotPublishAfterActualHistoryReset(currentOverlap: Bool) async throws {
        let scratch = ScratchDefaults(), temp = TempDir(), gate = CacheRestoreDeliveryGate()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = temp.url; gateway.outboxRoot = nil
        let key = "agent:main:restore", chat = gateway.chat(for: "agent:main:restore")
        defer { chat.stopCaching(); gateway.stop(); scratch.remove() }
        let cleanupURL = temp.url
        do {
        let old = [item("old"), item("shared")]
        let file = try #require(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: temp.url))
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        let stats = await writer.write(.init(items: old, complete: true, forwardedSenderRefreshPending: true), to: file)
        await writer.drain(); try #require(stats.modified != nil || stats.unchanged)
        let disk = try #require(await TranscriptCache.load(gatewayId: gateway.id, sessionKey: key, root: temp.url))
        try #require(disk.items == old && disk.complete && disk.forwardedSenderRefreshPending)
        chat.exportCacheCompletionGate = { await gate.hold() }
        let restore = Task { await chat.restoreFromCache() }
        do { try await gate.wait() } catch { await gate.release(); await restore.value; throw error }
        await chat.reloadAfterHistoryChange(clearingCache: { await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: temp.url) })
        if currentOverlap { chat.items = [item("shared"), item("fresh")]; chat.hasLoaded = true }
        let expected = State(chat)
        #expect(expected.items == (currentOverlap ? [item("shared"), item("fresh")] : []))
        await gate.release(); await restore.value
        #expect(State(chat) == expected)
        } catch {
            await gate.release()
            await Task.detached { try? FileManager.default.removeItem(at: cleanupURL) }.value
            throw error
        }
        await Task.detached { try? FileManager.default.removeItem(at: cleanupURL) }.value
    }
    @Test func ordinaryRestorePreservesPendingInputAndExactCachedRows() async throws {
        let scratch = ScratchDefaults(), temp = TempDir()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = temp.url; gateway.outboxRoot = nil
        let key = "agent:main:ordinary", chat = gateway.chat(for: "agent:main:ordinary")
        defer { chat.stopCaching(); gateway.stop(); scratch.remove() }
        let cleanupURL = temp.url
        do {
        let cached = item("cached"), pending = ChatItem(id: "pending", role: .user, blocks: [.text("Unsent input")], isPending: true)
        let file = try #require(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: temp.url))
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        let stats = await writer.write(.init(items: [cached], complete: true), to: file)
        await writer.drain(); try #require(stats.modified != nil || stats.unchanged)
        chat.items = [pending]
        await chat.restoreFromCache()
        #expect(chat.items == [cached, pending])
        #expect(chat.cacheOutcome == .loaded && !chat.hasOlderItems && chat.hasPagedOlder && chat.olderOffset == 1)
        } catch {
            await Task.detached { try? FileManager.default.removeItem(at: cleanupURL) }.value
            throw error
        }
        await Task.detached { try? FileManager.default.removeItem(at: cleanupURL) }.value
    }
}
#endif
