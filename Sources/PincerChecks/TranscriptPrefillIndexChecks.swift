import Foundation
#if DEBUG
@testable import PincerKit

/// A background fill restores a disk baseline before appending Gateway history. Measure work
/// by built documents, rather than a wall-clock deadline affected by other native work.
@MainActor
func runTranscriptPrefillIndexChecks() async {
    await withScratchCache { root in
        let gatewayID = UUID()
        let key = "agent:main:prefill-check"
        let items = (0..<1_000).map { n in
            messageItem("prefill-\(n)", n.isMultiple(of: 2) ? .user : .assistant,
                        "prefill original message \(n)", at: 1_700_000_000 + Double(n))
        }
        let original = TranscriptCache.Snapshot(items: items, complete: true)
        let seeded = await TranscriptCache.saveReturningStats(original, gatewayId: gatewayID, sessionKey: key, root: root)
        check(seeded.filesWritten > 0, "prefill: a real disk transcript and index were seeded")
        guard seeded.filesWritten > 0,
              let directory = TranscriptCache.directory(gatewayId: gatewayID, root: root)
        else { return }

        await TranscriptCache.Writer.shared.forget(under: directory)
        let loaded = await TranscriptCache.loadNewestForHeadlessFill(
            gatewayId: gatewayID, sessionKey: key, limit: TranscriptCache.maxItems, root: root)
        check(loaded.outcome == .loaded && loaded.items == items,
              "prefill: headless restore preserves the full cached transcript")
        guard loaded.outcome == .loaded, loaded.items == items else { return }

        let appended = messageItem("prefill-tail", .user, "prefill appended sentinel", at: 1_700_010_000)
        let updated = TranscriptCache.Snapshot(items: loaded.items + [appended], complete: true)
        await TranscriptCache.save(updated, gatewayId: gatewayID, sessionKey: key, root: root)
        let index = MessageIndex.shared(gatewayId: gatewayID, root: root)
        let stats = index.lastIndexStats
        // A new user row reindexes the preceding user/assistant pair as well as the append.
        check(stats.path == .tail && stats.documentsBuilt <= 3,
              "prefill: user append uses the tail path and at most three boundary documents (path=\(stats.path), documents=\(stats.documentsBuilt))")
        let originalHits = await indexHits(gatewayID, "original message 0", root: root)
        let tailHits = await indexHits(gatewayID, "appended sentinel", root: root)
        check(!originalHits.isEmpty && !tailHits.isEmpty,
              "prefill: old messages and the new tail remain searchable")
        let expected = MessageSearch.positionedDocuments(sessionKey: key, items: updated.items[...])
        let rows = await index.indexedRows(sessionKey: key)
        check(rows.count == expected.count,
              "prefill: indexed row count equals a full transcript rebuild")
    }
}

@MainActor
func runDemoTranscriptHeadlessFillChecks() async {
    let suite = "PincerChecks.demoHeadlessFill.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    let key = "agent:main:dashboard:trip"
    let chat = ChatStore(sessionKey: key, agentId: "main", gateway: gateway, headless: true)
    chat.windowLimit = TranscriptCache.maxItems
    defer {
        chat.stopCaching()
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
        TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true)
    }
    gateway.start()
    let ready = await waitFor("demo headless history fill") {
        gateway.state.isConnected && gateway.sessions[key] != nil
    }
    check(ready, "prefill demo: the seeded trip is available")
    guard ready else { return }
    await chat.fillCache()
    check(chat.hasLoaded && !chat.hasMoreHistory && chat.items.count > 120,
          "prefill demo: the actual headless fill loads beyond the newest history page")
    check(Set(chat.items.map(\.id)).count == chat.items.count,
          "prefill demo: older pages and the newest page merge without duplicates")
    let index = MessageIndex.shared(gatewayId: gateway.id, root: nil)
    let info = await index.chatInfo(sessionKey: key)
    check(info?.itemCount == chat.items.count,
          "prefill demo: the in-memory search index receives the complete headless history")
    await TranscriptCache.flush(gatewayId: gateway.id)
}
#else
import PincerKit
@MainActor func runTranscriptPrefillIndexChecks() async {}
@MainActor func runDemoTranscriptHeadlessFillChecks() async {}
#endif
