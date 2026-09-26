import Foundation
import Testing
@testable import PincerKit

@Suite("Connect handshake")
struct ConnectParamsTests {
    let identity = Fixtures.identity()
    let scopes = ["operator.read", "operator.write", "operator.approvals"]

    func params(authMode: GatewayProfile.AuthMode = .token, deviceToken: String? = nil, secret: String? = nil,
                scopes: [String]? = nil, nonce: String = "nonce-1", signedAt: Int64 = 1_700_000_000_123) throws -> JSONValue
    {
        .object(try GatewayConnection.connectParams(
            identity: self.identity, authMode: authMode, deviceToken: deviceToken, secret: secret,
            scopes: scopes ?? self.scopes, nonce: nonce, signedAt: signedAt, instanceId: "instance-1"))
    }

    /// Rebuilds the signed payload from the frame and checks the signature with the device's public key.
    func signatureVerifies(_ params: JSONValue, token: String?) throws -> Bool {
        let device = try #require(params["device"])
        let signatureText = try #require(device["signature"]?.string)
        let publicKeyText = try #require(device["publicKey"]?.string)
        let signature = try #require(base64UrlDecode(signatureText))
        let publicKey = try #require(base64UrlDecode(publicKeyText))
        #expect(publicKey == self.identity.privateKey.publicKey.rawRepresentation)
        guard let deviceId = device["id"]?.string, let clientId = params["client"]?["id"]?.string,
              let clientMode = params["client"]?["mode"]?.string, let role = params["role"]?.string,
              let signedAt = device["signedAt"]?.int64, let nonce = device["nonce"]?.string
        else {
            Issue.record("device block incomplete")
            return false
        }
        let payload = DeviceAuthPayload.v2(
            deviceId: deviceId, clientId: clientId, clientMode: clientMode, role: role,
            scopes: params["scopes"]?.array?.compactMap(\.string) ?? [],
            signedAtMs: signedAt, token: token, nonce: nonce)
        return self.identity.privateKey.publicKey.isValidSignature(signature, for: Data(payload.utf8))
    }

    @Test func frameShape() throws {
        let params = try self.params(secret: "s")
        #expect(params["minProtocol"]?.int == 4 && params["maxProtocol"]?.int == 4)
        #expect(GatewayConnection.protocolVersion == 4)
        #expect(params["role"]?.string == "operator")
        #expect(params["scopes"]?.array?.compactMap(\.string) == self.scopes)
        #expect(params["client"]?["id"]?.string == GatewayConnection.clientId)
        #expect(params["client"]?["mode"]?.string == "ui")
        #expect(params["client"]?["instanceId"]?.string == "instance-1")
        #expect(params["commands"] == [] && params["caps"] == ["tool-events"])
        #expect(params["device"]?["id"]?.string == Fixtures.deviceId)
        #expect(params["device"]?["publicKey"]?.string == Fixtures.publicKeyBase64Url)
    }

    @Test func deviceEchoesChallenge() throws {
        let params = try self.params(nonce: "abc-123", signedAt: 42)
        #expect(params["device"]?["nonce"]?.string == "abc-123")
        #expect(params["device"]?["signedAt"]?.int64 == 42)
    }

    @Test func signatureCoversScopesNonceAndToken() throws {
        let params = try self.params(secret: "shared")
        #expect(try self.signatureVerifies(params, token: "shared"))
        #expect(try !self.signatureVerifies(params, token: nil))
        // Signed scopes are the requested ones; altering them in the frame breaks the signature.
        guard case var .object(object) = params else { Issue.record("not an object"); return }
        object["scopes"] = ["operator.read", "operator.admin"]
        #expect(try !self.signatureVerifies(.object(object), token: "shared"))
        object = params.object!
        var device = object["device"]!.object!
        device["nonce"] = "replayed"
        object["device"] = .object(device)
        #expect(try !self.signatureVerifies(.object(object), token: "shared"))
    }

    @Test func deviceTokenBeatsSharedSecret() throws {
        let params = try self.params(authMode: .token, deviceToken: "device-tok", secret: "shared")
        #expect(params["auth"] == ["token": "device-tok"])
        #expect(try self.signatureVerifies(params, token: "device-tok"))
    }

    @Test func deviceTokenSentRegardlessOfAuthMode() throws {
        let params = try self.params(authMode: .none, deviceToken: "device-tok", secret: "ignored")
        #expect(params["auth"] == ["token": "device-tok"])
        #expect(try self.signatureVerifies(params, token: "device-tok"))
    }

    @Test func sharedSecretWhenNoDeviceToken() throws {
        let params = try self.params(authMode: .token, secret: "shared")
        #expect(params["auth"] == ["token": "shared"])
        #expect(try self.signatureVerifies(params, token: "shared"))
    }

    @Test func passwordIsSentButNeverSigned() throws {
        let params = try self.params(authMode: .password, secret: "hunter2")
        #expect(params["auth"] == ["password": "hunter2"])
        #expect(try self.signatureVerifies(params, token: nil))
        #expect(try !self.signatureVerifies(params, token: "hunter2"))

        let paired = try self.params(authMode: .password, deviceToken: "device-tok", secret: "hunter2")
        #expect(paired["auth"] == ["token": "device-tok", "password": "hunter2"])
        #expect(try self.signatureVerifies(paired, token: "device-tok"))
    }

    @Test func authOmittedWhenEmpty() throws {
        #expect(absent(try self.params(authMode: .none, secret: "ignored")["auth"]))
        #expect(absent(try self.params(authMode: .token, secret: nil)["auth"]))
        #expect(absent(try self.params(authMode: .password, secret: nil)["auth"]))
        #expect(try self.signatureVerifies(try self.params(authMode: .none), token: nil))
    }
}

@Suite("Connect challenge")
struct ChallengeTests {
    @Test func valid() {
        let parsed = GatewayConnection.challenge(from: ["nonce": "abc", "ts": 1_700_000_000_000])
        #expect(parsed?.nonce == "abc" && parsed?.ts == 1_700_000_000_000)
        #expect(GatewayConnection.challenge(from: ["nonce": "abc", "ts": 0])?.ts == 0)
    }

    @Test func rejected() {
        #expect(GatewayConnection.challenge(from: ["ts": 1]) == nil)
        #expect(GatewayConnection.challenge(from: ["nonce": "  ", "ts": 1]) == nil)
        #expect(GatewayConnection.challenge(from: ["nonce": "abc"]) == nil)
        #expect(GatewayConnection.challenge(from: ["nonce": "abc", "ts": -1]) == nil)
        #expect(GatewayConnection.challenge(from: ["nonce": "abc", "ts": "soon"]) == nil)
        #expect(GatewayConnection.challenge(from: ["nonce": "abc", "ts": 1.5]) == nil)
        #expect(GatewayConnection.challenge(from: .null) == nil)
    }
}
