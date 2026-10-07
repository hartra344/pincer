@testable import PincerKit
@MainActor func runDemoEffectiveAgentCompatibilityChecks() async {
    let demo = DemoGateway()
    do {
        let baseline = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
        for (params, problem) in [(JSONValue.object(["agentId": .null]), "must have required property 'sessionKey'"), (.object(["sessionKey": .string("agent:main:dashboard:garden"), "agentId": .null, "extra": .bool(true)]), "must NOT have additional properties (extra)")] {
            do {
                _ = try await demo.handle("tools.effective", params)
                check(false, "existing validation priority rejects")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid tools.effective params: \(problem)", "exact existing required/extra priority")
            }
            let after = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
            check(after == baseline, "priority rejections retain full effective report")
        }
    } catch { check(false, "actual effective compatibility completes") }
}
