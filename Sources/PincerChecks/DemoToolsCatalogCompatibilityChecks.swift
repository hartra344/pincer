import Foundation
@testable import PincerKit

@MainActor func runDemoToolsCatalogCompatibilityChecks() async {
    let demo = DemoGateway()
    do {
        let all = try await demo.handle("tools.catalog", ["agentId": "research"])
        guard let groups = all["groups"]?.array, !groups.isEmpty else {
            check(false, "actual research catalog has groups"); return
        }
        let included = try await demo.handle("tools.catalog", ["agentId": " research ", "includePlugins": true])
        check(all["agentId"]?.text == "research" && included == all,
              "existing trimmed research resolution retains exact full catalog")
        let hasCore = groups.contains { $0["source"]?.text == "core" }
        let hasPlugin = groups.contains { $0["source"]?.text == "plugin" }
        check(hasCore && hasPlugin, "research has actual core and plugin groups")
        let excluded = try await demo.handle("tools.catalog", ["agentId": "research", "includePlugins": false])
        check(excluded["groups"]?.array == groups.filter { $0["source"]?.text != "plugin" }, "research false retains exact non-plugin groups")
        let cases: [(JSONValue, String)] = [
            (.object(["agentId": "pincer-missing-agent"]), "unknown agent id \"pincer-missing-agent\""),
            (.object(["extra": true, "includePlugins": "false"]), "invalid tools.catalog params: must NOT have additional properties (extra)"),
        ]
        for (params, expected) in cases {
            do {
                _ = try await demo.handle("tools.catalog", params)
                check(false, "existing invalid catalog request fails")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == expected, "existing catalog error and priority unchanged")
            }
        }
    } catch { check(false, "catalog compatibility controls complete") }
}
