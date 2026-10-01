import Foundation
import Network
@testable import PincerKit

/// A loopback WebSocket Gateway that speaks just enough of the protocol (challenge, connect, `users.prefs.*`)
/// for a real `GatewayStore` to connect, with control over how `users.prefs.set` answers and what it
/// receives. Every other method answers `{}`.
final class FakePrefsGateway: @unchecked Sendable {
    enum SetReply: Sendable {
        case ok
        case conflict
        case error
    }

    private let lock = NSLock()
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var prefValues: [String: JSONValue] = [:]
    private var setParams: [JSONValue] = []
    private var getCount = 0
    private var getFailures = 0
    private var reply: SetReply = .ok
    /// Whether an accepted set also sends `users.prefs.changed`, like the real Gateway.
    private var echoes = true
    private var echoCount = 0
    private var subscriptionCalls: [(method: String, params: JSONValue)] = []
    private var rejectsSubscriptionId = false
    private let queue = DispatchQueue(label: "FakePrefsGateway")
    private(set) var port: UInt16 = 0

    init() throws {
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
        self.lock.lock()
        let open = self.connections
        self.connections = []
        self.lock.unlock()
        for connection in open { connection.cancel() }
    }

    // MARK: Test controls

    var setReply: SetReply {
        get { self.locked { self.reply } }
        set { self.locked { self.reply = newValue } }
    }

    var sendsEchoes: Bool {
        get { self.locked { self.echoes } }
        set { self.locked { self.echoes = newValue } }
    }

    /// The `users.prefs.set` params received, oldest first (answered or not).
    var sets: [JSONValue] { self.locked { self.setParams } }
    var gets: Int { self.locked { self.getCount } }
    /// How many upcoming `users.prefs.get` requests fail with `UNAVAILABLE`.
    var failingGets: Int {
        get { self.locked { self.getFailures } }
        set { self.locked { self.getFailures = newValue } }
    }
    /// Whether message subscriptions with a `subscriptionId` are refused, like a Gateway before 2026.9.7.
    var rejectsSubscriptionIds: Bool {
        get { self.locked { self.rejectsSubscriptionId } }
        set { self.locked { self.rejectsSubscriptionId = newValue } }
    }

    /// `sessions.messages.subscribe` / `unsubscribe` requests received, oldest first (including refused ones).
    var subscriptions: [(method: String, params: JSONValue)] { self.locked { self.subscriptionCalls } }

    /// `users.prefs.changed` events sent for accepted sets.
    var echoesSent: Int { self.locked { self.echoCount } }

    /// The stored map for a pref as `[entry: value]`, `nil` when unset.
    func map(_ pref: String) -> [String: String]? {
        self.locked { self.prefValues[pref]?.object?.compactMapValues(\.string) }
    }

    func seed(_ pref: String, _ entries: [String: String]) {
        self.locked { self.prefValues[pref] = .object(entries.mapValues(JSONValue.string)) }
    }

    /// Another device writes the pref: stored, then announced like the Gateway does.
    func externalChange(_ pref: String, _ entries: [String: String]) {
        self.seed(pref, entries)
        self.broadcast(event: "users.prefs.changed", ["profileId": "other", "keys": [.string(pref)]])
    }

    // MARK: Protocol

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }

    private func accept(_ connection: NWConnection) {
        self.locked { self.connections.append(connection) }
        connection.start(queue: self.queue)
        self.send(event: "connect.challenge", ["nonce": "n", "ts": 1], on: connection)
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
            let methods: [JSONValue] = ["users.prefs.get", "users.prefs.set"]
            self.respond(id, ["server": ["version": "test"], "auth": ["scopes": ["operator.read", "operator.write"]],
                              "policy": ["tickIntervalMs": 600_000], "features": ["methods": .array(methods)],
                              "snapshot": [:]], on: connection)
        case "users.prefs.get":
            let keys = params["keys"]?.array?.compactMap(\.string)
            let entries: [String: JSONValue]? = self.locked {
                self.getCount += 1
                if self.getFailures > 0 {
                    self.getFailures -= 1
                    return nil
                }
                return self.prefValues.filter { keys?.contains($0.key) ?? true }
            }
            guard let entries else {
                self.respond(id, error: "UNAVAILABLE", on: connection)
                return
            }
            self.respond(id, ["status": "ok", "entries": .object(entries)], on: connection)
        case "users.prefs.set":
            self.handleSet(id, params, on: connection)
        case "sessions.messages.subscribe", "sessions.messages.unsubscribe":
            let refuse = self.locked { () -> Bool in
                self.subscriptionCalls.append((method, params))
                return self.rejectsSubscriptionId && params["subscriptionId"] != nil
            }
            if refuse {
                self.respond(id, error: "INVALID_REQUEST", message: "invalid \(method) params: unexpected property 'subscriptionId'", on: connection)
            } else {
                self.respond(id, ["ok": true], on: connection)
            }
        default:
            self.respond(id, [:], on: connection)
        }
    }

    private func handleSet(_ id: String, _ params: JSONValue, on connection: NWConnection) {
        let (reply, echoes) = self.locked { () -> (SetReply, Bool) in
            self.setParams.append(params)
            return (self.reply, self.echoes)
        }
        // Like the Gateway: one pref value is at most 4 KiB.
        let tooLarge = (params["entries"]?.object ?? [:]).values.contains { ((try? $0.encoded().count) ?? 0) > 4 * 1024 }
        switch tooLarge ? .error : reply {
        case .error:
            self.respond(id, error: "INVALID_REQUEST", on: connection)
        case .conflict:
            self.respond(id, ["status": "conflict"], on: connection)
        case .ok:
            let entries = params["entries"]?.object ?? [:]
            // Compare-and-set, like the Gateway's `expectedEntries`.
            let conflicted: Bool = self.locked {
                // An unset map and an empty one count as the same.
                func normal(_ value: JSONValue?) -> JSONValue {
                    value == nil || value == .object([:]) ? .null : value!
                }
                for (key, expected) in params["expectedEntries"]?.object ?? [:] where normal(self.prefValues[key]) != normal(expected) {
                    return true
                }
                for (key, value) in entries { self.prefValues[key] = value.isNull ? nil : value }
                return false
            }
            if conflicted {
                self.respond(id, ["status": "conflict"], on: connection)
                return
            }
            // Like the Gateway: the ok response first, then the changed event on the same socket.
            self.respond(id, ["status": "ok"], on: connection)
            if echoes {
                self.locked { self.echoCount += 1 }
                self.broadcast(event: "users.prefs.changed",
                               ["profileId": "me", "keys": .array(entries.keys.map(JSONValue.string))])
            }
        }
    }

    private func respond(_ id: String, _ payload: JSONValue, on connection: NWConnection) {
        self.write(["type": "res", "id": .string(id), "ok": true, "payload": payload], on: connection)
    }

    private func respond(_ id: String, error code: String, message: String = "rejected", on connection: NWConnection) {
        self.write(["type": "res", "id": .string(id), "ok": false,
                    "error": ["code": .string(code), "message": .string(message)]], on: connection)
    }

    private func send(event: String, _ payload: JSONValue, on connection: NWConnection) {
        self.write(["type": "event", "event": .string(event), "payload": payload], on: connection)
    }

    private func broadcast(event: String, _ payload: JSONValue) {
        for connection in self.locked({ self.connections }) { self.send(event: event, payload, on: connection) }
    }

    private func write(_ frame: JSONValue, on connection: NWConnection) {
        guard let data = try? frame.encoded() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
