import Foundation

extension AppModel {
    /// The palette's existing create-and-open action, shared with its causal coverage.
    @discardableResult
    package func createPaletteChat(gateway: GatewayStore, agentId: String) async -> String? {
        if let key = await gateway.createSession(agentId: agentId, label: nil) {
            self.open(Notifier.Target(gatewayId: gateway.id, sessionKey: key))
            return key
        }
        return nil
    }
}
