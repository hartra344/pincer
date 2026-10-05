import Foundation
@testable import PincerKit

@MainActor func runChatWindowCommandTargetChecks() {
    let id = UUID()
    let main = ChatWindowCommandTarget(ref: .init(gatewayId: id, sessionKey: "agent:main:main"), isDetached: false)
    let front = ChatWindowCommandTarget(ref: .init(gatewayId: id, sessionKey: "agent:main:front"), isDetached: true)
    check(ChatWindowCommandTarget.resolve(main: main, focused: front) == front, "front detached chat owns the new-window target")
    check(ChatWindowCommandTarget.resolve(main: main, focused: nil) == main, "ordinary main target remains unchanged")
    check(ChatWindowCommandTarget.resolve(main: main, focused: main)?.isDetached == false, "main split target retains main context")
}
@MainActor func runDemoChatWindowCommandTargetChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let mainKey = DemoBookmarks.tripSessionKey, frontKey = "agent:main:dashboard:garden"
    let ready = await waitFor("window command Demo contexts", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[mainKey] != nil && gateway.sessions[frontKey] != nil
    }
    check(ready && mainKey != frontKey, "actual Demo supplies distinct main and front chats"); guard ready else { return }
    gateway.selectedKey = mainKey
    guard let mainFocused = gateway.focusedKey else { check(false, "actual main context exists"); return }
    let main = ChatWindowCommandTarget(ref: .init(gatewayId: gateway.id, sessionKey: mainFocused), isDetached: false)
    let front = ChatWindowCommandTarget(ref: .init(gatewayId: gateway.id, sessionKey: frontKey), isDetached: true)
    check(ChatWindowCommandTarget.resolve(main: main, focused: front) == front, "command resolves actual detached Demo chat instead of main selection")
    gateway.openInSplit(frontKey); gateway.splitPaneFocused = true
    guard let splitKey = gateway.focusedKey else { check(false, "actual split context exists"); return }
    let split = ChatWindowCommandTarget(ref: .init(gatewayId: gateway.id, sessionKey: splitKey), isDetached: false)
    check(splitKey == frontKey && ChatWindowCommandTarget.resolve(main: split, focused: split) == split,
          "actual focused main split preserves its target and context")
    // These are actual stored chat contexts; no claim about native foreground FocusedValues dispatch.
}
