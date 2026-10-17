import Foundation

/// The demo's portals, with the Gateway's scoping: "Studio clock" is a host portal the coder's main chat
/// opened with a `portal` tool call (see `studioClockExchange`); "Build dashboard" is owned by the
/// retry-fix chat, whose session has an attached environment (`environments.session.status`,
/// `portal.session.list`, `portal.session.close`). Their URLs use the `demo-portal` scheme, which the UI
/// serves from memory (no network).
extension DemoGateway {
    static let portalMethods = ["portal.list", "portal.close", "environments.session.status", "portal.session.list",
                                "portal.session.close"]

    static let demoPortalId = "demo-portal-studio-clock"
    static let demoPortalPublicURL = "demo-portal://studio-clock/"
    static let demoPortalLoadURL = "demo-portal://studio-clock/?openclaw_portal=demo"
    /// The chat whose agent opened the Studio clock. Other agents' chats show no portal.
    static let studioClockSessionKey = "agent:coder:main"

    static let demoDashboardId = "demo-portal-build-dashboard"
    static let demoDashboardPublicURL = "demo-portal://build-dashboard/"
    static let demoDashboardLoadURL = "demo-portal://build-dashboard/?openclaw_portal=demo"
    /// The chat whose session owns the Build dashboard through its attached environment.
    static let dashboardSessionKey = fileEditsKey
    static let dashboardEnvironmentId = "demo-env-retry-fix"

    /// Fixed for the process, so repeated lists compare equal.
    static let demoPortalCreatedAtMs = ((Date().timeIntervalSince1970 - 20 * 60) * 1000).rounded()
    static let demoDashboardCreatedAtMs = ((Date().timeIntervalSince1970 - 8 * 60) * 1000).rounded()

    func handlePortals(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "portal.list":
            return ["portals": .array(self.openDemoPortals())]
        case "portal.close":
            guard let id = params["id"]?.string, !id.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid portal.close params", details: nil)
            }
            return ["closed": .bool(self.closeDemoPortal(id))]
        case "environments.session.status":
            guard params["sessionKey"]?.string == Self.dashboardSessionKey else { return ["attachment": .null] }
            return [
                "attachment": ["environmentId": .string(Self.dashboardEnvironmentId), "closedAtMs": .null],
                "closed": false,
                "environment": ["id": .string(Self.dashboardEnvironmentId), "type": "worker", "status": "available"],
            ]
        case "portal.session.list":
            try self.requireDashboardOwner(params, method: method)
            return ["portals": .array(self.demoDashboardOpen ? [Self.buildDashboard()] : [])]
        case "portal.session.close":
            try self.requireDashboardOwner(params, method: method)
            guard let id = params["id"]?.string, !id.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid portal.session.close params", details: nil)
            }
            return ["closed": .bool(id == Self.demoDashboardId ? self.closeDemoPortal(id) : false)]
        default:
            return nil
        }
    }

    private func openDemoPortals() -> [JSONValue] {
        (self.demoPortalOpen ? [Self.studioClock()] : []) + (self.demoDashboardOpen ? [Self.buildDashboard()] : [])
    }

    private func closeDemoPortal(_ id: String) -> Bool {
        var closed = false
        if id == Self.demoPortalId, self.demoPortalOpen { self.demoPortalOpen = false; closed = true }
        if id == Self.demoDashboardId, self.demoDashboardOpen { self.demoDashboardOpen = false; closed = true }
        // Like the Gateway, the event is redacted: clients re-fetch.
        if closed { self.emit("portal.changed", ["portals": .array(self.openDemoPortals().map(Self.redacted))]) }
        return closed
    }

    private func requireDashboardOwner(_ params: JSONValue, method: String) throws {
        guard params["sessionKey"]?.string == Self.dashboardSessionKey,
              params["environmentId"]?.string == Self.dashboardEnvironmentId else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid \(method) params", details: nil)
        }
    }

    private static func redacted(_ portal: JSONValue) -> JSONValue {
        guard var object = portal.object else { return portal }
        object["url"] = nil
        object["tokenQuery"] = nil
        return .object(object)
    }

    static func studioClock() -> JSONValue {
        [
            "id": .string(demoPortalId), "title": "Studio clock", "port": 4173, "listenPort": 4173,
            "publicUrl": .string(demoPortalPublicURL), "url": .string(demoPortalLoadURL),
            "tokenQuery": "openclaw_portal=demo",
            "createdAtMs": .number(Self.demoPortalCreatedAtMs),
            "path": "/", "description": "A small clock the agent built to track studio sessions.",
            "exposure": ["kind": "non-loopback", "browserReachability": "unverified"],
        ]
    }

    static func buildDashboard() -> JSONValue {
        [
            "id": .string(demoDashboardId), "title": "Build dashboard", "port": 4174, "listenPort": 4174,
            "publicUrl": .string(demoDashboardPublicURL), "url": .string(demoDashboardLoadURL),
            "tokenQuery": "openclaw_portal=demo",
            "createdAtMs": .number(Self.demoDashboardCreatedAtMs),
            "path": "/", "description": "CI status for the retry fix.",
            "exposure": ["kind": "non-loopback", "browserReachability": "unverified"],
        ]
    }

    /// Forge's `portal` call that opened the Studio clock: the opener's link, then the summary as JSON,
    /// the way the agent's tool returns it.
    static func studioClockExchange(ago: Double) -> [JSONValue] {
        let callId = "call_demo_portal_open"
        let summary = studioClock()
        let args: JSONValue = ["action": "open", "port": 4173, "title": "Studio clock"]
        return [
            message("user", [text("Put a live clock on the studio wall display.")], ago: ago),
            message("assistant", [toolCall(callId, "portal", args)], ago: ago - 20),
            message("toolResult", [
                text("Portal route allocated at \(demoPortalPublicURL)"),
                text(ContentBlock.prettyJSON(summary) ?? ""),
            ], ago: ago - 25, extra: ["toolCallId": .string(callId), "toolName": "portal", "isError": false, "details": summary]),
            message("assistant", [text("The studio clock is live. Open it from the Portals button.")], ago: ago - 30),
        ]
    }
}
