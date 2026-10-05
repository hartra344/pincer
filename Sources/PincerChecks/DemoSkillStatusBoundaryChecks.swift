@testable import PincerKit

@MainActor func runDemoSkillStatusBoundaryChecks() async {
    let demo = DemoGateway()
    do {
        let report = try await demo.handle("skills.status", ["agentId": "research"])
        let again = try await demo.handle("skills.status", ["agentId": "research"])
        check(report["agentId"]?.string == "research" && report["skills"]?.array?.isEmpty == false && again == report,
              "valid research retains its full actual status")
        let cases: [(JSONValue, String)] = [
            (["agentId": " "], "unknown agent id \" \""),
            (["agentId": "missing-agent"], "unknown agent id \"missing-agent\""),
            (["sessionKey": " "], "Session not found."),
            (["sessionKey": "agent:main:missing"], "Session not found."),
            (["extra": true], "invalid skills.status params: must NOT have additional properties (extra)"),
        ]
        for (params, expected) in cases {
            do {
                _ = try await demo.handle("skills.status", params)
                check(false, "existing invalid status resolution control must reject")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == expected, "raw whitespace, unknown ids and extra-key errors stay unchanged")
            }
        }
    } catch { check(false, "actual status boundary controls complete") }
}
