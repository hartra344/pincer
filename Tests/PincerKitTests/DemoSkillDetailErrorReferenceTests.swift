import Testing
@testable import PincerKit

@MainActor
struct DemoSkillDetailErrorReferenceTests {
    @Test(arguments: [("@Missing-Owner/missing-detail", "missing-detail"),
                      ("missing detail", "missing%20detail"), ("missing-é", "missing-%C3%A9")])
    func missingReferencesUseNormalizedEncodedPath(reference: String, encoded: String) async throws {
        do {
            _ = try await DemoGateway().handle("skills.detail", ["slug": .string(reference)])
            Issue.record("Missing detail must fail")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "UNAVAILABLE")
            #expect(message == "ClawHub /api/v1/skills/\(encoded) failed (404): Skill not found")
        }
    }
}
