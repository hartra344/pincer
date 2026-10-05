import Foundation
import Testing
@testable import PincerKit

// Official df96d22d333b00929cb85582cdbe89184421b9db:
// agents-models-skills.ts344–349 optional apiKey Type.String permits an empty string;
// server-methods/skills.ts467 validates before mutation. Exact field wording below is the
// existing mock's config-variant fixture, not the complete upstream union error formatting.
@Suite(.timeLimit(.minutes(2)))
struct DemoSkillApiKeyValidationTests {
    @Test(arguments: [JSONValue.null, .number(12)])
    func invalidApiKeyCannotBeAcceptedOrChangeSavedState(value: JSONValue) async throws {
        let demo = DemoGateway()
        let baseline = try await demo.handle("skills.status", [:])
        let original = try #require(baseline["skills"]?.array?.first { $0["skillKey"]?.string == "notion" })
        try #require(original["primaryEnv"]?.string == "NOTION_API_KEY" && original["missing"]?["env"]?.array?.contains(.string("NOTION_API_KEY")) == true)
        let dummy = "owned-demo-api-key-validation"
        do {
            let saved = try await demo.handle("skills.update", ["skillKey": "notion", "apiKey": .string(dummy)])
            #expect(saved["ok"]?.bool == true && saved["config"]?["apiKey"]?.string == "__OPENCLAW_REDACTED__")
            let current = try await demo.handle("skills.status", [:])
            let notion = try #require(current["skills"]?.array?.first { $0["skillKey"]?.string == "notion" })
            try #require(notion["eligible"]?.bool == true && notion["missing"]?["env"]?.array?.isEmpty == true)
            let redacted = try await Task.detached { try JSONEncoder().encode(current).range(of: Data(dummy.utf8)) == nil }.value
            #expect(redacted)
            do {
                _ = try await demo.handle("skills.update", ["skillKey": "notion", "apiKey": value])
                Issue.record("Present non-string apiKey must be rejected")
            } catch let GatewayError.rpc(code, message, _) {
                #expect(code == "INVALID_REQUEST" && message == "invalid skills.update params: at /apiKey: must be string")
            }
            let after = try await demo.handle("skills.status", [:])
            #expect(after == current, "Invalid local key request cannot change any actual status field")
            let cleared = try await demo.handle("skills.update", ["skillKey": "notion", "apiKey": ""])
            #expect(cleared["ok"]?.bool == true && absent(cleared["config"]?["apiKey"]))
            let restored = try await demo.handle("skills.status", [:])
            #expect(restored == baseline)
        } catch {
            _ = try? await demo.handle("skills.update", ["skillKey": "notion", "apiKey": ""])
            throw error
        }
    }
}
