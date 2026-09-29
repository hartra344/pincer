import Foundation
import Testing
@testable import PincerKit

/// #225: deleting, rewinding, branch-switching or recovering a session removes its cached transcript
/// and its messages from search, whether the change came from this app or from another client.
@MainActor
@Suite("Transcript removal")
struct TranscriptRemovalTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func gateway() -> GatewayStore {
        let gateway = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        return gateway
    }

    func demoGateway() -> GatewayStore {
        let gateway = GatewayStore(profile: GatewayProfile.demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        return gateway
    }

    func cache(_ gateway: GatewayStore, _ key: String, _ text: String) async {
        let item = ChatItem(id: "m-\(key)", role: .user, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: 1))
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [item], complete: true), gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
    }

    func cached(_ gateway: GatewayStore, _ key: String) -> Bool {
        TranscriptCache.file(gatewayId: gateway.id, sessionKey: key, root: self.temp.url).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func found(_ gateway: GatewayStore, _ word: String) async -> Bool {
        let hits = (try? await gateway.messageIndex.search(word)) ?? []
        return !hits.isEmpty
    }

    func removed(_ gateway: GatewayStore, _ key: String, _ word: String) async -> Bool {
        let stillFound = await self.found(gateway, word)
        return !self.cached(gateway, key) && !stillFound
    }

    func settle(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func finish(_ gateway: GatewayStore) async {
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }

    @Test(arguments: [SessionTranscriptChange.deleted, .changed(editorText: nil), .changed(editorText: "cut me")])
    func changeDropsCacheAndSearch(change: SessionTranscriptChange) async {
        let gateway = self.gateway()
        await self.cache(gateway, "agent:main:dashboard:a", "zorblax pancake")
        await self.cache(gateway, "agent:main:dashboard:b", "quillon waffle")
        await self.settle { await self.found(gateway, "zorblax") }
        #expect(await self.found(gateway, "zorblax"))

        await gateway.transcriptChanged(key: "agent:main:dashboard:a", change: change)
        #expect(!self.cached(gateway, "agent:main:dashboard:a"))
        #expect(await !self.found(gateway, "zorblax"))
        #expect(self.cached(gateway, "agent:main:dashboard:b"))
        #expect(await self.found(gateway, "quillon"))
        await self.finish(gateway)
    }

    @Test func rewoundOpenChatLosesItsCachedTranscript() async {
        let gateway = self.gateway()
        let key = "agent:main:dashboard:a"
        let chat = gateway.chat(for: key)
        chat.hasLoaded = true
        chat.items = [ChatItem(id: "m1", role: .user, blocks: [.text("zorblax pancake")], timestamp: Date(timeIntervalSince1970: 1))]
        await chat.saveToCache()
        await self.settle { await self.found(gateway, "zorblax") }
        #expect(self.cached(gateway, key))

        await gateway.transcriptChanged(key: key, change: .changed(editorText: nil))
        #expect(!self.cached(gateway, key))
        #expect(await !self.found(gateway, "zorblax"))
        chat.stopCaching()
        await self.finish(gateway)
    }

    @Test func externalDeleteRemovesCacheAndSearch() async {
        let gateway = self.gateway()
        let key = "agent:main:dashboard:a"
        await self.cache(gateway, key, "zorblax pancake")
        await self.settle { await self.found(gateway, "zorblax") }
        gateway.applySessionChange(["reason": "delete", "key": .string(key)])
        await self.settle { await self.removed(gateway, key, "zorblax") }
        #expect(!self.cached(gateway, key))
        #expect(await !self.found(gateway, "zorblax"))
        await self.finish(gateway)
    }

    @Test func externalRewindRemovesCacheAndSearch() async {
        let gateway = self.gateway()
        let key = "agent:main:dashboard:a"
        await self.cache(gateway, key, "zorblax pancake")
        await self.settle { await self.found(gateway, "zorblax") }
        gateway.applySessionChange(["reason": "rewind", "sessionKey": .string(key)])
        await self.settle { await self.removed(gateway, key, "zorblax") }
        #expect(!self.cached(gateway, key))
        #expect(await !self.found(gateway, "zorblax"))
        await self.finish(gateway)
    }

    @Test func changeInvalidatesInFlightFills() async {
        let gateway = self.gateway()
        let key = "agent:main:dashboard:a"
        let before = gateway.cacheGeneration(of: key)
        await gateway.transcriptChanged(key: key, change: .changed(editorText: nil))
        #expect(gateway.cacheGeneration(of: key) == before + 1)
        await gateway.transcriptChanged(key: key, change: .deleted)
        #expect(gateway.cacheGeneration(of: key) == before + 2)
        #expect(gateway.cacheGeneration(of: "agent:main:dashboard:b") == 0)
        await self.finish(gateway)
    }

    @Test(arguments: [SessionTranscriptChange.deleted, .changed(editorText: nil)])
    func fillInFlightCantReAddRemovedContent(change: SessionTranscriptChange) async {
        let gateway = self.demoGateway()
        gateway.start()
        await self.settle { gateway.state.isConnected && !gateway.sessions.isEmpty }
        let key = "agent:main:dashboard:trip"
        #expect(gateway.state.isConnected)
        await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
        let fill = gateway.startHeadlessFill(sessionKey: key, agentId: "main")
        await gateway.transcriptChanged(key: key, change: change)
        await fill.value
        #expect(!self.cached(gateway, key))
        #expect(await !self.found(gateway, "ramen"))
        gateway.stop()
        await self.finish(gateway)
    }

    @Test func vanishedSessionIsForgottenOnlyWhenTheGatewayNoLongerListsIt() async {
        let gateway = self.demoGateway()
        gateway.start()
        await self.settle { gateway.state.isConnected && !gateway.sessions.isEmpty }
        let gone = "agent:main:dashboard:deleted-offline"
        let archived = "agent:main:dashboard:tax-2025"
        await self.cache(gateway, gone, "zorblax pancake")
        await self.cache(gateway, archived, "quillon waffle")
        await self.settle { await self.found(gateway, "zorblax") }
        gateway.setSession(nil, for: archived)
        let unsent = "agent:main:dashboard:not-created-yet"
        await self.cache(gateway, unsent, "brindle muffin")
        let failure = OutboxFailure(message: "held", retryable: false)
        gateway.outbox.enqueue(OutboxEntry(sessionKey: unsent, text: "brindle", createdAt: Date(), state: .failed(failure)))

        await gateway.forgetVanishedSessions([gone, archived, unsent])
        #expect(!self.cached(gateway, gone))
        #expect(await !self.found(gateway, "zorblax"))
        #expect(self.cached(gateway, archived), "still listed (archived): its cache stays")
        #expect(self.cached(gateway, unsent) && gateway.outbox.entries(for: unsent).count == 1,
                "a chat with outbox sends isn't forgotten")
        gateway.stop()
        await self.finish(gateway)
    }
}
