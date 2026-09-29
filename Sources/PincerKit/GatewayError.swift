import Foundation

/// One reading of the Gateway's authorization / availability failures, shared by every page.
///
/// Upstream (`packages/gateway-protocol/src/gateway-error-details.ts`) rejects a call with top-level
/// `FORBIDDEN` (or `INVALID_REQUEST`) and `details: { code: "MISSING_SCOPE", missingScope, requiredScopes }`;
/// older Gateways only send the message `missing scope: <scope>`. A bare `FORBIDDEN` (a role refusal)
/// names no scope, so it's *not* a missing scope. There's no dedicated unknown-method code upstream:
/// it's `INVALID_REQUEST` "unknown method: …". `UNKNOWN_METHOD` / `METHOD_NOT_FOUND` are accepted too.
extension GatewayError {
    static let missingScopeCode = "MISSING_SCOPE"

    /// The device lacks an operator scope: `MISSING_SCOPE` as the code or in `details`, the legacy
    /// `missing scope` message, or a `FORBIDDEN` / `INVALID_REQUEST` whose message names an `operator.*` scope.
    static func isMissingScope(_ error: Error) -> Bool {
        guard case let .rpc(code, message, details) = error as? GatewayError else { return false }
        if code == self.missingScopeCode || details?["code"]?.text == self.missingScopeCode { return true }
        guard code == "FORBIDDEN" || code == "INVALID_REQUEST" else { return false }
        let lower = message.lowercased()
        return lower.contains("missing scope") || lower.contains("operator.")
    }

    /// The scope the Gateway said was missing (`missingScope`, or `scope`), if it named one.
    static func missingScope(_ error: Error) -> String? {
        guard case let .rpc(_, _, details) = error as? GatewayError else { return nil }
        return details?["missingScope"]?.text ?? details?["scope"]?.text
    }

    /// The Gateway doesn't have the method.
    static func isUnknownMethod(_ error: Error) -> Bool {
        guard case let .rpc(code, message, _) = error as? GatewayError else { return false }
        return code == "UNKNOWN_METHOD" || code == "METHOD_NOT_FOUND" || message.lowercased().contains("unknown method")
    }

    /// `FORBIDDEN` that isn't about a scope this device could get (a role refusal).
    static func isForbidden(_ error: Error) -> Bool {
        guard case let .rpc(code, _, _) = error as? GatewayError else { return false }
        return code == "FORBIDDEN" && !self.isMissingScope(error)
    }

    /// Unknown method, or a role refusal.
    static func isUnavailable(_ error: Error) -> Bool {
        self.isUnknownMethod(error) || self.isForbidden(error)
    }

    /// How a failed call reads to the user, before it's put into words.
    public enum Failure: Equatable, Sendable {
        /// The device lacks an operator scope; `scope` when the Gateway named it.
        case missingScope(scope: String?)
        /// The Gateway doesn't have the method.
        case unsupported
        /// Anything else: the Gateway's own message, or the error's description.
        case message(String)
    }

    /// Classifies a failed call: missing scope, unsupported method, or the Gateway's message.
    public static func classify(_ error: Error) -> Failure {
        if self.isMissingScope(error) { return .missingScope(scope: self.missingScope(error) ?? self.scopeHint(in: error)) }
        if self.isUnknownMethod(error) { return .unsupported }
        guard case let .rpc(_, message, _) = error as? GatewayError else { return .message(error.localizedDescription) }
        return .message(message)
    }

    /// The default missing-scope sentence, naming the scope when the Gateway did.
    public static func missingScopeMessage(for error: Error) -> String {
        guard let scope = self.missingScope(error) ?? self.scopeHint(in: error) else {
            return L("Your device is missing a scope this needs. Approve it again from the Gateway with that scope.")
        }
        return L("Your device doesn't have the `\(scope)` scope. Approve it again from the Gateway with that scope.")
    }

    /// An `operator.*` scope named in the message ("missing scope: operator.read").
    private static func scopeHint(in error: Error) -> String? {
        guard case let .rpc(_, message, _) = error as? GatewayError,
              let range = message.range(of: #"operator\.[a-z0-9_.-]*[a-z0-9]"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(message[range])
    }

    /// Pages pass `unavailable` from `L(…)` so the feature phrase is localized too.
    ///
    /// `scope` (a page's own sentence, else the default) for a missing scope; for an unknown method,
    /// "This Gateway doesn't support <unavailable> yet." when a feature phrase is given; otherwise the
    /// Gateway's own message, or the error's description when it wasn't an RPC failure.
    static func message(for error: Error, scope: String? = nil, unavailable: String? = nil) -> String {
        if self.isMissingScope(error) { return scope ?? self.missingScopeMessage(for: error) }
        if let unavailable, self.isUnknownMethod(error) {
            return L("This Gateway doesn't support \(unavailable) yet.", comment: "The value is a feature phrase such as “device management”")
        }
        guard case let .rpc(_, message, _) = error as? GatewayError else { return error.localizedDescription }
        return message
    }
}
