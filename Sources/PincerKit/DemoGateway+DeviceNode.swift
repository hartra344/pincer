import Foundation

/// What the demo knows about Pincer's own opt-in node connection.
struct DemoNodeState {
    var attachId = 0
    var sink: (@Sendable (GatewayEvent) -> Void)?
    var commands: [String] = []
    var pending: [String: CheckedContinuation<JSONValue, Never>] = [:]
}

/// The demo's side of device mode: a node attach is auto-approved and listed in `node.list` under
/// Pincer's own device id; `node.invoke.result` answers `demoInvokeNode`.
extension DemoGateway {
    func attachNode(
        deviceId: String, caps: [String], commands: [String],
        sink: @escaping @Sendable (GatewayEvent) -> Void) async -> (Int, JSONValue)
    {
        self.demoNode.attachId += 1
        self.demoNode.sink = sink
        self.demoNode.commands = commands
        let nowMs = JSONValue.number((Date().timeIntervalSince1970 * 1000).rounded())
        let selfId = Self.deviceId
        let name = self.devicePaired.first { $0["deviceId"]?.text == selfId }?["displayName"]?.text ?? "Pincer"
        let row: JSONValue = [
            "nodeId": .string(selfId), "displayName": .string(name), "platform": .string(GatewayConnection.platform),
            "version": .string(GatewayConnection.appVersion), "clientId": .string(GatewayConnection.clientId),
            "clientMode": "node", "deviceFamily": .string(GatewayConnection.deviceFamily),
            "caps": JSONValue(caps), "commands": JSONValue(commands),
            "approvalState": "approved", "paired": true, "connected": true,
            "connectedAtMs": nowMs, "approvedAtMs": nowMs, "lastSeenAtMs": nowMs,
        ]
        if let index = self.demoNodes.firstIndex(where: { $0["nodeId"]?.text == selfId }) {
            self.demoNodes[index] = row
        } else {
            self.demoNodes.append(row)
        }
        if let index = self.devicePaired.firstIndex(where: { $0["deviceId"]?.text == selfId }),
           var device = self.devicePaired[index].object
        {
            let roles = Array(Set(DeviceRecords.roles(.object(device)) + ["node"])).sorted()
            device["roles"] = JSONValue(roles)
            self.devicePaired[index] = .object(device)
        }
        let hello: JSONValue = [
            "type": "hello-ok",
            "protocol": .number(Double(GatewayConnection.protocolVersion)),
            "server": ["version": "demo", "connId": .string(Self.shortId("conn_"))],
            "features": ["methods": ["node.invoke.result"], "events": ["node.invoke.request"]],
            "auth": ["role": "node", "scopes": []],
            "policy": ["maxPayload": 26_214_400, "tickIntervalMs": 15000],
        ]
        return (self.demoNode.attachId, hello)
    }

    /// Marks the node offline, unless a newer attach already replaced it.
    func detachNode(_ attachId: Int) {
        guard attachId == self.demoNode.attachId, self.demoNode.sink != nil else { return }
        self.demoNode.sink = nil
        self.demoNode.commands = []
        let selfId = Self.deviceId
        if let index = self.demoNodes.firstIndex(where: { $0["nodeId"]?.text == selfId }),
           var node = self.demoNodes[index].object
        {
            node["connected"] = false
            self.demoNodes[index] = .object(node)
        }
        for (_, waiter) in self.demoNode.pending {
            waiter.resume(returning: ["ok": false, "error": ["code": "UNAVAILABLE", "message": "node disconnected"]])
        }
        self.demoNode.pending.removeAll()
    }

    func handleDeviceNode(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        if method == "node.pair.remove", params["nodeId"]?.text == Self.deviceId {
            // Removing the node role drops the live attachment; the shared handler removes the rows.
            self.demoNode.sink = nil
            self.demoNode.commands = []
            return nil
        }
        guard method == "node.invoke.result" else { return nil }
        guard let id = params["id"]?.text, let waiter = self.demoNode.pending.removeValue(forKey: id) else {
            return ["ok": true, "ignored": true]
        }
        waiter.resume(returning: params)
        return ["ok": true]
    }

    /// Like an operator's `node.invoke`: `{ok, nodeId, command, payload?, payloadJSON?, error?}`.
    func invokeNode(command: String, paramsJSON: String?, timeout: TimeInterval = 10) async -> JSONValue {
        let selfId = Self.deviceId
        func failure(_ code: String, _ message: String) -> JSONValue {
            ["ok": false, "nodeId": .string(selfId), "command": .string(command),
             "error": ["code": .string(code), "message": .string(message)]]
        }
        guard let sink = self.demoNode.sink else { return failure("UNAVAILABLE", "node not connected") }
        guard self.demoNode.commands.contains(command) else {
            return failure("INVALID_REQUEST", "INVALID_REQUEST: unknown command")
        }
        let id = UUID().uuidString
        var requestParams: [String: JSONValue] = ["id": .string(id), "nodeId": .string(selfId), "command": .string(command)]
        if let paramsJSON { requestParams["paramsJSON"] = .string(paramsJSON) }
        let reply: JSONValue = await withCheckedContinuation { continuation in
            self.demoNode.pending[id] = continuation
            sink(GatewayEvent(name: "node.invoke.request", payload: .object(requestParams), seq: nil))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.expireInvoke(id)
            }
        }
        var result: [String: JSONValue] = ["ok": .bool(reply["ok"]?.bool ?? false), "nodeId": .string(selfId), "command": .string(command)]
        if let json = reply["payloadJSON"]?.string {
            result["payloadJSON"] = .string(json)
            if let payload = try? JSONValue.decode(Data(json.utf8)) { result["payload"] = payload }
        }
        if let error = reply["error"] { result["error"] = error }
        return .object(result)
    }

    private func expireInvoke(_ id: String) {
        self.demoNode.pending.removeValue(forKey: id)?
            .resume(returning: ["ok": false, "error": ["code": "UNAVAILABLE", "message": "node invoke timed out"]])
    }
}
