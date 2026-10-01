import PincerKit

@MainActor
func runSymbolCacheChecks() {
    var cache = BoundedLRUCache<String, Int>(countLimit: 2, costLimit: 8)
    cache.insert(1, for: "visible", cost: 2)
    cache.insert(2, for: "old", cost: 2)
    check(cache.value(for: "visible") == 1, "a warmed symbol cache reuses its value")
    cache.insert(3, for: "new", cost: 2)
    check(cache.value(for: "old") == nil && cache.value(for: "visible") == 1,
          "symbol entry pressure evicts the least recently drawn value")
    cache.insert(4, for: "large", cost: 7)
    check(cache.count == 1 && cache.totalCost == 7 && cache.value(for: "large") == 4,
          "symbol cost pressure enforces the memory budget")
    check(!cache.insert(5, for: "oversized", cost: 9) && cache.value(for: "large") == 4,
          "an oversized one-off symbol bypasses caching without displacing warm values")
    cache.removeAll()
    check(cache.count == 0 && cache.totalCost == 0, "appearance invalidation releases all cached symbol values")
}
