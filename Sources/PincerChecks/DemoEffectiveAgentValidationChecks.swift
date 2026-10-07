import Foundation
@testable import PincerKit

// Official faf63c5898e353c2b98d06725b2348bd8bf989fd tools-catalog.ts79–82: optional NonEmptyString agentId.
// Existing mock skills.mjs fieldType.nonEmpty and skillsParamsProblem supply exact error wording.
@MainActor private func checkEffectiveAgents(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let base: JSONValue = ["sessionKey": "agent:main:dashboard:garden"]
        let all = try await request("tools.effective", base)
        guard let groups = all["groups"]?.array, !groups.isEmpty else {
            check(false, "actual known session effective report is nonempty"); return
        }
        check(true, "actual known session effective report is nonempty")
        let main = try await request("tools.effective", ["sessionKey": "agent:main:dashboard:garden", "agentId": "main"])
        check(main == all, "matching agent preserves exact full effective report")
        for (value, problem) in [(JSONValue.number(12), "must be string"), (.null, "must be string"), (.string(""), "must NOT have fewer than 1 characters")] {
            do {
                _ = try await request("tools.effective", .object(["sessionKey": .string("agent:main:dashboard:garden"), "agentId": value]))
                check(false, "actual catalog rejects invalid present agentId")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid tools.effective params: at /agentId: \(problem)", "exact canonical agentId field error")
            }
        }
        do {
            _ = try await request("tools.effective", ["sessionKey": "agent:main:dashboard:garden", "agentId": "research"])
            check(false, "actual unknown agent remains rejected")
        } catch let GatewayError.rpc(code, message, _) {
            check(code == "INVALID_REQUEST" && message == "agent id \"research\" does not match session agent \"main\"", "existing mismatched-agent exact error remains")
        }
        let after = try await request("tools.effective", base)
        check(after == all, "invalid read attempts leave exact main catalog unchanged")
    } catch { check(false, "actual agent catalog controls complete") }
}
@MainActor func runDemoEffectiveAgentValidationOfflineChecks() async {
    let demo = DemoGateway()
    await checkEffectiveAgents { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedEffectiveAgents(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual catalog read connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("tools.effective") == true
    check(supported, "actual Gateway advertises tools.effective"); guard supported else { return }
    await checkEffectiveAgents { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoEffectiveAgentValidationChecks() async { await checkConnectedEffectiveAgents(profile: .demo()) }
@MainActor func runLiveToolsEffectiveAgentValidationChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Catalog read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedEffectiveAgents(profile: profile)
}
