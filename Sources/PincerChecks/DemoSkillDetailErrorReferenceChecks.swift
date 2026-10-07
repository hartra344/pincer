import Foundation
@testable import PincerKit

@MainActor func runDemoSkillDetailErrorReferenceChecks() async {
    let demo = DemoGateway()
    for (reference, encoded) in [("@Missing-Owner/missing-detail", "missing-detail"),
                                 (" missing-detail ", "missing-detail"), ("missing-detail-2", "missing-detail-2")] {
        do {
            _ = try await demo.handle("skills.detail", ["slug": .string(reference)])
            check(false, "missing reference rejects detail read")
        } catch let GatewayError.rpc(code, message, _) {
            check(code == "UNAVAILABLE" && message == "ClawHub /api/v1/skills/\(encoded) failed (404): Skill not found",
                  "missing reference keeps normalized encoded ClawHub path and canonical HTTP error")
        } catch { check(false, "missing detail has the expected Gateway error") }
    }
}
