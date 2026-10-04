#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct BookmarkPersistenceEncodingTests {
    @Test(arguments: ["toggle", "add", "remove"])
    func actualLocalMutationEncodesOffMainAndRoundTrips(action: String) async throws {
        let (entries, encoded, shardSizes) = try await Task.detached {
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
        try #require(entries.count < BookmarkStore.limit && shardSizes.allSatisfy { $0 < BookmarkStore.syncedByteBudget })
        let suite = "bookmark-encode-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gateway = UUID(), key = "pincer.bookmarks.\(gateway.uuidString)"
        defaults.set(encoded, forKey: key)
        let store = BookmarkStore(gatewayId: gateway, defaults: defaults)
        try #require(store.bookmarks == entries)
        let probe = BookmarkPersistenceEncodingProbe()
        store.persistenceEncodingProbe = probe
        let added = Bookmark(sessionKey: "agent:main:saved", messageId: "new", preview: "A newly saved ordinary message.")
        switch action {
        case "toggle": #expect(store.toggle(added))
        case "add": store.add(added)
        default: store.remove(sessionKey: entries[0].sessionKey, messageId: entries[0].messageId)
        }
        #expect(store.bookmarks.count == entries.count + (action == "remove" ? -1 : 1))
        #expect(store.isBookmarked(sessionKey: added.sessionKey, messageId: added.messageId) == (action != "remove"))
        #expect(store.droppedCount == 0)
        let expected = store.bookmarks
        await store.waitForPersistenceEncoding()
        let data = try #require(defaults.data(forKey: key))
        let persisted = try await Task.detached { try JSONDecoder().decode([Bookmark].self, from: data) }.value
        let fullRoundTrip = persisted == expected && !persisted.isEmpty
        try #require(fullRoundTrip)
        #expect(BookmarkStore(gatewayId: gateway, defaults: defaults).bookmarks == expected)
        let stats = probe.snapshot()
        #expect(stats.main + stats.worker == 1)
        #expect(stats.main == 0)
    }
}
#endif
