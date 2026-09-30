import Foundation
import Synchronization
import Testing
@testable import PincerKit

/// #336: transcript caches of chats the Gateway no longer lists are forgotten on connect,
/// including ones that vanished while the app wasn't running.
@MainActor
@Suite("Orphan cache reconcile")
struct OrphanCacheReconcileTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()

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
        !((try? await gateway.messageIndex.search(word)) ?? []).isEmpty
    }

    func settle(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func orphanCachedBeforeConnectIsRemovedAndListedKeysKept() async {
        let gateway = self.demoGateway()
        let orphan = "agent:main:dashboard:gone-while-closed"
        let listed = "agent:main:dashboard:tax-2025"
        let unsent = "agent:main:dashboard:not-created-yet"
        await self.cache(gateway, orphan, "zorblax pancake")
        await self.cache(gateway, listed, "quillon waffle")
        await self.cache(gateway, unsent, "brindle muffin")
        await self.settle { await self.found(gateway, "zorblax") }
        gateway.outbox.enqueue(OutboxEntry(sessionKey: unsent, text: "brindle", createdAt: Date(),
                                           state: .failed(OutboxFailure(message: "held", retryable: false))))
        gateway.start()
        await self.settle { gateway.state.isConnected && !gateway.sessions.isEmpty }
        await self.settle { !self.cached(gateway, orphan) }
        #expect(!self.cached(gateway, orphan))
        #expect(await !self.found(gateway, "zorblax"))
        #expect(self.cached(gateway, listed), "the demo lists this chat")
        #expect(self.cached(gateway, unsent), "outbox entries keep their chat")
        gateway.stop()
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }

    @Test func digestOnlyOrphanIsRemovedToo() async {
        let gateway = self.demoGateway()
        let orphan = "agent:main:dashboard:no-index-rows"
        await self.cache(gateway, orphan, "snorvel crumpet")
        await self.settle { await self.found(gateway, "snorvel") }
        await gateway.messageIndex.remove(sessionKey: orphan)
        #expect(await !self.found(gateway, "snorvel"))
        #expect(self.cached(gateway, orphan), "only the cache file is left")
        gateway.start()
        await self.settle { gateway.state.isConnected && !gateway.sessions.isEmpty }
        await self.settle { !self.cached(gateway, orphan) }
        #expect(!self.cached(gateway, orphan))
        gateway.stop()
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }

    @Test func digestOnlyFileOfAnOutboxChatIsKept() async {
        let gateway = self.demoGateway()
        let unsent = "agent:main:dashboard:queued-digest-only"
        await self.cache(gateway, unsent, "wimble scone")
        await self.settle { await self.found(gateway, "wimble") }
        await gateway.messageIndex.remove(sessionKey: unsent)
        gateway.outbox.enqueue(OutboxEntry(sessionKey: unsent, text: "x", createdAt: Date(),
                                           state: .failed(OutboxFailure(message: "held", retryable: false))))
        gateway.start()
        await self.settle { gateway.state.isConnected && !gateway.sessions.isEmpty }
        try? await Task.sleep(for: .seconds(1))
        #expect(self.cached(gateway, unsent))
        gateway.stop()
        await TranscriptCache.shutdown(root: self.temp.url)
        self.temp.remove()
        self.scratch.remove()
    }
}

/// The paging behind the reconcile: a partial list must never count as complete.
@Suite("Complete session list")
struct CompleteSessionKeysTests {
    struct Failure: Error {}

    func page(_ keys: [String], hasMore: Bool? = nil, next: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["sessions": .array(keys.map { .object(["key": .string($0)]) })]
        if let hasMore { object["hasMore"] = .bool(hasMore) }
        if let next { object["nextOffset"] = JSONValue(next) }
        return .object(object)
    }

    /// Serves `pages` in order, recording each request's params.
    func run(_ pages: [JSONValue], maxPages: Int = 40, limit: Int = 300) async -> (keys: Set<String>?, params: [JSONValue]) {
        let served = Mutex(0)
        let seen = Mutex<[JSONValue]>([])
        let keys = await GatewayStore.completeSessionKeys(maxPages: maxPages, limit: limit) { params in
            seen.withLock { $0.append(params) }
            let index = served.withLock { value in defer { value += 1 }; return value }
            guard index < pages.count else { throw Failure() }
            return pages[index]
        }
        return (keys, seen.withLock { $0 })
    }

    @Test func twoPagesUnionViaNextOffset() async {
        let result = await self.run([self.page(["a", "b"], hasMore: true, next: 2), self.page(["c"], hasMore: false)])
        #expect(result.keys == ["a", "b", "c"])
        #expect(result.params.count == 2)
        #expect(result.params[0]["offset"] == nil && result.params[0]["archived"]?.string == "all")
        #expect(result.params[1]["offset"]?.int == 2)
    }

    @Test func hasMoreOnTheLastAllowedPageIsPartial() async {
        let pages = [self.page(["a"], hasMore: true, next: 1), self.page(["b"], hasMore: true, next: 2)]
        #expect(await self.run(pages, maxPages: 2).keys == nil)
        #expect(await self.run(pages + [self.page(["c"], hasMore: false)], maxPages: 3).keys == ["a", "b", "c"])
    }

    @Test func withoutHasMoreAFullPageIsPartialAndAShortOneComplete() async {
        #expect(await self.run([self.page(["a", "b"])], limit: 2).keys == nil)
        #expect(await self.run([self.page(["a"])], limit: 2).keys == ["a"])
    }

    @Test func aFailedRequestIsPartial() async {
        #expect(await self.run([]).keys == nil)
        #expect(await self.run([self.page(["a"], hasMore: true, next: 1)]).keys == nil)
    }

    @Test func anUnexpectedNextOffsetIsPartial() async {
        #expect(await self.run([self.page(["a"], hasMore: true), self.page(["b"], hasMore: false)]).keys == ["a", "b"])
        #expect(await self.run([self.page([], hasMore: true)]).keys == nil)
        #expect(await self.run([self.page(["a"], hasMore: true, next: 0)]).keys == nil)
        #expect(await self.run([self.page(["a"], hasMore: true, next: 1), self.page(["b"], hasMore: true, next: 1)]).keys == nil)
    }
}
