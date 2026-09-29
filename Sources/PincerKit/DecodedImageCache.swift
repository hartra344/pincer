import CoreGraphics

/// LRU cache of decoded images, bounded by decoded bytes rather than image count.
struct DecodedImageCache {
    private struct Entry {
        var image: CGImage?
        var cost: Int
        var stamp: Int
    }

    private var entries: [String: Entry] = [:]
    private var clock = 0
    private(set) var totalBytes = 0
    var byteLimit: Int
    /// Keys that are never evicted (images currently on screen); the budget may be exceeded to honour this.
    var protectedKeys: Set<String> = []

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    var count: Int { self.entries.count }

    func contains(_ key: String) -> Bool { self.entries[key] != nil }

    func peek(_ key: String) -> CGImage? { self.entries[key]?.image }

    mutating func value(for key: String) -> CGImage? {
        guard var entry = self.entries[key] else { return nil }
        self.clock += 1
        entry.stamp = self.clock
        self.entries[key] = entry
        return entry.image
    }

    /// Returns the keys evicted to make room. The new entry is kept even if it alone exceeds the limit.
    @discardableResult
    mutating func insert(_ image: CGImage, for key: String) -> [String] {
        self.insert(image: image, cost: image.bytesPerRow * image.height, for: key)
    }

    /// Cost-only entry, for tests that don't want to allocate real images.
    @discardableResult
    mutating func insert(cost: Int, for key: String) -> [String] {
        self.insert(image: nil, cost: cost, for: key)
    }

    @discardableResult
    mutating func remove(_ key: String) -> Bool {
        guard let entry = self.entries.removeValue(forKey: key) else { return false }
        self.totalBytes -= entry.cost
        return true
    }

    /// Evicts least-recently-used entries until at most `bytes` remain. Returns the evicted keys.
    @discardableResult
    mutating func trim(toBytes bytes: Int) -> [String] {
        var evicted: [String] = []
        guard self.totalBytes > bytes else { return evicted }
        for (key, entry) in self.entries.sorted(by: { $0.value.stamp < $1.value.stamp }) where !self.protectedKeys.contains(key) {
            guard self.totalBytes > bytes else { break }
            self.entries.removeValue(forKey: key)
            self.totalBytes -= entry.cost
            evicted.append(key)
        }
        return evicted
    }

    @discardableResult
    mutating func removeAll(keepingProtected: Bool = false) -> [String] {
        let keys = self.entries.keys.filter { !keepingProtected || !self.protectedKeys.contains($0) }
        for key in keys { self.remove(key) }
        return keys
    }

    private mutating func insert(image: CGImage?, cost: Int, for key: String) -> [String] {
        if let old = self.entries[key] { self.totalBytes -= old.cost }
        self.clock += 1
        self.entries[key] = Entry(image: image, cost: cost, stamp: self.clock)
        self.totalBytes += cost
        guard self.totalBytes > self.byteLimit, self.entries.count > 1 else { return [] }
        // The entry just inserted has the highest stamp, so it is evicted last; stop before it.
        var evicted: [String] = []
        for (other, entry) in self.entries.sorted(by: { $0.value.stamp < $1.value.stamp }) where other != key && !self.protectedKeys.contains(other) {
            guard self.totalBytes > self.byteLimit else { break }
            self.entries.removeValue(forKey: other)
            self.totalBytes -= entry.cost
            evicted.append(other)
        }
        return evicted
    }
}
