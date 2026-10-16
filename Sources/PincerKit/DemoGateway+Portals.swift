import Foundation

/// The demo's `portal.list` and `portal.close`, with one seeded portal ("Studio clock").
/// Its URLs use the `demo-portal` scheme, which the UI serves from a bundled page (no network).
extension DemoGateway {
    static let portalMethods = ["portal.list", "portal.close"]

    static let demoPortalId = "demo-portal-studio-clock"
    static let demoPortalPublicURL = "demo-portal://studio-clock/"
    static let demoPortalLoadURL = "demo-portal://studio-clock/?openclaw_portal=demo"

    /// Fixed for the process, so repeated lists compare equal.
    static let demoPortalCreatedAtMs = ((Date().timeIntervalSince1970 - 20 * 60) * 1000).rounded()

    func handlePortals(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "portal.list":
            return ["portals": .array(self.demoPortalOpen ? [Self.studioClock()] : [])]
        case "portal.close":
            guard let id = params["id"]?.string, !id.isEmpty else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid portal.close params", details: nil)
            }
            let closed = id == Self.demoPortalId && self.demoPortalOpen
            if closed {
                self.demoPortalOpen = false
                // Like the Gateway, the event is redacted: clients re-fetch `portal.list`.
                self.emit("portal.changed", ["portals": .array([])])
            }
            return ["closed": .bool(closed)]
        default:
            return nil
        }
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
}
