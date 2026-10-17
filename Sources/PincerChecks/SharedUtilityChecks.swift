import Foundation
import PincerKit

@MainActor
func runSharedUtilityChecks() {
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
}
