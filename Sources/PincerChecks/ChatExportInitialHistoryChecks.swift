import Foundation
@testable import PincerKit

@MainActor func runChatExportInitialHistoryChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Offline export", url: "ws://127.0.0.1:1", authMode: .none), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    let chat = gateway.chat(for: "agent:main:missing")
    defer { chat.stopCaching(); gateway.stop() }
    let missing = await chat.exportItems()
    check(!chat.hasLoaded && chat.items.isEmpty, "offline export has no initial history or usable cache")
    check(missing == nil, "unavailable initial history rejects export instead of empty success")
    chat.hasLoaded = true
    let empty = await chat.exportItems()
    check(empty == [], "successfully loaded empty history remains exportable")
}

@MainActor func runDemoChatExportInitialHistoryChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("export history Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "genuine Demo export connection is ready")
    guard connected else { return }
    let key = DemoBookmarks.tripSessionKey
    let current = gateway.chat(for: key)
    defer { current.stopCaching() }
    await current.load()
    let complete = await current.loadFullHistory()
    check(complete && !current.hasOlderItems, "genuine seeded history has complete export coverage")
    guard complete && !current.hasOlderItems else { return }
    let expected = current.items.filter { !$0.isPending }
    check(current.hasLoaded && expected.count == 302, "genuine seeded history loads all 302 committed messages")
    guard current.hasLoaded && expected.count == 302 else { return }
    let exported = await current.exportItems()
    check(exported == expected, "ordinary real Demo history exports exact committed messages")
    // A separate disconnected Demo instance has no local cache; no RPC overlay or server write.
    let offline = GatewayStore(profile: .demo(), defaults: defaults)
    offline.cacheRoot = nil; offline.outboxRoot = nil; offline.notifier = nil
    let missing = offline.chat(for: key)
    defer { missing.stopCaching(); offline.stop() }
    let unavailable = await missing.exportItems()
    check(!missing.hasLoaded && missing.items.isEmpty, "disconnected Demo has no usable local history")
    check(unavailable == nil, "disconnected missing Demo history cannot become an empty export")
}
