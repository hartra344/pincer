import Foundation
import Testing
@testable import PincerKit

/// v9 caches predate a way to record whether projected assistant rows have sender attribution.
@Suite("Forwarded sender cache refresh")
@MainActor
struct ForwardedSenderRefreshTests {
    private let legacyVersion = 9

    @Test func v9CacheIsMigratedWithoutDroppingProjectedAssistantRows() throws {
        var forwarded = ChatItem(id: "fwd-1", role: .assistant, blocks: [.text("Hi from the other agent")])
        forwarded.transcriptId = "fwd-1"
        let data = try JSONEncoder().encode(
            TranscriptCache.Snapshot(version: self.legacyVersion, items: [forwarded], complete: true))

        let (snapshot, outcome) = TranscriptCache.decode(data)

        #expect(outcome == .migrated(from: self.legacyVersion),
                "the segmented v9 cache needs the sender-attribution refresh migration")
        #expect(snapshot?.version == self.legacyVersion + 1)
        #expect(snapshot?.items == [forwarded], "migration keeps cached content available offline")
    }

    @Test func oldCompleteAndRetainedCachesMustRefreshEvenWhenActivityMatches() {
        let oldVersion = TranscriptCache.Meta(complete: true, activityMs: 10, version: self.legacyVersion, retained: false)
        let oldRetainedVersion = TranscriptCache.Meta(complete: false, activityMs: 10, version: self.legacyVersion, retained: true)

        #expect(!GatewayStore.prefetchIsFresh(oldVersion, activityMs: 10),
                "a complete v9 cache cannot prove older forwarded rows were attributed")
        #expect(!GatewayStore.prefetchIsFresh(oldRetainedVersion, activityMs: 10),
                "a retained v9 cache also needs the bounded attribution refresh")
    }

    @Test func preSenderRawCacheReceivesTheSamePendingMarker() throws {
        var forwarded = ChatItem(id: "fwd-legacy", role: .assistant, blocks: [.text("Older forwarded turn")])
        forwarded.transcriptId = "fwd-legacy"
        let data = try JSONEncoder().encode(
            TranscriptCache.Snapshot(version: 6, items: [forwarded], complete: true))

        let (snapshot, outcome) = TranscriptCache.decode(data)

        #expect(outcome == .migrated(from: 6))
        #expect(snapshot?.forwardedSenderRefreshPending == true)
        #expect(snapshot?.items.first?.plainText == "Older forwarded turn")
    }

    @Test func preV10ManifestDefaultsToPending() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": self.legacyVersion,
            "complete": true,
            "activityMs": 10,
            "retained": false,
            "token": "legacy",
            "segments": [],
        ])

        let manifest = try JSONDecoder().decode(TranscriptCache.Manifest.self, from: data)

        #expect(manifest.forwardedSenderRefreshPending)
    }

    @Test func refreshPagePolicyRejectsEmptyOrNonAdvancingPagesThatClaimMore() {
        #expect(ChatStore.forwardedRefreshPageDisposition(messageCount: 0, reportedHasMore: true,
                                                          requestedOffset: 120, returnedOffset: 120,
                                                          fallbackLimit: 120) == .abort)
        #expect(ChatStore.forwardedRefreshPageDisposition(messageCount: 12, reportedHasMore: true,
                                                          requestedOffset: 120, returnedOffset: 120,
                                                          fallbackLimit: 120) == .abort)
        #expect(ChatStore.forwardedRefreshPageDisposition(messageCount: 0, reportedHasMore: nil,
                                                          requestedOffset: 120, returnedOffset: nil,
                                                          fallbackLimit: 120) == .complete(nextOffset: 120),
                "a normal empty terminal page completes a scan")
        #expect(ChatStore.forwardedRefreshPageDisposition(messageCount: nil, reportedHasMore: nil,
                                                          requestedOffset: 120, returnedOffset: nil,
                                                          fallbackLimit: 120) == .abort,
                "a missing messages array is not a valid empty terminal page")
        #expect(ChatStore.forwardedRefreshPageDisposition(messageCount: 12, reportedHasMore: true,
                                                          requestedOffset: 120, returnedOffset: nil,
                                                          fallbackLimit: 120) == .more(nextOffset: 132))
    }

    @Test func authoritativeRefreshReplacesMatchingSenderAndKeepsOfflineOnlyRows() async {
        // Old projected cache rows can retain a stable id without the newer transcriptId field.
        let stale = ChatItem(id: "forwarded", role: .assistant, blocks: [.text("Kiko's message")],
                             timestamp: Date(timeIntervalSince1970: 2))
        var offlineOnly = ChatItem(id: "offline", role: .user, blocks: [.text("Offline note")],
                                   timestamp: Date(timeIntervalSince1970: 1))
        offlineOnly.transcriptId = "offline"
        var refreshed = stale
        refreshed.sender = MessageSender(kind: .agent, sessionKey: "agent:kiko:main", agentId: "kiko")

        let merged = await ChatStore.mergeForwardedRefresh(cached: [offlineOnly, stale], authoritative: [refreshed])

        #expect(merged.count == 2)
        #expect(merged.first?.transcriptId == "offline")
        #expect(merged.last?.id == "forwarded")
        #expect(merged.last?.sender?.agentId == "kiko")
    }

    @Test func reconciliationKeepsConcurrentRowsAndLetsAuthorityReplaceSender() async {
        let oldTime = Date(timeIntervalSince1970: 10)
        let newestTime = Date(timeIntervalSince1970: 20)
        var cachedMatched = ChatItem(id: "matched", role: .assistant, blocks: [.text("Old body")], timestamp: oldTime)
        cachedMatched.transcriptId = "matched"
        cachedMatched.sender = MessageSender(kind: .agent, sessionKey: "agent:main:main", agentId: "main")

        var currentMatched = cachedMatched
        currentMatched.blocks = [.text("New live body")]

        var authoritativeMatched = cachedMatched
        authoritativeMatched.blocks = [.text("Server body")]
        authoritativeMatched.sender = MessageSender(kind: .agent, sessionKey: "agent:kiko:main", agentId: "kiko")

        var cachedConcurrent = ChatItem(id: "concurrent", role: .assistant, blocks: [.text("Before live update")],
                                        timestamp: oldTime)
        cachedConcurrent.transcriptId = "concurrent"
        var currentConcurrent = cachedConcurrent
        currentConcurrent.blocks = [.text("After live update")]
        currentConcurrent.timestamp = newestTime

        let reconciled = await ChatStore.reconcileForwardedRefresh(
            restoredCache: [cachedMatched, cachedConcurrent], pagesNewestFirst: [[authoritativeMatched]],
            current: [currentMatched, currentConcurrent])
        let byId = Dictionary(uniqueKeysWithValues: reconciled.compactMap { item in
            item.transcriptId.map { ($0, item) }
        })

        #expect(byId["matched"]?.plainText == "New live body",
                "the current body wins while its sender is refreshed from the authoritative page")
        #expect(byId["matched"]?.sender?.agentId == "kiko",
                "a stale non-nil current sender cannot override the authoritative sender")
        #expect(byId["concurrent"]?.plainText == "After live update",
                "a current row absent from the scan wins over its restored cached copy")
    }

    @Test func efficientMergePreservesUndatedAndEqualTimeOrdering() async {
        let first = ChatItem(id: "first", role: .assistant, blocks: [.text("First")],
                             timestamp: Date(timeIntervalSince1970: 10))
        let undatedAuthority = ChatItem(id: "authority-undated", role: .assistant, blocks: [.text("No time")], timestamp: nil)
        let last = ChatItem(id: "last", role: .assistant, blocks: [.text("Last")],
                            timestamp: Date(timeIntervalSince1970: 20))
        let undatedCacheA = ChatItem(id: "cache-undated-a", role: .user, blocks: [.text("No time")], timestamp: nil)
        let undatedCacheB = ChatItem(id: "cache-undated-b", role: .user, blocks: [.text("No time")], timestamp: nil)
        let datedCacheA = ChatItem(id: "cache-dated-a", role: .user, blocks: [.text("Equal time")],
                                   timestamp: Date(timeIntervalSince1970: 20))
        let datedCacheB = ChatItem(id: "cache-dated-b", role: .user, blocks: [.text("Equal time")],
                                   timestamp: Date(timeIntervalSince1970: 20))

        let merged = await ChatStore.mergeForwardedRefresh(
            cached: [undatedCacheA, undatedCacheB, datedCacheA, datedCacheB],
            authoritative: [first, undatedAuthority, last])

        #expect(merged.map(\.id) == ["cache-undated-b", "cache-undated-a", "first", "authority-undated",
                                     "last", "cache-dated-a", "cache-dated-b"])
    }

    @Test func workerKeepsRestoredRowsWhenHistoryPagesDoNotOverlapAndPreservesPendingRows() async {
        var cachedRows = V8.items(12)
        var offlineOnly = ChatItem(id: "offline-only", role: .user, blocks: [.text("Keep this offline")],
                                   timestamp: Date(timeIntervalSince1970: 0))
        offlineOnly.transcriptId = "offline-only"
        cachedRows.insert(offlineOnly, at: 0)
        let olderPage = V8.items(4, from: 100)
        let newestPage = V8.items(4, from: 104)
        let authoritative = olderPage + newestPage
        var pending = ChatItem(id: "pending", role: .user, blocks: [.text("Pending")])
        pending.isPending = true

        let merged = await ChatStore.reconcileForwardedRefresh(
            restoredCache: cachedRows, pagesNewestFirst: [newestPage, olderPage],
            current: newestPage + [pending])

        #expect(merged.count == 22)
        #expect(merged.contains(where: { $0.id == offlineOnly.id }))
        #expect(merged.suffix(9).dropLast().map(\.id) == authoritative.map(\.id))
        #expect(merged.last?.id == pending.id && merged.last?.isPending == true)
        #expect(merged.map(\.id).count == Set(merged.map(\.id)).count)
    }

    @Test func windowSavesRetainPendingMarkerUntilCompletedScan() async throws {
        let temp = TempDir()
        defer { temp.remove() }
        let gateway = UUID()
        let key = "agent:main:main"
        let items = V8.items(30)
        let stale = TranscriptCache.Snapshot(items: items, complete: true, activityMs: 10,
                                             forwardedSenderRefreshPending: true)
        await TranscriptCache.save(stale, gatewayId: gateway, sessionKey: key, root: temp.url)
        await TranscriptCache.flush(gatewayId: gateway, root: temp.url)
        let manifestURL = try #require(TranscriptCache.file(gatewayId: gateway, sessionKey: key, root: temp.url))
        var oldManifest = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))) as? [String: Any])
        oldManifest["version"] = self.legacyVersion
        oldManifest.removeValue(forKey: "forwardedSenderRefreshPending")
        try JSONSerialization.data(withJSONObject: oldManifest).write(to: manifestURL, options: .atomic)
        let oldMeta = TranscriptCache.Meta(complete: true, activityMs: 10, version: self.legacyVersion, retained: false)
        try JSONEncoder().encode(oldMeta).write(to: manifestURL.appendingPathExtension("meta"), options: .atomic)

        let window = TranscriptCache.Snapshot(items: Array(items.suffix(8)), complete: false, activityMs: 10)
        await TranscriptCache.save(window, gatewayId: gateway, sessionKey: key, keepingOlder: true, root: temp.url)
        await TranscriptCache.flush(gatewayId: gateway, root: temp.url)

        let afterWindow = try #require(await TranscriptCache.load(gatewayId: gateway, sessionKey: key, root: temp.url))
        #expect(afterWindow.forwardedSenderRefreshPending)
        #expect(afterWindow.items.count == items.count)

        var completed = TranscriptCache.Snapshot(items: afterWindow.items, complete: true, activityMs: 10)
        completed.forwardedSenderRefreshCompleted = true
        await TranscriptCache.save(completed, gatewayId: gateway, sessionKey: key, root: temp.url)
        await TranscriptCache.flush(gatewayId: gateway, root: temp.url)
        let afterRefresh = try #require(await TranscriptCache.load(gatewayId: gateway, sessionKey: key, root: temp.url))
        #expect(!afterRefresh.forwardedSenderRefreshPending)
    }
}
