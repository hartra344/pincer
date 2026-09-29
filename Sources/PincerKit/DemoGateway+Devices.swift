import Foundation

/// Seed rows for the demo's Devices and Nodes pages (upstream `device.pair.list` / `node.list` shapes).
/// Owned by the tester; the handlers live in DemoGateway+DevicePairing.swift.
///
/// Pending: a brand-new iPad and a scope upgrade (the Studio MacBook Pro's CLI asking for
/// `operator.admin`). Paired: Pincer itself (connected, `DemoGateway.deviceId`), the Studio MacBook
/// Pro CLI (seen 3 h ago) and a Pixel 9 that's also a node (seen 2 d ago). Nodes: the Mac mini
/// (connected) and the Pixel (offline). Device ids are the hex SHA-256 of the public key, like the
/// Gateway's (except Pincer's own, which is `DemoGateway.deviceId`).
extension DemoGateway {
    static let demoStudioDeviceId = "aa0a1b5c1530dc5c7ec20e0641e5ee33ecbe1c9a85dea543b1fcbb80ef1b0282"
    static let demoPixelDeviceId = "8f8305ee22fcb175207541bacdbbf1bf5dfcebc3fa5c764ef15c53a204fe5a17"
    static let demoMacMiniDeviceId = "38e20cce67628990f4c584acf43206f4f7e9ff2ea3817df3d44754c96c4d9438"
    static let demoIPadDeviceId = "971eb0348e5329977dd18c02ba95a9632f2676f809533a76a0822e44eb423cf1"
    static let demoPendingRequestId = "demo-device-request-ipad"
    static let demoScopeUpgradeRequestId = "demo-device-request-studio-admin"

