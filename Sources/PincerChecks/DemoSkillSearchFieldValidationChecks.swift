import Foundation
@testable import PincerKit

// Official cbe3ff13b844546d355dc3593a9df562e59c0204 validates optional NonEmptyString query
// and optional integer limit 1...100 before the ClawHub read. No external registry writes.
@MainActor private func checkSkillSearchFields(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let all = try await request("skills.search", [:])
        guard let allRows = all["results"]?.array, !allRows.isEmpty,
              allRows.contains(where: { $0["slug"]?.text == "nas-report" }) else {
            check(false, "actual seeded default search has nonempty nas-report inventory"); return
        }
        check(true, "actual default search is available")
        let limited = try await request("skills.search", ["query": "nas", "limit": 1])
        check(limited["results"]?.array?.count == 1 && limited["results"]?[0]?["slug"]?.text == "nas-report",
              "actual query and limit return the seeded matching skill")
        let cases: [(String, JSONValue, String)] = [
            ("limit", .number(0), "must be >= 1"), ("limit", .number(101), "must be <= 100"),
            ("limit", .number(1.5), "must be integer"), ("limit", .null, "must be integer"),
            ("query", .string(""), "must NOT have fewer than 1 characters"),
            ("query", .null, "must be string"), ("query", .number(12), "must be string"),
        ]
        for (field, value, problem) in cases {
            do {
                _ = try await request("skills.search", .object([field: value]))
                check(false, "actual search rejects invalid \(field) field")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid skills.search params: at /\(field): \(problem)",
                      "invalid \(field) keeps exact canonical field validation error")
            }
        }
    } catch { check(false, "actual skill search read controls complete") }
}
@MainActor func runDemoSkillSearchFieldValidationOfflineChecks() async {
    let demo = DemoGateway()
    await checkSkillSearchFields { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedSkillSearchFields(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual skill search read connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("skills.search") == true
    check(supported, "actual Gateway advertises skills.search"); guard supported else { return }
    await checkSkillSearchFields { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoSkillSearchFieldValidationChecks() async { await checkConnectedSkillSearchFields(profile: .demo()) }
@MainActor func runLiveSkillSearchFieldValidationChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Skill search read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedSkillSearchFields(profile: profile)
}
