import Foundation
@testable import PincerKit

// Official df96d22d333b00929cb85582cdbe89184421b9db local skills.update enabled: optional Boolean.
// Existing mock skills.mjs fieldType.boolean and skillsParamsProblem supply exact error wording.
@MainActor private func checkSkillEnabled(_ request: (String, JSONValue) async throws -> JSONValue) async {
    var originalEnabled: Bool?
    var needsRestore = false
    do {
        let before = try await request("skills.status", [:])
        guard let rows = before["skills"]?.array, !rows.isEmpty,
              let row = rows.first(where: { $0["skillKey"]?.text == "weather" }),
              let disabled = row["disabled"]?.bool else {
            check(false, "actual seeded weather skill has Boolean state"); return
        }
        originalEnabled = !disabled
        check(true, "actual weather status is nonempty and typed")
        needsRestore = true
        let off = try await request("skills.update", ["skillKey": "weather", "enabled": false])
        check(off == JSONValue.object(["ok": true, "skillKey": "weather", "config": ["enabled": false]]), "actual disable exact update response")
        let offStatus = try await request("skills.status", [:])
        let offRows = offStatus["skills"]?.array ?? []
        check(offRows.first(where: { $0["skillKey"]?.text == "weather" })?["disabled"]?.bool == true && offRows.filter { $0["skillKey"]?.text != "weather" } == rows.filter { $0["skillKey"]?.text != "weather" }, "actual disabled readback preserves full other skills")
        let on = try await request("skills.update", ["skillKey": "weather", "enabled": true])
        check(on == JSONValue.object(["ok": true, "skillKey": "weather", "config": ["enabled": true]]), "actual enable exact update response")
        let onStatus = try await request("skills.status", [:])
        check(onStatus["skills"]?.array?.first(where: { $0["skillKey"]?.text == "weather" })?["disabled"]?.bool == false, "actual enabled readback")
        if !disabled { check(onStatus == before, "actual enable restores exact full initial enabled status") }
        for value in [JSONValue.string("false"), .number(0), .null] {
            do {
                _ = try await request("skills.update", .object(["skillKey": "weather", "enabled": value]))
                check(false, "actual update rejects invalid enabled")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid skills.update params: at /enabled: must be boolean", "exact canonical enabled Boolean error")
            }
            let after = try await request("skills.status", [:])
            check(after == onStatus, "rejected update retains exact full skill status")
        }
        _ = try await request("skills.update", .object(["skillKey": "weather", "enabled": .bool(!disabled)]))
        needsRestore = false
        let restored = try await request("skills.status", [:])
        check(restored == before, "actual original full status restored")
    } catch { check(false, "actual enabled update controls complete") }
    if needsRestore, let originalEnabled {
        do { _ = try await request("skills.update", .object(["skillKey": "weather", "enabled": .bool(originalEnabled)])) }
        catch { check(false, "original enabled state cleanup completes") }
    }
}
@MainActor func runDemoSkillEnabledValidationOfflineChecks() async {
    let demo = DemoGateway()
    await checkSkillEnabled { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedSkillEnabled(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual skill update connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("skills.update") == true && gateway.hello?.methods.contains("skills.status") == true
    check(supported, "actual Gateway advertises skill status and update"); guard supported else { return }
    await checkSkillEnabled { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoSkillEnabledValidationChecks() async { await checkConnectedSkillEnabled(profile: .demo()) }
@MainActor func runLiveSkillEnabledValidationChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Skill enabled update", url: url, authMode: .token, access: .admin)
    profile.secret = token
    await checkConnectedSkillEnabled(profile: profile)
}
