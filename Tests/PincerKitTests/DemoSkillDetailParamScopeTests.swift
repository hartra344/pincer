import Testing
@testable import PincerKit

@MainActor
struct DemoSkillDetailParamScopeTests {
    @Test func unrelatedMethodValidationRemainsUnchanged() async throws {
        do {
            _ = try await DemoGateway().handle("skills.search", ["extra": true])
            Issue.record("Unknown search field must fail before search")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid skills.search params: must NOT have additional properties (extra)")
        }
    }
    @Test func detailVersionValidationRemainsUnchanged() async throws {
        do {
            _ = try await DemoGateway().handle("skills.detail", ["slug": "nas-report", "version": ""])
            Issue.record("Empty version must fail")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST")
            #expect(message == "invalid skills.detail params: version must be a non-empty string")
        }
    }
}
