import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Filled cache adoption save recovery")
struct FilledCacheAdoptionRecoveryTests {
    @Test func concurrentTrimDoesNotLoseTheCancelledDirtySave() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "agent:main:adoption", agentId: "main", gateway: gateway)
        defer { chat.saveTask?.cancel() }
        chat.items = [ChatItem(id: "fresh", role: .user, blocks: [.text("Unsaved message")], timestamp: .now)]
        chat.hasLoaded = true
        chat.scheduleSave()
        let original = try #require(chat.saveTask)

        await chat.adoptFilledCache(afterOlderRead: { chat.olderInCache = true })

        #expect(original.isCancelled, "adoption holds the queued write while reading the fill")
        #expect(chat.saveTask?.isCancelled == false,
                "a concurrent trim causing early return still reschedules the dirty snapshot")
    }

    @Test func dehydrateDuringAdoptionDoesNotRestartPersistence() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "agent:main:adoption", agentId: "main", gateway: gateway)
        defer { chat.saveTask?.cancel() }
        chat.items = [ChatItem(id: "fresh", role: .user, blocks: [.text("Unsaved message")], timestamp: .now)]
        chat.hasLoaded = true
        chat.scheduleSave()
        let original = try #require(chat.saveTask)
        await chat.adoptFilledCache(afterOlderRead: { chat.isDehydrated = true })
        #expect(original.isCancelled, "dehydration cancels the queued cache write")
        #expect(chat.saveTask == nil, "a store that stopped retaining content must not schedule a replacement write")
    }
}
