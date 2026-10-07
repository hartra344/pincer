import Foundation
@testable import PincerKit

@MainActor func runDemoSkillApiKeyCompatibilityChecks() async {
    let demo = DemoGateway()
    do {
        let baseline = try await demo.handle("skills.status", [:])
        guard baseline["skills"]?.array?.isEmpty == false else { check(false, "nonempty compatibility baseline"); return }
        for key in ["notion", "owned-unknown-skill"] {
            let result = try await demo.handle("skills.update", ["skillKey": .string(key)])
            check(result == ["ok": true, "skillKey": .string(key), "config": [:]], "omitted API key preserves existing result")
            let after = try await demo.handle("skills.status", [:])
            check(after == baseline, "omitted API key preserves full status")
        }
        let cases: [(JSONValue, String)] = [
            (["skillKey": "notion", "apiKey": .null, "extra": true], "invalid skills.update params: must NOT have additional properties (extra)"),
            (["apiKey": .null], "invalid skills.update params: must have required property 'skillKey'")
        ]
        for (params, expected) in cases {
            do { _ = try await demo.handle("skills.update", params); check(false, "invalid compatibility request rejected") }
            catch GatewayError.rpc(let code, let message, _) { check(code == "INVALID_REQUEST" && message == expected, "existing validation priority retained") }
            let after = try await demo.handle("skills.status", [:])
            check(after == baseline, "priority rejection preserves full status")
        }
    } catch { check(false, "skill API key compatibility: \(error)") }
}
