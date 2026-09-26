import CryptoKit
import Foundation
import Testing
@testable import PincerKit

@Suite("TLS pinning")
struct PinningTests {
    @Test func fingerprintNormalization() {
        #expect(PinningDelegate.normalized("AB:CD:EF") == "abcdef")
        #expect(PinningDelegate.normalized("ab cd  EF") == "abcdef")
        #expect(PinningDelegate.normalized(" AB:cd ef:01 ") == "abcdef01")
        #expect(PinningDelegate.normalized("") == nil)
        #expect(PinningDelegate.normalized(" : : ") == nil)
        #expect(PinningDelegate.normalized(nil) == nil)
        #expect(PinningDelegate(fingerprint: "AA:BB").fingerprint == "aabb")
        #expect(PinningDelegate(fingerprint: "  ").fingerprint == nil)
    }

    @Test func leafMatchesPin() throws {
        let der = Data("pretend leaf certificate".utf8)
        let hex = SHA256.hash(data: der).map { String(format: "%02X", $0) }
        let colonUpper = hex.joined(separator: ":")
        let pin = try #require(PinningDelegate.normalized(colonUpper))
        #expect(PinningDelegate.matches(leafDER: der, pin: pin))
        #expect(!PinningDelegate.matches(leafDER: Data("another certificate".utf8), pin: pin))
        var wrong = Array(pin)
        wrong[0] = wrong[0] == "0" ? "1" : "0"
        #expect(!PinningDelegate.matches(leafDER: der, pin: String(wrong)))
        #expect(!PinningDelegate.matches(leafDER: der, pin: String(pin.dropLast())))
    }
}

@Suite("Gateway URL policy")
struct URLPolicyTests {
    func resolve(_ url: String) throws -> URL {
        try GatewayProfile(name: "t", url: url, authMode: .none).resolvedURL()
    }

    func refusal(_ url: String) -> GatewayError? {
        do {
            _ = try self.resolve(url)
            return nil
        } catch let error as GatewayError {
            return error
        } catch {
            return nil
        }
    }

    @Test(arguments: [
        "ws://127.0.0.1:18789", "ws://10.1.2.3", "ws://192.168.1.10", "ws://172.16.0.1", "ws://172.31.255.255",
        "ws://100.64.0.1", "ws://100.127.255.255", "ws://localhost:18789", "ws://mac.local", "ws://box.tail1.ts.net",
        "ws://[::1]:18789", "ws://[fd7a:115c:a1e0::1]:18789",
    ])
    func cleartextAllowedOnPrivateHosts(_ url: String) throws {
        #expect(try self.resolve(url).scheme == "ws")
    }

    @Test(arguments: [
        ("ws://172.15.255.255", "172.15.255.255"), ("ws://172.32.0.1", "172.32.0.1"),
        ("ws://100.63.255.255", "100.63.255.255"), ("ws://100.128.0.1", "100.128.0.1"),
        ("ws://8.8.8.8", "8.8.8.8"), ("ws://gateway.example.com", "gateway.example.com"),
        ("http://Gateway.Example.com", "gateway.example.com"),
    ])
    func cleartextRefusedOnPublicHosts(_ url: String, _ host: String) {
        #expect(self.refusal(url) == .insecureURL(host))
    }

    @Test func encryptedAllowedAnywhere() throws {
        #expect(try self.resolve("wss://gateway.example.com").absoluteString == "wss://gateway.example.com")
        #expect(try self.resolve("https://gateway.example.com/ws").absoluteString == "wss://gateway.example.com/ws")
    }

    @Test func schemeInference() throws {
        #expect(try self.resolve("box.tail1.ts.net").scheme == "wss")
        #expect(try self.resolve("box.tail1.ts.net:443").scheme == "wss")
        #expect(try self.resolve("100.64.1.2:18789").absoluteString == "ws://100.64.1.2:18789")
        #expect(try self.resolve("  ws://127.0.0.1  ").host() == "127.0.0.1")
        #expect(self.refusal("gateway.example.com") == .insecureURL("gateway.example.com"))
    }

    @Test func invalidSchemesAndURLs() {
        #expect(self.refusal("ftp://gateway.example.com") == .invalidURL("ftp://gateway.example.com"))
        #expect(self.refusal("file:///etc/passwd") == .invalidURL("file:///etc/passwd"))
        #expect(self.refusal("") == .invalidURL(""))
    }

    @Test func privateHostRanges() {
        #expect(GatewayProfile.isPrivateHost("fd7a:115c:a1e0::53"))
        #expect(!GatewayProfile.isPrivateHost("fd7a:115c:a1e1::53"))
        #expect(!GatewayProfile.isPrivateHost("2001:db8::1"))
        #expect(GatewayProfile.isPrivateHost("::1"))
        #expect(!GatewayProfile.isPrivateHost("172.15.0.1") && GatewayProfile.isPrivateHost("172.16.0.1"))
        #expect(GatewayProfile.isPrivateHost("172.31.0.1") && !GatewayProfile.isPrivateHost("172.32.0.1"))
        #expect(!GatewayProfile.isPrivateHost("100.63.0.1") && GatewayProfile.isPrivateHost("100.64.0.1"))
        #expect(GatewayProfile.isPrivateHost("100.127.0.1") && !GatewayProfile.isPrivateHost("100.128.0.1"))
        #expect(!GatewayProfile.isPrivateHost("192.169.0.1") && !GatewayProfile.isPrivateHost("11.0.0.1"))
        #expect(!GatewayProfile.isPrivateHost("evil-ts.net.example.com"))
    }
}