    private static func ms(_ date: Date) -> JSONValue { .number((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func ago(_ now: Date, _ seconds: TimeInterval) -> JSONValue { Self.ms(now.addingTimeInterval(-seconds)) }
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    private static let studioScopes = ["operator.read", "operator.write", "operator.approvals", "operator.pairing"]

    private static var selfName: String {
        GatewayConnection.platform == "ios" ? "Alex’s iPhone" : "Alex’s MacBook Pro"
    }

    /// `device.pair.list` `pending[]`, newest first.
    static func seedPendingDevices(now: Date = Date()) -> [JSONValue] {
        [
            [
                "requestId": .string(Self.demoPendingRequestId),
                "deviceId": .string(Self.demoIPadDeviceId),
                "publicKey": "dKjoLrZPeob6ibnKwkxmWONW9dUsRGb_qAE2rJ5GHq4",
                "displayName": "Alex’s iPad", "platform": "ios", "deviceFamily": "iPad",
                "clientId": "openclaw-ios", "clientMode": "ui", "role": "operator", "roles": ["operator"],
                "scopes": JSONValue(GatewayConnection.scopes), "remoteIp": "192.168.1.42",
                "silent": false, "isRepair": false,
                "ts": Self.ago(now, 2 * 60),
            ],
            [
                "requestId": .string(Self.demoScopeUpgradeRequestId),
                "deviceId": .string(Self.demoStudioDeviceId),
                "publicKey": "LjriRfo5ljbrSOQ1Vu22__8prJRD_RTwaNPhMb1P4Ts",
                "displayName": "Studio MacBook Pro", "platform": "darwin", "deviceFamily": "Mac",
                "clientId": "cli", "clientMode": "cli", "role": "operator", "roles": ["operator"],
                "scopes": JSONValue(Self.studioScopes + [GatewayConnection.adminScope]), "remoteIp": "192.168.1.24",
                "silent": false, "isRepair": true,
                "ts": Self.ago(now, 15 * 60),
            ],
        ]
    }

    /// `device.pair.list` `paired[]`, including Pincer's own device (`DemoGateway.deviceId`).
    static func seedPairedDevices(now: Date = Date()) -> [JSONValue] {
        let selfScopes = GatewayConnection.scopes + [PairingInboxModel.pairingScope, GatewayConnection.adminScope]
        return [
            Self.paired(
                deviceId: Self.deviceId, publicKey: "MjvLK1rwG2gsY2fajuW0bicAn_60l-u8oeFy8hT4Rjo",
                name: Self.selfName, platform: GatewayConnection.platform, family: GatewayConnection.deviceFamily,
                clientId: GatewayConnection.clientId, mode: "ui", roles: ["operator"], scopes: selfScopes,
                remoteIp: "192.168.1.18", approvedVia: "owner", connected: true,
                approvedAt: Self.ago(now, 30 * Self.day), lastSeenAt: Self.ms(now)),
            Self.paired(
                deviceId: Self.demoStudioDeviceId, publicKey: "LjriRfo5ljbrSOQ1Vu22__8prJRD_RTwaNPhMb1P4Ts",
                name: "Studio MacBook Pro", platform: "darwin", family: "Mac",
                clientId: "cli", mode: "cli", roles: ["operator"], scopes: Self.studioScopes,
                remoteIp: "192.168.1.24", approvedVia: "owner", connected: false,
                approvedAt: Self.ago(now, 40 * Self.day), lastSeenAt: Self.ago(now, 3 * Self.hour)),
            Self.paired(
                deviceId: Self.demoPixelDeviceId, publicKey: "b2HcnkpHFbcAp5xJMSVxQYsJFFsh1atR-bDaP4yv8uo",
                name: "Pixel 9", platform: "android", family: "Android",
                clientId: "openclaw-android", mode: "node", roles: ["node", "operator"],
                scopes: ["operator.read", "operator.write"],
                remoteIp: "100.84.12.7", approvedVia: "owner", connected: false,
                approvedAt: Self.ago(now, 12 * Self.day), lastSeenAt: Self.ago(now, 2 * Self.day)),
        ]
    }

    private static func paired(deviceId: String, publicKey: String, name: String, platform: String, family: String,
                               clientId: String, mode: String, roles: [String], scopes: [String], remoteIp: String,
                               approvedVia: String, connected: Bool, approvedAt: JSONValue, lastSeenAt: JSONValue) -> JSONValue {
        let tokens: [JSONValue] = roles.sorted().map { role in
            ["role": .string(role), "scopes": JSONValue(role == "operator" ? scopes : []),
             "createdAtMs": approvedAt, "lastUsedAtMs": lastSeenAt]
        }
        return [
            "deviceId": .string(deviceId), "publicKey": .string(publicKey),
            "displayName": .string(name), "platform": .string(platform), "deviceFamily": .string(family),
            "clientId": .string(clientId), "clientMode": .string(mode),
            "role": .string(roles.first ?? "operator"), "roles": JSONValue(roles), "scopes": JSONValue(scopes),
            "remoteIp": .string(remoteIp), "tokens": .array(tokens), "approvedVia": .string(approvedVia),
            "connected": .bool(connected), "createdAtMs": approvedAt, "approvedAtMs": approvedAt,
            "lastSeenAtMs": lastSeenAt,
        ]
    }

    /// `node.list` `nodes[]`: node ids are the backing devices' ids.
    static func seedNodes(now: Date = Date()) -> [JSONValue] {
        [
            [
                "nodeId": .string(Self.demoMacMiniDeviceId), "displayName": "Mac mini (home)", "platform": "darwin",
                "version": "2026.9.2", "clientId": "node-host", "clientMode": "node", "remoteIp": "192.168.1.10",
                "deviceFamily": "Mac", "modelIdentifier": "Macmini9,1",
                "caps": ["browser", "canvas", "screen", "system"],
                "commands": ["system.run", "system.which", "browser.proxy", "screen.record", "canvas.present"],
                "approvalState": "approved", "paired": true, "connected": true, "active": true,
                "connectedAtMs": Self.ago(now, 5 * Self.hour), "approvedAtMs": Self.ago(now, 90 * Self.day),
                "lastSeenAtMs": Self.ago(now, 60),
            ],
            [
                "nodeId": .string(Self.demoPixelDeviceId), "displayName": "Pixel 9", "platform": "android",
                "version": "2026.9.1", "clientId": "openclaw-android", "clientMode": "node", "remoteIp": "100.84.12.7",
                "deviceFamily": "Android", "modelIdentifier": "Pixel 9",
                "caps": ["camera", "location", "notifications"], "commands": ["camera.snap", "location.get"],
                "approvalState": "approved", "paired": true, "connected": false,
                "approvedAtMs": Self.ago(now, 12 * Self.day), "lastConnectedAtMs": Self.ago(now, 2 * Self.day),
                "lastSeenAtMs": Self.ago(now, 2 * Self.day),
            ],
        ]
    }
}
