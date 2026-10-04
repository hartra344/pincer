import Foundation

/// The Share extension's connection dependency, defaulting to the actual Gateway transport.
@MainActor final class ShareConnection {
    typealias StateHandler = @Sendable (ConnectionState, GatewayHello?) -> Void
    let requestBody: @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue
    let handlersBody: @MainActor (@escaping @Sendable (GatewayEvent) -> Void, @escaping StateHandler) async -> Void
    let startBody: @MainActor () async -> Void
    let stopBody: @MainActor () async -> Void
    init(request: @escaping @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue,
         setHandlers: @escaping @MainActor (@escaping @Sendable (GatewayEvent) -> Void, @escaping StateHandler) async -> Void,
         start: @escaping @MainActor () async -> Void, stop: @escaping @MainActor () async -> Void) {
        requestBody = request; handlersBody = setHandlers; startBody = start; stopBody = stop
    }
    convenience init(profile: GatewayProfile, identity: DeviceIdentity) {
        let connection = GatewayConnection(profile: profile, identity: identity)
        self.init(request: { try await connection.request($0, $1, timeout: $2) },
                  setHandlers: { await connection.setHandlers(onEvent: $0, onState: $1) },
                  start: { await connection.start() }, stop: { await connection.stop() })
    }
    func request(_ method: String, _ params: JSONValue = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        try await requestBody(method, params, timeout)
    }
    func setHandlers(onEvent: @escaping @Sendable (GatewayEvent) -> Void, onState: @escaping StateHandler) async {
        await handlersBody(onEvent, onState)
    }
    func start() async { await startBody() }
    func stop() async { await stopBody() }
}
