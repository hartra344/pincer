import Foundation

/// A Gateway-rejected synced preference as it appears on the Gateway Health page.
public struct RejectedPrefHealthRow: Hashable, Identifiable, Sendable {
    public enum Feature: String, Hashable, Sendable {
        case serverNames, chatIcons, chatColors, groups, chatOrder, groupIcons
        case reactions, healthDismissals, avatars, bookmarks, other
    }

    /// The preference key is stable across refreshes and identifies one rejected map.
    public let id: String
    public let feature: Feature
    public let message: String

    private init(id: String, feature: Feature, message: String) {
        self.id = id
        self.feature = feature
        self.message = message
    }

    /// Builds stable Health rows from the active Gateway rejection map.
    public static func rows(from rejectedPrefs: [String: String]) -> [RejectedPrefHealthRow] {
        rejectedPrefs.keys.sorted().compactMap { key in
            guard let message = rejectedPrefs[key] else { return nil }
            return RejectedPrefHealthRow(id: key, feature: Self.feature(for: key), message: message)
        }
    }

    private static func feature(for key: String) -> Feature {
        switch key {
        case GatewayStore.serverNamesPref: .serverNames
        case GatewayStore.chatIconsPref: .chatIcons
        case GatewayStore.chatColorsPref: .chatColors
        case GatewayStore.groupsPref: .groups
        case GatewayStore.chatOrderPref: .chatOrder
        case GatewayStore.groupIconsPref: .groupIcons
        case Reactions.prefKey: .reactions
        case GatewayStore.healthDismissalsPref: .healthDismissals
        case AvatarPreferences.prefKey: .avatars
        default:
            key.hasPrefix("pincer.bookmarks.") ? .bookmarks : .other
        }
    }
}

extension GatewayStore {
    /// One sorted row per currently rejected preference, including bookmark shards.
    public var rejectedPrefHealthRows: [RejectedPrefHealthRow] {
        RejectedPrefHealthRow.rows(from: self.rejectedPrefs)
    }
}
