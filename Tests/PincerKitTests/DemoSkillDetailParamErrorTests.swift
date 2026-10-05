import Testing
@testable import PincerKit

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DemoSkillDetailParamErrorTests {
    @Test func unexpectedDetailPropertyUsesCanonicalValidationError() async throws {
        do {
            _ = try await DemoGateway().handle("skills.detail", ["slug": "nas-report", "extra": true])
            Issue.record("Unexpected detail field must be rejected")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid skills.detail params: at root: unexpected property 'extra'")
        }
    }
    @Test func ordinarySeededDetailIsStillAvailable() async throws {
        let response = try await DemoGateway().handle("skills.detail", ["slug": "nas-report"])
        #expect(response["skill"]?["slug"]?.text == "nas-report")
    }
}
