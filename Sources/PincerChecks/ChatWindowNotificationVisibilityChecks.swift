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

    let secondOwner = UUID()
    app.chatWindowOpened(ref, windowID: secondOwner)
    app.chatWindowVisibilityChanged(ref, windowID: secondOwner, isVisible: true)
    app.chatWindowClosed(ref, windowID: owner)
    check(app.notifier.windowVisible.contains(target) && gateway.openWindowKeys.contains(key),
          "window visibility: closing hidden owner preserves second visible owner")
    app.chatWindowVisibilityChanged(ref, windowID: secondOwner, isVisible: false)
    check(!app.notifier.windowVisible.contains(target) && gateway.chat(for: key).hasLoaded,
          "window visibility: last hidden owner permits notifications while history stays resident")
    app.chatWindowClosed(ref, windowID: secondOwner)
    check(!gateway.openWindowKeys.contains(key), "window visibility: last owner close releases residency")

    app.chatWindowOpened(ref)
    app.chatWindowOpened(ref, windowID: owner)
    app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: false)
    check(app.notifier.windowVisible.contains(target), "window visibility: legacy visible window survives owned hidden report")
    app.chatWindowClosed(ref)
    check(!app.notifier.windowVisible.contains(target) && gateway.openWindowKeys.contains(key),
          "window visibility: closing legacy window does not unpin hidden owned window")
    app.chatWindowClosed(ref, windowID: owner)

    let garden = ChatWindowRef(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:garden")
    app.chatWindowOpened(ref, windowID: owner)
    app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
    app.chatWindowOpened(garden, windowID: owner)
    app.chatWindowVisibilityChanged(garden, windowID: owner, isVisible: true)
    app.chatWindowClosed(ref, windowID: owner)
    app.chatWindowVisibilityChanged(ref, windowID: owner, isVisible: true)
    check(gateway.openWindowKeys.contains(garden.sessionKey) && !gateway.openWindowKeys.contains(key)
          && !app.notifier.windowVisible.contains(target),
          "window visibility: stale old target cannot close or resurrect rebound owner")
    app.chatWindowClosed(garden, windowID: owner)

    if let doomed = await gateway.createSession(agentId: "main", label: "Window visibility removal probe", select: false) {
        let listed = await waitFor("window visibility removal source") { gateway.sessions[doomed] != nil }
        check(listed, "window visibility: deletion probe is an actual listed Demo chat")
        if listed {
            let deletedRef = ChatWindowRef(gatewayId: gateway.id, sessionKey: doomed)
            app.chatWindowOpened(deletedRef, windowID: owner)
            app.chatWindowVisibilityChanged(deletedRef, windowID: owner, isVisible: true)
            await gateway.sessionManager.load(filter: .all)
            let removed = await gateway.sessionManager.delete([doomed])
            let gone = await waitFor("window visibility deleted source") { gateway.sessions[doomed] == nil }
            check(removed.succeeded.contains(doomed) && gone, "window visibility: Demo deletes the owned source through real session management")
            app.chatWindowVisibilityChanged(deletedRef, windowID: owner, isVisible: true)
            check(!gateway.openWindowKeys.contains(doomed) && !app.notifier.windowVisible.contains(Notifier.Target(gatewayId: gateway.id, sessionKey: doomed)),
                  "window visibility: stale report for deleted connected source releases its owner")
        }
    } else {
        check(false, "window visibility: Demo creates deletion probe")
    }
}
