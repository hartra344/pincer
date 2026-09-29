import CoreGraphics
import Foundation
import PincerKit

// #420: the chat's scroll-to-bottom button. The list reports how far it is from the end; this
// drives the same state with the demo chat's rows as a reply arrives while scrolled up.

@MainActor
func runDemoScrollToBottom() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("demo for scroll to bottom") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for scroll to bottom connected")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    _ = await waitFor("demo main history") { chat.hasLoaded && !chat.entries.isEmpty }
    let viewport: CGFloat = 700
    var state = ScrollToBottomState()
    state.update(distance: 0, viewport: viewport, lastRowId: chat.entries.last?.id)
    check(!state.isVisible, "hidden at the bottom of the demo chat")
    state.update(distance: 2000, viewport: viewport, lastRowId: chat.entries.last?.id)
    check(state.isVisible && !state.hasNewMessages, "shows once scrolled up, no dot yet")

    let before = chat.entries.last?.id
    await chat.send("hello from the scroll-to-bottom check")
    let replied = await waitFor("demo reply") { chat.entries.last?.id != before && !chat.isRunning }
    state.update(distance: 2400, viewport: viewport, lastRowId: chat.entries.last?.id)
    check(replied && state.isVisible && state.hasNewMessages, "a reply below while scrolled up shows the dot")
    state.update(distance: 0, viewport: viewport, lastRowId: chat.entries.last?.id)
    check(!state.isVisible && !state.hasNewMessages, "back at the bottom: hidden, dot cleared")
}
