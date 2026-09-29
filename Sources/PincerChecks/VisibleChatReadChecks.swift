import Foundation
import PincerKit

/// #374: a demo reply that lands in the chat on screen is read at once; one that lands while the
/// app is away stays unread (so it notifies) until the chat is on screen again.
@MainActor
func runDemoVisibleChatRead() async {
    let (defaults, defaultsName) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
    let gateway = app.add(.demo(), secret: nil)
    let ready = await waitFor("demo connection") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "visible-chat demo connected")
    guard ready else { return }
    let key = "agent:main:dashboard:trip"
    app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: key))
    app.mainChatVisible = true
    check(gateway.visibleChatKeys == [key], "the main window reports the open chat as visible")
    let chat = gateway.chat(for: key)

    func reply() async -> Bool {
        await chat.send("hello")
        return await waitFor("demo reply", timeout: 20) { !chat.isRunning && gateway.sessions[key]?.hasActiveRun == false }
    }

    let first = await reply()
    check(first, "the demo replied in the open chat")
    let read = await waitFor("open chat read") { gateway.sessions[key]?.isUnread == false }
    check(read, "a reply in the chat on screen doesn't leave it unread")

    app.mainChatVisible = false
    check(gateway.visibleChatKeys.isEmpty, "in the background nothing is visible")
    let second = await reply()
    check(second, "the demo replied while the app was away")
    let unread = await waitFor("away chat unread") { gateway.sessions[key]?.isUnread == true }
    check(unread, "a reply while away leaves the chat unread")

    app.mainChatVisible = true
    let caughtUp = await waitFor("read on return") { gateway.sessions[key]?.isUnread == false }
    check(caughtUp, "coming back to the chat marks it read")
}
