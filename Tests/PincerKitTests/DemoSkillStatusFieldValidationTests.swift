import Testing
@testable import PincerKit

// Official cbe3ff13b844546d355dc3593a9df562e59c0204: SkillsStatusParamsSchema
// requires optional NonEmptyString agentId/sessionKey; skills-status.ts54 validates first.
@Suite(.timeLimit(.minutes(2)))
struct DemoSkillStatusFieldValidationTests {
    @Test(arguments: ["agentId", "sessionKey"])
    func invalidOptionalFieldsUseCanonicalErrors(field: String) async throws {
        let demo = DemoGateway()
        for (value, problem) in [(JSONValue.null, "must be string"), (.number(12), "must be string"),
                                  (.string(""), "must NOT have fewer than 1 characters")] {
            do {
                _ = try await demo.handle("skills.status", .object([field: value]))
                Issue.record("Actual status must reject invalid optional field")
            } catch let GatewayError.rpc(code, message, _) {
                #expect(code == "INVALID_REQUEST")
                #expect(message == "invalid skills.status params: at /\(field): \(problem)")
            }
        }
    }
    @Test func ordinaryAgentAndKnownSessionPreserveFullStatus() async throws {
        let demo = DemoGateway()
        let ordinary = try await demo.handle("skills.status", [:])
        let skills = try #require(ordinary["skills"]?.array)
        #expect(!skills.isEmpty && ordinary["agentId"]?.string == "main")
        let main = try await demo.handle("skills.status", ["agentId": "main"])
        let session = try await demo.handle("skills.status", ["agentId": "main", "sessionKey": "agent:main:main"])
        #expect(main == ordinary && session == ordinary)
        let after = try await demo.handle("skills.status", [:])
        #expect(after == ordinary)
    }
}
