import Testing
@testable import PincerKit

@MainActor
struct DemoSkillDetailErrorReferenceTests {
    @Test(arguments: [("@Missing-Owner/missing-detail", "missing-detail"),
                      (" missing-detail ", "missing-detail"), ("missing-detail-2", "missing-detail-2")])
    func missingReferencesUseNormalizedEncodedPath(reference: String, encoded: String) async throws {
        do {
            _ = try await DemoGateway().handle("skills.detail", ["slug": .string(reference)])
            Issue.record("Missing detail must fail")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "UNAVAILABLE")
            #expect(message == "ClawHub /api/v1/skills/\(encoded) failed (404): Skill not found")
        }
    }
    @Test(arguments: ["missing detail", "missing-é", "@invalid!/missing-detail"])
    func invalidReferenceKeepsExistingDemoBehavior(reference: String) async throws {
        do {
            _ = try await DemoGateway().handle("skills.detail", ["slug": .string(reference)])
            Issue.record("Missing invalid reference must fail")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "UNAVAILABLE")
            #expect(message == "ClawHub skill \"\(reference)\" not found")
        }
    }

}
