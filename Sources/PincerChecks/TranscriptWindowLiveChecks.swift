import Foundation
#if DEBUG
@testable import PincerKit

// Windowed transcript against a mock started with MOCK_LONG_CHAT=<n> (#282): after the cache start is
// reached, older pages come from the Gateway at the right offset, with no gaps or duplicates.

private let longChatKey = "agent:main:dashboard:long-chat"

@MainActor
func runLiveTranscriptWindow(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let profile = GatewayProfile(name: "Mock window", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    var chats: [ChatStore] = []
    defer {
        for chat in chats { chat.stopCaching() }
        gateway.stop()
        TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    gateway.start()
    guard await waitFor("window connect", timeout: 25, { gateway.state.isConnected && !gateway.sessions.isEmpty }) else {
        return check(false, "connected for the window check")
    }
    guard gateway.sessions[longChatKey] != nil else {
        print("  · mock has no long chat (start it with MOCK_LONG_CHAT=400); skipped")
        return
    }
    func makeChat() -> ChatStore {
        let chat = ChatStore(sessionKey: longChatKey, agentId: "main", gateway: gateway, headless: false)
        chat.windowLimit = 50
        chats.append(chat)
        return chat
    }

    // The reference: the whole transcript paged in from the Gateway.
    let reference = makeChat()
    await reference.load()
    _ = await waitFor("long chat history") { reference.hasLoaded }
    var pages = 0
    while reference.hasMoreHistory, pages < 200 {
        guard await reference.loadOlder() else { break }
        pages += 1
    }
    let all = reference.items.map(\.id)
    let stamps = reference.items.compactMap(\.timestamp)
    check(all.count > 150 && Set(all).count == all.count && stamps.count == all.count && zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 },
          "the long chat pages in whole from the Gateway (\(all.count) items, \(pages) pages, no duplicates, in order)")

    // A cache holding only the newest 150 items; the rest is on the Gateway only. The reference's
    // own save must land first, or it can overwrite this cache with the whole transcript.
    await reference.finishCaching()
    await TranscriptCache.flush(gatewayId: gateway.id)
    await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: longChatKey)
    let cachedCount = 150
    await TranscriptCache.save(TranscriptCache.Snapshot(items: Array(reference.items.suffix(cachedCount)), complete: false, activityMs: nil),
                               gatewayId: gateway.id, sessionKey: longChatKey)
    await TranscriptCache.flush(gatewayId: gateway.id)

    let reopened = makeChat()
    await reopened.restoreFromCache()
    reopened.hasLoaded = true
    let window = reopened.items.count
    check(window >= 50 && window <= 53 && reopened.olderInCache && reopened.hasMoreHistory,
          "reopening the partly cached chat loads only its window (\(window) items)")
    var rounds = 0
    while reopened.hasOlderItems, rounds < 200 {
        guard await reopened.loadOlder() else { break }
        rounds += 1
    }
    let paged = reopened.items.map(\.id)
    check(paged == all, "cache pages then Gateway pages join with no gap or duplicate (\(paged.count) of \(all.count) items, \(rounds) pages)")
    check(!reopened.hasOlderItems, "nothing older is reported once the start is reached")

    // Items that merged several messages leave the cache shorter than the span it covers, so the
    // Gateway offset from the cache start underestimates and the first page overlaps the cache.
    // Without message ids (MOCK_HISTORY_NO_IDS=1) the overlap can't be deduped by id.
    var thinned = Array(reference.items.suffix(cachedCount))
    for index in stride(from: thinned.count - 5, to: 10, by: -12) { thinned.remove(at: index) }
    await reopened.finishCaching()
    await TranscriptCache.flush(gatewayId: gateway.id)
    await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: longChatKey)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: thinned, complete: false, activityMs: nil),
                               gatewayId: gateway.id, sessionKey: longChatKey)
    await TranscriptCache.flush(gatewayId: gateway.id)
    let overlapped = makeChat()
    await overlapped.restoreFromCache()
    overlapped.hasLoaded = true
    rounds = 0
    while overlapped.hasOlderItems, rounds < 200 {
        guard await overlapped.loadOlder() else { break }
        rounds += 1
    }
    let seen = overlapped.items.map { "\($0.timestamp?.timeIntervalSince1970 ?? 0)|\($0.plainText)" }
    let idless = reference.items.contains { $0.transcriptId == nil }
    check(Set(overlapped.items.map(\.id)).count == overlapped.items.count && Set(seen).count == seen.count,
          "paging from an underestimated offset adds no duplicate or colliding items (\(overlapped.items.count) items, ids \(idless ? "index-based" : "stable"))")
    let stamps2 = overlapped.items.compactMap(\.timestamp)
    check(stamps2.count == overlapped.items.count && zip(stamps2, stamps2.dropFirst()).allSatisfy { $0 < $1 },
          "the joined transcript stays in order")
}
#else
@MainActor
func runLiveTranscriptWindow(url: String, token: String) async {
    print("  · needs a debug build; skipped")
}
#endif
