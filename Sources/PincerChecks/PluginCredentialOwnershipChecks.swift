import Foundation
@testable import PincerKit

@MainActor private final class CredentialInspectionGate {
    var entered = false
    var calls = 0
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func release() { released = true; waiter?.resume(); waiter = nil }
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
}

@MainActor private func checkCredentialOwnership(plugin: PluginInfo,
    request: @escaping @MainActor @Sendable (String, JSONValue, TimeInterval) async throws -> JSONValue) async {
    let gate = CredentialInspectionGate()
    let model = GatewaySettingsModel(request: { method, params, timeout in
        check(method == "plugins.inspect" && params == ["pluginId": .string(plugin.id)] && timeout == 20,
              "credential metadata uses the existing inspect request and timeout")
        let actual = try await request(method, params, timeout)
        gate.calls += 1
        if gate.calls == 1 {
            // Explicit metadata fixture overlay, NOT a seeded Demo credential or secret.
            // The underlying real inspect response is fetched before the held boundary.
            var fixture = actual.object ?? [:]
            fixture["credentials"] = [["path": .array((plugin.configPath + ["apiKey"]).map(JSONValue.string)),
                "label": "Old metadata fixture", "envVars": ["EXAMPLE_API_KEY"], "status": "missing"]]
            await gate.hold()
            return .object(fixture)
        }
        return actual
    }, scopes: { [] })
    let old = Task { await model.loadCredentials(for: plugin) }
    defer { gate.release(); old.cancel() }
    let entered = await waitFor("held plugin inspection", { gate.entered })
    check(entered, "old inspection reaches its actual response publication boundary")
    guard entered else { return }
    await model.loadCredentials(for: plugin)
    let latest = model.credentials[plugin.id]
    check(latest == [], "latest actual inspection publishes its empty descriptor list")
    gate.release(); await old.value
    check(model.credentials[plugin.id] == latest && gate.calls == 2,
          "older fixture metadata cannot replace the newer real descriptor result")
}

@MainActor func runPluginCredentialOwnershipChecks() async {
    guard let plugin = PluginInfo(["id": "example", "name": "Example"]) else {
        check(false, "existing plugin fixture parses"); return
    }
    await checkCredentialOwnership(plugin: plugin, request: { _, _, _ in ["credentials": []] })
}

@MainActor func runDemoPluginCredentialOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("plugin inspection Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "connect to the genuine Demo plugin catalog")
    guard connected else { return }
    let result = try? await gateway.connection.request("plugins.list", [:])
    guard let plugin = result?["plugins"]?.array?.compactMap(PluginInfo.init).first else {
        check(false, "actual Demo plugins.list supplies an inspectable plugin"); return
    }
    await checkCredentialOwnership(plugin: plugin, request: { method, params, timeout in
        try await gateway.connection.request(method, params, timeout: timeout)
    })
}
