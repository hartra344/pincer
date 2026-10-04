import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ChatExportEmptyCacheTests {
    @Test(arguments: [false, true])
    func emptyCacheRequiresActualCompleteMetadata(complete: Bool) async throws {
        let scratch = ScratchDefaults(), temp = TempDir()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = temp.url; gateway.outboxRoot = nil
        let key = "agent:main:empty-cache", chat = gateway.chat(for: "agent:main:empty-cache")
        defer { chat.stopCaching(); gateway.stop(); temp.remove(); scratch.remove() }
        let file = try #require(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: temp.url))
        let writer = TranscriptCache.Writer(writeOptions: .atomic)
        let stats = await writer.write(.init(items: [], complete: complete), to: file)
        await writer.drain()
        try #require(stats.modified != nil || stats.unchanged)
        let result = await chat.exportItems()
        try #require(chat.cacheOutcome == .loaded)
        #expect(!chat.hasLoaded && chat.items.isEmpty)
        if complete { #expect(result == []) }
        else { #expect(result == nil) }
        // A real history reset removes both the cache and its coverage authority.
        await chat.reloadAfterHistoryChange(clearingCache: { await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: temp.url) })
        let afterReset = await chat.exportItems()
        #expect(afterReset == nil)
    }
}
