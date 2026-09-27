import Foundation

/// The demo's device pairing and node inventory (`device.pair.list/approve/reject/remove/rename`,
/// `node.list/describe/rename`, `node.pair.remove`), with the Gateway's reply shapes, error messages
/// and events (see openclaw `src/gateway/server-methods/devices.ts`, `nodes.pairing.ts`, `nodes.read.ts`).
/// Seed rows come from DemoGateway+Devices.swift; changes live in memory for the session.
extension DemoGateway {
    static let deviceMethods = [
        "device.pair.list", "device.pair.approve", "device.pair.reject", "device.pair.remove", "device.pair.rename",
        "node.list", "node.describe", "node.rename", "node.pair.remove",
    ]

    /// Every param object is closed upstream: these are the only keys each method accepts.
    private static let deviceParamKeys: [String: Set<String>] = [
        "device.pair.list": [], "device.pair.approve": ["requestId"], "device.pair.reject": ["requestId"],
        "device.pair.remove": ["deviceId"], "device.pair.rename": ["deviceId", "label"],
        "node.list": [], "node.describe": ["nodeId"], "node.rename": ["nodeId", "displayName"],
        "node.pair.remove": ["nodeId"],
    ]

    func handleDevices(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard let allowed = Self.deviceParamKeys[method] else { return nil }
        let fields = params.object ?? [:]
        if let extra = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Self.deviceInvalid("invalid \(method) params: unexpected property '\(extra)'")
        }
        let nowMs = JSONValue.number((Date().timeIntervalSince1970 * 1000).rounded())
        switch method {
        case "device.pair.list":
            return ["pending": .array(self.devicePending), "paired": .array(self.devicePaired)]
        case "device.pair.approve":
            let requestId = try Self.required(params, "requestId", method)
            guard let index = self.devicePending.firstIndex(where: { $0["requestId"]?.text == requestId }) else {
                throw Self.deviceInvalid("unknown requestId")
            }
            let request = self.devicePending.remove(at: index)
            let device = Self.pairedDevice(from: request, nowMs: nowMs)
            let deviceId = device["deviceId"]?.text ?? ""
            self.devicePaired.removeAll { $0["deviceId"]?.text == deviceId }
            self.devicePaired.append(device)
            self.emit("device.pair.resolved", ["requestId": .string(requestId), "deviceId": .string(deviceId),
                                               "decision": "approved", "ts": nowMs])
            return ["requestId": .string(requestId), "device": device]
        case "device.pair.reject":
            let requestId = try Self.required(params, "requestId", method)
            guard let index = self.devicePending.firstIndex(where: { $0["requestId"]?.text == requestId }) else {
                throw Self.deviceInvalid("unknown requestId")
            }
            let deviceId = self.devicePending.remove(at: index)["deviceId"] ?? .null
            self.emit("device.pair.resolved", ["requestId": .string(requestId), "deviceId": deviceId,
                                               "decision": "rejected", "ts": nowMs])
            return ["requestId": .string(requestId), "deviceId": deviceId]
        case "device.pair.remove":
            let deviceId = try Self.required(params, "deviceId", method)
            guard let index = self.devicePaired.firstIndex(where: { $0["deviceId"]?.text == deviceId }) else {
                throw Self.deviceInvalid("unknown deviceId")
            }
            self.devicePaired.remove(at: index)
            self.demoNodes.removeAll { $0["nodeId"]?.text == deviceId }
            return ["deviceId": .string(deviceId)]
        case "device.pair.rename":
            let deviceId = try Self.required(params, "deviceId", method)
            guard let raw = params["label"]?.string, !raw.isEmpty, raw.count <= 64 else {
                throw Self.deviceInvalid("invalid device.pair.rename params: label must be 1-64 characters")
            }
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { throw Self.deviceInvalid("label required") }
            guard let index = self.devicePaired.firstIndex(where: { $0["deviceId"]?.text == deviceId }),
                  var device = self.devicePaired[index].object
            else { throw Self.deviceInvalid("unknown deviceId") }
            device["operatorLabel"] = .string(label)
            self.devicePaired[index] = .object(device)
            self.emit("device.pair.changed", [:])
            return ["deviceId": .string(deviceId), "label": .string(label)]
        case "node.list":
            let activeId = self.demoNodes.first { $0["active"]?.bool == true }?["nodeId"]
            var result: [String: JSONValue] = ["ts": nowMs, "nodes": .array(self.demoNodes)]
            if let activeId { result["activeNodeId"] = activeId }
            return .object(result)
        case "node.describe":
            let nodeId = try Self.required(params, "nodeId", method)
            guard var node = self.demoNodes.first(where: { $0["nodeId"]?.text == nodeId })?.object else {
                throw Self.deviceInvalid("unknown nodeId")
            }
            node["ts"] = nowMs
            return .object(node)
        case "node.rename":
            let nodeId = try Self.required(params, "nodeId", method)
            guard let name = params["displayName"]?.text else { throw Self.deviceInvalid("displayName required") }
            guard let index = self.demoNodes.firstIndex(where: { $0["nodeId"]?.text == nodeId }),
                  var node = self.demoNodes[index].object
            else { throw Self.deviceInvalid("unknown nodeId") }
            node["displayName"] = .string(name)
            self.demoNodes[index] = .object(node)
            return ["nodeId": .string(nodeId), "displayName": .string(name)]
        case "node.pair.remove":
            let nodeId = try Self.required(params, "nodeId", method)
            guard let index = self.demoNodes.firstIndex(where: { $0["nodeId"]?.text == nodeId }) else {
                throw Self.deviceInvalid("unknown nodeId")
            }
            self.demoNodes.remove(at: index)
            self.dropNodeRole(nodeId)
            self.emit("node.pair.resolved", ["requestId": "", "nodeId": .string(nodeId), "decision": "removed", "ts": nowMs])
            return ["nodeId": .string(nodeId)]
        default:
            return nil
        }
    }

    /// A node-only device row goes away with its node role; a mixed-role one keeps its other roles.
    private func dropNodeRole(_ deviceId: String) {
        guard let index = self.devicePaired.firstIndex(where: { $0["deviceId"]?.text == deviceId }),
              var device = self.devicePaired[index].object
        else { return }
        let roles = DeviceRecords.roles(.object(device)).filter { $0 != "node" }
        if roles.isEmpty {
            self.devicePaired.remove(at: index)
            return
        }
        device["role"] = .string(roles[0])
        device["roles"] = JSONValue(roles)
        if let tokens = device["tokens"]?.array {
            device["tokens"] = .array(tokens.filter { $0["role"]?.text != "node" })
        }
        self.devicePaired[index] = .object(device)
    }

    /// The paired row an approval makes: the request's metadata plus a token summary per role.
    private static func pairedDevice(from request: JSONValue, nowMs: JSONValue) -> JSONValue {
        var device = request.object ?? [:]
        for key in ["requestId", "silent", "isRepair", "ts"] { device[key] = nil }
        let roles = DeviceRecords.roles(request)
        let scopes = request["scopes"] ?? []
        device["tokens"] = .array((roles.isEmpty ? ["operator"] : roles).sorted().map {
            ["role": .string($0), "scopes": $0 == "operator" ? scopes : [], "createdAtMs": nowMs]
        })
        device["approvedVia"] = "owner"
        device["connected"] = false
        device["createdAtMs"] = nowMs
        device["approvedAtMs"] = nowMs
        return .object(device)
    }

    private static func required(_ params: JSONValue, _ key: String, _ method: String) throws -> String {
        guard let value = params[key]?.text else {
            throw Self.deviceInvalid("invalid \(method) params: must have required property '\(key)'")
        }
        return value
    }

    private static func deviceInvalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }
}
