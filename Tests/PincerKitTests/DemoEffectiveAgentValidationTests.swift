import Testing
@testable import PincerKit

// Official faf63c5898e353c2b98d06725b2348bd8bf989fd tools-catalog.ts79–82;
// tools-effective.ts564–566 validates before resolution. Exact errors are the mock field contract.
@Suite(.timeLimit(.minutes(2)))
struct DemoEffectiveAgentValidationTests {
    @Test(arguments: [(JSONValue.number(12), "must be string"), (.null, "must be string"), (.string(""), "must NOT have fewer than 1 characters")])
    func invalidPresentAgentUsesCanonicalFieldError(value: JSONValue, problem: String) async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
        do {
            _ = try await demo.handle("tools.effective", .object(["sessionKey": .string("agent:main:dashboard:garden"), "agentId": value]))
            Issue.record("Actual catalog must reject the invalid present agentId")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid tools.effective params: at /agentId: \(problem)")
        }
        let after = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
        #expect(after == before)
    }
    @Test func ordinarySessionAndMatchingAgentRetainFullReport() async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
        let groups = try #require(before["groups"]?.array)
        try #require(!groups.isEmpty)
        let matched = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden", "agentId": "main"])
        #expect(matched == before)
        do {
            _ = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden", "agentId": "research"])
            Issue.record("Mismatched agent must remain rejected")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "agent id \"research\" does not match session agent \"main\"")
        }
        let after = try await demo.handle("tools.effective", ["sessionKey": "agent:main:dashboard:garden"])
        #expect(after == before)
    }
}