@Suite("Connect failure classification")
struct ClassifyTests {
    typealias Failure = GatewayConnection.FailureClass

    func classify(_ code: String, _ message: String = "m", details: JSONValue? = nil) -> Failure {
        GatewayConnection.classify(.rpc(code: code, message: message, details: details))
    }

    @Test func pairingRequired() {
        #expect(self.classify("NOT_PAIRED", details: ["code": "PAIRING_REQUIRED", "requestId": "req-1"]) == .pairing("req-1"))
        #expect(self.classify("PAIRING_REQUIRED", "pairing required (requestId: abc123)") == .pairing("abc123"))
        #expect(self.classify("PAIRING_REQUIRED", "device not paired") == .pairing(nil))
        // The details id wins over one in the message.
        #expect(self.classify("PAIRING_REQUIRED", "requestId: fromMessage", details: ["requestId": "fromDetails"]) == .pairing("fromDetails"))
    }

    @Test func staleDeviceToken() {
        #expect(self.classify("UNAUTHORIZED", details: ["code": "AUTH_DEVICE_TOKEN_MISMATCH"]) == .staleDeviceToken)
        #expect(self.classify("AUTH_SCOPE_MISMATCH") == .staleDeviceToken)
    }

    @Test func retryable() {
        #expect(self.classify("UNAUTHORIZED", "slow down", details: ["code": "AUTH_RATE_LIMITED"]) == .retry("slow down"))
        #expect(self.classify("UNAVAILABLE", "busy") == .retry("busy"))
        #expect(self.classify("INTERNAL", "oops") == .retry("oops"))
        #expect(GatewayConnection.classify(.timeout("connect")) == .retry(GatewayError.timeout("connect").localizedDescription))
        #expect(GatewayConnection.classify(.closed("bye")) == .retry(GatewayError.closed("bye").localizedDescription))
    }

    @Test func fatal() {
        for (code, details) in [("PROTOCOL_MISMATCH", nil), ("X", ["code": "PROTOCOL_MISMATCH"]), ("AUTH_TOKEN_INVALID", nil),
                                ("X", ["code": "AUTH_PASSWORD_INVALID"]), ("DEVICE_REVOKED", nil), ("CLIENT_VERSION_MISMATCH", nil)]
                as [(String, JSONValue?)]
        {
            let error = GatewayError.rpc(code: code, message: "m", details: details)
            #expect(GatewayConnection.classify(error) == .fatal(error.localizedDescription), "\(code) \(String(describing: details))")
        }
        #expect(GatewayConnection.classify(.insecureURL("h")) == .fatal(GatewayError.insecureURL("h").localizedDescription))
        #expect(GatewayConnection.classify(.invalidURL("u")) == .fatal(GatewayError.invalidURL("u").localizedDescription))
    }
}

@Suite("Scope upgrade refusal")
struct ScopeUpgradeTests {
    let requested = GatewayConnection.scopes

    @Test func dropsUnapprovedOptionalScope() {
        let details: JSONValue = ["reason": "scope-upgrade",
                                  "approvedScopes": ["operator.read", "operator.write", "operator.approvals"]]
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: details)
            == ["operator.read", "operator.write", "operator.approvals"])
    }

    @Test func adminApprovalCoversEverything() {
        let details: JSONValue = ["reason": "scope-upgrade", "approvedScopes": ["operator.admin"]]
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: details) == nil)
    }

    @Test func writeImpliesRead() {
        let details: JSONValue = ["reason": "scope-upgrade", "approvedScopes": ["operator.write", "operator.approvals"]]
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: details)
            == ["operator.read", "operator.write", "operator.approvals"])
    }

    @Test func missingRequiredScopeMeansNoFallback() {
        let details: JSONValue = ["reason": "scope-upgrade", "approvedScopes": ["operator.read"]]
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: details) == nil)
    }

    @Test func unknownApprovedListDropsOptionalOnly() {
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: ["reason": "scope-upgrade"])
            == ["operator.read", "operator.write", "operator.approvals"])
    }

    @Test func otherRefusalsAreIgnored() {
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: nil) == nil)
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: ["reason": "other"]) == nil)
        let approvedAll: JSONValue = ["reason": "scope-upgrade", "approvedScopes": .array(self.requested.map(JSONValue.string))]
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(requested: self.requested, details: approvedAll) == nil)
        #expect(GatewayConnection.scopesAfterUpgradeRefusal(
            requested: ["operator.read", "operator.write"], details: ["reason": "scope-upgrade"]) == nil)
    }
}

@Suite("Reconnect backoff")
struct BackoffTests {
    @Test func doublesThenCaps() {
        #expect((0...6).map { GatewayConnection.backoffSeconds(attempt: $0) } == [1, 2, 4, 8, 16, 30, 30])
        #expect(GatewayConnection.backoffSeconds(attempt: 1000) == 30)
        #expect(GatewayConnection.backoffSeconds(attempt: Int.max) == 30)
    }
}
