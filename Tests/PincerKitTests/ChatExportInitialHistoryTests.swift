import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ChatExportInitialHistoryTests {
    @Test func missingInitialHistoryCannotExportAnEmptySuccess() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil
        let chat = gateway.chat(for: "agent:main:missing")
        defer { chat.stopCaching(); gateway.stop(); scratch.remove() }
        let result = await chat.exportItems()
        #expect(!chat.hasLoaded && chat.items.isEmpty)
        #expect(result == nil)
    }

    @Test func successfullyLoadedEmptyAndOrdinaryChatsRemainExportable() async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil
        let chat = gateway.chat(for: "agent:main:loaded")
        defer { chat.stopCaching(); gateway.stop(); scratch.remove() }
        chat.hasLoaded = true
        let empty = await chat.exportItems()
        #expect(empty == [])
        var item = ChatItem(id: "one", role: .assistant, blocks: [.text("Preserve this reply")])
        item.transcriptId = item.id
        chat.items = [item]
        let ordinary = await chat.exportItems()
        #expect(ordinary == [item])
    }

    @Test(arguments: [false, true])
    func offlineCacheMustProveCompleteCoverage(complete: Bool) async throws {
        let scratch = ScratchDefaults(), temp = TempDir()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = temp.url; gateway.outboxRoot = nil
        let key = "agent:main:cached"
        let chat = gateway.chat(for: key)
        defer { chat.stopCaching(); gateway.stop(); temp.remove(); scratch.remove() }
        var item = ChatItem(id: "cached", role: .assistant, blocks: [.text("Actual cached reply")])
        item.transcriptId = item.id
        let file = try #require(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: temp.url))
        // An isolated writer seeds real cache format without requiring protected-write capability.
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        let stats = await writer.write(.init(items: [item], complete: complete), to: file)
        await writer.drain()
        try #require(stats.modified != nil || stats.unchanged)
        let result = await chat.exportItems()
        try #require(chat.items == [item])
        if complete { #expect(result == [item]) }
        else { #expect(result == nil) }
    }
}
