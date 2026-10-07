import Testing
@testable import PincerKit

// Official df96d22d333b00929cb85582cdbe89184421b9db schema/agents-models-skills.ts344–349;
// server-methods/skills.ts466–469 validates before local-config mutation.
// Exact single-field wording below is the existing mock local-variant selection, not a universal union-error claim.
@Suite(.timeLimit(.minutes(2)))
struct DemoSkillEnabledValidationTests {
    @Test(arguments: [JSONValue.string("false"), .number(0), .null])
    func invalidEnabledUsesCanonicalBooleanErrorWithoutMutation(value: JSONValue) async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("skills.status", [:])
        do {
            _ = try await demo.handle("skills.update", .object(["skillKey": "weather", "enabled": value]))
            Issue.record("Actual Demo update must reject non-Boolean enabled")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid skills.update params: at /enabled: must be boolean")
        }
        let after = try await demo.handle("skills.status", [:])
        #expect(after == before)
    }
    @Test func actualBooleanUpdatesHaveExactResponseAndStatusReadback() async throws {
        let demo = DemoGateway()
        let before = try await demo.handle("skills.status", [:])
        let rows = try #require(before["skills"]?.array)
        let weather = try #require(rows.first { $0["skillKey"]?.text == "weather" })
        #expect(weather["disabled"]?.bool == false)
        let disabled = try await demo.handle("skills.update", ["skillKey": "weather", "enabled": false])
        #expect(disabled == JSONValue.object(["ok": true, "skillKey": "weather", "config": ["enabled": false]]))
        let status = try await demo.handle("skills.status", [:])
        let updatedRows = try #require(status["skills"]?.array)
        #expect(updatedRows.first { $0["skillKey"]?.text == "weather" }?["disabled"]?.bool == true)
        let others = rows.filter { $0["skillKey"]?.text != "weather" }
        let updatedOthers = updatedRows.filter { $0["skillKey"]?.text != "weather" }
        #expect(updatedOthers == others)
        let enabled = try await demo.handle("skills.update", ["skillKey": "weather", "enabled": true])
        #expect(enabled == JSONValue.object(["ok": true, "skillKey": "weather", "config": ["enabled": true]]))
        let restored = try await demo.handle("skills.status", [:])
        #expect(restored == before)
    }
}
