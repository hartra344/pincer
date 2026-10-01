import Foundation

extension ChatStore {
    /// Subscribes with this chat's `subscriptionId`. A Gateway before 2026.9.7 rejects the unknown
    /// param, so that connection is remembered and the subscribe is retried once without it.
    func subscribeToMessages(on gateway: GatewayStore) async throws {
        let withId = !gateway.messageSubscriptionIdUnsupported
        var params = self.params(keyName: "key")
        if withId { params["subscriptionId"] = .string(self.subscriptionId) }
        do {
            _ = try await gateway.connection.request("sessions.messages.subscribe", .object(params), timeout: 10)
            self.subscribedWithId = withId
        } catch let GatewayError.rpc(code, message, _)
            where withId && code == "INVALID_REQUEST" && message.contains("sessions.messages.subscribe params")
        {
            gateway.messageSubscriptionIdUnsupported = true
            _ = try await gateway.connection.request(
                "sessions.messages.subscribe", .object(self.params(keyName: "key")), timeout: 10)
            self.subscribedWithId = false
        }
    }

    /// Unsubscribes the same observer the subscribe created.
    func unsubscribeParams() -> [String: JSONValue] {
        var params = self.params(keyName: "key")
        if self.subscribedWithId { params["subscriptionId"] = .string(self.subscriptionId) }
        return params
    }
}
