import Testing
@testable import PincerKit

@Suite("Bounded image cache policy")
struct BoundedLRUCacheTests {
    @Test func recentlyDrawnImagesSurviveEntryPressure() {
        var cache = BoundedLRUCache<String, Int>(countLimit: 2, costLimit: 10)
        cache.insert(1, for: "visible", cost: 2)
        cache.insert(2, for: "old", cost: 2)
        let warm = cache.value(for: "visible")
        #expect(warm == 1)
        cache.insert(3, for: "new", cost: 2)
        let old = cache.value(for: "old")
        let visible = cache.value(for: "visible")
        let new = cache.value(for: "new")
        #expect(old == nil && visible == 1 && new == 3)
        #expect(cache.count == 2 && cache.totalCost == 4)
    }

    @Test func bytePressureReplacementAndOversizedImagesRespectBudgets() {
        var cache = BoundedLRUCache<String, Int>(countLimit: 4, costLimit: 8)
        cache.insert(1, for: "old", cost: 4)
        cache.insert(2, for: "visible", cost: 4)
        cache.insert(3, for: "new", cost: 5)
        let new = cache.value(for: "new")
        #expect(cache.count == 1 && cache.totalCost == 5 && new == 3)
        let oversized = cache.insert(4, for: "oversized", cost: 9)
        let retained = cache.value(for: "new")
        #expect(!oversized && retained == 3)
        cache.insert(5, for: "new", cost: 2)
        let replacement = cache.value(for: "new")
        #expect(cache.count == 1 && cache.totalCost == 2 && replacement == 5)
        cache.removeAll()
        let cleared = cache.value(for: "new")
        #expect(cache.count == 0 && cache.totalCost == 0 && cleared == nil)
    }

    @Test func aDisabledCacheKeepsNoImages() {
        var cache = BoundedLRUCache<String, Int>(countLimit: 0, costLimit: 8)
        let inserted = cache.insert(1, for: "image", cost: 1)
        #expect(!inserted && cache.count == 0 && cache.totalCost == 0)
    }
}
