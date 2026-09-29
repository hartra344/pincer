import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Chat eviction")
struct ChatEvictionTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func gateway() -> GatewayStore {
        GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
    }

    func item(_ id: String, _ text: String = "hi") -> ChatItem {
        ChatItem(id: id, role: .user, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: 1))
    }

    func hydrate(_ chat: ChatStore, _ count: Int = 3) {
        chat.hasLoaded = true
        chat.items = (0..<count).map { self.item("m\($0)") }
    }

    func cleanup(_ gateway: GatewayStore) async {
        for key in gateway.chats.keys {
            gateway.chats[key]?.stopCaching()
            await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key)
        }
        self.scratch.remove()
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<1500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func dehydrateDropsHeavyStateAndKeepsLightState() async {
        let gateway = self.gateway()
        let chat = gateway.chat(for: "agent:main:dashboard:a")
        self.hydrate(chat)
        chat.draft = ComposerDraft(text: "typing")
        chat.fullMessages["m0"] = self.item("m0")
        chat.recoveryAttempted = ["m0"]
        await chat.dehydrate()
        #expect(chat.isDehydrated && !chat.hasLoaded)
        #expect(chat.items.isEmpty && chat.entries.isEmpty)
        #expect(chat.fullMessages.isEmpty && chat.recoveryAttempted.isEmpty)
        #expect(chat.draft.text == "typing")
        #expect(chat.stale)
        await self.cleanup(gateway)
    }

    @Test func dehydratedChatRestoresFromCacheOnLoad() async {
        let gateway = self.gateway()
        let chat = gateway.chat(for: "agent:main:dashboard:a")
        self.hydrate(chat)
        await chat.dehydrate()
        await chat.load()
        #expect(!chat.isDehydrated)
        #expect(chat.items.map(\.id) == ["m0", "m1", "m2"])
        await self.cleanup(gateway)
    }

    @Test func pendingItemsSurviveDehydration() async {
        let gateway = self.gateway()
        let chat = gateway.chat(for: "agent:main:dashboard:a")
        self.hydrate(chat)
        var pending = self.item("p1", "unsent")
        pending.isPending = true
        chat.items.append(pending)
        await chat.dehydrate()
        #expect(chat.items.map(\.id) == ["p1"])
        await chat.load()
        #expect(chat.items.map(\.id) == ["m0", "m1", "m2", "p1"])
        await self.cleanup(gateway)
    }

    @Test func dehydratedChatIgnoresTranscriptMessagesAndMarksStale() async {
        let gateway = self.gateway()
        let chat = gateway.chat(for: "agent:main:dashboard:a")
        self.hydrate(chat)
        await chat.dehydrate()
        chat.stale = false
        chat.handleSessionMessage(["message": ["role": "assistant", "content": "late", "__openclaw": ["id": "x1"]]])
        #expect(chat.items.isEmpty)
        #expect(chat.stale)
        await self.cleanup(gateway)
    }

    @Test func pinnedChatsAreNotDehydrated() async {
        let gateway = self.gateway()
        gateway.residency.limit = 0
        let selected = gateway.chat(for: "agent:main:dashboard:a")
        let idle = gateway.chat(for: "agent:main:dashboard:b")
        let unsent = gateway.chat(for: "agent:main:dashboard:c")
        for chat in [selected, idle, unsent] { self.hydrate(chat) }
        gateway.selectedKey = selected.sessionKey
        selected.isSending = true
        #expect(gateway.pinnedChatKeys().contains(selected.sessionKey))
        gateway.enforceChatBudget()
        await self.settle { idle.isDehydrated && unsent.isDehydrated }
        #expect(!selected.isDehydrated && selected.hasLoaded)
        #expect(idle.isDehydrated && unsent.isDehydrated)
        await self.cleanup(gateway)
    }

    @Test func leastRecentlyUsedChatsGoFirst() async {
        let gateway = self.gateway()
        gateway.residency.limit = 2
        let chats = ["a", "b", "c", "d"].map { gateway.chat(for: "agent:main:dashboard:\($0)") }
        for chat in chats { self.hydrate(chat) }
        _ = gateway.chat(for: "agent:main:dashboard:a")
        gateway.enforceChatBudget()
        await self.settle { chats[1].isDehydrated && chats[2].isDehydrated }
        #expect(chats.map(\.isDehydrated) == [false, true, true, false])
        await self.cleanup(gateway)
    }

    @Test func criticalMemoryPressureKeepsOnlyPinnedChats() async {
        let gateway = self.gateway()
        let a = gateway.chat(for: "agent:main:dashboard:a")
        let b = gateway.chat(for: "agent:main:dashboard:b")
        self.hydrate(a)
        self.hydrate(b)
        gateway.selectedKey = a.sessionKey
        gateway.handleMemoryPressure(critical: true)
        await self.settle { b.isDehydrated }
        #expect(b.isDehydrated && !a.isDehydrated)
        await self.cleanup(gateway)
    }

    @Test func recoveryStateIsPrunedToLatestPage() {
        let gateway = self.gateway()
        let chat = gateway.chat(for: "agent:main:dashboard:a")
        chat.fullMessages = ["old": self.item("old"), "new": self.item("new")]
        chat.recoveryAttempted = ["old", "new"]
        var latest = self.item("new")
        latest.transcriptId = "new"
        chat.pruneRecoveryState(keeping: [latest])
        #expect(Set(chat.fullMessages.keys) == ["new"])
        #expect(chat.recoveryAttempted == ["new"])
        self.scratch.remove()
    }
}
