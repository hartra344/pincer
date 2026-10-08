import Foundation
@testable import PincerKit

/// Offline: leaving the demo keeps real Gateways, and the Add Gateway flow opens in the right place.
@MainActor
func runLeaveDemoOfflineChecks() {
    let (defaults, suite) = scratchDefaults()
    let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
    GatewayProfileStore.save([real], to: defaults)
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.openDemo()
    check(app.demoGateway != nil && app.selectedGatewayId == app.demoGateway?.id, "leave demo: demo added and selected")
    app.leaveDemo(connect: true)
    check(app.demoGateway == nil, "leave demo: demo removed")
    check(app.gateways.map(\.id) == [real.id], "leave demo: the real Gateway is kept")
    check(app.selectedGatewayId == real.id, "leave demo: the real Gateway is selected")
    check(app.firstRun.presentation == .sheet && app.firstRun.state.step == .findGateway,
          "leave demo: Find opens over the chat list")
    app.leaveDemo()
    check(app.gateways.map(\.id) == [real.id] && app.selectedGatewayId == real.id,
          "leave demo: leaving without a demo changes nothing")
}

/// Demo: a connected demo is removed with its local data, a saved Gateway survives, and the demo comes back fresh.
@MainActor
func runDemoLeaveDemoChecks() async {
    let (defaults, suite) = scratchDefaults()
    let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
    GatewayProfileStore.save([real], to: defaults)
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.openDemo()
    guard let demo = app.demoGateway else { return check(false, "leave demo: demo added") }
    let ready = await waitFor("demo connection") { demo.state.isConnected && !demo.sessions.isEmpty }
    check(ready, "leave demo: demo connected")
    guard ready else { return }
    let demoId = demo.id
    let key = "agent:main:main"
    await DraftStore.save(ComposerDraft(text: "unsent"), gatewayId: demoId, sessionKey: key)
    let saved = await DraftStore.load(gatewayId: demoId, sessionKey: key)
    check(saved != nil, "leave demo: draft saved")

    app.leaveDemo(connect: true)
    check(app.demoGateway == nil && !app.gateways.contains { $0.id == demoId }, "leave demo: demo removed")
    guard let kept = app.gateways.first else { return check(false, "leave demo: real Gateway kept") }
    check(app.gateways.count == 1 && kept.id == real.id && kept.profile.name == "Home"
          && kept.profile.url == "ws://127.0.0.1:1", "leave demo: real Gateway kept unchanged")
    check(app.selectedGatewayId == real.id, "leave demo: real Gateway selected")
    check(app.firstRun.presentation == .sheet && app.firstRun.state.step == .findGateway,
          "leave demo: Find opens as a sheet")
    let after = await DraftStore.load(gatewayId: demoId, sessionKey: key)
    check(after == nil, "leave demo: demo drafts wiped")
    check(TranscriptCache.cachedDigests(gatewayId: demoId).isEmpty, "leave demo: demo transcript cache wiped")

    app.openDemo()
    guard let again = app.demoGateway else { return check(false, "leave demo: demo re-entered") }
    check(again.id != demoId, "leave demo: re-entering gives a fresh demo")
    let back = await waitFor("demo reconnection") { again.state.isConnected && !again.sessions.isEmpty }
    check(back, "leave demo: re-entered demo connects")
}
