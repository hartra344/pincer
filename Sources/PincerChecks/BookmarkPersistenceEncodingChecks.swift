#if DEBUG
import Foundation
@testable import PincerKit

/// Ordinary local user bookmark state, generated/encoded away from Main, not Gateway data.
private func bookmarkPersistenceFixture() async throws -> (entries: [Bookmark], data: Data, sizes: [Int]) {
    try await Task.detached {
        let entries = (0..<80).map { index in
            Bookmark(sessionKey: "agent:main:saved", messageId: "entry-\(index)",
                     preview: "A saved message about the weekend plan and its next step.",
                     createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let sizes = try (0..<Bookmark.shardCount).map { shard in
            let values = Dictionary(uniqueKeysWithValues: entries.filter { Bookmark.shard(ofKey: $0.id) == shard }.map { ($0.id, $0.syncedValue) })
            return try JSONEncoder().encode(values).count
        }
        return (entries, try JSONEncoder().encode(entries), sizes)
    }.value
}

@MainActor private func checkBookmarkPersistence(item: ChatItem?, sessionKey: String) async {
    do {
        let fixture = try await bookmarkPersistenceFixture()
        let bounded = fixture.entries.count < BookmarkStore.limit && fixture.sizes.allSatisfy { $0 < BookmarkStore.syncedByteBudget }
        check(bounded, "normal local bookmark fixture honors count and every synced shard budget")
        guard bounded else { return }
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), key = "pincer.bookmarks.\(id.uuidString)"
        defaults.set(fixture.data, forKey: key)
        let store = BookmarkStore(gatewayId: id, defaults: defaults)
        check(store.bookmarks == fixture.entries, "actual bookmark store loads the full ordinary local collection")
        guard store.bookmarks == fixture.entries else { return }
        store.previewPreparationQueue = BookmarkPreviewPreparationQueue() // Own the existing preview worker/drain in this fixture.
        let probe = BookmarkPersistenceEncodingProbe()
        store.persistenceEncodingProbe = probe
        let messageId = item?.transcriptId ?? item?.id ?? "new-local-bookmark"
        if let item {
            check(store.toggle(item, sessionKey: sessionKey), "actual loaded Demo item is starred immediately")
            await store.waitForPreviewPreparation()
        } else {
            check(store.toggle(Bookmark(sessionKey: sessionKey, messageId: messageId, preview: "A newly saved ordinary message.")),
                  "actual ordinary local toggle stars immediately")
        }
        check(store.isBookmarked(sessionKey: sessionKey, messageId: messageId) && store.bookmarks.count == fixture.entries.count + 1 && store.droppedCount == 0,
              "toggle keeps its exact identity without dropping ordinary bookmarks")
        await store.waitForPersistenceEncoding()
        let expected = store.bookmarks
        guard let data = defaults.data(forKey: key) else { check(false, "actual persisted bookmark data exists"); return }
        let persisted = try await Task.detached { try JSONDecoder().decode([Bookmark].self, from: data) }.value
        let fullRoundTrip = persisted == expected && !persisted.isEmpty
        check(fullRoundTrip, "the full actual persisted bookmark collection round-trips exactly")
        guard fullRoundTrip else { return }
        check(BookmarkStore(gatewayId: id, defaults: defaults).bookmarks == expected,
              "a new actual store loads the complete saved mutation")
        let counts = probe.snapshot()
        check(counts.main + counts.worker > 0, "probe observes the actual local persistence encoder")
        check(counts.main == 0, "full local bookmark persistence encoding stays off Main")
    } catch { check(false, "bookmark persistence fixture/round-trip completes: \(error.localizedDescription)") }
}

@MainActor func runBookmarkPersistenceEncodingChecks() async {
    await checkBookmarkPersistence(item: nil, sessionKey: "agent:main:saved")
}

@MainActor func runDemoBookmarkPersistenceEncodingChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("bookmark persistence Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "genuine Demo bookmark source connection is ready")
    guard connected else { return }
    let chat = gateway.chat(for: DemoBookmarks.tripSessionKey)
    await chat.load()
    guard let item = chat.items.first(where: { $0.role == .assistant && $0.transcriptId != nil }) else {
        check(false, "genuine loaded Demo history provides a committed bookmark target"); return
    }
    check(item.transcriptId != nil, "bookmark target comes from actual committed Demo history")
    await checkBookmarkPersistence(item: item, sessionKey: chat.sessionKey)
}
#endif
