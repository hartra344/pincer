import Testing
@testable import PincerKit

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DemoSkillDetailErrorTests {
    @Test func missingRegistrySkillUsesCanonicalClawHubHTTPError() async throws {
        let demo = DemoGateway()
        do {
            _ = try await demo.handle("skills.detail", ["slug": "pincer-missing-detail-167"])
            Issue.record("Missing skill detail must fail")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "UNAVAILABLE")
            #expect(message == "ClawHub /api/v1/skills/pincer-missing-detail-167 failed (404): Skill not found")
        }
    }
    @Test func seededDetailStillReturnsItsActualSkill() async throws {
        let response = try await DemoGateway().handle("skills.detail", ["slug": "nas-report"])
        #expect(response["skill"]?["slug"]?.text == "nas-report")
    }
}
