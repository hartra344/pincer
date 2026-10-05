import Foundation

extension AppModel {
    /// The palette's existing create-and-open action, shared with its causal coverage.
    @discardableResult
    package func createPaletteChat(gateway: GatewayStore, agentId: String) async -> String? {
        let gatewayRevision = self.gatewaySelectionIntentRevision
        let chatRevision = gateway.selectionIntentRevision
        // Select once through the owned app action, after the actual creation has finished.
        if let key = await gateway.createSession(agentId: agentId, label: nil, select: false) {
            if self.gatewaySelectionIntentRevision == gatewayRevision,
               gateway.selectionIntentRevision == chatRevision,
               self.gateways.first(where: { $0.id == gateway.id }) === gateway {
                self.open(Notifier.Target(gatewayId: gateway.id, sessionKey: key))
            }
            return key
        }
        return nil
    }
}
