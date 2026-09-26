import Foundation

/// Storage the app shares with its Share extension: the App Group's UserDefaults (saved
/// gateways, last share target) and a Keychain access group (device key, secrets, device tokens).
///
/// Both identifiers come from Info.plist keys that the Xcode targets fill in from their
/// entitlements. SwiftPM builds have neither and keep using per-process storage.
public enum SharedContainer {
    public static let appGroupInfoKey = "PincerAppGroup"
    public static let keychainGroupInfoKey = "PincerKeychainGroup"

    public static let appGroupId: String? = infoValue(appGroupInfoKey)
    public static let keychainAccessGroup: String? = infoValue(keychainGroupInfoKey)

    /// UserDefaults shared with extensions, or `.standard` when there's no App Group.
    public static var defaults: UserDefaults {
        appGroupId.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Records which Keychain group existing items were copied into, so it runs once per group.
    static let keychainMigrationKey = "pincer.keychainSharedGroup"

    /// Copies Keychain items written before the extension existed into the shared access group,
    /// so the extension signs in as the same, already-paired device. Only the app calls this:
    /// the extension never creates a device key of its own.
    public static func shareKeychainItems(for profiles: [GatewayProfile], defaults: UserDefaults = SharedContainer.defaults) {
        guard let group = keychainAccessGroup, defaults.string(forKey: keychainMigrationKey) != group else { return }
        Keychain.moveToSharedGroup(self.keychainAccounts(for: profiles))
        defaults.set(group, forKey: keychainMigrationKey)
    }

    public static func keychainAccounts(for profiles: [GatewayProfile]) -> [String] {
        [DeviceIdentity.keychainAccount] + profiles.flatMap { ["secret.\($0.id.uuidString)", "deviceToken.\($0.id.uuidString)"] }
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }
}
