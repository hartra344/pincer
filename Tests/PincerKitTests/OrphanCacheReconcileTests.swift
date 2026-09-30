import Foundation
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
}
