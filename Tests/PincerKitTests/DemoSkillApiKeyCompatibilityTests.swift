import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct DemoSkillApiKeyCompatibilityTests {
    @Test func omittedAndUnknownKeysPreserveFullStatus() async throws {
        let demo = DemoGateway()
        let baseline = try await demo.handle("skills.status", [:])
        try #require(baseline["skills"]?.array?.isEmpty == false)
        for key in ["notion", "owned-unknown-skill"] {
            let result = try await demo.handle("skills.update", ["skillKey": .string(key)])
            #expect(result == ["ok": true, "skillKey": .string(key), "config": [:]])
            let after = try await demo.handle("skills.status", [:])
            #expect(after == baseline)
        }
    }
    @Test func existingValidationPriorityIsPreserved() async throws {
        let demo = DemoGateway()
        let baseline = try await demo.handle("skills.status", [:])
        try #require(baseline["skills"]?.array?.isEmpty == false)
        let cases: [(JSONValue, String)] = [
            (["skillKey": "notion", "apiKey": .null, "extra": true], "invalid skills.update params: must NOT have additional properties (extra)"),
            (["apiKey": .null], "invalid skills.update params: must have required property 'skillKey'")
        ]
        for (params, expected) in cases {
            do { _ = try await demo.handle("skills.update", params); Issue.record("Invalid request was accepted") }
            catch GatewayError.rpc(let code, let message, _) { #expect(code == "INVALID_REQUEST" && message == expected) }
            let after = try await demo.handle("skills.status", [:])
            #expect(after == baseline)
        }
    }
}
