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

    /// What Pincer asks the Gateway to allow.
    public enum AccessLevel: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Read, chat and approvals.
        case standard
        /// Also `operator.admin`, which the Gateway requires to change its config and plugins.
        case admin

        public var id: String { self.rawValue }
        public var label: String {
            switch self {
            case .standard: "Chat & Approvals"
            case .admin: "Full Management"
            }
        }

        public var detail: String {
            switch self {
            case .standard: "Chat, read history and answer approvals. Gateway settings are read-only."
            case .admin: "Also change the Gateway's settings and plugins. The Gateway host approves this device again."
            }
        }
    }

    public var id: UUID
    public var name: String
    public var url: String
    public var authMode: AuthMode
    /// Optional SHA-256 fingerprint (hex) of the Gateway's TLS leaf certificate.
    public var tlsFingerprint: String?
    /// Standard by default, so Pincer stays read/write/approvals-only unless asked.
    public var access: AccessLevel

    public init(id: UUID = UUID(), name: String, url: String, authMode: AuthMode, tlsFingerprint: String? = nil,
                access: AccessLevel = .standard)
    {
        self.id = id
        self.name = name
        self.url = url
        self.authMode = authMode
        self.tlsFingerprint = tlsFingerprint
        self.access = access
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, authMode, tlsFingerprint, access
        /// Before access levels: a Bool for "also request admin".
        case manageSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(String.self, forKey: .url)
        self.authMode = try container.decode(AuthMode.self, forKey: .authMode)
        self.tlsFingerprint = try container.decodeIfPresent(String.self, forKey: .tlsFingerprint)
        if let access = try container.decodeIfPresent(AccessLevel.self, forKey: .access) {
            self.access = access
        } else {
            self.access = try container.decodeIfPresent(Bool.self, forKey: .manageSettings) == true ? .admin : .standard
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.url, forKey: .url)
        try container.encode(self.authMode, forKey: .authMode)
        try container.encodeIfPresent(self.tlsFingerprint, forKey: .tlsFingerprint)
        try container.encode(self.access, forKey: .access)
    }

    /// Scopes requested on connect.
    public var requestedScopes: [String] {
        self.access == .admin ? GatewayConnection.scopes + [GatewayConnection.adminScope] : GatewayConnection.scopes
    }

    /// The built-in demo, which runs a simulated Gateway on the device.
    public var isDemo: Bool { self.url == DemoGateway.url }

    public static func demo() -> GatewayProfile {
        GatewayProfile(name: "Demo", url: DemoGateway.url, authMode: .none)
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

/// Saved gateways live in the App Group's defaults so the Share extension can list them.
/// Lists saved before the App Group existed are copied over from the app's own defaults once.
public enum GatewayProfileStore {
    static let key = "pincer.gatewayProfiles.v1"

    public static func load(
        from defaults: UserDefaults = SharedContainer.defaults,
        legacy: UserDefaults = .standard) -> [GatewayProfile]
    {
        if let data = defaults.data(forKey: self.key) {
            return (try? JSONDecoder().decode([GatewayProfile].self, from: data)) ?? []
        }
        guard defaults !== legacy, let data = legacy.data(forKey: self.key),
              let profiles = try? JSONDecoder().decode([GatewayProfile].self, from: data)
        else { return [] }
        defaults.set(data, forKey: self.key)
        return profiles
    }

    public static func save(_ profiles: [GatewayProfile], to defaults: UserDefaults = SharedContainer.defaults) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: self.key)
        }
    }
}
