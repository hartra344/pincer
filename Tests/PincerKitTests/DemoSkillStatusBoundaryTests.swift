import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct DemoSkillStatusBoundaryTests {
    @Test func validResearchRetainsItsActualStatus() async throws {
        let demo = DemoGateway()
        let report = try await demo.handle("skills.status", ["agentId": "research"])
        let skills = try #require(report["skills"]?.array)
        #expect(report["agentId"]?.string == "research" && !skills.isEmpty)
        let again = try await demo.handle("skills.status", ["agentId": "research"])
        #expect(again == report)
    }
    @Test func rawWhitespaceAndUnknownIdsKeepExistingResolutionErrors() async throws {
        let demo = DemoGateway()
        for (params, expected) in [
            (JSONValue.object(["agentId": " "]), "unknown agent id \" \""),
            (.object(["agentId": "missing-agent"]), "unknown agent id \"missing-agent\""),
            (.object(["sessionKey": " "]), "Session not found."),
            (.object(["sessionKey": "agent:main:missing"]), "Session not found."),
            (.object(["extra": true]), "invalid skills.status params: must NOT have additional properties (extra)"),
        ] {
            do {
                _ = try await demo.handle("skills.status", params)
                Issue.record("Existing invalid resolution control must fail")
            } catch let GatewayError.rpc(code, message, _) {
                #expect(code == "INVALID_REQUEST" && message == expected)
            }
        }
    }
}
