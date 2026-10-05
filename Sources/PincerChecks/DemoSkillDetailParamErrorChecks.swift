import Foundation
@testable import PincerKit

// Pinned cd29ad5a9823b7ce70e4b741d13f3e1f2d4e72be: closed SkillsDetailParamsSchema,
// gateway validation.ts prefix, protocol validation-errors.ts additional-property formatting.
@MainActor private func checkSkillDetailParamError(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let ordinary = try await request("skills.detail", ["slug": "nas-report"])
        check(ordinary["skill"]?["slug"]?.text == "nas-report", "actual ordinary skill detail remains available")
        do {
            _ = try await request("skills.detail", ["slug": "nas-report", "extra": true])
            check(false, "unexpected detail property rejects the request")
        } catch let GatewayError.rpc(code, message, _) {
            check(code == "INVALID_REQUEST", "unexpected property preserves upstream invalid-request classification")
            check(message == "invalid skills.detail params: at root: unexpected property 'extra'",
                  "unexpected detail property has canonical upstream validation wording")
        }
    } catch { check(false, "skill detail validation control completes: \(error)") }
}
@MainActor func runDemoSkillDetailParamErrorOfflineChecks() async {
    let demo = DemoGateway()
    await checkSkillDetailParamError { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedSkillDetailParams(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("skill detail params connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("skills.detail") == true
    check(supported, "actual Gateway advertises the existing detail method"); guard supported else { return }
    await checkSkillDetailParamError { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoSkillDetailParamErrorChecks() async { await checkConnectedSkillDetailParams(profile: .demo()) }
@MainActor func runLiveSkillDetailParamErrorChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Skill detail parameter read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedSkillDetailParams(profile: profile)
}
