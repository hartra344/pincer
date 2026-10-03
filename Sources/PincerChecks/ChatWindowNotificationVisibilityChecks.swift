import Foundation
import PincerKit

/// #379: native visibility and residency have different lifetimes.
@MainActor
func runDemoChatWindowNotificationVisibility() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.openDemo()
    guard let gateway = app.gateways.first(where: \.profile.isDemo) else {
        return check(false, "window visibility: demo added")
    }
    let key = "agent:main:dashboard:trip"
    let main = "agent:main:main"
    let ready = await waitFor("window visibility seeded demo") {
        gateway.state.isConnected && gateway.sessions[key] != nil && gateway.sessions[main] != nil
    }
    check(ready, "window visibility: connected seeded targets exist")
    guard ready else { return }
    gateway.selectedKey = main
    app.selectedGatewayId = gateway.id
    app.updateVisible()
    let ref = ChatWindowRef(gatewayId: gateway.id, sessionKey: key)
    let owner = UUID()
    let target = Notifier.Target(gatewayId: gateway.id, sessionKey: key)
    let mainTarget = Notifier.Target(gatewayId: gateway.id, sessionKey: main)
    defer { app.chatWindowClosed(ref, windowID: owner) }
    check(app.notifier.visible == mainTarget && !app.notifier.windowVisible.contains(target),
          "window visibility: main identity differs from detached seeded target")
    app.chatWindowOpened(ref, windowID: owner)
    app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
    check(app.notifier.windowVisible.contains(target), "window visibility: visible owned window suppresses its target")
    let loaded = await waitFor("visible detached seeded chat loads") { gateway.chat(for: key).hasLoaded }
    check(loaded, "window visibility: owned window loads actual seeded history")
    app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
    check(!app.notifier.windowVisible.contains(target), "window visibility: hidden owned window allows its notifications (#379)")
    check(gateway.openWindowKeys.contains(key) && gateway.chat(for: key).hasLoaded,
          "window visibility: hiding preserves loaded chat residency")
    check(app.notifier.visible == mainTarget, "window visibility: hiding detached target preserves main identity")
}
