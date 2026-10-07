import Foundation
@testable import PincerKit

// Official cd29ad5a9823b7ce70e4b741d13f3e1f2d4e72be:
// skills.ts detail passes the fetch error through; clawhub-client.ts formats path/status/body.
// "Skill not found" is the existing mock's canonical 404 body, not a universal service promise.
@MainActor private func checkSkillDetailError(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let ordinary = try await request("skills.detail", ["slug": "nas-report"])
        check(ordinary["skill"]?["slug"]?.text == "nas-report", "actual seeded skill detail remains available")
        do {
            _ = try await request("skills.detail", ["slug": "pincer-missing-detail-167"])
            check(false, "missing skill detail rejects the read")
        } catch let GatewayError.rpc(code, message, _) {
            check(code == "UNAVAILABLE", "missing skill preserves upstream unavailable classification")
            check(message == "ClawHub /api/v1/skills/pincer-missing-detail-167 failed (404): Skill not found",
                  "canonical missing fixture preserves actual ClawHub path, status and response body")
        }
    } catch { check(false, "skill detail read control completes: \(error)") }
}
@MainActor func runDemoSkillDetailErrorOfflineChecks() async {
    let demo = DemoGateway()
    await checkSkillDetailError { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedSkillDetailError(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual skill detail read connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("skills.detail") == true
    check(supported, "actual Gateway advertises the existing skill detail method"); guard supported else { return }
    await checkSkillDetailError { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoSkillDetailErrorChecks() async { await checkConnectedSkillDetailError(profile: .demo()) }
@MainActor func runLiveSkillDetailErrorChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Skill detail read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedSkillDetailError(profile: profile)
}
