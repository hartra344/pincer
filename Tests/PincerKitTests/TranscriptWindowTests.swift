import Foundation
import Testing
@testable import PincerKit

/// A chat holds only its newest `windowLimit` items; older history stays on disk and pages back in (#282).
@Suite("Transcript window", .serialized)
@MainActor
struct TranscriptWindowTests {
    let key = "agent:main:main"
    let temp = TempDir()
    let total = 400
    let limit = 60

    func makeStore(key: String? = nil, headless: Bool = false) -> (ChatStore, GatewayStore) {
        let suite = "TranscriptWindowTests.\(UUID().uuidString)"
        let profile = GatewayProfile(id: UUID(), name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: UserDefaults(suiteName: suite)!, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        let chat = ChatStore(sessionKey: key ?? self.key, agentId: nil, gateway: gateway, headless: headless)
        chat.windowLimit = self.limit
        return (chat, gateway)
    }

    /// The ids `V8.items` gives for positions `range`.
    func ids(_ range: Range<Int>) -> [String] {
        V8.items(range.count, from: range.lowerBound).map(\.id)
    }

    func seed(_ gateway: GatewayStore, count: Int? = nil, complete: Bool = true) async {
        let items = V8.items(count ?? self.total)
        await TranscriptCache.save(V8.snapshot(items, complete: complete), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
    }

    func cached(_ gateway: GatewayStore) async -> [String] {
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        return await TranscriptCache.load(gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)?.items.map(\.id) ?? []
    }

    /// The ids in `items` are a contiguous run of the seeded transcript ending at its newest item.
    func expectNewestSuffix(_ chat: ChatStore, total: Int? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let total = total ?? self.total
        let count = chat.items.count
        #expect(chat.items.map(\.id) == self.ids((total - count)..<total), sourceLocation: sourceLocation)
    }

    // MARK: Restore

    @Test func restoreLoadsOnlyTheNewestWindow() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        #expect(chat.cacheOutcome == .loaded)
        #expect(chat.items.count >= self.limit && chat.items.count <= self.limit + 3)
        self.expectNewestSuffix(chat)
        #expect(chat.olderInCache)
        #expect(chat.hasOlderItems)
    }

    @Test func smallChatRestoresWholeWithNothingOlder() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway, count: 30)
        await chat.restoreFromCache()
        #expect(chat.items.count == 30)
        #expect(!chat.olderInCache && !chat.hasMoreHistory && !chat.hasOlderItems)
    }

    @Test func restoreOfExactlyWindowSizedChatHasNothingOlder() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway, count: self.limit)
        await chat.restoreFromCache()
        #expect(chat.items.count == self.limit)
        // A full window can't tell whether older items exist until the first page comes back empty.
        #expect(await chat.loadOlder())
        #expect(chat.items.count == self.limit)
        #expect(!chat.olderInCache && !chat.hasOlderItems)
    }

    @Test func defaultWindowLimitIsSetForThePlatform() {
        #if os(macOS)
        #expect(ChatStore.defaultWindowLimit == 3_000)
        #else
        #expect(ChatStore.defaultWindowLimit == 1_200)
        #endif
    }

    // MARK: Paging older items from the cache

    @Test func loadOlderPagesFromCacheWithoutGapsOrDuplicates() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        let windowIds = chat.items.map(\.id)
        var rounds = 0
        while chat.olderInCache, rounds < 100 {
            let before = chat.items.count
            #expect(await chat.loadOlder())
            #expect(chat.items.count > before)
            #expect(Set(chat.items.map(\.id)).count == chat.items.count)
            #expect(Array(chat.items.suffix(windowIds.count)).map(\.id) == windowIds)
            rounds += 1
        }
        #expect(!chat.olderInCache)
        #expect(chat.items.map(\.id) == self.ids(0..<self.total))
        #expect(!chat.hasOlderItems)
    }

    @Test func loadOlderKeepsRowIdentity() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        let before = chat.entries.map(\.id)
        #expect(await chat.loadOlder())
        let after = chat.entries.map(\.id)
        #expect(after.count > before.count)
        #expect(Array(after.suffix(before.count)) == before)
    }

    @Test func reachingCacheStartHandsOverToGatewayPaging() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway, complete: false)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        #expect(chat.hasMoreHistory && chat.olderInCache)
        var rounds = 0
        while chat.olderInCache, rounds < 100 {
            #expect(await chat.loadOlder())
            rounds += 1
        }
        #expect(chat.items.count == self.total)
        #expect(!chat.olderInCache)
        #expect(chat.hasMoreHistory && chat.hasOlderItems)
        #expect(chat.olderOffset == self.total)
        // Offline, the Gateway page can't load: reported, and nothing lost.
        #expect(await chat.loadOlder() == false)
        #expect(chat.items.count == self.total)
        #expect(chat.hasOlderItems)
    }

    @Test func loadOlderWithNothingOlderIsANoOp() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway, count: 20)
        await chat.restoreFromCache()
        #expect(await chat.loadOlder())
        #expect(chat.items.count == 20)
    }

    @Test func missingCacheWhilePagingFallsBackToGateway() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway, complete: false)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        let count = chat.items.count
        await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        _ = await chat.loadOlder()
        #expect(!chat.olderInCache)
        #expect(chat.items.count == count)
    }

    // MARK: Trim

    @Test func windowCutNeverSplitsATurn() {
        let items = V8.items(300)
        for limit in [10, 60, 61, 62, 63, 150, 299] {
            let cut = ChatStore.windowCut(items, limit: limit)
            #expect(cut >= 0 && cut <= items.count)
            #expect(items.count - cut <= limit + 3, "limit \(limit)")
            if cut > 0 { #expect(items[cut].role == .user, "limit \(limit) cut at \(cut)") }
        }
        #expect(ChatStore.windowCut(items, limit: 300) == 0)
        #expect(ChatStore.windowCut(items, limit: 1_000) == 0)
        #expect(ChatStore.windowCut([], limit: 10) == 0)
    }

    @Test func windowCutWithoutUserMessagesFallsBackToTheCount() {
        let items = V8.items(90).map { item -> ChatItem in
            var item = item
            item.role = .assistant
            return item
        }
        #expect(ChatStore.windowCut(items, limit: 40) == 50)
    }

    @Test func trimDropsOlderItemsAtATurnBoundary() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        await chat.trimToWindow()
        #expect(chat.items.count <= self.limit && chat.items.count >= self.limit - 3)
        #expect(chat.items.first?.role == .user)
        self.expectNewestSuffix(chat)
        #expect(chat.olderInCache && chat.hasOlderItems)
        #expect(await self.cached(gateway) == self.ids(0..<self.total))
    }

    @Test func trimKeepsPendingItems() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        var pending = ChatItem(id: "p1", role: .user, blocks: [.text("unsent")], timestamp: Date(timeIntervalSince1970: 2_000_000_000))
        pending.isPending = true
        chat.items.append(pending)
        chat.hasLoaded = true
        await chat.trimToWindow()
        #expect(chat.items.last?.id == "p1" && chat.items.last?.isPending == true)
        #expect(chat.items.filter { !$0.isPending }.count <= self.limit)
        #expect(await self.cached(gateway) == self.ids(0..<self.total))
    }

    @Test func trimIsANoOpForTheSelectedChat() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        gateway.selectedKey = self.key
        await chat.trimToWindow()
        #expect(chat.items.count == self.total)
        #expect(!chat.olderInCache)
    }

    @Test func trimIsANoOpWithinTheWindow() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.limit)
        chat.hasLoaded = true
        await chat.trimToWindow()
        #expect(chat.items.count == self.limit)
        #expect(!chat.olderInCache)
    }

    @Test func trimmedChatPagesBackFromTheCache() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        await chat.trimToWindow()
        var rounds = 0
        while chat.olderInCache, rounds < 100 {
            #expect(await chat.loadOlder())
            rounds += 1
        }
        #expect(chat.items.map(\.id) == self.ids(0..<self.total))
    }

    // MARK: Saves keep older history

    @Test func saveAfterTrimKeepsOlderOnDisk() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        chat.items += V8.items(5, from: self.total)
        await chat.saveSnapshot()
        #expect(await self.cached(gateway) == self.ids(0..<(self.total + 5)))
        await chat.trimToWindow()
        chat.items += V8.items(2, from: self.total + 5)
        await chat.saveSnapshot()
        #expect(await self.cached(gateway) == self.ids(0..<(self.total + 7)))
    }

    @Test func saveOfAWindowedChatKeepsCompleteFlag() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        chat.items += V8.items(1, from: self.total)
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        let snapshot = await TranscriptCache.load(gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        #expect(snapshot?.complete == true)
        #expect(snapshot?.items.count == self.total + 1)
    }

    // MARK: Locate and find

    @Test func locateFindsAnItemOutsideTheWindowViaTheCache() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        let target = "u3"
        #expect(chat.message(withId: target) == nil)
        #expect(await chat.locate(target))
        #expect(chat.message(withId: target) != nil)
        #expect(Set(chat.items.map(\.id)).count == chat.items.count)
        self.expectNewestSuffix(chat)
    }

    @Test func locateOfAnUnknownIdReportsAndKeepsWhatLoaded() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        #expect(await chat.locate("nope") == false)
        #expect(chat.notice != nil)
        self.expectNewestSuffix(chat)
    }

    @Test func loadAllCachedMakesTheWholeCachedHistoryAvailable() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        #expect(chat.items.count < self.total)
        await chat.loadAllCached()
        #expect(chat.items.map(\.id) == self.ids(0..<self.total))
        #expect(!chat.olderInCache && !chat.hasOlderItems)
    }

    @Test func loadAllCachedThenTrimReturnsToTheWindow() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        await chat.loadAllCached()
        await chat.trimToWindow()
        #expect(chat.items.count <= self.limit && chat.olderInCache)
        self.expectNewestSuffix(chat)
        #expect(await self.cached(gateway) == self.ids(0..<self.total))
    }

    // MARK: Background fill vs. the visible store

    @Test func aNewerMessageSavedByTheVisibleStoreSurvivesTheFullFill() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        chat.items += V8.items(1, from: self.total)
        await chat.saveSnapshot()
        // The background fill finishes with a full history that predates the new message.
        let stale = V8.items(self.total)
        let filler = ChatStore(sessionKey: self.key, agentId: nil, gateway: gateway, headless: true)
        filler.items = stale
        filler.hasLoaded = true
        await filler.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        // The visible store then re-saves with what it holds, keeping the older history.
        chat.savedState = nil
        await chat.saveSnapshot()
        let ids = await self.cached(gateway)
        #expect(ids.contains(V8.items(1, from: self.total)[0].id))
        #expect(Array(ids.prefix(self.total)) == self.ids(0..<self.total))
    }

    // MARK: Architect amendments (A1, A2, A5, A6, id-less messages)

    /// Gateway-shaped messages: users carry a transcript id, replies and tool results don't (they get `idx-` ids).
    func idlessMessages(_ count: Int, from start: Int = 0) -> [JSONValue] {
        (start..<(start + count)).map { n -> JSONValue in
            switch n % 3 {
            case 0: ["role": "user", "content": .string("question \(n)"), "timestamp": .number(1_700_000_000 + Double(n)), "__openclaw": ["id": .string("u\(n)")]]
            case 1: ["role": "assistant", "content": .string("answer \(n)"), "timestamp": .number(1_700_000_000 + Double(n))]
            default: ["role": "toolResult", "content": .string("result \(n)"), "timestamp": .number(1_700_000_000 + Double(n))]
            }
        }
    }

    @Test func snapshotIsIncompleteWhileOlderItemsAreOnlyOnDisk() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        await self.seed(gateway)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        #expect(chat.olderInCache && !chat.hasMoreHistory)
        #expect(chat.snapshot().complete == false)
        await chat.loadAllCached()
        #expect(chat.snapshot().complete == true)
    }

    @Test func windowSaveAfterAHeadlessFillOfIdlessMessagesKeepsOlderHistory() async {
        let (chat, gateway) = self.makeStore(headless: true)
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        let first = ChatStore.parse(self.idlessMessages(self.total), fallbackBase: 0)
        await TranscriptCache.save(V8.snapshot(first), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        #expect(chat.items.first?.transcriptId != nil)
        let windowCount = chat.items.count

        // A headless fill re-parses the same transcript; its id-less items get different fallback ids.
        let refilled = ChatStore.parse(self.idlessMessages(self.total), fallbackBase: 5_000)
        #expect(refilled.map(\.id) != first.map(\.id))
        await TranscriptCache.save(V8.snapshot(refilled), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)

        chat.items += ChatStore.parse(self.idlessMessages(3, from: self.total), fallbackBase: self.total)
        await chat.saveSnapshot()
        let saved = await self.cached(gateway)
        #expect(saved.count == self.total + 3)
        #expect(Array(saved.prefix(self.total - windowCount)) == refilled.prefix(self.total - windowCount).map(\.id))
    }

    @Test func windowsStartOnAnItemWithATranscriptIdEvenWithIdlessMessages() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.windowLimit = 50
        let items = ChatStore.parse(self.idlessMessages(self.total), fallbackBase: 0)
        await TranscriptCache.save(V8.snapshot(items), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        await chat.restoreFromCache()
        chat.hasLoaded = true
        #expect(chat.items.first?.transcriptId != nil)
        #expect(chat.items.map(\.id) == items.suffix(chat.items.count).map(\.id))
        chat.items = items
        await chat.trimToWindow()
        #expect(chat.items.count < items.count && chat.items.count <= 50)
        #expect(chat.items.first?.transcriptId != nil)
        #expect(chat.items.map(\.id) == items.suffix(chat.items.count).map(\.id))
        let saved = await self.cached(gateway)
        #expect(saved == items.map(\.id))
    }

    @Test func loadOlderWorksInTheTrimmedStateWithoutAnOffset() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        await chat.trimToWindow()
        #expect(chat.olderInCache && chat.olderOffset == nil)
        let before = chat.items.count
        #expect(await chat.loadOlder())
        #expect(chat.items.count > before)
        self.expectNewestSuffix(chat)
    }

    @Test func trimmedChatFallsBackToGatewayPagingWhenTheCacheIsGone() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasMoreHistory = true
        chat.hasLoaded = true
        await chat.trimToWindow()
        let count = chat.items.count
        await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        _ = await chat.loadOlder()
        #expect(!chat.olderInCache && chat.hasMoreHistory)
        #expect(chat.olderOffset == count)
        #expect(chat.items.count == count)
    }

    @Test func locateWorksInTheTrimmedState() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        await chat.trimToWindow()
        #expect(await chat.locate("u3"))
        #expect(chat.message(withId: "u3") != nil)
    }

    @Test func aWarmIdleChatTrimsWhenAnotherIsSelected() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        gateway.selectedKey = "agent:main:dashboard:other"
        await chat.trimToWindow()
        #expect(chat.items.count <= self.limit && chat.olderInCache)
    }

    @Test func aBusyChatIsNotTrimmed() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        chat.live = LiveRun(runId: "r1")
        #expect(chat.isRunning)
        await chat.trimToWindow()
        #expect(chat.items.count == self.total)
    }

    @Test func reconnectWithMoreThanAPageOfNewMessagesAfterATrimLeavesNoGap() async {
        let (chat, gateway) = self.makeStore()
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
            self.temp.remove()
        }
        chat.items = V8.items(self.total)
        chat.hasLoaded = true
        await chat.trimToWindow()
        #expect(chat.olderInCache)

        // 130 new messages, none of them in what's loaded: the loaded window is stale.
        let messages = self.idlessMessages(130, from: 1_000)
        let parsed = ChatStore.parse(messages, fallbackBase: 0)
        chat.apply(history: ["messages": .array(messages), "hasMore": true, "nextOffset": 130], parsed: parsed)
        #expect(!chat.olderInCache)
        #expect(chat.hasMoreHistory)
        #expect(chat.items.map(\.id) == parsed.map(\.id))
        await chat.saveSnapshot()
        #expect(await self.cached(gateway) == parsed.map(\.id))
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<1500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aCappedCacheIsNotRefilledOnEveryOpenOrReconnect() async throws {
        let starts = try await self.reopenCachedChat(retained: true)
        #expect(starts == 0)
    }

    @Test func anUncappedIncompleteCacheIsRefilledOnOpen() async throws {
        let starts = try await self.reopenCachedChat(retained: false)
        #expect(starts > 0)
    }

    /// Reopens a chat whose cache is incomplete and stale; returns how many background fills started for it.
    func reopenCachedChat(retained: Bool) async throws -> Int {
        let profile = GatewayProfile.demo()
        let key = "agent:main:dashboard:garden"
        let defaults = UserDefaults(suiteName: "TranscriptWindowTests.\(UUID().uuidString)")!
        func connect() async -> GatewayStore {
            let gateway = GatewayStore(profile: profile, defaults: defaults, identity: Fixtures.identity())
            gateway.cacheRoot = self.temp.url
            gateway.start()
            await self.settle { gateway.state == .connected && !gateway.sessions.isEmpty }
            return gateway
        }
        let first = await connect()
        defer { TranscriptCache.removeAll(gatewayId: first.id, permanently: true, root: self.temp.url); self.temp.remove() }
        let seed = first.chat(for: key)
        await seed.load(force: true)
        let real = seed.items.filter { !$0.isPending }
        #expect(!real.isEmpty)
        seed.stopCaching()
        first.stop()

        // The newest 20,000 items are cached (the retention cap) with older history left out.
        let older = V8.items(TranscriptCache.maxItems - real.count).map { item -> ChatItem in
            var item = item
            item.id = "old-\(item.id)"
            item.transcriptId = item.id
            return item
        }
        var capped = V8.snapshot(older + real, complete: false, activityMs: 1, retained: retained)
        capped.retained = retained
        await TranscriptCache.save(capped, gatewayId: first.id, sessionKey: key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: first.id, root: self.temp.url)

        let gateway = await connect()
        defer { gateway.stop() }
        let chat = gateway.chat(for: key)
        for _ in 0..<3 { await chat.load(force: true) }
        // Long enough for a background fill (or the prefetch, which waits 2 s) to have rewritten the cache.
        try? await Task.sleep(for: .seconds(3))
        await gateway.settlePrefetch()
        chat.stopCaching()
        let meta = await TranscriptCache.meta(gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
        if retained {
            #expect(meta?.retained == true)
            let cached = await TranscriptCache.load(gatewayId: gateway.id, sessionKey: key, root: self.temp.url)
            #expect(cached?.items.count == TranscriptCache.maxItems)
            #expect(cached?.items.first?.id == older.first?.id)
        }
        return gateway.headlessFillStarts[key, default: 0]
    }
}
