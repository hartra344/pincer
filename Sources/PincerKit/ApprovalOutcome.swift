import Foundation

/// What happened when Pincer tried to answer an exec approval (`exec.approval.resolve`), from a
/// notification action or the chat banner.
public enum ApprovalOutcome: Equatable, Sendable {
    /// The Gateway accepted the decision (an identical retry counts too).
    case resolved
    /// This session already sent a decision for it (in flight or done), so nothing was sent again.
    case alreadyHandled
    /// Unknown or expired on the Gateway, or past `expiresAt`. Nothing ran.
    case expired
    /// Someone else answered first (another device, a channel, the Control UI).
    case answeredElsewhere(decision: String?)
    /// `allow-always` isn't in the request's `allowedDecisions`; the approval is still pending.
    case allowAlwaysUnavailable
    /// Timeout, not connected, connection closed or `UNAVAILABLE`; the approval is still pending.
    case unreachable
    /// Missing `operator.approvals`, `FORBIDDEN` or another auth error.
    case notPermitted
    /// The notification names a gateway that's no longer saved. Nothing was sent.
    case unknownGateway
    /// Any other Gateway error, with its message.
    case failed(String)

    static let notFoundReason = "APPROVAL_NOT_FOUND"
    static let alreadyResolvedReason = "APPROVAL_ALREADY_RESOLVED"
    static let allowAlwaysUnavailableReason = "APPROVAL_ALLOW_ALWAYS_UNAVAILABLE"

    /// Maps an `exec.approval.resolve` failure to an outcome (see openclaw `src/infra/approval-errors.ts`).
    public static func classify(_ error: Error) -> ApprovalOutcome {
        guard let error = error as? GatewayError else {
            if error is CancellationError || error is URLError { return .unreachable }
            return .failed(error.localizedDescription)
        }
        switch error {
        case .timeout, .notConnected, .closed:
            return .unreachable
        case let .rpc(code, message, details):
            let reason = details?["reason"]?.string
            let lower = message.lowercased()
            if reason == Self.notFoundReason || lower.contains("expired or not found") || lower.contains("unknown or expired") {
                return .expired
            }
            if reason == Self.alreadyResolvedReason || lower.contains("already resolved") {
                return .answeredElsewhere(decision: details?["decision"]?.string)
            }
            if reason == Self.allowAlwaysUnavailableReason || lower.contains("allow-always is unavailable") {
                return .allowAlwaysUnavailable
            }
            let codes = [code.uppercased(), (details?["code"]?.string ?? "").uppercased()]
            if codes.contains("UNAVAILABLE") { return .unreachable }
            if codes.contains(where: { ["FORBIDDEN", "UNAUTHORIZED", "NOT_PAIRED", "PERMISSION_DENIED"].contains($0) })
                || details?["missingScope"] != nil
                || lower.contains("missing scope") || lower.contains("operator.approvals")
            {
                return .notPermitted
            }
            return .failed(message)
        case let .invalidURL(text), let .insecureURL(text), let .protocolViolation(text):
            return .failed(text)
        }
    }

    /// The Gateway no longer has it pending, so the banner and notifications go.
    public var removesApproval: Bool {
        switch self {
        case .resolved, .expired, .answeredElsewhere: true
        default: false
        }
    }

    /// Text for the follow-up notification, or nil when none is posted (success, or nothing new to say).
    /// Never contains the command.
    public func followUpBody(gatewayName: String?) -> String? {
        let name = gatewayName ?? "the gateway"
        switch self {
        case .resolved, .alreadyHandled: return nil
        case .expired: return "That approval expired. Nothing was run."
        case let .answeredElsewhere(decision):
            switch decision {
            case "allow-once", "allow-always": return "Already allowed elsewhere."
            case "deny": return "Already denied elsewhere."
            default: return "Already answered elsewhere."
            }
        case .allowAlwaysUnavailable: return "Always allow isn't available for this command."
        case .unreachable: return "Couldn't reach \(name) — the command is still waiting."
        case .notPermitted: return "This device can't approve commands on \(name). Open Pincer for details."
        case .unknownGateway: return "This gateway is no longer in Pincer."
        case let .failed(message): return Notifier.clip(message)
        }
    }

    /// The follow-up's category: the approval categories keep the actions for a retry, `reply` has none.
    /// `original` is the category of the notification that was acted on.
    public func followUpCategory(original: String) -> String {
        switch self {
        case .allowAlwaysUnavailable: return Notifier.approvalOnceCategory
        case .unreachable: return original == Notifier.approvalOnceCategory ? Notifier.approvalOnceCategory : Notifier.approvalCategory
        default: return Notifier.replyCategory
        }
    }

    /// Short text for the chat banner or `lastError`, for outcomes that leave something to tell.
    public func inAppMessage(gatewayName: String) -> String? {
        switch self {
        case .resolved, .alreadyHandled, .expired, .answeredElsewhere: nil
        default: self.followUpBody(gatewayName: gatewayName)
        }
    }
}
