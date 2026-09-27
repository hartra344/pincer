import Foundation

extension DemoGateway {
    /// The WhatsApp account in the demo's `health`: enabled, but not linked (so not configured,
    /// and not a problem). Setup never asks about channels (#175).
    func whatsappAccount() -> JSONValue {
        [
            "accountId": "default", "name": "WhatsApp", "enabled": true, "configured": false, "linked": false,
            "running": false, "connected": false, "restartPending": false, "reconnectAttempts": 0, "lifecycle": "stopped",
        ]
    }
}
