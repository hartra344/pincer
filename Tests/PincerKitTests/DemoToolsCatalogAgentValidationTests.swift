import Testing
@testable import PincerKit

// Official d8096acbafe680e73d70e4310795957212122421 schema/tools-catalog.ts7–10;
// server-methods/tools-catalog.ts201–209 validates before optional-string normalization.
@Suite(.timeLimit(.minutes(2)))
struct DemoToolsCatalogAgentValidationTests {
    @Test(arguments: [(JSONValue.number(12), "must be string"), (.null, "must be string"), (.string(""), "must NOT have fewer than 1 characters")])
    func invalidPresentAgentUsesCanonicalFieldError(value: JSONValue, problem: String) async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("tools.catalog", [:])
        do {
            _ = try await demo.handle("tools.catalog", .object(["agentId": value]))
            Issue.record("Actual catalog must reject the invalid present agentId")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid tools.catalog params: at /agentId: \(problem)")
        }
        let after = try await demo.handle("tools.catalog", [:])
        #expect(after == before)
    }
    @Test func actualOrdinaryAgentCatalogsAndWhitespaceRemainUnchanged() async throws {
        let demo = DemoGateway()
        let all = try await demo.handle("tools.catalog", [:])
        let groups = try #require(all["groups"]?.array)
        #expect(!groups.isEmpty && all["agentId"]?.text == "main")
        let main = try await demo.handle("tools.catalog", ["agentId": "main"])
        let whitespace = try await demo.handle("tools.catalog", ["agentId": "   "])
        #expect(main == all && whitespace == all)
        let research = try await demo.handle("tools.catalog", ["agentId": "research"])
        let researchGroups = try #require(research["groups"]?.array)
        #expect(!researchGroups.isEmpty && research["agentId"]?.text == "research")
        let trimmed = try await demo.handle("tools.catalog", ["agentId": " research "])
        #expect(trimmed == research)
        do {
            _ = try await demo.handle("tools.catalog", ["agentId": "pincer-missing-agent"])
            Issue.record("Unknown agent must remain rejected")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "unknown agent id \"pincer-missing-agent\"")
        }
    }
}
