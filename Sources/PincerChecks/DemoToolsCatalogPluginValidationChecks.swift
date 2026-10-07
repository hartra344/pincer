import Foundation
@testable import PincerKit

// Official eaae0fdae778ff2711600323bc5180b28666db27 tools-catalog.ts: optional Boolean includePlugins.
// Existing mock skills.mjs fieldType.boolean and skillsParamsProblem supply exact error wording.
@MainActor private func checkCatalogPlugins(_ request: (String, JSONValue) async throws -> JSONValue) async {
    do {
        let all = try await request("tools.catalog", [:])
        guard let groups = all["groups"]?.array, !groups.isEmpty,
              groups.contains(where: { $0["source"]?.text == "plugin" }),
              groups.contains(where: { $0["source"]?.text == "core" }) else {
            check(false, "actual catalog contains nonempty core and plugin groups"); return
        }
        check(true, "actual catalog contains core and plugins")
        let included = try await request("tools.catalog", ["includePlugins": true])
        check(included == all, "omitted and true return exact full catalog")
        let excluded = try await request("tools.catalog", ["includePlugins": false])
        check(excluded["groups"]?.array == groups.filter { $0["source"]?.text != "plugin" }, "false removes only plugin groups and retains exact core groups")
        for value in [JSONValue.string("false"), .number(0), .null] {
            do {
                _ = try await request("tools.catalog", .object(["includePlugins": value]))
                check(false, "actual catalog rejects non-Boolean includePlugins")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid tools.catalog params: at /includePlugins: must be boolean", "exact canonical Boolean validation error")
            }
        }
        let after = try await request("tools.catalog", [:])
        check(after == all, "invalid read attempts leave exact catalog unchanged")
    } catch { check(false, "actual catalog controls complete") }
}
@MainActor func runDemoToolsCatalogPluginValidationOfflineChecks() async {
    let demo = DemoGateway()
    await checkCatalogPlugins { try await demo.handle($0, $1) }
}
@MainActor private func checkConnectedCatalogPlugins(profile: GatewayProfile) async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("actual catalog read connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(ready, "actual connection is ready"); guard ready else { return }
    let supported = gateway.hello?.methods.contains("tools.catalog") == true
    check(supported, "actual Gateway advertises tools.catalog"); guard supported else { return }
    await checkCatalogPlugins { try await gateway.connection.request($0, $1) }
}
@MainActor func runDemoToolsCatalogPluginValidationChecks() async { await checkConnectedCatalogPlugins(profile: .demo()) }
@MainActor func runLiveToolsCatalogPluginValidationChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Catalog read", url: url, authMode: .token)
    profile.secret = token
    await checkConnectedCatalogPlugins(profile: profile)
}
