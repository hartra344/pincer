import Testing
@testable import PincerKit
@Suite(.timeLimit(.minutes(2)))
struct DemoEffectiveAgentCompatibilityTests {
    @Test func existingValidationPriorityRetainsFullReport() async throws {
        let demo = DemoGateway()
        let baseline = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
        for (params, problem) in [(JSONValue.object(["agentId": .null]), "must have required property 'sessionKey'"), (.object(["sessionKey": .string("agent:main:dashboard:garden"), "agentId": .null, "extra": .bool(true)]), "must NOT have additional properties (extra)")] {
            do {
                _ = try await demo.handle("tools.effective", params)
                Issue.record("Existing invalid request must reject")
            } catch let GatewayError.rpc(code, message, _) {
                #expect(code == "INVALID_REQUEST")
                #expect(message == "invalid tools.effective params: \(problem)")
            }
            let after = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
            #expect(after == baseline)
        }
    }
}
