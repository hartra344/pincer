import Foundation
#if DEBUG
@testable import PincerKit

/// A failed older page stays retryable on the same chat after the built-in Gateway reconnects.
@MainActor
func runDemoTranscriptPagingRecovery() async {
    let suite = "PincerChecks.demoTranscriptRecovery.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let profile = GatewayProfile.demo()
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    let sessionKey = "agent:main:dashboard:trip"
    func waitForConnectionReady(_ expected: Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if await gateway.connection.isReady == expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await gateway.connection.isReady == expected
    }
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
        TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true)
    }

    gateway.start()
    let connected = await waitFor("demo paging recovery initial connect") {
        gateway.state.isConnected && gateway.sessions[sessionKey] != nil
    }
    check(connected, "demo connects for transcript paging recovery")
    guard connected else { return }

    let chat = ChatStore(sessionKey: sessionKey, agentId: "main", gateway: gateway, headless: true)
    await chat.load()
    let latestIds = chat.items.map(\.id)
    check(chat.hasLoaded && chat.items.count == 120 && chat.hasMoreHistory,
          "demo trip loads exactly its latest 120 messages with an older page available")
    guard chat.hasLoaded && chat.hasMoreHistory else { return }

    gateway.stop()
    await gateway.connection.stop()
    let stopped = await waitForConnectionReady(false)
    check(stopped, "demo connection is stopped before requesting an older page")
    let offlinePage = await chat.loadOlder()
    check(!offlinePage && chat.hasOlderItems, "offline older-page failure leaves the same trip retryable")

    gateway.start()
    let readyAgain = await waitForConnectionReady(true)
    let reconnected: Bool
    if readyAgain {
        reconnected = await waitFor("demo paging recovery reconnect") {
            gateway.state.isConnected && gateway.sessions[sessionKey] != nil
        }
    } else {
        reconnected = false
    }
    check(reconnected, "demo reconnects without replacing the chat store")
    guard reconnected else { return }

    let recoveredPage = await chat.loadOlder()
    check(recoveredPage && chat.items.count == 240 && chat.hasMoreHistory
          && Array(chat.items.suffix(latestIds.count)).map(\.id) == latestIds
          && Set(chat.items.map(\.id)).count == 240,
          "the same chat pages one older demo page after reconnect without gaps or duplicates")

    gateway.stop()
    await gateway.connection.stop()
    await TranscriptCache.flush(gatewayId: gateway.id)
}
#else
@MainActor
func runDemoTranscriptPagingRecovery() async {
    print("  · needs a debug build; skipped")
}
#endif
