import CryptoKit
import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Secrets (device key, gateway token/password,
/// paired device tokens) never touch UserDefaults or disk outside the Keychain.
public enum Keychain {
    static let service = "chat.pincer.gateway"

    /// Process-local store for headless checks (`PINCER_KEYCHAIN=memory`), so tests never
    /// touch or prompt for the real Keychain.
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

    public static func set(_ value: String, for account: String) {
        if let memory { memory[account] = value; return }
        guard let data = value.data(using: .utf8) else { return }
        self.delete(account)
        var query = self.baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Written into the group shared with the Share extension; reads search every group.
        if let group = SharedContainer.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement, query[kSecAttrAccessGroup as String] != nil {
            // Builds signed without the keychain-access-groups entitlement.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(query as CFDictionary, nil)
        }
        #if os(macOS)
        if status == errSecMissingEntitlement {
            // Unsigned development builds cannot use the data-protection keychain.
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemAdd(query as CFDictionary, nil)
        }
        #endif
        if status != errSecSuccess {
            NSLog("[Pincer] Keychain write failed for %@: %d", account, status)
        }
    }

    public static func get(_ account: String) -> String? {
        if let memory { return memory[account] }
        for query in self.readQueries(account) {
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let value = String(data: data, encoding: .utf8)
            {
                return value
            }
        }
        return nil
    }

    public static func delete(_ account: String) {
        if let memory { memory[account] = nil; return }
        for query in self.readQueries(account) {
            var deleteQuery = query
            deleteQuery.removeValue(forKey: kSecReturnData as String)
            deleteQuery.removeValue(forKey: kSecMatchLimit as String)
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    /// Rewrites existing items so they land in the shared access group (see `set`).
    static func moveToSharedGroup(_ accounts: [String]) {
        guard self.memory == nil, SharedContainer.keychainAccessGroup != nil else { return }
        for account in accounts {
            if let value = self.get(account) { self.set(value, for: account) }
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func readQueries(_ account: String) -> [[String: Any]] {
        var primary = self.baseQuery(account)
        primary[kSecReturnData as String] = true
        primary[kSecMatchLimit as String] = kSecMatchLimitOne
        #if os(macOS)
        var legacy = primary
        legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return [primary, legacy]
        #else
        return [primary]
        #endif
    }
}

/// Ed25519 identity that the Gateway pairs with. Mirrors the official Swift client:
/// deviceId = hex(sha256(rawPublicKey)), publicKey/signature are unpadded base64url.
public struct DeviceIdentity: Sendable {
    public let deviceId: String
    let privateKey: Curve25519.Signing.PrivateKey

    public var publicKeyBase64Url: String {
        Self.base64Url(self.privateKey.publicKey.rawRepresentation)
    }

    init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.deviceId = Self.deviceId(forPublicKey: privateKey.publicKey.rawRepresentation)
    }

    public func sign(_ payload: String) throws -> String {
        let signature = try self.privateKey.signature(for: Data(payload.utf8))
        return Self.base64Url(signature)
    }

    static let keychainAccount = "device.ed25519"

    public static func loadOrCreate() -> DeviceIdentity {
        if let existing = self.loadExisting() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        Keychain.set(key.rawRepresentation.base64EncodedString(), for: self.keychainAccount)
        return DeviceIdentity(privateKey: key)
    }

    /// The paired identity, without creating one. The Share extension uses this so it never
    /// shows up on the Gateway as a second, unapproved device.
    public static func loadExisting() -> DeviceIdentity? {
        guard let stored = Keychain.get(self.keychainAccount),
              let raw = Data(base64Encoded: stored),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { return nil }
        return DeviceIdentity(privateKey: key)
    }

    static func deviceId(forPublicKey raw: Data) -> String {
        SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Signed device-auth payload. Uses the `v2` layout that every current Gateway verifies
/// (the official Swift apps also still sign v2).
public enum DeviceAuthPayload {
    public static func v2(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int64,
        token: String?,
        nonce: String) -> String
    {
        [
            "v2",
            deviceId,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce,
        ].joined(separator: "|")
    }
}
