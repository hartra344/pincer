import Foundation
import UniformTypeIdentifiers

// MARK: Approvals

public struct ExecApproval: Identifiable, Hashable, Sendable {
    public let id: String
    public let command: String
    public let cwd: String?
    public let sessionKey: String?
    public let agentId: String?
    public let warning: String?
    public let expiresAt: Date?
    /// `request.allowedDecisions`; nil from Gateways that don't send it, where every decision is offered.
    public let allowedDecisions: [String]?

    public init?(_ payload: JSONValue) {
        let request = payload["request"] ?? payload
        guard let id = payload["id"]?.text ?? request["id"]?.text else { return nil }
        self.id = id
        let argv = request["commandArgv"]?.array?.compactMap(\.string).joined(separator: " ")
        self.command = request["command"]?.text ?? request["systemRunPlan"]?["rawCommand"]?.text ?? argv ?? "(command)"
        self.cwd = request["cwd"]?.text ?? request["systemRunPlan"]?["cwd"]?.text
        self.sessionKey = request["sessionKey"]?.text ?? payload["sessionKey"]?.text
        self.agentId = request["agentId"]?.text ?? payload["agentId"]?.text
        self.warning = request["warningText"]?.text
        self.expiresAt = (payload["expiresAtMs"]?.double).map { Date(timeIntervalSince1970: $0 / 1000) }
        self.allowedDecisions = (request["allowedDecisions"] ?? payload["allowedDecisions"])?.array?.compactMap(\.string)
    }

    /// Whether "Always allow" may be offered.
    public var allowsAlways: Bool { self.allowedDecisions?.contains("allow-always") ?? true }

    public func isExpired(at date: Date = Date()) -> Bool {
        self.expiresAt.map { $0 <= date } ?? false
    }
}
