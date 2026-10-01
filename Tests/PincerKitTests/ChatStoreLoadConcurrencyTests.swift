import Foundation
import Testing
@testable import PincerKit

/// #471: a second `load()` waits for the fetch already in flight instead of returning early.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { self.lock.withLock { self.flag } }
    func set() { self.lock.withLock { self.flag = true } }
}

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

    /// Waits until the gated `chat.history` has been requested.
    func awaitHistoryRequest(_ gateway: GatewayStore, after baseline: Int) async {
        for _ in 0..<2000 where await gateway.connection.demoHistoryRequestCount(for: Self.key) <= baseline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func concurrentLoadsShareOneHistoryFetch() async {
        let gateway = await self.connected()
        await gateway.connection.holdDemoHistory(true)
        let baseline = await gateway.connection.demoHistoryRequestCount(for: Self.key)
        let chat = gateway.chat(for: Self.key)
        #expect(chat.loadCount == 0 && chat.items.isEmpty)
        let first = Task { await chat.load() }
        await self.awaitHistoryRequest(gateway, after: baseline)
        let second = Task { await chat.load() }
        for _ in 0..<20 { await Task.yield() }
        #expect(chat.loadInFlight && !chat.hasLoaded, "both callers are parked on the gated fetch")
        await gateway.connection.holdDemoHistory(false)
        await first.value
        await second.value
        #expect(chat.hasLoaded && !chat.items.isEmpty)
        #expect(chat.loadCount == 1, "chat.history was requested once")
        #expect(await gateway.connection.demoHistoryRequestCount(for: Self.key) == baseline + 1)
        #expect(!chat.loadInFlight)
        self.finish(gateway)
    }

    @Test func aWaiterLoadsItselfWhenTheStarterIsCancelled() async {
        let gateway = await self.connected()
        await gateway.connection.holdDemoHistory(true)
        let baseline = await gateway.connection.demoHistoryRequestCount(for: Self.key)
        let chat = gateway.chat(for: Self.key)
        let starter = Task { await chat.load() }
        await self.awaitHistoryRequest(gateway, after: baseline)
        let waiter = Task { await chat.load() }
        for _ in 0..<20 { await Task.yield() }
        starter.cancel()
        await gateway.connection.holdDemoHistory(false)
        await waiter.value
        #expect(chat.hasLoaded && !chat.items.isEmpty, "the waiter isn't left with empty items")
        await starter.value
        self.finish(gateway)
    }

    @Test func aCancelledWaiterReturnsWhileTheSharedLoadKeepsRunning() async {
        let gateway = await self.connected()
        await gateway.connection.holdDemoHistory(true)
        let baseline = await gateway.connection.demoHistoryRequestCount(for: Self.key)
        let chat = gateway.chat(for: Self.key)
        let starter = Task { await chat.load() }
        await self.awaitHistoryRequest(gateway, after: baseline)
        let returned = Flag()
        let waiter = Task { await chat.load(); returned.set() }
        let other = Task { await chat.load() }
        for _ in 0..<20 { await Task.yield() }
        waiter.cancel()
        // The history is still gated, so the waiter only returns if it stops waiting when cancelled.
        for _ in 0..<200 where !returned.value { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(returned.value, "the cancelled waiter returned before the load finished")
        #expect(chat.loadInFlight && !chat.hasLoaded, "the shared load wasn't cancelled")
        await gateway.connection.holdDemoHistory(false)
        await starter.value
        await other.value
        #expect(chat.hasLoaded && !chat.items.isEmpty)
        #expect(chat.loadCount == 1)
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
