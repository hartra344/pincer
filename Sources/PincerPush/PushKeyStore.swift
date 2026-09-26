import Foundation
import Security

/// Per-gateway Web Push keys in the Keychain. When `PincerKeychainGroup` is set in Info.plist,
/// they go into that shared access group so the Notification Service Extension can decrypt.
public enum PushKeyStore {
    static let service = "chat.pincer.push"

    private static let memory: MemoryStore? =
        ProcessInfo.processInfo.environment["PINCER_KEYCHAIN"] == "memory" ? MemoryStore() : nil

    private final class MemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        subscript(key: String) -> String? {
            get { self.lock.withLock { self.values[key] } }
            set { self.lock.withLock { self.values[key] = newValue } }
        }
    }

    /// The shared access group, ignoring unexpanded build settings.
    public static var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PincerKeychainGroup") as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }

    public static func keys(for gatewayId: UUID) -> WebPushKeys? {
        self.read(self.account(gatewayId)).flatMap(WebPushKeys.init(stored:))
    }

    public static func loadOrCreate(for gatewayId: UUID) -> WebPushKeys {
        if let existing = self.keys(for: gatewayId) { return existing }
        let keys = WebPushKeys.generate()
        self.write(keys.stored, account: self.account(gatewayId))
        return keys
    }

    public static func delete(for gatewayId: UUID) {
        let account = self.account(gatewayId)
        if let memory { memory[account] = nil; return }
        SecItemDelete(self.query(account, group: nil) as CFDictionary)
    }

    private static func account(_ gatewayId: UUID) -> String { "webpush.\(gatewayId.uuidString)" }

    private static func query(_ account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func write(_ value: String, account: String) {
        if let memory { memory[account] = value; return }
        SecItemDelete(self.query(account, group: nil) as CFDictionary)
        for group in [self.accessGroup, nil] {
            var query = self.query(account, group: group)
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return }
            // Unsigned builds lack the shared group; the app still works, but the extension can't decrypt.
            if status != errSecMissingEntitlement || group == nil {
                NSLog("[Pincer] Push key write failed: %d", status)
                return
            }
        }
    }

    private static func read(_ account: String) -> String? {
        if let memory { return memory[account] }
        var query = self.query(account, group: nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
