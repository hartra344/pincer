import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct DemoSkillEnabledCompatibilityTests {
    @Test func omittedEnabledAndUnknownSkillRetainExistingNoOpBehavior() async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("skills.status", [:])
        let noOp = try await demo.handle("skills.update", ["skillKey": "weather"])
        #expect(noOp == JSONValue.object(["ok": true, "skillKey": "weather", "config": [:]]))
        let unknown = try await demo.handle("skills.update", ["skillKey": "pincer-missing-skill", "enabled": false])
        #expect(unknown == JSONValue.object(["ok": true, "skillKey": "pincer-missing-skill", "config": [:]]))
        let after = try await demo.handle("skills.status", [:])
        #expect(after == before)
    }
    @Test func existingExtraKeyErrorPrecedesInvalidEnabled() async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("skills.status", [:])
        do {
            _ = try await demo.handle("skills.update", ["skillKey": "weather", "enabled": "false", "extra": true])
            Issue.record("Unexpected property must remain rejected")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid skills.update params: must NOT have additional properties (extra)")
        }
        let after = try await demo.handle("skills.status", [:])
        #expect(after == before)
    }
}
