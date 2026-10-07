import Foundation
@testable import PincerKit

@MainActor
func runResidentChatCacheChecks() {
    var cache = ResidentChatCache<Int>(limit: 2)
    check(cache.store(1, for: "a").isEmpty && cache.store(2, for: "b").isEmpty,
          "resident chat cache stores up to its limit without evicting")
    check(cache.peek("a") == 1 && cache.keys == ["a", "b"], "peek reads without touching recency")
    check(cache.store(3, for: "c") == ["a"] && cache.keys == ["b", "c"],
          "past the limit the least recent key is evicted and reported")
    cache.store(9, for: "b")
    check(cache.keys == ["c", "b"] && cache.peek("b") == 9, "replacing a key makes it most recent")
    check(cache.take("c") == 3 && cache.take("c") == nil && cache.keys == ["b"], "take removes and returns the value")
    cache.store(4, for: "d")
    cache.removeAll { key, _ in key == "b" }
    check(cache.keys == ["d"], "removeAll(where:) drops matching entries")
    cache.removeAll()
    check(cache.count == 0, "removeAll empties the cache")
    var empty = ResidentChatCache<Int>(limit: 0)
    _ = empty.store(1, for: "a")
    check(empty.count == 0 && ResidentChatCache<Int>(limit: -1).limit == 0, "a zero limit stores nothing and negatives clamp")
    check(ResidentChatCache<Int>().limit == ChatResidency.defaultLimit, "the default limit is the residency limit")
}
