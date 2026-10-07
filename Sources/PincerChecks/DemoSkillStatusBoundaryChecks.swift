@testable import PincerKit

@MainActor func runDemoSkillStatusBoundaryChecks() async {
    let demo = DemoGateway()
    do {
        let report = try await demo.handle("skills.status", ["agentId": "research"])
        let again = try await demo.handle("skills.status", ["agentId": "research"])
        check(report["agentId"]?.string == "research" && report["skills"]?.array?.isEmpty == false && again == report,
              "valid research retains its full actual status")
        let ordinary = try await demo.handle("skills.status", [:])
        check(ordinary["agentId"]?.string == "main" && ordinary["skills"]?.array?.isEmpty == false,
              "ordinary main report is nonempty")
        for field in ["agentId", "sessionKey"] {
            let whitespace = try await demo.handle("skills.status", .object([field: " "]))
            check(whitespace == ordinary, "raw whitespace retains existing full main defaults")
        }
        let cases: [(JSONValue, String)] = [
            (["agentId": "missing-agent"], "unknown agent id \"missing-agent\""),
            (["sessionKey": "agent:main:missing"], "Session not found."),
            (["extra": true], "invalid skills.status params: must NOT have additional properties (extra)"),
        ]
        for (params, expected) in cases {
            do {
                _ = try await demo.handle("skills.status", params)
                check(false, "existing invalid status resolution control must reject")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == expected, "unknown ids and extra-key errors stay unchanged")
            }
        }
    } catch { check(false, "actual status boundary controls complete") }
}
