@testable import PincerKit
import Testing

/// #934: the count-bounded per-chat LRU behind the transcript height cache.
@Suite("Resident chat cache")
struct ResidentChatCacheTests {
    @Test func storeOrdersLeastRecentFirstAndReplaces() {
        var cache = ResidentChatCache<Int>(limit: 4)
        cache.store(1, for: "a")
        cache.store(2, for: "b")
        cache.store(3, for: "c")
        #expect(cache.keys == ["a", "b", "c"])
        cache.store(10, for: "a")
        #expect(cache.keys == ["b", "c", "a"])
        #expect(cache.count == 3)
        #expect(cache.peek("a") == 10)
    }

    @Test func evictsLeastRecentPastTheLimitAndReportsKeys() {
        var cache = ResidentChatCache<Int>(limit: 2)
        #expect(cache.store(1, for: "a").isEmpty)
        #expect(cache.store(2, for: "b").isEmpty)
        #expect(cache.store(3, for: "c") == ["a"])
        #expect(cache.keys == ["b", "c"])
        #expect(cache.peek("a") == nil)
        #expect(cache.store(4, for: "b").isEmpty)
        #expect(cache.store(5, for: "d") == ["c"])
        #expect(cache.count == 2)
    }

    @Test func peekDoesNotTouch() {
        var cache = ResidentChatCache<Int>(limit: 2)
        cache.store(1, for: "a")
        cache.store(2, for: "b")
        #expect(cache.peek("a") == 1)
        #expect(cache.keys == ["a", "b"])
        #expect(cache.store(3, for: "c") == ["a"])
    }

    @Test func takeRemovesAndReturns() {
        var cache = ResidentChatCache<Int>(limit: 3)
        cache.store(1, for: "a")
        cache.store(2, for: "b")
        #expect(cache.take("a") == 1)
        #expect(cache.take("a") == nil)
        #expect(cache.keys == ["b"])
        #expect(cache.take("missing") == nil)
    }

    @Test func removeAllWhereFiltersAndRemoveAllClears() {
        var cache = ResidentChatCache<Int>(limit: 5)
        for (index, key) in ["a", "b", "c", "d"].enumerated() { cache.store(index, for: key) }
        cache.removeAll { key, value in key == "b" || value == 3 }
        #expect(cache.keys == ["a", "c"])
        cache.removeAll()
        #expect(cache.count == 0 && cache.keys.isEmpty)
    }

    @Test func limitZeroStoresNothingAndNegativeClamps() {
        var cache = ResidentChatCache<Int>(limit: 0)
        _ = cache.store(1, for: "a")
        #expect(cache.count == 0 && cache.peek("a") == nil)
        let negative = ResidentChatCache<Int>(limit: -3)
        #expect(negative.limit == 0)
    }

    @Test func defaultLimitFollowsResidency() {
        #expect(ResidentChatCache<Int>.defaultLimit == ChatResidency.defaultLimit)
        #expect(ResidentChatCache<Int>().limit == ChatResidency.defaultLimit)
    }
}
