import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway call outcome")
@MainActor
struct GatewayCallOutcomeTests {
    private struct Boom: Error {}

    private func kind(_ outcome: GatewayCallOutcome<Int>) -> String {
        switch outcome {
        case let .success(value): "success \(value)"
        case .unknownMethod: "unknown"
        case .missingScope: "scope"
        case .failure: "failure"
        }
    }

    @Test func classifiesEachBranch() async {
        #expect(kind(await GatewayCallOutcome.run { 3 }) == "success 3")
        #expect(kind(await GatewayCallOutcome.run {
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "nope", details: nil)
        }) == "unknown")
        #expect(kind(await GatewayCallOutcome.run {
            throw GatewayError.rpc(code: "FORBIDDEN", message: "x", details: ["code": "MISSING_SCOPE"])
        }) == "scope")
        #expect(kind(await GatewayCallOutcome<Int>.run { throw Boom() }) == "failure")
    }

    @Test func unknownMethodWinsOverMissingScope() async {
        let both = GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method: operator.x", details: nil)
        #expect(kind(await GatewayCallOutcome<Int>.run { throw both }) == "unknown")
    }

    @Test func methodSupportFoldsUnknownAndEmptyLists() {
        #expect(GatewayMethodSupport.supports("a", advertised: []))
        #expect(!GatewayMethodSupport.supports("a", advertised: ["b"]))
    }
}

@Suite("Invalid request errors")
struct InvalidRequestErrorTests {
    @Test func buildsInvalidRequestRpc() {
        let plain = GatewayError.invalidRequest("bad")
        #expect(plain == .rpc(code: "INVALID_REQUEST", message: "bad", details: nil))
        let detailed = GatewayError.invalidRequest("bad", details: ["k": "v"])
        #expect(detailed == .rpc(code: "INVALID_REQUEST", message: "bad", details: ["k": "v"]))
        #expect(!GatewayError.isUnknownMethod(plain))
    }
}
