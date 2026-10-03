import Foundation
#if DEBUG
@testable import PincerKit

/// Explicit history navigation remains available after UIKit disables status-bar tap-to-top.
/// The native hosted suite covers that gesture policy; this check covers real Demo paging,
/// message locators and preserved history through the same ChatStore paths used by message jumps.
@MainActor
func runDemoTranscriptManualNavigationChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    let chat = ChatStore(sessionKey: DemoGateway.longChatKey, agentId: "main", gateway: gateway, headless: false)
    chat.cacheRoot = nil
    chat.stopCaching()
    defer {
        chat.stopCaching()
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    gateway.start()
    let connected = await waitFor("manual history Demo connection") {
        gateway.state.isConnected && gateway.sessions[DemoGateway.longChatKey] != nil
    }
    check(connected, "manual history: actual seeded Demo long chat is connected")
    guard connected else { return }
    await chat.load()
    check(chat.hasLoaded && chat.errorMessage == nil, "manual history: interactive ChatStore loads the actual Demo transcript")
    guard chat.hasLoaded, let oldest = chat.items.first?.transcriptId,
          let newest = chat.items.last?.transcriptId else {
        return check(false, "manual history: actual Demo history supplies oldest and newest locators")
    }
    let expected = chat.items.compactMap(\.transcriptId)
    check(expected.count > 8 && !chat.hasMoreHistory, "manual history: the full seeded reference spans more than one small page")

    do {
        // Use the existing Gateway history method to obtain an actual short newest page, then
        // adopt it through load()'s normal history-adoption path. No paging state is fabricated.
        let history = try await gateway.connection.request("chat.history", [
            "sessionKey": .string(DemoGateway.longChatKey), "limit": 8,
        ])
        let parsed = await Task.detached(priority: .utility) {
            (history["messages"]?.array ?? []).enumerated().compactMap { index, message in
                ChatItem(message, fallbackIndex: index)
            }
        }.value
        chat.apply(history: history, parsed: parsed)
        check(chat.hasMoreHistory && chat.message(withId: oldest) == nil,
              "manual history: oldest message begins outside the adopted newest page")
        check(chat.items.last?.transcriptId == newest,
              "manual history: adopting a smaller page keeps the newest message locator")
        let found = await chat.locate(oldest)
        check(found && chat.message(withId: oldest)?.transcriptId == oldest,
              "manual history: explicit locate loads older Demo pages and resolves the original message")
        let actual = chat.items.compactMap(\.transcriptId)
        check(actual == expected && Set(actual).count == actual.count,
              "manual history: paging preserves complete transcript order without gaps or duplicate locators")
        check(chat.items.last?.transcriptId == newest && !chat.isLoadingOlder && chat.locatingReplyId == nil,
              "manual history: explicit navigation keeps the newest reply and releases paging/lookup state")
        let retained = chat.items.count
        let foundNewest = await chat.locate(newest)
        check(foundNewest && chat.items.count == retained,
              "manual history: navigating back to an already loaded newest message preserves all history")
    } catch {
        check(false, "manual history: Demo history navigation failed: \(error)")
    }
}
#else
@MainActor
func runDemoTranscriptManualNavigationChecks() async {
    print("  · needs a debug build; skipped")
}
#endif
