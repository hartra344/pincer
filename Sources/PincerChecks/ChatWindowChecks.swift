import Foundation
import PincerKit

/// A separate chat window pins its chat on the demo gateway and releases it on close (#48).
@MainActor
func runDemoChatWindows() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.openDemo()
    guard let demo = app.gateways.first(where: \.profile.isDemo) else { return check(false, "chat windows: demo added") }
    let ready = await waitFor("demo connection") { demo.state.isConnected && !demo.sessions.isEmpty }
    check(ready, "chat windows: demo connected")
    guard ready else { return }
    let key = "agent:main:dashboard:trip"
    let ref = ChatWindowRef(gatewayId: demo.id, sessionKey: key)
    let target = Notifier.Target(gatewayId: demo.id, sessionKey: key)
    app.chatWindowOpened(ref)
    check(demo.openWindowKeys.contains(key),
          "an open window is tracked by the gateway (pinning is covered by unit tests)")
    check(app.notifier.windowVisible.contains(target), "an open window suppresses its notifications")
    let loaded = await waitFor("window chat loads") { demo.chat(for: key).hasLoaded }
    check(loaded, "an open window loads its chat")
    app.chatWindowClosed(ref)
    check(!demo.openWindowKeys.contains(key) && !app.notifier.windowVisible.contains(target),
          "closing the window releases the chat")
}
