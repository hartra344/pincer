import Foundation

/// Device-local compact iOS header preference; never part of Gateway preferences.
package enum ChatHeaderAvatarSize: String, CaseIterable, Sendable {
    case small, large
    package static let defaultsKey = "pincer.chatHeaderAvatarSize"
    package init(normalizing rawValue: String) { self = Self(rawValue: rawValue) ?? .small }
    package static func load(from defaults: UserDefaults) -> Self {
        Self(normalizing: defaults.string(forKey: defaultsKey) ?? "")
    }
    package var avatarSize: Double { self == .small ? 48 : 64 }
    package var minimumReservation: Double { self == .small ? 44 : 60 }
}
