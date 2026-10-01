import Foundation

/// Keeps reactions synced through `users.prefs` within the Gateway's per-value limit.
package enum LegacyReactionPrefs {
    package static let syncedByteBudget = 3_800

    /// Returns nil when the protected current reaction cannot fit by itself.
    package static func fitting(_ entries: [String: String], preserving key: String?) -> [String: String]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        func quotedSize(_ value: String) -> Int {
            // A string has the same JSON escaping inside a dictionary as it does on its own.
            (try? encoder.encode(value).count) ?? Int.max
        }

        var fitted = entries
        var encodedSize = 2 + max(0, fitted.count - 1) // braces and commas
        var entrySizes: [String: Int] = [:]
        for (entryKey, value) in entries {
            let keyBytes = quotedSize(entryKey)
            let valueBytes = quotedSize(value)
            guard keyBytes < Int.max, valueBytes < Int.max else { return nil }
            let size = keyBytes + 1 + valueBytes // key, colon, value
            entrySizes[entryKey] = size
            encodedSize += size
        }
        guard let protectedSize = key.flatMap({ entrySizes[$0] }) else {
            if encodedSize <= self.syncedByteBudget { return fitted }
            // A missing protected key is already deleted; it must never be reintroduced.
            return self.evictToFit(&fitted, entrySizes: entrySizes, startingSize: encodedSize, preserving: nil)
        }
        guard protectedSize + 2 <= self.syncedByteBudget else { return nil }
        guard encodedSize > self.syncedByteBudget else { return fitted }
        return self.evictToFit(&fitted, entrySizes: entrySizes, startingSize: encodedSize, preserving: key)
    }

    private static func evictToFit(
        _ entries: inout [String: String], entrySizes: [String: Int], startingSize: Int, preserving key: String?
    ) -> [String: String]? {
        var encodedSize = startingSize
        // There are no timestamps on legacy reaction entries. A stable key order makes eviction
        // repeatable across devices without claiming that lexical order represents age.
        for candidate in entries.keys.filter({ $0 != key }).sorted() where encodedSize > self.syncedByteBudget {
            guard let size = entrySizes[candidate] else { continue }
            encodedSize -= size + (entries.count > 1 ? 1 : 0)
            entries.removeValue(forKey: candidate)
        }
        return encodedSize <= self.syncedByteBudget ? entries : nil
    }
}
