import Foundation

/// Value snapshot of the parts of a chat's state that decide whether it may be dehydrated.
struct ChatResidencySnapshot: Equatable, Sendable {
    var isSelected = false
    var isRunning = false
    var hasActiveRun = false
    var compactionRunning = false
    var loadInFlight = false
    var isLoadingOlder = false
    var isLocatingReply = false
    var isSending = false
    var hasUnsent = false
    var isSetupTestChat = false

    /// Pinned chats are never dehydrated. Drafts are not a reason: they stay in memory and on disk.
    var isPinned: Bool {
        self.isSelected || self.isRunning || self.hasActiveRun || self.compactionRunning
            || self.loadInFlight || self.isLoadingOlder || self.isLocatingReply || self.isSending
            || self.hasUnsent || self.isSetupTestChat
    }
}

/// MRU bookkeeping and eviction choice for hydrated chat stores. Pure and unit-tested.
///
/// A memory-budgeted LRU: recently used chats stay hydrated up to `limit` chats **and** `budget`
/// items in total, so switching back to any of them is instant (#563). Many small chats fit; a
/// few huge ones push the oldest out sooner.
struct ChatResidency: Sendable {
    /// Warm (subscribed) chats always fit inside the limit.
    static let warmFloor = 4
    #if os(iOS)
    static let defaultLimit = 8
    /// Items held across hydrated chats (about 2.5 full iOS windows).
    static let defaultBudget = 3_000
    #else
    static let defaultLimit = 24
    /// Items held across hydrated chats (about 4 full macOS windows).
    static let defaultBudget = 12_000
    #endif

    var limit: Int
    var budget: Int
    private(set) var stamps: [String: UInt64] = [:]
    private var clock: UInt64 = 0

    init(limit: Int = ChatResidency.defaultLimit, budget: Int = ChatResidency.defaultBudget) {
        self.limit = max(0, limit)
        self.budget = max(0, budget)
    }

    /// Limit to enforce under memory pressure: warm chats on a warning, pinned-only when critical.
    static func pressureLimit(critical: Bool, base: Int = defaultLimit) -> Int {
        critical ? 0 : min(base, warmFloor)
    }

    mutating func touch(_ key: String) {
        self.clock += 1
        self.stamps[key] = self.clock
    }

    mutating func forget(_ key: String) {
        self.stamps[key] = nil
    }

    /// Unpinned hydrated keys to drop, least recent first, so that at most `limit` chats stay hydrated
    /// (pinned ones included; pinned chats are never dropped, so they may exceed it), and their `costs`
    /// (items held; a missing key costs nothing) add up to at most `budget`. Never-touched keys count as oldest.
    func victims(hydrated: Set<String>, pinned: Set<String>, limit: Int? = nil,
                 costs: [String: Int] = [:], budget: Int? = nil) -> [String] {
        let cap = max(0, limit ?? self.limit)
        let candidates = hydrated.subtracting(pinned).sorted { a, b in
            let sa = self.stamps[a] ?? 0, sb = self.stamps[b] ?? 0
            return sa != sb ? sa < sb : a < b
        }
        let allowed = max(cap, hydrated.intersection(pinned).count)
        var count = hydrated.count > allowed ? hydrated.count - allowed : 0
        let maxCost = max(0, budget ?? self.budget)
        var total = hydrated.reduce(0) { $0 + (costs[$1] ?? 0) }
        for key in candidates.prefix(count) { total -= costs[key] ?? 0 }
        while total > maxCost, count < candidates.count {
            total -= costs[candidates[count]] ?? 0
            count += 1
        }
        return Array(candidates.prefix(count))
    }
}
