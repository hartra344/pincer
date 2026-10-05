@testable import PincerKit

@MainActor func runChatWindowTitleChecks() {
    let main = ChatWindowTitle.title("Main", isDetached: false)
    let detached = ChatWindowTitle.title("Main", isDetached: true)
    check(main == "Main", "main window preserves actual chat title")
    check(!detached.isEmpty && detached != main, "same chat in a detached window has a distinct native title")
}
@MainActor func runDemoChatWindowTitleChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let key = DemoBookmarks.tripSessionKey
    let ready = await waitFor("chat window Demo title", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil
    }
    check(ready, "actual Demo has its seeded trip session"); guard ready else { return }
    guard let title = gateway.sessions[key]?.title, !title.isEmpty else {
        check(false, "actual seeded title is nonempty"); return
    }
    let main = ChatWindowTitle.title(title, isDetached: false)
    let detached = ChatWindowTitle.title(title, isDetached: true)
    check(main == title, "main title preserves full actual Demo session title")
    check(!detached.isEmpty && detached != main, "native title distinguishes the same actual Demo chat window")
    // Presentation-context check; no claim about an actual Mission Control or Window menu host.
}
