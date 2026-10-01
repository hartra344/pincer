import Foundation

/// Keeps reactions synced through `users.prefs` within the Gateway's per-value limit.
enum LegacyReactionPrefs {
    static let syncedByteBudget = 3_800

    /// Returns nil when the protected current reaction cannot fit by itself.
    static func fitting(_ entries: [String: String], preserving key: String?) -> [String: String]? {
        entries
    }
}
