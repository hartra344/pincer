/// A small least-recently-used cache with explicit entry and cost budgets. Owners provide the
/// cost of their values; rejected oversized values never displace useful cached entries.
public struct BoundedLRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var stamp: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public let countLimit: Int
    public let costLimit: Int
    public private(set) var totalCost = 0
    public var count: Int { self.entries.count }

    public init(countLimit: Int, costLimit: Int) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
    }

    public mutating func value(for key: Key) -> Value? {
        guard var entry = self.entries[key] else { return nil }
        self.clock &+= 1
        entry.stamp = self.clock
        self.entries[key] = entry
        return entry.value
    }

    @discardableResult
    public mutating func insert(_ value: Value, for key: Key, cost: Int) -> Bool {
        guard self.countLimit > 0, cost >= 0, cost <= self.costLimit else { return false }
        if let old = self.entries.removeValue(forKey: key) { self.totalCost -= old.cost }
        while self.entries.count >= self.countLimit || self.totalCost > self.costLimit - cost {
            guard let oldest = self.entries.min(by: { $0.value.stamp < $1.value.stamp }) else { break }
            self.entries.removeValue(forKey: oldest.key)
            self.totalCost -= oldest.value.cost
        }
        self.clock &+= 1
        self.entries[key] = Entry(value: value, cost: cost, stamp: self.clock)
        self.totalCost += cost
        return true
    }

    @discardableResult
    public mutating func removeValue(for key: Key) -> Value? {
        guard let entry = self.entries.removeValue(forKey: key) else { return nil }
        self.totalCost -= entry.cost
        return entry.value
    }

    public mutating func removeAll() {
        self.entries.removeAll(keepingCapacity: true)
        self.totalCost = 0
    }
}
