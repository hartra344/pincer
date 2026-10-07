import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct DemoToolsCatalogCompatibilityTests {
    @Test func actualResearchResolutionAndFullCatalogRemainUnchanged() async throws {
        let demo = DemoGateway()
        let all = try await demo.handle("tools.catalog", ["agentId": "research"])
        let groups = try #require(all["groups"]?.array)
        #expect(all["agentId"]?.text == "research")
        let hasCore = groups.contains { $0["source"]?.text == "core" }
        let hasPlugin = groups.contains { $0["source"]?.text == "plugin" }
        #expect(!groups.isEmpty && hasCore && hasPlugin)
        let included = try await demo.handle("tools.catalog", ["agentId": " research ", "includePlugins": true])
        #expect(included == all)
        let excluded = try await demo.handle("tools.catalog", ["agentId": "research", "includePlugins": false])
        let expected = groups.filter { $0["source"]?.text != "plugin" }
        #expect(excluded["groups"]?.array == expected)
    }
    @Test(arguments: [
        (JSONValue.object(["agentId": "pincer-missing-agent"]), "unknown agent id \"pincer-missing-agent\""),
        (JSONValue.object(["extra": true, "includePlugins": "false"]), "invalid tools.catalog params: must NOT have additional properties (extra)"),
    ])
    func existingErrorsRetainPriority(params: JSONValue, expected: String) async throws {
        do {
            _ = try await DemoGateway().handle("tools.catalog", params)
            Issue.record("Existing invalid catalog request must fail")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == expected)
        }
    }
}
