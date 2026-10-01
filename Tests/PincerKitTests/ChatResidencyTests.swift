import Testing
@testable import PincerKit

@Suite("Chat residency")
struct ChatResidencyTests {
    @Test func victimsAreLeastRecentBeyondLimit() {
        var r = ChatResidency(limit: 2)
        for k in ["a", "b", "c", "d"] { r.touch(k) }
        r.touch("a")
        #expect(r.victims(hydrated: ["a", "b", "c", "d"], pinned: []) == ["b", "c"])
    }

    @Test func pinnedNeverVictimsButCountAgainstLimit() {
        var r = ChatResidency(limit: 1)
        for k in ["a", "b", "c"] { r.touch(k) }
        #expect(r.victims(hydrated: ["a", "b", "c"], pinned: ["a"]) == ["b", "c"])
        #expect(r.victims(hydrated: ["a", "b", "c"], pinned: ["a"], limit: 2) == ["b"])
        #expect(r.victims(hydrated: ["a", "b", "c", "d"], pinned: ["a", "b", "x"], limit: 3) == ["d"])
        #expect(r.victims(hydrated: ["a", "b", "c"], pinned: ["a", "b", "c"]).isEmpty)
    }

    @Test func nothingEvictedWithinLimit() {
        var r = ChatResidency(limit: 3)
        for k in ["a", "b", "c"] { r.touch(k) }
        #expect(r.victims(hydrated: ["a", "b", "c"], pinned: []).isEmpty)
    }

    @Test func untouchedKeysAreOldestAndTieBreakIsStable() {
        var r = ChatResidency(limit: 1)
        r.touch("z")
        #expect(r.victims(hydrated: ["z", "x", "y"], pinned: []) == ["x", "y"])
    }

    @Test func forgetDropsStamp() {
        var r = ChatResidency(limit: 1)
        r.touch("a"); r.touch("b")
        r.forget("b")
        #expect(r.stamps["b"] == nil)
        #expect(r.victims(hydrated: ["a", "b"], pinned: []) == ["b"])
    }

    @Test func limitOverrideAndNegativeClamp() {
        var r = ChatResidency(limit: -5)
        #expect(r.limit == 0)
        r.touch("a"); r.touch("b")
        #expect(r.victims(hydrated: ["a", "b"], pinned: []) == ["a", "b"])
        #expect(r.victims(hydrated: ["a", "b"], pinned: [], limit: 1) == ["a"])
    }

    /// #563: recent chats stay resident within an item budget; past it the oldest go first.
    @Test func itemBudgetEvictsLeastRecentFirst() {
        var r = ChatResidency(limit: 10, budget: 1_000)
        for k in ["a", "b", "c", "d"] { r.touch(k) }
        let costs = ["a": 400, "b": 300, "c": 300, "d": 200]
        #expect(r.victims(hydrated: ["a", "b", "c", "d"], pinned: [], costs: costs) == ["a"])
        #expect(r.victims(hydrated: ["a", "b", "c", "d"], pinned: ["a"], costs: costs) == ["b"])
        #expect(r.victims(hydrated: ["b", "c", "d"], pinned: [], costs: costs).isEmpty)
        // Pinned chats are never dropped, even past the budget.
        #expect(r.victims(hydrated: ["a", "b"], pinned: ["a", "b"], costs: ["a": 5_000, "b": 5_000]).isEmpty)
        // The count limit and the budget both apply.
        #expect(r.victims(hydrated: ["a", "b", "c", "d"], pinned: [], limit: 3, costs: costs) == ["a"])
        #expect(r.victims(hydrated: ["a", "b", "c", "d"], pinned: [], limit: 1, costs: costs) == ["a", "b", "c"])
    }

    @Test func defaultsKeepManyRecentChatsResident() {
        #expect(ChatResidency.defaultLimit >= 8)
        var r = ChatResidency()
        let keys = (0..<ChatResidency.defaultLimit).map { "k\($0)" }
        for k in keys { r.touch(k) }
        let costs = Dictionary(uniqueKeysWithValues: keys.map { ($0, 150) })
        #expect(r.victims(hydrated: Set(keys), pinned: [], costs: costs).isEmpty)
    }

    @Test func pressureLimits() {
        #expect(ChatResidency.pressureLimit(critical: true) == 0)
        #expect(ChatResidency.pressureLimit(critical: false) == ChatResidency.warmFloor)
        #expect(ChatResidency.pressureLimit(critical: false, base: 2) == 2)
        #expect(ChatResidency.defaultLimit >= ChatResidency.warmFloor)
    }

    @Test func pinPredicate() {
        #expect(!ChatResidencySnapshot().isPinned)
        let flags: [WritableKeyPath<ChatResidencySnapshot, Bool>] = [
            \.isSelected, \.isRunning, \.hasActiveRun, \.compactionRunning, \.loadInFlight,
            \.isLoadingOlder, \.isLocatingReply, \.isSending, \.hasUnsent, \.isSetupTestChat,
        ]
        for f in flags {
            var s = ChatResidencySnapshot()
            s[keyPath: f] = true
            #expect(s.isPinned)
        }
    }
}
