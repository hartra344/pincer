import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runIdentityChecks() {
    check(
        DeviceAuthPayload.v2(deviceId: "d", clientId: "openclaw-macos", clientMode: "ui", role: "operator",
                             scopes: ["operator.read", "operator.write"], signedAtMs: 42, token: nil, nonce: "n")
            == "v2|d|openclaw-macos|ui|operator|operator.read,operator.write|42||n",
        "v2 payload layout, empty token")
    let identity = DeviceIdentity.loadOrCreate()
    check(identity.deviceId.count == 64, "deviceId is sha256 hex")
    check(DeviceIdentity.loadOrCreate().deviceId == identity.deviceId, "identity persists")
    check(!identity.publicKeyBase64Url.contains("=") && !identity.publicKeyBase64Url.contains("+"), "public key is base64url")
}

@MainActor
func runURLPolicyChecks() {
    func resolves(_ url: String) -> String? {
        try? GatewayProfile(name: "t", url: url, authMode: .token).resolvedURL().absoluteString
    }
    check(resolves("home.tail1234.ts.net") == "wss://home.tail1234.ts.net", "bare .ts.net → wss")
    check(resolves("100.101.102.103:18789") == "ws://100.101.102.103:18789", "tailnet IP → ws")
    check(resolves("ws://127.0.0.1:18789") != nil, "loopback ws allowed")
    check(resolves("ws://192.168.1.5:18789") != nil, "LAN ws allowed")
    check(resolves("ws://example.com") == nil, "public ws rejected")
    check(resolves("wss://example.com") != nil, "public wss allowed")
    check(resolves("https://home.tail1234.ts.net") == "wss://home.tail1234.ts.net", "https → wss")
    check(resolves("ftp://x") == nil, "other schemes rejected")
}
