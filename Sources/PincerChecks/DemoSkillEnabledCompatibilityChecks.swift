import Foundation
@testable import PincerKit

@MainActor func runDemoSkillEnabledCompatibilityChecks() async {
    let demo = DemoGateway()
    do {
        let before = try await demo.handle("skills.status", [:])
        let noOp = try await demo.handle("skills.update", ["skillKey": "weather"])
        check(noOp == JSONValue.object(["ok": true, "skillKey": "weather", "config": [:]]), "omitted enabled preserves existing no-op response")
        let unknown = try await demo.handle("skills.update", ["skillKey": "pincer-missing-skill", "enabled": false])
        check(unknown == JSONValue.object(["ok": true, "skillKey": "pincer-missing-skill", "config": [:]]), "unknown skill preserves existing empty-config response")
        do {
            _ = try await demo.handle("skills.update", ["skillKey": "weather", "enabled": "false", "extra": true])
            check(false, "extra key remains rejected")
        } catch let GatewayError.rpc(code, message, _) {
            check(code == "INVALID_REQUEST" && message == "invalid skills.update params: must NOT have additional properties (extra)", "legacy extra-key priority unchanged")
        }
        let after = try await demo.handle("skills.status", [:])
        check(after == before, "compatibility controls preserve exact full status")
    } catch { check(false, "enabled compatibility controls complete") }
}
