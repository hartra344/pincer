import Foundation

/// A saved Gateway connection. Non-secret fields persist in UserDefaults;
/// the shared secret and paired device token live in the Keychain.
public struct GatewayProfile: Codable, Identifiable, Hashable, Sendable {
    public enum AuthMode: String, Codable, CaseIterable, Sendable {
        /// Tailscale Serve identity or private-ingress `auth.mode: none`.
        case none
        case token
        case password

        public var label: String {
            switch self {
            case .none: "Tailscale identity / none"
            case .token: "Gateway token"
            case .password: "Gateway password"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var url: String
    public var authMode: AuthMode
    /// Optional SHA-256 fingerprint (hex) of the Gateway's TLS leaf certificate.
    public var tlsFingerprint: String?

    public init(id: UUID = UUID(), name: String, url: String, authMode: AuthMode, tlsFingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.authMode = authMode
        self.tlsFingerprint = tlsFingerprint
    }

    public var initials: String {
        let words = self.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "OC" : letters.uppercased()
    }

    /// Validated WebSocket URL. `ws://` is only accepted for loopback, private LAN and
    /// Tailscale (100.64.0.0/10, *.ts.net) hosts so credentials never cross the internet in cleartext.
    public func resolvedURL() throws -> URL {
        var raw = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") {
            raw = (raw.hasSuffix(".ts.net") || raw.contains(".ts.net:") || raw.contains(".ts.net/"))
                ? "wss://\(raw)" : "ws://\(raw)"
        }
        raw = raw.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw GatewayError.invalidURL(self.url)
        }
        guard scheme == "ws" || scheme == "wss" else { throw GatewayError.invalidURL(self.url) }
        if scheme == "ws", !Self.isPrivateHost(host) {
            throw GatewayError.insecureURL(host)
        }
        return url
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return host.hasPrefix("fd7a:115c:a1e0") }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // Tailscale CGNAT range
        default: return false
        }
    }

    // MARK: Keychain-backed secrets

    public var secret: String? {
        get { Keychain.get("secret.\(self.id.uuidString)") }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, for: "secret.\(self.id.uuidString)")
            } else {
                Keychain.delete("secret.\(self.id.uuidString)")
            }
        }
    }

    var deviceToken: String? {
        get { Keychain.get("deviceToken.\(self.id.uuidString)") }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, for: "deviceToken.\(self.id.uuidString)")
            } else {
                Keychain.delete("deviceToken.\(self.id.uuidString)")
            }
        }
    }

    public func forgetDeviceToken() {
        self.deviceToken = nil
    }

    public func forgetCredentials() {
        self.secret = nil
        self.deviceToken = nil
    }
}

public enum GatewayProfileStore {
    private static let key = "pincer.gatewayProfiles.v1"

    public static func load() -> [GatewayProfile] {
        guard let data = UserDefaults.standard.data(forKey: self.key),
              let profiles = try? JSONDecoder().decode([GatewayProfile].self, from: data)
        else { return [] }
        return profiles
    }

    public static func save(_ profiles: [GatewayProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: self.key)
        }
    }
}
