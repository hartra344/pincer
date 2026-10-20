import Foundation
import Network
@testable import PincerKit

/// A loopback WebSocket Gateway that records every request after `connect` and answers
/// `sessions.abort` / `chat.abort` as configured. `agents.list` reports the configured scope.
final class FakeAbortGateway: @unchecked Sendable {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(code: String, message: String)
    }

    private let lock = NSLock()
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var recorded: [(method: String, params: JSONValue)] = []
    private var replies: [String: Reply] = [:]
    private var methods: [String]
    private var scope = "per-sender"
    private let queue = DispatchQueue(label: "FakeAbortGateway")
    private(set) var port: UInt16 = 0

    init(methods: [String] = ["sessions.abort", "chat.abort"]) throws {
        self.methods = methods
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredInterfaceType = .loopback
        self.listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        self.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        self.listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener.start(queue: self.queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = self.listener.port?.rawValue else {
            throw GatewayError.closed("fake gateway did not start")
        }
        self.port = port
    }

    var url: String { "ws://127.0.0.1:\(self.port)" }

    func stop() {
        self.listener.cancel()
        let open = self.locked { () -> [NWConnection] in
            let open = self.connections
            self.connections = []
            return open
        }
        for connection in open { connection.cancel() }
    }

    var advertisedMethods: [String] {
        get { self.locked { self.methods } }
        set { self.locked { self.methods = newValue } }
    }

    var agentScope: String {
        get { self.locked { self.scope } }
        set { self.locked { self.scope = newValue } }
    }

    func reply(to method: String, _ reply: Reply) { self.locked { self.replies[method] = reply } }

    /// Requests received for `method`, oldest first.
    func requests(_ method: String) -> [JSONValue] { self.locked { self.recorded.filter { $0.method == method }.map(\.params) } }

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }

    private func accept(_ connection: NWConnection) {
        self.locked { self.connections.append(connection) }
        connection.start(queue: self.queue)
        self.write(["type": "event", "event": "connect.challenge", "payload": ["nonce": "n", "ts": 1]], on: connection)
        self.receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let frame = try? JSONValue.decode(data), frame["type"]?.string == "req" {
                self.handle(frame, on: connection)
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ frame: JSONValue, on connection: NWConnection) {
        guard let id = frame["id"]?.string, let method = frame["method"]?.string else { return }
        let params = frame["params"] ?? .null
        switch method {
        case "connect":
            let methods = self.advertisedMethods.map(JSONValue.string)
            self.respond(id, ["server": ["version": "test"], "auth": ["scopes": ["operator.read", "operator.write"]],
                              "policy": ["tickIntervalMs": 600_000], "features": ["methods": .array(methods)],
                              "snapshot": [:]], on: connection)
        case "agents.list":
            self.respond(id, ["defaultId": "main", "mainKey": "main", "scope": .string(self.agentScope),
                              "agents": [["id": "main"]]], on: connection)
        default:
            let reply = self.locked { () -> Reply? in
                self.recorded.append((method, params))
                return self.replies[method]
            }
            switch reply {
            case let .result(value): self.respond(id, value, on: connection)
            case let .error(code, message): self.respond(id, error: code, message: message, on: connection)
            case nil: self.respond(id, [:], on: connection)
            }
        }
    }

    private func respond(_ id: String, _ payload: JSONValue, on connection: NWConnection) {
        self.write(["type": "res", "id": .string(id), "ok": true, "payload": payload], on: connection)
    }

    private func respond(_ id: String, error code: String, message: String, on connection: NWConnection) {
        self.write(["type": "res", "id": .string(id), "ok": false,
                    "error": ["code": .string(code), "message": .string(message)]], on: connection)
    }

    private func write(_ frame: JSONValue, on connection: NWConnection) {
        guard let data = try? frame.encoded() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
