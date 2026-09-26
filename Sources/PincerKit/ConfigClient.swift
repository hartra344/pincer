import Foundation

/// One `config.get` result.
public struct ConfigSnapshot: Sendable, Equatable {
    /// The authored config after includes and env substitution, secrets redacted. (`config` in
    /// the response also carries runtime defaults, which would be written back as if the user set them.)
    public let config: JSONValue
    public let raw: String?
    public let path: String?
    public let hash: String?
    public let isValid: Bool
    public let issues: [ConfigIssue]
    public let warnings: [ConfigIssue]

    public init(response result: JSONValue) {
        self.config = result["resolved"] ?? result["sourceConfig"] ?? result["parsed"] ?? result["config"] ?? .object([:])
        self.raw = result["raw"]?.string
        self.path = result["path"]?.text
        self.hash = result["hash"]?.text
        self.isValid = result["valid"]?.bool ?? true
        self.issues = ConfigIssue.list(result["issues"])
        self.warnings = ConfigIssue.list(result["warnings"])
    }

    /// A committed write the Gateway couldn't finish applying (`details.persistedConfig`).
    init(config: JSONValue, hash: String?, previous: ConfigSnapshot?) {
        self.config = config
        self.raw = previous?.raw
        self.path = previous?.path
        self.hash = hash
        self.isValid = true
        self.issues = []
        self.warnings = previous?.warnings ?? []
    }
}

/// How a saved change took effect.
public enum ConfigApplyOutcome: Equatable, Sendable {
    case noChange
    case applied
    case restarting
    /// Saved, but the Gateway couldn't apply it yet.
    case savedNotApplied(String)

    public var message: String {
        switch self {
        case .noChange: "Nothing changed."
        case .applied: "Saved and applied."
        case .restarting: "Saved. The Gateway is restarting to apply it."
        case let .savedNotApplied(reason): "Saved, but not applied yet. \(reason)"
        }
    }

    public init(configWrite response: JSONValue) {
        if response["noop"]?.bool == true {
            self = .noChange
        } else if let restart = response["restart"], !restart.isNull, restart.bool != false {
            self = .restarting
        } else if response["sentinel"]?["payload"]?["stats"]?["requiresRestart"]?.bool == true {
            self = .restarting
        } else {
            self = .applied
        }
    }

    public init(pluginChange response: JSONValue) {
        self = response["restartRequired"]?.bool == true ? .restarting : .applied
    }
}

/// Why a config write failed, mapped once from the Gateway's error.
public enum ConfigWriteError: Error, Equatable, Sendable {
    /// The connection lacks `operator.admin`.
    case adminRequired
    /// Someone else changed the config since it was loaded (`baseHash` mismatch).
    case staleHash
    /// The Gateway rejected the config; issues carry the paths.
    case invalid([ConfigIssue])
    /// Saved, but not applied. The committed config comes along when the Gateway sends it.
    case notApplied(message: String, persisted: JSONValue?, hash: String?)
    case rateLimited(String)
    case other(String)

    public init(_ error: Error) {
        guard case let GatewayError.rpc(code, message, details) = error else {
            self = .other(error.localizedDescription)
            return
        }
        let text = message.lowercased()
        if details?["code"]?.string == "MISSING_SCOPE" || text.contains("missing scope: operator.admin") {
            self = .adminRequired
        } else if text.contains("base hash") || text.contains("config changed since last load") {
            self = .staleHash
        } else if code == "UNAVAILABLE" {
            let persisted = details?["persistedConfig"]
            self = .notApplied(message: message, persisted: persisted?["config"], hash: persisted?["hash"]?.text)
        } else if code == "RATE_LIMITED" || text.contains("rate limit") {
            self = .rateLimited(message)
        } else if let issues = details?["issues"], !ConfigIssue.list(issues).isEmpty {
            self = .invalid(ConfigIssue.list(issues))
        } else if text.hasPrefix("invalid config") {
            self = .invalid([ConfigIssue(path: "", message: message)])
        } else {
            self = .other(message)
        }
    }

    public var message: String {
        switch self {
        case .adminRequired:
            "Changing Gateway settings needs Full Management access. Turn it on under Connection, then approve this device on the Gateway host."
        case .staleHash:
            "The config changed on the Gateway since it was loaded."
        case let .invalid(issues):
            issues.count == 1 ? "The Gateway rejected the change: \(issues[0].message)" : "The Gateway rejected \(issues.count) values."
        case let .notApplied(message, _, _), let .rateLimited(message), let .other(message):
            message
        }
    }
}

/// Progress of one action (a save, a plugin change…), shown next to whatever started it.
public enum OperationState: Equatable, Sendable {
    case idle
    case running
    case failed(String)

    public var isRunning: Bool { self == .running }
    public var error: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// The Gateway protocol calls behind Gateway Settings. Nothing is written to files directly:
/// the Gateway validates, persists and hot-applies (or restarts) itself.
@MainActor
struct GatewayConfigClient {
    let connection: GatewayConnection

    enum Unsupported: Error { case method }

    func snapshot() async throws -> ConfigSnapshot {
        do {
            return ConfigSnapshot(response: try await self.connection.request("config.get", [:], timeout: 20))
        } catch let error where Self.isUnknownMethod(error) {
            throw Unsupported.method
        }
    }

    func schema() async -> ConfigSchema? {
        guard let result = try? await self.connection.request("config.schema", [:], timeout: 30) else { return nil }
        return ConfigSchema(response: result)
    }

    func patch(_ patch: JSONValue, replacePaths: [String], baseHash: String?, note: String?) async throws(ConfigWriteError) -> JSONValue {
        var params: [String: JSONValue] = ["raw": .string(patch.compactString())]
        if !replacePaths.isEmpty { params["replacePaths"] = JSONValue(replacePaths) }
        if let note { params["note"] = .string(note) }
        if let baseHash { params["baseHash"] = .string(baseHash) }
        return try await self.write("config.patch", params)
    }

    func apply(_ raw: String, baseHash: String?) async throws(ConfigWriteError) -> JSONValue {
        var params: [String: JSONValue] = ["raw": .string(raw), "note": "Pincer: Raw Config"]
        if let baseHash { params["baseHash"] = .string(baseHash) }
        return try await self.write("config.apply", params)
    }

    private func write(_ method: String, _ params: [String: JSONValue]) async throws(ConfigWriteError) -> JSONValue {
        do {
            return try await self.connection.request(method, .object(params), timeout: 60)
        } catch {
            throw ConfigWriteError(error)
        }
    }

    func plugins() async throws -> [PluginInfo] {
        do {
            let result = try await self.connection.request("plugins.list", [:], timeout: 20)
            return (result["plugins"]?.array ?? []).compactMap(PluginInfo.init)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error where Self.isUnknownMethod(error) {
            throw Unsupported.method
        }
    }

    func credentials(for pluginId: String) async -> [PluginCredential]? {
        guard let result = try? await self.connection.request("plugins.inspect", ["pluginId": .string(pluginId)]) else {
            return nil
        }
        return (result["credentials"]?.array ?? []).compactMap(PluginCredential.init)
    }

    func pluginChange(_ method: String, _ params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        try await self.connection.request(method, .object(params), timeout: timeout)
    }

    static func isUnknownMethod(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error else { return false }
        return code == "UNKNOWN_METHOD" || code == "METHOD_NOT_FOUND" || message.lowercased().contains("unknown method")
    }
}
