import PincerKit

@MainActor
func runSidebarSplitActionChecks() {
    check(!SidebarSplitActionPolicy.shouldOffer(supportsSplitView: true, isCompactWidth: true),
          "compact iPad hides an action that cannot present a split")
    check(SidebarSplitActionPolicy.shouldOffer(supportsSplitView: true, isCompactWidth: false),
          "regular iPad and macOS retain the split action")
    check(!SidebarSplitActionPolicy.shouldOffer(supportsSplitView: false, isCompactWidth: false),
          "iPhone does not offer the split action at any width")
}

@MainActor
func runDemoSidebarSplitActions() async {
    let (gateway, ready) = await startStore(.demo(), waiting: "demo split sidebar chats", until: { $0.sessions.count >= 2 })
    defer { gateway.stop() }
    check(ready, "demo split sidebar has multiple chats")
    guard ready else { return }
    // The same policy used by every sidebar row reads the current layout each time.
    let widths = [false, true, false]
    let offers = widths.map { SidebarSplitActionPolicy.shouldOffer(supportsSplitView: true, isCompactWidth: $0) }
    check(offers == [true, false, true],
          "demo sidebar split action follows regular, compact, then regular layout without latching")
}
