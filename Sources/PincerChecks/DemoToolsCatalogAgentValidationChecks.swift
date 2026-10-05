import Foundation
@testable import PincerKit

// Official d8096acbafe680e73d70e4310795957212122421 tools-catalog.ts7–10: optional NonEmptyString agentId.
// Existing mock skills.mjs fieldType.nonEmpty and skillsParamsProblem supply exact error wording.
@MainActor private func checkCatalogAgents(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let all = try await request("tools.catalog", [:])
        guard let groups = all["groups"]?.array, !groups.isEmpty, all["agentId"]?.text == "main" else {
            check(false, "actual default main catalog is nonempty"); return
        }
        check(true, "actual main catalog is nonempty")
        let main = try await request("tools.catalog", ["agentId": "main"])
        let whitespace = try await request("tools.catalog", ["agentId": "   "])
        check(main == all && whitespace == all, "omitted/main and existing whitespace normalization retain exact full catalog")
        let research = try await request("tools.catalog", ["agentId": "research"])
        guard let researchGroups = research["groups"]?.array, !researchGroups.isEmpty, research["agentId"]?.text == "research" else {
            check(false, "actual research catalog is nonempty"); return
        }
        let trimmed = try await request("tools.catalog", ["agentId": " research "])
        check(trimmed == research, "trimmed research retains exact full catalog")
        for (value, problem) in [(JSONValue.number(12), "must be string"), (.null, "must be string"), (.string(""), "must NOT have fewer than 1 characters")] {
            do {
                _ = try await request("tools.catalog", .object(["agentId": value]))
                check(false, "actual catalog rejects invalid present agentId")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid tools.catalog params: at /agentId: \(problem)", "exact canonical agentId field error")
            }
        }
        do {
            _ = try await request("tools.catalog", ["agentId": "pincer-missing-agent"])
            check(false, "actual unknown agent remains rejected")
        } catch let GatewayError.rpc(code, _, _) {
            check(code == "INVALID_REQUEST", "unknown-agent existing error classification remains")
        }
        let after = try await request("tools.catalog", [:])
        check(after == all, "invalid read attempts leave exact main catalog unchanged")
    } catch { check(false, "actual agent catalog controls complete") }
}
@MainActor func runDemoToolsCatalogAgentValidationOfflineChecks() async {
    let demo = DemoGateway()
    await checkCatalogAgents { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedCatalogAgents(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual catalog read connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("tools.catalog") == true
    check(supported, "actual Gateway advertises tools.catalog"); guard supported else { return }
    await checkCatalogAgents { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoToolsCatalogAgentValidationChecks() async { await checkConnectedCatalogAgents(profile: .demo()) }
@MainActor func runLiveToolsCatalogAgentValidationChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Catalog read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedCatalogAgents(profile: profile)
}
