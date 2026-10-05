import Testing
@testable import PincerKit

// Official cbe3ff13b844546d355dc3593a9df562e59c0204:
// packages/gateway-protocol/src/schema/agents-models-skills.ts361–364.
// Exact validation wording follows the existing mock's skillsParamsProblem formatter.
@Suite(.timeLimit(.minutes(2)))
struct DemoSkillSearchFieldValidationTests {
    @Test(arguments: [
        ("limit", JSONValue.number(0), "must be >= 1"),
        ("limit", JSONValue.number(101), "must be <= 100"),
        ("limit", JSONValue.number(1.5), "must be integer"),
        ("limit", JSONValue.null, "must be integer"),
        ("query", JSONValue.string(""), "must NOT have fewer than 1 characters"),
        ("query", JSONValue.null, "must be string"),
        ("query", JSONValue.number(12), "must be string"),
    ])
    func invalidSearchFieldUsesCanonicalValidationError(field: String, value: JSONValue, problem: String) async throws {
        do {
            _ = try await DemoGateway().handle("skills.search", .object([field: value]))
            Issue.record("Actual Demo search must reject the invalid field")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid skills.search params: at /\(field): \(problem)")
        }
    }
    @Test func actualDefaultAndLimitedSearchRemainAvailable() async throws {
        let demo = DemoGateway()
        let all = try await demo.handle("skills.search", [:])
        let allRows = try #require(all["results"]?.array)
        let hasSeededSkill = allRows.contains { $0["slug"]?.text == "nas-report" }
        #expect(!allRows.isEmpty && hasSeededSkill)
        let limited = try await demo.handle("skills.search", ["query": "nas", "limit": 1])
        let rows = try #require(limited["results"]?.array)
        #expect(rows.count == 1 && rows.first?["slug"]?.text == "nas-report")
    }
}
