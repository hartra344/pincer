import CryptoKit
import Foundation
import Testing
@testable import PincerKit

@Suite("Device auth payload v2")
struct DeviceAuthPayloadTests {
    @Test func nilTokenIsEmptyField() {
        let payload = DeviceAuthPayload.v2(
            deviceId: "dev", clientId: "openclaw-macos", clientMode: "ui", role: "operator",
            scopes: ["operator.read"], signedAtMs: 1_700_000_000_000, token: nil, nonce: "n1")
        #expect(payload == "v2|dev|openclaw-macos|ui|operator|operator.read|1700000000000||n1")
    }

    @Test func deviceToken() {
        let payload = DeviceAuthPayload.v2(
            deviceId: "dev", clientId: "c", clientMode: "ui", role: "operator",
            scopes: ["operator.read"], signedAtMs: 5, token: "device-token-abc", nonce: "n")
        #expect(payload == "v2|dev|c|ui|operator|operator.read|5|device-token-abc|n")
    }

    @Test func sharedSecret() {
        let payload = DeviceAuthPayload.v2(
            deviceId: "dev", clientId: "c", clientMode: "ui", role: "operator",
            scopes: [], signedAtMs: 5, token: "s3cret", nonce: "n")
        #expect(payload == "v2|dev|c|ui|operator||5|s3cret|n")
    }

    @Test func multipleScopesKeepOrderJoinedByComma() {
        let payload = DeviceAuthPayload.v2(
            deviceId: "d", clientId: "c", clientMode: "ui", role: "operator",
            scopes: ["operator.write", "operator.read", "operator.admin"], signedAtMs: 1, token: nil, nonce: "n")
        #expect(payload == "v2|d|c|ui|operator|operator.write,operator.read,operator.admin|1||n")
    }

    @Test func signedAtBoundaries() {
        func payload(_ ms: Int64) -> String {
            DeviceAuthPayload.v2(deviceId: "d", clientId: "c", clientMode: "ui", role: "operator",
                                 scopes: ["s"], signedAtMs: ms, token: nil, nonce: "n")
        }
        #expect(payload(0) == "v2|d|c|ui|operator|s|0||n")
        #expect(payload(Int64.max) == "v2|d|c|ui|operator|s|9223372036854775807||n")
    }

    /// Documents current behaviour: fields are not escaped, so `|` inside a token or nonce is ambiguous.
    @Test func pipeIsNotEscaped() {
        let payload = DeviceAuthPayload.v2(
            deviceId: "d", clientId: "c", clientMode: "ui", role: "operator",
            scopes: ["s"], signedAtMs: 1, token: "a|b", nonce: "x|y")
        #expect(payload == "v2|d|c|ui|operator|s|1|a|b|x|y")
        #expect(payload.split(separator: "|", omittingEmptySubsequences: false).count == 11)
    }
}

@Suite("Device identity signing")
struct DeviceIdentitySigningTests {
    let identity = Fixtures.identity()

    @Test func deviceIdIsSha256OfPublicKey() {
        #expect(self.identity.deviceId == Fixtures.deviceId)
        let publicKey = self.identity.privateKey.publicKey.rawRepresentation
        let expected = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        #expect(self.identity.deviceId == expected)
        #expect(self.identity.deviceId.count == 64)
    }

    @Test func publicKeyIsUnpaddedBase64Url() {
        let key = self.identity.publicKeyBase64Url
        #expect(key == Fixtures.publicKeyBase64Url)
        #expect(!key.contains("=") && !key.contains("+") && !key.contains("/"))
        #expect(base64UrlDecode(key) == self.identity.privateKey.publicKey.rawRepresentation)
    }

    @Test func signatureVerifies() throws {
        let payload = "v2|\(Fixtures.deviceId)|openclaw-macos|ui|operator|operator.read|123|tok|nonce"
        let signature = try self.identity.sign(payload)
        #expect(!signature.contains("=") && !signature.contains("+") && !signature.contains("/"))
        let bytes = try #require(base64UrlDecode(signature))
        #expect(bytes.count == 64)
        #expect(self.identity.privateKey.publicKey.isValidSignature(bytes, for: Data(payload.utf8)))
    }

    @Test func tamperedPayloadsFailVerification() throws {
        func payload(nonce: String = "nonce", signedAt: Int64 = 123, token: String? = "tok", scopes: [String] = ["operator.read"]) -> String {
            DeviceAuthPayload.v2(deviceId: Fixtures.deviceId, clientId: "openclaw-macos", clientMode: "ui", role: "operator",
                                 scopes: scopes, signedAtMs: signedAt, token: token, nonce: nonce)
        }
        let signed = try self.identity.sign(payload())
        let signature = try #require(base64UrlDecode(signed))
        let publicKey = self.identity.privateKey.publicKey
        #expect(publicKey.isValidSignature(signature, for: Data(payload().utf8)))
        for tampered in [payload(nonce: "other"), payload(signedAt: 124), payload(token: nil), payload(token: "tok2"),
                         payload(scopes: ["operator.read", "operator.admin"])]
        {
            #expect(!publicKey.isValidSignature(signature, for: Data(tampered.utf8)))
        }
    }

    @Test func otherKeysSignatureFails() throws {
        let other = Fixtures.identity(Fixtures.otherRawKey)
        #expect(other.deviceId != self.identity.deviceId)
        let payload = "v2|x|c|ui|operator|s|1||n"
        let signed = try other.sign(payload)
        let signature = try #require(base64UrlDecode(signed))
        #expect(!self.identity.privateKey.publicKey.isValidSignature(signature, for: Data(payload.utf8)))
        #expect(other.privateKey.publicKey.isValidSignature(signature, for: Data(payload.utf8)))
    }
}
