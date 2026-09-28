import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// Back/forward and ⌘1–⌘9 through `AppModel`, across two demo Gateways.
@MainActor
func runNavigation() async {
    let (defaults, defaultsName) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    guard app.gateways.isEmpty else {
        check(false, "navigation checks need an empty profile list (found \(app.gateways.count))")
        return
    }
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
    let first = app.add(.demo(), secret: nil)
    let ready = await waitFor("demo connection") { first.state.isConnected && !first.sessions.isEmpty }
    check(ready, "navigation demo connected")
    guard ready else { return }
    func target(_ gateway: GatewayStore, _ key: String) -> Notifier.Target { Notifier.Target(gatewayId: gateway.id, sessionKey: key) }
    let main = target(first, "agent:main:main")
    let trip = target(first, "agent:main:dashboard:trip")
    let papers = target(first, "agent:research:dashboard:papers")

    app.open(main)
    app.open(trip)
    app.open(papers)
    check(app.history.current == papers && app.canGoBack && !app.canGoForward, "opening chats records history")
    app.goBack()
    check(first.selectedKey == trip.sessionKey && app.history.current == trip && app.canGoForward, "Back opens the previous chat")
    // What RootView does after the selection changes; it must not disturb the history.
    app.updateVisible()
    app.goBack()
    check(first.selectedKey == main.sessionKey && !app.canGoBack, "Back again reaches the first chat")
    app.goForward()
    check(first.selectedKey == trip.sessionKey && app.history.forwardStack == [papers], "Forward retraces")
    first.selectedKey = main.sessionKey
    app.updateVisible()
    check(!app.canGoForward && app.history.current == main, "picking a chat in the sidebar clears Forward")

    app.openPinned(1)
    check(first.selectedKey == first.pinnedChats.first?.key, "⌘1 opens the first pinned chat")
    let beforeMissing = app.history.current
    app.openPinned(9)
    app.openPinned(0)
    check(app.history.current == beforeMissing, "⌘ with no pinned chat at that number does nothing")

    let requests = app.openRequests
    let match = TranscriptSearch.Match(entryId: "u-x", section: .message(0), occurrence: 0)
    app.open(trip, find: "ramen", match: match)
    check(first.selectedKey == trip.sessionKey && app.history.current == trip && app.openRequests == requests + 1,
          "opening a message result opens its chat and records history")
    check(app.takeFindRequest(for: main) == nil, "a find request is only for its chat")
    let request = app.takeFindRequest(for: trip)
    check(request?.query == "ramen" && request?.match == match && request?.target == trip, "the chat takes its find request")
    check(app.takeFindRequest(for: trip) == nil, "a find request is taken once")
    app.open(papers, find: "diffusion", match: nil)
    app.open(main, find: "welcome", match: nil)
    check(app.takeFindRequest(for: papers) == nil && app.takeFindRequest(for: main)?.query == "welcome",
          "a newer find request replaces an untaken one")

    let second = app.add(.demo(), secret: nil)
    let secondReady = await waitFor("second demo") { second.state.isConnected && !second.sessions.isEmpty }
    check(secondReady && app.selectedGatewayId == second.id, "second gateway added and selected")
    let secondTrip = target(second, "agent:main:dashboard:trip")
    app.open(secondTrip)
    let beforeSwitch = app.history.current
    app.open(papers)
    check(app.selectedGatewayId == first.id && app.history.backStack.last == beforeSwitch,
          "switching gateways records only the opened chat")
    app.goBack()
    check(app.selectedGatewayId == second.id && second.selectedKey == secondTrip.sessionKey, "Back crosses gateways")
    app.remove(second.id)
    check(!app.history.backStack.contains { $0.gatewayId == second.id } && app.history.current?.gatewayId != second.id,
          "removing a gateway drops its chats from history")
    app.goBack()
    check(app.selectedGatewayId == first.id, "Back still works after removing a gateway")
}
