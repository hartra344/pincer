import Foundation
import Observation
import Testing
@testable import PincerKit

@MainActor
@Suite("Chat eviction")
struct ChatEvictionTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func gateway() -> GatewayStore {
        let gateway = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        return gateway
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
            await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
        }
        self.scratch.remove()
        self.temp.remove()
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
        self.temp.remove()
    }

    @Test func warmChatsAreNeverVictims() async {
        let gateway = self.gateway()
        let keys = ["a", "b", "c", "d", "e", "f"].map { "agent:main:dashboard:\($0)" }
        let chats = keys.map { gateway.chat(for: $0) }
        for chat in chats { self.hydrate(chat) }
        for key in keys { gateway.selectedKey = key }
        gateway.residency.limit = 0
        let warm = gateway.warmKeys(includingLive: true)
        #expect(warm == Set(keys.suffix(GatewayStore.warmChatLimit)))
        #expect(warm.isSubset(of: gateway.pinnedChatKeys()))
        let victims = gateway.residency.victims(hydrated: Set(keys), pinned: gateway.pinnedChatKeys())
        #expect(Set(victims) == Set(keys.prefix(2)))
        gateway.enforceChatBudget()
        await self.settle { chats[0].isDehydrated && chats[1].isDehydrated }
        #expect(chats.map(\.isDehydrated) == [true, true, false, false, false, false])
        await self.cleanup(gateway)
    }

    @Test func defaultResidencyLimitCoversWarmChats() {
        let gateway = self.gateway()
        #expect(gateway.residency.limit >= GatewayStore.warmChatLimit)
        self.scratch.remove()
        self.temp.remove()
    }

    @Test func reopeningADehydratedChatReloadsOnceWithoutFlash() async {
        let gateway = GatewayStore(profile: .demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        gateway.start()
        await self.settle { gateway.state == .connected && !gateway.sessions.isEmpty }
        #expect(gateway.state == .connected)
        let target = gateway.chat(for: "agent:main:dashboard:garden")
        gateway.selectedKey = target.sessionKey
        await self.settle { target.hasLoaded }
        #expect(target.hasLoaded && !target.items.isEmpty)
        let full = target.items.map(\.id)
        // Five other selections push it out of the warm set.
        for key in ["agent:main:main", "agent:main:dashboard:tax-2025", "agent:research:dashboard:gpu-bench",
                    "agent:coder:dashboard:refactor", "agent:coder:dashboard:ci-fix"]
        {
            gateway.selectedKey = key
            await self.settle { gateway.chat(for: key).hasLoaded }
        }
        #expect(!gateway.warmKeys(includingLive: true).contains(target.sessionKey))
        await target.dehydrate()
        #expect(target.isDehydrated && target.items.isEmpty)

        let counts = CountLog(target)
        counts.watch()
        let loadsBefore = target.loadCount
        gateway.selectedKey = target.sessionKey
        await self.settle { target.hasLoaded && target.loadCount > loadsBefore }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(target.items.map(\.id) == full)
        #expect(!counts.values.isEmpty && !counts.values.contains(0), "cached restore never passes through an empty transcript")
        // One chat.history fetch for the reopen; a second open doesn't refetch.
        #expect(target.loadCount == loadsBefore + 1)
        await target.load()
        #expect(target.loadCount == loadsBefore + 1)
        gateway.stop()
        self.scratch.remove()
        self.temp.remove()
    }
    @Test func requestArrivingMidPassRunsAfterwardsWithStrictestLimit() async {
        let gateway = self.gateway()
        gateway.residency.limit = 3
        let chats = ["a", "b", "c", "d", "e"].map { gateway.chat(for: "agent:main:dashboard:\($0)") }
        for chat in chats { self.hydrate(chat) }
        gateway.enforceChatBudget()
        gateway.handleMemoryPressure(critical: true)
        #expect(gateway.pendingChatBudgetLimit == 0)
        await self.settle { chats.allSatisfy { $0.isDehydrated } }
        #expect(chats.allSatisfy { $0.isDehydrated })
        #expect(gateway.pendingChatBudgetLimit == nil)
        await self.cleanup(gateway)
    }

    @Test func dehydratedChatNeverWritesEmptiedStateToCache() async {
        let gateway = self.gateway()
        let chat = gateway.chat(for: "agent:main:dashboard:a")
        self.hydrate(chat)
        await chat.dehydrate()
        await chat.saveToCache()
        chat.scheduleSave()
        await gateway.cacheCleared()
        await chat.finishCaching()
        try? await Task.sleep(for: .milliseconds(1300))
        let (snapshot, _) = await TranscriptCache.loadWithOutcome(gatewayId: gateway.id, sessionKey: chat.sessionKey, root: self.temp.url)
        #expect(snapshot?.items.map(\.id) == ["m0", "m1", "m2"])
        await self.cleanup(gateway)
    }

    @Test func prefetchRecachesDehydratedChatsAfterCacheClear() async {
        let gateway = GatewayStore(profile: .demo(), defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        gateway.start()
        await self.settle { gateway.state == .connected && !gateway.sessions.isEmpty }
        let key = "agent:main:dashboard:garden"
        let chat = gateway.chat(for: key)
        await chat.load(force: true)
        #expect(chat.hasLoaded)
        await chat.dehydrate()
        #expect(chat.isDehydrated)
        await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
        #expect(await TranscriptCache.meta(gatewayId: gateway.id, sessionKey: key, root: self.temp.url) == nil)
        await gateway.cacheCleared()
        for _ in 0..<600 {
            if await TranscriptCache.meta(gatewayId: gateway.id, sessionKey: key, root: self.temp.url) != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(await TranscriptCache.meta(gatewayId: gateway.id, sessionKey: key, root: self.temp.url) != nil)
        #expect(chat.isDehydrated && chat.items.isEmpty)
        gateway.stop()
        self.scratch.remove()
        self.temp.remove()
    }
}

@MainActor
final class CountLog {
    var values: [Int] = []
    private let chat: ChatStore
    init(_ chat: ChatStore) { self.chat = chat }

    func watch() {
        withObservationTracking { _ = self.chat.items } onChange: {
            Task { @MainActor in
                self.values.append(self.chat.items.count)
                self.watch()
            }
        }
    }
}
