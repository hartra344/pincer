import Foundation

/// One plugin from `plugins.list`.
public struct PluginInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let version: String?
    public let origin: String?
    public let packageName: String?
    public let installed: Bool
    public let enabled: Bool
    /// `enabled`, `disabled`, `needs-setup`, `not-installed` or `error`.
    public let state: String
    /// Observed runtime state: `active`, `disabled`, `unloaded` or `service-failed`.
    public let runtimeState: String?
    public let error: String?
    public let removable: Bool
    public let kinds: [String]

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.name = json["name"]?.text ?? id
        self.description = json["description"]?.text
        self.version = json["version"]?.text
        self.origin = json["origin"]?.text
        self.packageName = json["packageName"]?.text
        self.installed = json["installed"]?.bool ?? true
        self.enabled = json["enabled"]?.bool ?? false
        self.state = json["state"]?.text ?? (self.enabled ? "enabled" : "disabled")
        self.runtimeState = json["runtime"]?["state"]?.text
        self.error = json["error"]?.text ?? json["runtime"]?["error"]?.text
        self.removable = json["removable"]?.bool ?? (self.origin != "bundled")
        self.kinds = json["kind"]?.array?.compactMap(\.text) ?? []
    }

    public var needsSetup: Bool { self.state == "needs-setup" }
    public var hasError: Bool { self.state == "error" || self.runtimeState == "service-failed" || self.error != nil }

    public var statusLabel: String {
        if self.hasError { return "Error" }
        switch self.state {
        case "needs-setup": return "Needs setup"
        case "not-installed": return "Not installed"
        case "enabled": return self.runtimeState == "active" || self.runtimeState == nil ? "On" : "Starting…"
        default: return "Off"
        }
    }

    /// Where this plugin's own settings live in the config.
    public var configPath: [String] { ["plugins", "entries", self.id, "config"] }
}

/// A credential a plugin says it needs (from `plugins.inspect`).
public struct PluginCredential: Identifiable, Hashable, Sendable {
    public let path: [String]
    public let label: String
    public let envVars: [String]
    public let placeholder: String?
    public let signupURL: URL?
    public let isRequired: Bool
    public var id: String { ConfigPath.string(self.path) }

    public init?(_ json: JSONValue) {
        let parts = json["path"]?.array ?? []
        // Paths through arrays can't be written with a merge patch; leave those to the raw editor.
        let path = parts.compactMap(\.string)
        guard !path.isEmpty, path.count == parts.count, let label = json["label"]?.text else { return nil }
        self.path = path
        self.label = label
        self.envVars = json["envVars"]?.array?.compactMap(\.text) ?? []
        self.placeholder = json["placeholder"]?.text
        self.signupURL = json["signupUrl"]?.text.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        self.isRequired = json["requiresCredential"]?.bool ?? false
    }
}

/// Where to install a plugin from.
public enum PluginSource: String, CaseIterable, Identifiable, Sendable {
    case clawhub
    case npm
    case official
    case git

    public var id: String { self.rawValue }
    public var label: String {
        switch self {
        case .clawhub: "ClawHub"
        case .npm: "npm"
        case .official: "Official"
        case .git: "Git"
        }
    }

    public var prompt: String {
        switch self {
        case .clawhub: "Package name, e.g. @openclaw/weather"
        case .npm: "npm spec, e.g. openclaw-plugin-foo@1.2.0"
        case .official: "Plugin ID, e.g. memory-lancedb"
        case .git: "Git URL, e.g. github:owner/repo"
        }
    }

    func params(_ spec: String) -> [String: JSONValue] {
        let spec = JSONValue.string(spec)
        switch self {
        case .clawhub: return ["source": "clawhub", "packageName": spec]
        case .npm: return ["source": "npm", "spec": spec]
        case .official: return ["source": "official", "pluginId": spec]
        case .git: return ["source": "git", "spec": spec]
        }
    }
}

/// A plugin change the Gateway wants confirmed before it goes ahead.
public struct PluginConfirmation: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// The plugin asks for new capabilities; retried with `acknowledgeCapabilities`.
        case capabilities(reviewToken: String)
        /// The install policy flagged the package; retried with `acknowledgeInstallPolicyWarning`.
        case installPolicy
    }

    public let id = UUID()
    public let kind: Kind
    public let message: String
    let retry: @MainActor @Sendable (_ acknowledgement: [String: JSONValue]) async -> Bool

    public var acknowledgement: [String: JSONValue] {
        switch self.kind {
        case let .capabilities(token): ["acknowledgeCapabilities": ["reviewToken": .string(token)]]
        case .installPolicy: ["acknowledgeInstallPolicyWarning": true]
        }
    }
}
