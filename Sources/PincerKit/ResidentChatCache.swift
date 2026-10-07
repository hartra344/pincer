import Foundation

/// A small LRU of per-chat values keyed by session key, bounded by count. Callers prune entries for chats
/// that left residency (dehydrated or gone).
public struct ResidentChatCache<Value> {
    /// The resident-chat limit (`ChatResidency.defaultLimit`: 24 macOS, 8 iOS).
    public static var defaultLimit: Int { ChatResidency.defaultLimit }

    public let limit: Int
    private var order: [String] = []
    private var values: [String: Value] = [:]

    public init(limit: Int = Self.defaultLimit) {
        self.limit = max(0, limit)
    }

    public var count: Int { self.order.count }

    /// Keys, least recent first.
    public var keys: [String] { self.order }

    /// The value without making it most recent.
    public func peek(_ key: String) -> Value? { self.values[key] }

    /// Inserts or replaces and makes it most recent; evicts least recent past `limit`. Returns evicted keys.
    @discardableResult
    public mutating func store(_ value: Value, for key: String) -> [String] {
        guard self.limit > 0 else { return [] }
        if let at = self.order.firstIndex(of: key) { self.order.remove(at: at) }
        self.order.append(key)
        self.values[key] = value
        var evicted: [String] = []
        while self.order.count > self.limit {
            let oldest = self.order.removeFirst()
            self.values.removeValue(forKey: oldest)
            evicted.append(oldest)
        }
        return evicted
    }

    /// Removes and returns the value (the open chat's live state is authoritative while it's open).
    public mutating func take(_ key: String) -> Value? {
        guard let value = self.values.removeValue(forKey: key) else { return nil }
        if let at = self.order.firstIndex(of: key) { self.order.remove(at: at) }
        return value
    }

    public mutating func removeAll(where shouldRemove: (String, Value) -> Bool) {
        for key in self.order {
            if let value = self.values[key], shouldRemove(key, value) { self.values.removeValue(forKey: key) }
        }
        self.order.removeAll { self.values[$0] == nil }
    }

    public mutating func removeAll() {
        self.order.removeAll()
        self.values.removeAll()
    }
}
