import Foundation

/// What a Gateway's agents may ask this device for once the user opts into device mode.
public enum DeviceCapability: String, CaseIterable, Codable, Sendable, Identifiable {
    case location, device, calendar, contacts, reminders, motion
    /// Apple Health summaries: today's aggregates computed on the device (upstream `health`).
    case health
    /// Read-only Apple Health queries on request (Pincer-only `pincer.health.query`, #1084).
    case healthData

    public var id: String { self.rawValue }

    /// Whether this device can ever answer it; Motion & fitness and Apple Health are iPhone/iPad only.
    public var isSupported: Bool {
        #if os(macOS)
        self != .motion && self != .health && self != .healthData
        #else
        true
        #endif
    }

    /// Whether the node connect reports an OS permission for it. HealthKit hides read denial, and
    /// upstream's iOS node reports no `health` permission either.
    public var reportsPermission: Bool { self != .health && self != .healthData }

    /// The only commands this capability ever declares.
    public var commands: [String] {
        switch self {
        case .location: ["location.get"]
        case .device: ["device.info", "device.status"]
        case .calendar: ["calendar.events"]
        case .contacts: ["contacts.search"]
        case .reminders: ["reminders.list"]
        case .motion: ["motion.activity", "motion.pedometer"]
        case .health: [HealthSummary.command]
        case .healthData: [HealthQuery.command]
        }
    }
}

/// The allowlist of commands a node connection may declare, and the denylist that is never declared.
public enum DeviceModePolicy {
    public static let allowedCommands: Set<String> = Set(DeviceCapability.allCases.flatMap(\.commands))

    private static let forbiddenPrefixes = [
        "camera.", "screen.", "system.", "browser.", "computer.", "files.", "file.", "talk.", "canvas.",
        "sms.", "health.", "photos.", "watch.", "pincer.",
    ]
    private static let forbiddenExact: Set<String> = ["device.apps", "chat.push"]
    /// The two read-only Health commands in otherwise forbidden families: no Health writes, no other `pincer.*`.
    private static let permittedExact: Set<String> = [HealthSummary.command, HealthQuery.command]

    /// Whether `command` is in a family Pincer never declares (camera, screen, system, files, writes…).
    public static func isForbidden(_ command: String) -> Bool {
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.permittedExact.contains(name) { return false }
        if self.forbiddenExact.contains(name) || name.hasSuffix(".add") { return true }
        return self.forbiddenPrefixes.contains { name.hasPrefix($0) }
    }

    /// Sorted commands for the supported `caps`, filtered through the allowlist and denylist.
    /// `supported` defaults to this platform; checks on a Mac pass iPhone-only capabilities to a fake handler.
    public static func declaredCommands(
        for caps: Set<DeviceCapability>, supported: (DeviceCapability) -> Bool = { $0.isSupported }) -> [String]
    {
        Set(caps.filter(supported).flatMap(\.commands))
            .filter { !self.isForbidden($0) && self.allowedCommands.contains($0) }
            .sorted()
    }
}

/// Per-Gateway device mode choice. Off by default; location is the only capability checked at first.
public struct DeviceModeSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var capabilities: Set<DeviceCapability> = [.location]

    public init(enabled: Bool = false, capabilities: Set<DeviceCapability> = [.location]) {
        self.enabled = enabled
        self.capabilities = capabilities
    }

    static func key(_ gatewayId: UUID) -> String { "pincer.deviceMode.\(gatewayId.uuidString)" }

    public static func load(gatewayId: UUID, defaults: UserDefaults) -> DeviceModeSettings {
        guard let data = defaults.data(forKey: self.key(gatewayId)),
              let settings = try? JSONDecoder().decode(DeviceModeSettings.self, from: data)
        else { return DeviceModeSettings() }
        return settings.sanitized()
    }

    public func save(gatewayId: UUID, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key(gatewayId))
        }
    }

    /// Without capabilities this device can't answer.
    func sanitized(_ supported: (DeviceCapability) -> Bool = { $0.isSupported }) -> DeviceModeSettings {
        var copy = self
        copy.capabilities = self.capabilities.filter(supported)
        return copy
    }

    /// Nothing while device mode is off.
    public var declaredCommands: [String] { self.declaredCommands() }

    public func declaredCommands(supported: (DeviceCapability) -> Bool = { $0.isSupported }) -> [String] {
        self.enabled ? DeviceModePolicy.declaredCommands(for: self.capabilities, supported: supported) : []
    }
}

public enum DeviceNodeResult: Sendable, Equatable {
    case ok(payloadJSON: String)
    case failure(code: String, message: String)
}

/// A `node.invoke.request` the Gateway sent for a command this device declared.
public struct DeviceNodeInvoke: Sendable, Equatable {
    public let id: String
    public let nodeId: String
    public let command: String
    public let paramsJSON: String?
    public let timeoutMs: Int?

    public init(id: String, nodeId: String, command: String, paramsJSON: String? = nil, timeoutMs: Int? = nil) {
        self.id = id
        self.nodeId = nodeId
        self.command = command
        self.paramsJSON = paramsJSON
        self.timeoutMs = timeoutMs
    }
}

/// Implemented by PincerUI (real device APIs) and by tests/checks (fakes). Called off the main actor.
public protocol DeviceNodeHandler: Sendable {
    func permissions(for caps: Set<DeviceCapability>) async -> [String: Bool]
    /// Shows the OS permission prompt (called from the UI when a capability is switched on).
    func requestAccess(for cap: DeviceCapability) async -> Bool
    /// Only ever called for declared commands.
    func handle(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult
}
