import Foundation
import PincerKit

/// A cold external route is provisional; an explicit newer demo route still opens at once.
@MainActor
func runDemoColdLaunchRouteChecks() async {
    let (defaults, suite) = scratchDefaults()
    let offline = GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none)
    GatewayProfileStore.save([offline], to: defaults)
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        defaults.removePersistentDomain(forName: suite)
    }
    app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:dashboard:remote"))
    check(app.routeNotice == nil && app.gatewayListRequests == 0,
          "cold link: an unlisted saved Gateway does not immediately reject the route")
    let demoKey = "agent:main:main"
    app.open(PincerRoute(gateway: .demo, sessionKey: demoKey))
    let selected = app.selectedGateway
    check(selected?.profile.isDemo == true && selected?.selectedKey == demoKey,
          "cold link: a newer known demo route opens immediately")
    let ready = await waitFor("demo after cold link") { selected?.state.isConnected == true }
    check(ready && app.routeNotice == nil && app.selectedGatewayId == selected?.id,
          "cold link: pending work does not replace the newer demo navigation")
}

/// Actual successful cross-device fallback while an additional saved Gateway stays offline.
@MainActor
func runLiveColdLaunchRouteChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let live = GatewayProfile(name: "Mock", url: url, authMode: .token)
    let offline = GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none)
    GatewayProfileStore.save([live, offline], to: defaults)
    live.secret = token
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        defaults.removePersistentDomain(forName: suite)
    }
    let key = "agent:main:discord:channel:123"
    let route = PincerRoute(gateway: .id(UUID()), sessionKey: key, messageId: "msg-123")
    app.open(route)
    check(app.routeNotice == nil && app.gatewayListRequests == 0,
          "cold link live: pending before the first connection/list")
    app.start()
    let opened = await waitFor("cold link live resolution", timeout: 25) {
        app.selectedGatewayId == live.id && app.selectedGateway?.selectedKey == key
    }
    check(opened && app.routeNotice == nil,
          "cold link live: listed chat opens despite an offline second Gateway")
    let target = Notifier.Target(gatewayId: live.id, sessionKey: key)
    check(app.takeMessageJump(for: target)?.messageId == "msg-123",
          "cold link live: delayed navigation preserves its message jump")
}
