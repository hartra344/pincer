import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Chat windows")
struct ChatWindowTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)
    let a = "agent:main:dashboard:a"
    let b = "agent:main:dashboard:b"

    func gateway() -> GatewayStore {
        let gateway = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        return gateway
    }

    func hydrate(_ chat: ChatStore) {
        chat.hasLoaded = true
        chat.items = [ChatItem(id: "m0", role: .user, blocks: [.text("hi")], timestamp: Date(timeIntervalSince1970: 1))]
    }

    func cleanup(_ gateway: GatewayStore) async {
        for key in gateway.chats.keys {
            gateway.chats[key]?.stopCaching()
            await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
        }
        self.scratch.remove()
        self.temp.remove()
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<1500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func refRoundTripsAndHashes() throws {
        let ref = ChatWindowRef(gatewayId: UUID(), sessionKey: self.a)
        let decoded = try JSONDecoder().decode(ChatWindowRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded == ref)
        #expect(Set([ref, decoded, ChatWindowRef(gatewayId: ref.gatewayId, sessionKey: self.b)]).count == 2)
    }

    @Test func openWindowPinsAndWarmsTheChat() async {
        let gateway = self.gateway()
        #expect(gateway.openWindowKeys.isEmpty && !gateway.isChatPinned(self.a))
        gateway.chatWindowOpened(self.a)
        #expect(gateway.openWindowKeys == [self.a])
        #expect(gateway.isChatPinned(self.a))
        #expect(gateway.warmKeys(includingLive: false).contains(self.a))
        #expect(gateway.warmKeys(includingLive: true).contains(self.a))
        await self.cleanup(gateway)
    }

    @Test func doubleOpenNeedsDoubleClose() async {
        let gateway = self.gateway()
        gateway.chatWindowOpened(self.a)
        gateway.chatWindowOpened(self.a)
        gateway.chatWindowClosed(self.a)
        #expect(gateway.openWindowKeys.contains(self.a) && gateway.isChatPinned(self.a))
        gateway.chatWindowClosed(self.a)
        #expect(gateway.openWindowKeys.isEmpty && !gateway.isChatPinned(self.a))
        await self.cleanup(gateway)
    }

    @Test func closeWithoutOpenIsHarmless() async {
        let gateway = self.gateway()
        gateway.chatWindowClosed(self.a)
        #expect(gateway.openWindowKeys.isEmpty && !gateway.isChatPinned(self.a))
        await self.cleanup(gateway)
    }

    @Test func windowChatSurvivesBudgetWhileOthersAreDehydrated() async {
        let gateway = self.gateway()
        gateway.residency.limit = 0
        let windowed = gateway.chat(for: self.a)
        let idle = gateway.chat(for: self.b)
        self.hydrate(windowed)
        self.hydrate(idle)
        gateway.chatWindowOpened(self.a)
        self.hydrate(windowed)
        gateway.enforceChatBudget()
        await self.settle { idle.isDehydrated }
        #expect(idle.isDehydrated)
        #expect(!windowed.isDehydrated && windowed.hasLoaded)
        await self.cleanup(gateway)
    }

    @Test func closingReleasesTheChatToTheBudget() async {
        let gateway = self.gateway()
        gateway.residency.limit = 0
        let windowed = gateway.chat(for: self.a)
        gateway.chatWindowOpened(self.a)
        self.hydrate(windowed)
        gateway.chatWindowClosed(self.a)
        self.hydrate(windowed)
        gateway.enforceChatBudget()
        await self.settle { windowed.isDehydrated }
        #expect(windowed.isDehydrated)
        await self.cleanup(gateway)
    }

    @Test func notifierWindowVisibleHoldsTargets() {
        let notifier = Notifier()
        let target = Notifier.Target(gatewayId: UUID(), sessionKey: self.a)
        #expect(notifier.windowVisible.isEmpty)
        notifier.windowVisible.insert(target)
        #expect(notifier.windowVisible.contains(target))
    }

    @Test func appModelCountsWindowsPerRef() async {
        let app = AppModel(defaults: self.scratch.defaults)
        let store = app.add(self.profile, secret: nil)
        let ref = ChatWindowRef(gatewayId: store.id, sessionKey: self.a)
        let target = Notifier.Target(gatewayId: store.id, sessionKey: self.a)
        app.chatWindowOpened(ref)
        app.chatWindowOpened(ref)
        #expect(app.notifier.windowVisible.contains(target) && store.openWindowKeys == [self.a])
        app.chatWindowClosed(ref)
        #expect(app.notifier.windowVisible.contains(target) && store.openWindowKeys == [self.a])
        app.chatWindowClosed(ref)
        #expect(!app.notifier.windowVisible.contains(target) && store.openWindowKeys.isEmpty)
        app.remove(store.id)
        await self.cleanup(store)
    }
}
