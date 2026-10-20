import Foundation

extension GatewayConnection {
    /// The `request` closure the settings models take: every call goes through this connection with a fixed `timeout`.
    nonisolated func modelRequest(timeout: TimeInterval) -> @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue {
        { method, params in try await self.request(method, params, timeout: timeout) }
    }
}
