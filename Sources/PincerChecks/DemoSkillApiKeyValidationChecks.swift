import Foundation
@testable import PincerKit

// Exact error wording is the existing mock config-variant fixture; upstream's union formatter
// may include other variant errors. The df96 schema independently requires optional String.
@MainActor private func checkSkillApiKeyValidation(_ request: (String, JSONValue) async throws -> JSONValue) async {
    var keyWasSaved = false
    do {
        let baseline = try await request("skills.status", [:])
        guard let skills = baseline["skills"]?.array, !skills.isEmpty,
              let original = skills.first(where: { $0["skillKey"]?.string == "notion" }),
              original["primaryEnv"]?.string == "NOTION_API_KEY",
              original["missing"]?["env"]?.array?.contains(.string("NOTION_API_KEY")) == true else {
            check(false, "owned known notion baseline requires its primary API key"); return
        }
        check(true, "owned actual skill baseline is nonempty and requires NOTION_API_KEY")
        let dummy = "owned-demo-api-key-validation"
        keyWasSaved = true
        let saved = try await request("skills.update", ["skillKey": "notion", "apiKey": .string(dummy)])
        check(saved["ok"]?.bool == true && saved["skillKey"]?.string == "notion" && saved["config"]?["apiKey"]?.string == "__OPENCLAW_REDACTED__", "actual dummy key save is acknowledged and redacted")
        let current = try await request("skills.status", [:])
        guard let notion = current["skills"]?.array?.first(where: { $0["skillKey"]?.string == "notion" }),
              notion["eligible"]?.bool == true && notion["missing"]?["env"]?.array?.isEmpty == true else {
            check(false, "actual saved key makes known skill ready")
            _ = try? await request("skills.update", ["skillKey": "notion", "apiKey": ""]); return
        }
        check(true, "actual saved key makes known skill ready")
        let redacted = try await Task.detached { try JSONEncoder().encode(current).range(of: Data(dummy.utf8)) == nil }.value
        check(redacted, "full actual status does not expose the dummy key")
        for value in [JSONValue.null, .number(12)] {
            do {
                _ = try await request("skills.update", ["skillKey": "notion", "apiKey": value])
                check(false, "actual local update rejects a present non-string API key")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid skills.update params: at /apiKey: must be string", "invalid API key retains canonical mock config-field error")
            }
            let after = try await request("skills.status", [:])
            check(after == current, "invalid key request preserves the entire saved actual report")
        }
        let cleared = try await request("skills.update", ["skillKey": "notion", "apiKey": ""])
        let keyAbsent: Bool
        if case .none = cleared["config"]?["apiKey"] { keyAbsent = true } else { keyAbsent = false }
        check(cleared["ok"]?.bool == true && keyAbsent, "legal empty key clears the local value")
        let restored = try await request("skills.status", [:])
        check(restored == baseline, "empty key restores the complete owned baseline")
        keyWasSaved = false
    } catch {
        check(false, "actual local API key controls complete")
        if keyWasSaved { _ = try? await request("skills.update", ["skillKey": "notion", "apiKey": ""]) }
    }
}
@MainActor func runDemoSkillApiKeyOfflineChecks() async {
    let demo = DemoGateway()
    await checkSkillApiKeyValidation { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedSkillApiKey(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("owned skill key connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual owned skill key connection is ready"); guard ready else { return }
    let methods = gateway.hello?.methods ?? []
    let supported = methods.contains("skills.status") && methods.contains("skills.update")
    check(supported, "actual Gateway advertises existing local skill methods"); guard supported else { return }
    await checkSkillApiKeyValidation { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoSkillApiKeyChecks() async { await checkConnectedSkillApiKey(profile: .demo()) }
@MainActor func runLiveSkillApiKeyChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Owned skill key fixture", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedSkillApiKey(profile: profile)
}
