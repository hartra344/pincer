import Foundation
import PincerKit

@MainActor
func runSharedUtilityChecks() async {
    check(GatewayDates.iso("2026-01-02T03:04:05Z")?.timeIntervalSince1970 == 1_767_323_045, "GatewayDates parses plain ISO")
    check(GatewayDates.iso("2026-01-02T03:04:05.500Z")?.timeIntervalSince1970 == 1_767_323_045.5, "GatewayDates parses fractional ISO")
    check(GatewayDates.iso("nope") == nil, "GatewayDates rejects garbage")
    check(GatewayDates.isoString(Date(timeIntervalSince1970: 1_767_323_045.5)) == "2026-01-02T03:04:05.500Z", "GatewayDates formats fractional ISO")
    check(JSONValue.number(1500).epochMillisDate() == Date(timeIntervalSince1970: 1.5), "epoch ms converts")
    check(JSONValue.number(0).epochMillisDate(positiveOnly: true) == nil, "epoch ms positive-only rejects zero")
    check(JSONValue.number(.infinity).epochMillisDate(requireFinite: true) == nil, "epoch ms finite guard")
    check(GatewayMethodSupport.supports("a", advertised: nil), "unknown method list supports")
    check(GatewayMethodSupport.supports("a", advertised: ["a"]), "advertised method supports")
    check(!GatewayMethodSupport.supports("a", advertised: ["b"]), "unadvertised method unsupported")
    check(!GatewayMethodSupport.supports("a", advertised: nil, rejected: ["a"]), "rejected method unsupported")

    struct Boom: Error {}
    let unknown = GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method: x", details: nil)
    let scope = GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin", details: ["code": "MISSING_SCOPE"])
    func kind(_ outcome: GatewayCallOutcome<Int>) -> String {
        switch outcome {
        case let .success(value): "success \(value)"
        case .unknownMethod: "unknown"
        case .missingScope: "scope"
        case .failure: "failure"
        }
    }
    let ok = await GatewayCallOutcome<Int>.run { 7 }
    let unknownOutcome = await GatewayCallOutcome<Int>.run { throw unknown }
    let scopeOutcome = await GatewayCallOutcome<Int>.run { throw scope }
    let failureOutcome = await GatewayCallOutcome<Int>.run { throw Boom() }
    check(kind(ok) == "success 7", "call outcome success")
    check(kind(unknownOutcome) == "unknown", "call outcome unknown method")
    check(kind(scopeOutcome) == "scope", "call outcome missing scope")
    check(kind(failureOutcome) == "failure", "call outcome generic failure")
    check(GatewayError.invalidRequest("bad") == .rpc(code: "INVALID_REQUEST", message: "bad", details: nil), "invalidRequest builds INVALID_REQUEST")
}
