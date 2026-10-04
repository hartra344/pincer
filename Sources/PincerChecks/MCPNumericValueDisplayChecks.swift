import Foundation
@testable import PincerKit

@MainActor func runMCPNumericValueDisplayChecks() {
    let source = json(#"{"command":"fixture","env":{"HUGE":1e30,"INT":42,"FRACTION":1.25,"BOOL":true,"SECRET":"__OPENCLAW_REDACTED__"},"headers":{"NEGATIVE":-1e30}}"#)
    guard let server = MCPServer(name: "numeric", json: source) else { check(false, "actual MCP decoder accepts fixture"); return }
    check(server.env.first { $0.key == "HUGE" }?.value == String(1e30)
          && server.headers.first?.value == String(-1e30), "actual MCP env and headers safely display oversized numbers")
    check(server.env.first { $0.key == "INT" }?.value == "42" && server.env.first { $0.key == "FRACTION" }?.value == "1.25"
          && server.env.first { $0.key == "BOOL" }?.value == "true", "ordinary MCP scalar display is unchanged")
    check(server.env.first { $0.key == "SECRET" }?.isRedacted == true && server.raw == source,
          "MCP display retains redaction and original configuration")
}

@MainActor func runDemoMCPNumericValueDisplayChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("MCP numeric Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "MCP numeric checks connect to genuine Demo"); return
    }
    var reads = 0, writes = 0
    let settings = GatewaySettingsModel(request: { method, params, timeout in
        if method == "config.patch" || method == "config.apply" { writes += 1 }
        let response = try await gateway.connection.request(method, params, timeout: timeout)
        guard method == "config.get" else { return response }
        reads += 1
        let field = ["resolved", "sourceConfig", "parsed", "config"].first { response[$0] != nil } ?? "config"
        let config = response[field] ?? [:]
        // Explicit local read fixture on genuine seeded config; never change the Demo's saved data.
        let overlay: JSONValue = ["mcp": ["servers": ["numeric-display": ["command": "fixture", "env": ["HUGE": .number(1e30)],
                                                                           "headers": ["NEGATIVE": .number(-1e30)]]]]]
        return response.applyingMergePatch(.object([field: config.applyingMergePatch(overlay)]))
    }, scopes: { gateway.hello?.scopes ?? [] })
    await settings.reloadConfig()
    let model = MCPServersModel(settings: settings, request: { try await gateway.connection.request($0, $1) })
    let server = model.savedServer("numeric-display")
    check(reads > 0 && server?.env.first?.value == String(1e30) && server?.headers.first?.value == String(-1e30),
          "actual connected settings model displays explicit numeric read-overlay values")
    check(server?.raw["env"]?["HUGE"]?.double == 1e30 && writes == 0,
          "numeric display retains source values without saving configuration")
}
