import Foundation
@testable import PincerKit

// Same pinned optional NonEmptyString fields as the actual upstream status handler.
@MainActor private func checkSkillStatusFields(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let ordinary = try await request("skills.status", [:])
        guard let skills = ordinary["skills"]?.array, !skills.isEmpty,
              ordinary["agentId"]?.string == "main" else {
            check(false, "actual main status has nonempty skill inventory"); return
        }
        check(true, "actual default status is available")
        let main = try await request("skills.status", ["agentId": "main"])
        let session = try await request("skills.status", ["agentId": "main", "sessionKey": "agent:main:main"])
        check(main == ordinary && session == ordinary, "explicit main and known session retain full actual status")
        for field in ["agentId", "sessionKey"] {
            for (value, problem) in [(JSONValue.null, "must be string"), (.number(12), "must be string"),
                                      (.string(""), "must NOT have fewer than 1 characters")] {
                do {
                    _ = try await request("skills.status", .object([field: value]))
                    check(false, "actual status rejects invalid \(field)")
                } catch let GatewayError.rpc(code, message, _) {
                    check(code == "INVALID_REQUEST" && message == "invalid skills.status params: at /\(field): \(problem)",
                          "invalid \(field) retains exact canonical field error")
                }
            }
        }
        let after = try await request("skills.status", [:])
        check(after == ordinary, "invalid read requests leave full status unchanged")
    } catch { check(false, "actual status read controls complete") }
}
@MainActor func runDemoSkillStatusFieldOfflineChecks() async {
    let demo = DemoGateway()
    await checkSkillStatusFields { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedSkillStatusFields(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual skill status read connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual status connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("skills.status") == true
    check(supported, "actual Gateway advertises skills.status"); guard supported else { return }
    await checkSkillStatusFields { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoSkillStatusFieldChecks() async { await checkConnectedSkillStatusFields(profile: .demo()) }
@MainActor func runLiveSkillStatusFieldChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Skill status read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedSkillStatusFields(profile: profile)
}
