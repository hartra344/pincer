import Foundation
#if DEBUG
@testable import PincerKit

// Windowed transcript (#282): a big cached chat opens with only its newest items, pages older ones
// back from the cache without gaps, trims at a turn boundary, and never loses older history on save.

private func windowItems(_ count: Int, from start: Int = 0) -> [ChatItem] {
    (start..<(start + count)).map { n in
        messageItem("w\(n)", n.isMultiple(of: 3) ? .user : .assistant, "window message \(n)", at: 1_700_000_000 + Double(n))
    }
}

private func windowIds(_ range: Range<Int>) -> [String] { range.map { "w\($0)" } }

@MainActor
func runTranscriptWindowChecks() async {
    guard TranscriptCache.root != nil else {
        print("  · transcript cache is off; skipped")
        return
    }
    let key = "agent:main:window"
    let total = 300
    let limit = 50
    let profile = GatewayProfile(id: UUID(), name: "Window", url: "ws://127.0.0.1:1", authMode: .none)
    let defaults = UserDefaults(suiteName: "pincer.windowchecks.\(UUID().uuidString)")!
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    func makeChat() -> ChatStore {
        let chat = ChatStore(sessionKey: key, agentId: nil, gateway: gateway, headless: false)
        chat.windowLimit = limit
        chats.append(chat)
        return chat
    }
    func cachedIds() async -> [String] {
        await TranscriptCache.flush(gatewayId: gateway.id)
        return await TranscriptCache.load(gatewayId: gateway.id, sessionKey: key)?.items.map(\.id) ?? []
    }
    var chats: [ChatStore] = []
    defer {
        for chat in chats { chat.stopCaching() }
        TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true)
    }

    await TranscriptCache.save(TranscriptCache.Snapshot(items: windowItems(total), complete: false, activityMs: 5),
                               gatewayId: gateway.id, sessionKey: key)
    await TranscriptCache.flush(gatewayId: gateway.id)

    let chat = makeChat()
    await chat.restoreFromCache()
    chat.hasLoaded = true
    let opened = chat.items.count
    check(opened >= limit && opened <= limit + 3 && chat.items.map(\.id) == windowIds((total - opened)..<total),
          "a \(total)-item cached chat restores only its newest window (\(opened) items)")
    check(chat.olderInCache && chat.hasOlderItems, "older cached items are flagged")

    let windowTail = chat.items.map(\.id)
    var gapFree = true
    var everyPageFinished = true
    var rounds = 0
    while chat.olderInCache, rounds < 100 {
        let countBeforePage = chat.items.count
        let ok = await chat.loadOlder()
        everyPageFinished = everyPageFinished && !chat.isLoadingOlder && chat.items.count > countBeforePage
        gapFree = gapFree && ok && Set(chat.items.map(\.id)).count == chat.items.count
            && Array(chat.items.suffix(windowTail.count)).map(\.id) == windowTail
        rounds += 1
    }
    check(gapFree && chat.items.map(\.id) == windowIds(0..<total), "paging older from the cache leaves no gaps or duplicates (\(rounds) pages)")
    check(rounds > 0 && everyPageFinished, "each awaited cache page applies its rows and clears the loading state before returning")
    check(!chat.olderInCache && chat.hasMoreHistory && chat.hasOlderItems && chat.olderOffset == total,
          "at the cache start Gateway paging takes over")
    let offline = await chat.loadOlder()
    check(!offline && chat.items.count == total, "an offline Gateway page reports failure and loses nothing")

    let cut = ChatStore.windowCut(windowItems(total), limit: limit)
    let cutItems = windowItems(total)
    check(cut >= total - limit && cut <= total - limit + 3 && (cut == 0 || cutItems[cut].role == .user),
          "the window cut lands on the start of a turn (index \(cut))")

    let trimmed = makeChat()
    trimmed.items = windowItems(total)
    var pending = messageItem("unsent", .user, "unsent", at: 2_000_000_000)
    pending.isPending = true
    trimmed.items.append(pending)
    trimmed.hasLoaded = true
    await trimmed.trimToWindow()
    let kept = trimmed.items.filter { !$0.isPending }
    check(kept.count <= limit && kept.count >= limit - 3 && kept.first?.role == .user && kept.map(\.id) == windowIds((total - kept.count)..<total),
          "leaving a chat trims it to a turn-aligned newest window (\(kept.count) items)")
    check(trimmed.items.last?.id == "unsent", "an unsent message survives the trim")
    let afterTrim = await cachedIds()
    check(afterTrim == windowIds(0..<total), "the trim kept the whole history on disk")

    let selected = makeChat()
    selected.items = windowItems(total)
    selected.hasLoaded = true
    gateway.selectedKey = key
    await selected.trimToWindow()
    check(selected.items.count == total, "the selected chat is never trimmed")
    gateway.selectedKey = nil

    trimmed.items.removeLast()
    trimmed.items += windowItems(2, from: total)
    await trimmed.saveSnapshot()
    let afterSave = await cachedIds()
    check(afterSave == windowIds(0..<(total + 2)), "a save after a trim keeps the older history and adds the new messages")

    let searching = makeChat()
    await searching.restoreFromCache()
    searching.hasLoaded = true
    await searching.loadAllCached()
    check(searching.items.map(\.id) == windowIds(0..<(total + 2)) && !searching.olderInCache,
          "loading all cached items makes the whole history available")

    let jumping = makeChat()
    await jumping.restoreFromCache()
    jumping.hasLoaded = true
    check(jumping.message(withId: "w3") == nil, "an old message starts outside the window")
    let found = await jumping.locate("w3")
    check(found && jumping.message(withId: "w3") != nil, "locate finds it by paging the cache")

    jumping.items += windowItems(1, from: total + 2)
    await jumping.saveSnapshot()
    let filler = makeChat()
    filler.items = windowItems(total + 2)
    filler.hasLoaded = true
    await filler.saveSnapshot()
    await TranscriptCache.flush(gatewayId: gateway.id)
    jumping.savedState = nil
    await jumping.saveSnapshot()
    let afterFill = await cachedIds()
    check(afterFill == windowIds(0..<(total + 3)), "a newer message saved by the visible chat survives a later full save")

    let windowed = makeChat()
    await TranscriptCache.save(TranscriptCache.Snapshot(items: windowItems(total), complete: true, activityMs: 5),
                               gatewayId: gateway.id, sessionKey: key)
    await windowed.restoreFromCache()
    windowed.hasLoaded = true
    check(windowed.olderInCache && windowed.snapshot().complete == false, "a window with older items on disk saves as incomplete")

    let messages: [JSONValue] = (0..<130).map { n in
        ["role": "user", "content": .string("new \(n)"), "__openclaw": ["id": .string("new\(n)")]]
    }
    windowed.apply(history: ["messages": .array(messages), "hasMore": true], parsed: ChatStore.parse(messages))
    await windowed.saveSnapshot()
    let afterReset = await cachedIds()
    check(!windowed.olderInCache && afterReset == windowed.items.map(\.id),
          "more than a page of new messages with no overlap drops the stale window and saves no gap")
}

@MainActor
func runTranscriptWindowCacheOffChecks() async {
    let profile = GatewayProfile(id: UUID(), name: "Window", url: "ws://127.0.0.1:1", authMode: .none)
    let defaults = UserDefaults(suiteName: "pincer.windowchecks.off.\(UUID().uuidString)")!
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let chat = ChatStore(sessionKey: "agent:main:window-off", agentId: nil, gateway: gateway, headless: false)
    chat.windowLimit = 50
    chat.items = windowItems(300)
    chat.hasLoaded = true
    await chat.trimToWindow()
    check(chat.items.count == 300 && !chat.olderInCache, "with the cache off a chat is never trimmed (nothing could page back)")
    chat.stopCaching()
}
#else
@MainActor
func runTranscriptWindowChecks() async {
    print("  · needs a debug build; skipped")
}

@MainActor
func runTranscriptWindowCacheOffChecks() async {}
#endif
