import Foundation
import Testing
@testable import PincerKit

/// #471: a second `load()` waits for the fetch already in flight instead of returning early.
@MainActor
@Suite("ChatStore load concurrency")
struct ChatStoreLoadConcurrencyTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    static let key = "agent:main:dashboard:garden"

    func connected() async -> GatewayStore {
        let gateway = GatewayStore(profile: .demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        gateway.start()
        for _ in 0..<1500 where !(gateway.state == .connected && !gateway.sessions.isEmpty) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return gateway
    }

    func finish(_ gateway: GatewayStore) {
        gateway.stop()
        self.scratch.remove()
        self.temp.remove()
    }

    @Test func concurrentLoadsShareOneHistoryFetch() async {
        let gateway = await self.connected()
        #expect(gateway.state == .connected)
        let chat = gateway.chat(for: Self.key)
        #expect(chat.loadCount == 0 && chat.items.isEmpty)
        async let first: Void = chat.load()
        async let second: Void = chat.load()
        _ = await (first, second)
        #expect(chat.hasLoaded && !chat.items.isEmpty)
        #expect(chat.loadCount == 1, "chat.history was requested once")
        #expect(!chat.loadInFlight)
        self.finish(gateway)
    }

    @Test func aLoadStartedMidFetchReturnsOnlyOnceHistoryArrived() async {
        let gateway = await self.connected()
        let chat = gateway.chat(for: Self.key)
        let first = Task { await chat.load() }
        for _ in 0..<2000 where !chat.loadInFlight && chat.loadCount == 0 { await Task.yield() }
        await chat.load()
        #expect(chat.hasLoaded && !chat.items.isEmpty, "a waiting caller sees the history")
        await first.value
        #expect(chat.loadCount == 1)
        self.finish(gateway)
    }

    @Test func aWaiterLoadsItselfWhenTheStarterIsCancelled() async {
        let gateway = await self.connected()
        let chat = gateway.chat(for: Self.key)
        let starter = Task { await chat.load() }
        for _ in 0..<2000 where !chat.loadInFlight && chat.loadCount == 0 { await Task.yield() }
        let waiter = Task { await chat.load() }
        for _ in 0..<20 { await Task.yield() }
        starter.cancel()
        await waiter.value
        #expect(chat.hasLoaded && !chat.items.isEmpty, "the waiter isn't left with empty items")
        await starter.value
        self.finish(gateway)
    }

    @Test func forcedLoadStillFetches() async {
        let gateway = await self.connected()
        let chat = gateway.chat(for: Self.key)
        await chat.load()
        #expect(chat.loadCount == 1)
        await chat.load()
        #expect(chat.loadCount == 1, "a loaded, fresh chat doesn't refetch")
        await chat.load(force: true)
        #expect(chat.loadCount == 2)
        self.finish(gateway)
    }
}
