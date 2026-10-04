import Foundation
@testable import PincerKit

@MainActor
private func checkDottedConfigRevert(settings: GatewaySettingsModel, servers: MCPServersModel) {
    let name = "acme.docs"
    let path = MCPServers.path + [name, "connectionTimeoutMs"]
    let schema = ConfigSchema(schema: ["type": "object", "properties": ["mcp": ["type": "object",
        "properties": ["servers": ["type": "object", "properties": ["acme.docs": ["type": "object",
            "properties": ["connectionTimeoutMs": ["type": "integer"]]]]]]]]])
    guard let field = schema.field(at: path, value: 15000),
          let saved = settings.savedValue(at: MCPServers.path + [name]) else {
        check(false, "dotted server and actual integer form field are available")
        return
    }
    // Local-only draft entry, copied from genuine loaded config in the Demo. Nothing is saved.
    settings.set(MCPServers.path + ["acme"], saved)
    defer { settings.discardChanges() }
    settings.setText("not-a-number", for: field)
    let error = settings.inputError(for: field)
    check(error != nil && settings.saveBlocker != nil, "invalid dotted-server input blocks Save before Undo")
    servers.remove("acme")
    check(servers.isRemoved("acme") == false && servers.server("acme") == nil,
          "removing the unsaved local server drops its actual draft entry")
    servers.undoRemove("acme")
    check(settings.text(for: field) == "not-a-number" && settings.inputError(for: field) == error && error != nil,
          "Undo of acme preserves acme.docs raw input and exact error")
    check(settings.saveBlocker != nil, "Undo cannot silently clear the sibling's Save blocker")
    settings.revert(MCPServers.path + [name])
    check(settings.inputError(for: field) == nil, "reverting the actual dotted server clears its own descendant input")
}

@MainActor
func runDottedConfigRevertChecks() async {
    var edits = ConfigEdits()
    edits.texts[["a.b"]] = "literal"
    edits.texts[["a", "b"]] = "nested"
    edits.inputErrors[["a.b"]] = "invalid literal"
    edits.inputErrors[["a", "b"]] = "invalid nested"
    let acknowledged = ConfigEdits.acknowledging(intent: .init(), latest: edits, base: edits.base)
    check(acknowledged.texts == edits.texts && acknowledged.inputErrors == edits.inputErrors,
          "acknowledgment preserves both structurally distinct field buffers")
    edits.revert(["a", "b"])
    check(edits.texts[["a.b"]] == "literal" && edits.inputErrors[["a.b"]] != nil
          && edits.texts[["a", "b"]] == nil, "identical display paths do not alias draft ownership")
    edits.revert([])
    check(edits.texts.isEmpty && edits.inputErrors.isEmpty, "root revert clears all structural buffers")
    edits.texts[["a.b"]] = "again"
    edits.discardAll()
    check(edits.texts.isEmpty, "discard clears field buffers")
    let config: JSONValue = ["mcp": ["servers": ["acme.docs": ["command": "docs", "connectionTimeoutMs": 15000]]]]
    let settings = GatewaySettingsModel(request: { method, _, _ in
        check(method == "config.get", "local revert fixture only loads config")
        return ["resolved": config, "hash": "fixture", "valid": true]
    }, scopes: { [GatewayConnection.adminScope] })
    await settings.reloadConfig()
    checkDottedConfigRevert(settings: settings, servers: MCPServersModel(settings: settings, request: { _, _ in
        check(false, "local Remove and Undo never send an RPC")
        return [:]
    }))
}

@MainActor
func runDemoDottedConfigRevertChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("dotted config Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "connect to the genuine Demo Gateway")
    guard connected else { return }
    await gateway.settings.reloadConfig()
    check(gateway.mcp.savedServer("acme.docs") != nil, "actual Demo config contains the seeded dotted server")
    checkDottedConfigRevert(settings: gateway.settings, servers: gateway.mcp)
}
