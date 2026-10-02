import PincerKit

@MainActor
func runSidebarSplitPaneChecks() {
    let key = "agent:main:dashboard:notes"
    check(SidebarSplitPaneMarker.isVisible(sessionKey: key, splitKey: key),
          "the chat in the visible split pane carries its sidebar marker")
    check(!SidebarSplitPaneMarker.isVisible(sessionKey: "agent:main:main", splitKey: key),
          "the other pane's chat does not inherit the split marker")
    check(!SidebarSplitPaneMarker.isVisible(sessionKey: key, splitKey: nil),
          "an assigned but hidden split pane leaves no shown-in-pane marker")
}

@MainActor
func runDemoSidebarSplitPaneChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    defer { gateway.stop() }
    let ready = await waitFor("demo split marker sessions", timeout: 25) {
        gateway.state.isConnected && gateway.sessions.count >= 2
    }
    check(ready, "demo sessions are available for split marker membership")
    guard ready else { return }
    let keys = gateway.sessions.keys.sorted()
    let left = keys[0]
    let right = keys[1]
    gateway.selectedKey = left
    gateway.openInSplit(right)
    let configured = gateway.visibleSplitKey
    check(configured == right
          && SidebarSplitPaneMarker.isVisible(sessionKey: right, splitKey: configured)
          && !SidebarSplitPaneMarker.isVisible(sessionKey: left, splitKey: configured),
          "the actual demo split target identifies only its matching sidebar row")
    check(!SidebarSplitPaneMarker.isVisible(sessionKey: right, splitKey: nil),
          "a hidden demo pane removes the marker while its target remains assigned")
}
