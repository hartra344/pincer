import Foundation
import PincerKit

@MainActor
func runSettingsSaveRebaseChecks() async {
    let base: JSONValue = ["gateway": ["port": 18789, "bind": "loopback"]]
    var submitted = ConfigEdits(base: base)
    submitted.set(["gateway", "port"], 18790)
    var latest = submitted
    latest.revert(["gateway", "port"])
    latest.set(["gateway", "bind"], "lan")
    let admitted = submitted
    let acknowledged = admitted.current
    let captured = latest
    var local = ConfigEdits.LocalIntent()
    local.set(["gateway", "port"], 18789)
    local.set(["gateway", "bind"], "lan")
    let intent = local
    let merged = await Task.detached {
        ConfigEdits.acknowledging(intent: intent, latest: captured, base: acknowledged)
    }.value
    check(merged.baseValue(at: ["gateway", "port"]) == 18790
          && merged.value(at: ["gateway", "port"]) == 18789
          && merged.isChanged(["gateway", "port"]),
          "acknowledging a save preserves a later Revert as unsaved intent")
    check(merged.value(at: ["gateway", "bind"]) == "lan" && merged.isChanged(["gateway", "bind"]),
          "the production reconciliation preserves edits on another settings page")
    let clean = await Task.detached {
        ConfigEdits.acknowledging(intent: .init(), latest: admitted, base: acknowledged)
    }.value
    check(!clean.hasChanges, "an unchanged admitted draft becomes clean after acknowledgment")
    let newest: JSONValue = ["gateway": ["port": 18790, "bind": "auto"]]
    var externallyRebased = admitted
    _ = externallyRebased.rebase(onto: ["gateway": ["port": 18790, "bind": "lan"]])
    let refreshed = externallyRebased
    let serverOnly = await Task.detached {
        ConfigEdits.acknowledging(intent: .init(), latest: refreshed, base: newest)
    }.value
    check(serverOnly.value(at: ["gateway", "bind"]) == "auto" && !serverOnly.hasChanges,
          "an intermediate server reload does not become local settings intent")
    var nested = ConfigEdits.LocalIntent()
    nested.set(["gateway"], ["port": 19000, "bind": "lan"])
    nested.set(["gateway", "port"], 19001)
    let ordered = nested
    let parentThenChild = await Task.detached {
        ConfigEdits.acknowledging(intent: ordered, latest: admitted, base: acknowledged)
    }.value
    check(parentThenChild.value(at: ["gateway", "port"]) == 19001
          && parentThenChild.value(at: ["gateway", "bind"]) == "lan",
          "a later child setting overrides its admitted ancestor intent")
}

#if DEBUG
@testable import PincerKit
@MainActor
private final class SettingsSaveRequestGate {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        self.entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if self.released || Task.isCancelled { waiter.resume() }
                else { self.waiter = waiter }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() {
        self.released = true
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume()
    }
}

@MainActor
func runSettingsSaveRebaseDemoChecks() async {
    let namespace = "PincerChecks.settingsSave.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: namespace)!
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    gateway.start()
    defer { gateway.stop(); defaults.removePersistentDomain(forName: namespace) }
    let ready = await waitFor("demo settings save") { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "the actual Demo Gateway connects before editing settings")
    guard ready else { return }
    await gateway.settings.load()
    let path = ["mcp", "servers", "sentry", "enabled"]
    let original = gateway.settings.value(at: path)
    check(original == false, "the real seeded Sentry setting is initially disabled")
    guard original == false else { return }
    gateway.settings.set(path, true)
    let saved = await gateway.settings.save()
    check(saved && !gateway.settings.hasChanges && gateway.settings.savedValue(at: path) == true,
          "the real connected settings model acknowledges its unchanged submitted draft")
    gateway.settings.set(path, original)
    let restored = await gateway.settings.save()
    check(restored && !gateway.settings.hasChanges && gateway.settings.value(at: path) == original,
          "the connected Demo restores the actual seeded setting through the same save path")

    // Only timing is controlled: the real client params go unchanged to the connected Demo.
    let gate = SettingsSaveRequestGate()
    let model = GatewaySettingsModel(request: { method, params, timeout in
        if method == "config.patch" { await gate.wait() }
        return try await gateway.connection.request(method, params, timeout: timeout)
    }, scopes: { gateway.hello?.scopes ?? [] }, rootWritableWithoutAdmin: "mcp")
    await model.reloadConfig()
    model.set(path, true)
    let pendingSave = Task { await model.save() }
    defer { pendingSave.cancel(); gate.release() }
    let admitted = await waitFor("held real settings request") { gate.entered }
    check(admitted, "the actual settings model admits a captured request before the late edit")
    guard admitted else { return }
    model.revert(path)
    gate.release()
    let acknowledged = await pendingSave.value
    check(acknowledged && model.savedValue(at: path) == true && model.value(at: path) == false && model.isChanged(path),
          "connected Demo acknowledgment retains a newer Revert as unsaved intent")
    let finalSave = await model.save()
    check(finalSave && !model.hasChanges && model.savedValue(at: path) == false,
          "a subsequent actual save persists the retained intent and restores the seeded setting")
}
#else
@MainActor func runSettingsSaveRebaseDemoChecks() async {}
#endif
