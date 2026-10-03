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

func messageItem(_ id: String, _ role: ChatRole, _ text: String, at seconds: Double, via: String? = nil) -> ChatItem {
    var item = ChatItem(id: id, role: role, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: seconds))
    item.transcriptId = id
    item.via = via
    return item
}

func messageHit(_ key: String, _ entry: String, section: Int = 0, at seconds: Double?, text: String = "hit") -> MessageSearch.Hit {
    MessageSearch.Hit(sessionKey: key, entryId: entry, section: section, role: .assistant,
                      timestamp: seconds.map { Date(timeIntervalSince1970: $0) }, text: text)
}

/// Pure message search logic: what's indexed, query building, verification, snippets, grouping, dates.
@MainActor
func checkMessageSearchLogic() {
    check(MessageSearch.ftsQuery("  Café  Tokyo ") == #""cafe"* "tokyo"*"#, "query words become folded, quoted prefixes")
    check(MessageSearch.ftsQuery("a") == nil && MessageSearch.ftsQuery("??") == nil && MessageSearch.ftsQuery("") == nil
          && MessageSearch.ftsQuery("   ") == nil, "too short or no words: nothing to search")
    check(MessageSearch.ftsQuery("a tokyo") == #""tokyo"*"#, "one-letter words are dropped")
    let hostile = MessageSearch.ftsQuery(#"foo AND "bar" NEAR( -x*"#)
    check(hostile == #""foo"* "and"* "bar"* "near"*"#, "FTS syntax typed is quoted as words (\(hostile ?? "nil"))")

    let items = [
        messageItem("u1", .user, "Hello from the lab", at: 1000, via: "Discord"),
        ChatItem(json(#"{"role":"assistant","content":[{"type":"thinking","thinking":"secret thinking"},{"type":"text","text":"First reply"},{"type":"toolCall","id":"t1","name":"exec","arguments":{"command":"grep toolword"}}],"timestamp":2000,"__openclaw":{"id":"a1"}}"#), fallbackIndex: 1)!,
        ChatItem(json(#"{"role":"toolResult","toolCallId":"t1","toolName":"exec","content":[{"type":"text","text":"toolword output"}],"timestamp":2500,"__openclaw":{"id":"t1r"}}"#), fallbackIndex: 2)!,
        ChatItem(json(#"{"role":"assistant","content":[{"type":"text","text":"Second reply"}],"timestamp":3000,"__openclaw":{"id":"a2"}}"#), fallbackIndex: 3)!,
        ChatItem(json(#"{"role":"marker","kind":"compaction","__openclaw":{"id":"m1","kind":"compaction"}}"#), fallbackIndex: 4)!,
        ChatItem(id: "p1", role: .user, blocks: [.text("pending words")], isPending: true),
    ]
    let documents = MessageSearch.documents(sessionKey: "k", items: items)
    let entries = TranscriptBuilder.build(items.filter { !$0.isPending })
    check(documents.count == 3, "documents: a user message and an assistant turn's two texts (got \(documents.count))")
    if documents.count == 3 {
        let user = documents[0]
        check(user.entryId == entries[0].id && user.section == 0 && user.role == .user && user.via == "Discord"
              && user.timestamp == Date(timeIntervalSince1970: 1000) && user.text == "Hello from the lab", "user message document keeps via")
        check(documents[1].entryId == entries[1].id && documents[2].entryId == entries[1].id
              && documents.dropFirst().map(\.section) == [0, 1] && documents.dropFirst().allSatisfy { $0.role == .assistant },
              "assistant texts are sections of the turn's entry")
        check(documents[1].timestamp == Date(timeIntervalSince1970: 2000) && documents[2].timestamp == Date(timeIntervalSince1970: 3000),
              "each assistant text has its own timestamp")
        check(documents.allSatisfy { $0.sessionKey == "k" } && documents[1].match
              == TranscriptSearch.Match(entryId: entries[1].id, section: .message(0), occurrence: 0), "document match is Find's")
    }
    check(!documents.contains { $0.text.contains("secret") || $0.text.contains("toolword") || $0.text.contains("pending") },
          "thinking, tools, markers and pending messages aren't indexed")

    check(!MessageSearch.verify(query: "zebra", markdown: "See [the docs](https://zebra.example) now"), "link target alone doesn't verify")
    check(MessageSearch.verify(query: "hello world", markdown: "**hello** world"), "phrase verifies across styling")
    check(!MessageSearch.verify(query: "japan trip", markdown: "Japan, trip"), "punctuation breaks a phrase")
    check(MessageSearch.verify(query: "CAFÉ", markdown: "the cafe"), "verification ignores case and accents")

    // Every verified document is a match Find reports, and every message match Find reports is verified.
    let fixture = json(#"""
    [
     {"role":"user","content":"Where is the Café receipt? The **hello** world receipt.","__openclaw":{"id":"f1"}},
     {"role":"assistant","content":[{"type":"text","text":"See [docs](https://x.example/receipt) and the receipt."}],"__openclaw":{"id":"f2"}},
     {"role":"assistant","content":[{"type":"text","text":"Day 7? Hello, world. `receipt` in code."}],"__openclaw":{"id":"f3"}},
     {"role":"user","content":"Japan, trip. trip to Japan","__openclaw":{"id":"f4"}},
     {"role":"assistant","content":[{"type":"thinking","thinking":"receipt thinking"},{"type":"text","text":"| a | b |\n|---|---|\n| cafe | day 7? |"}],"__openclaw":{"id":"f5"}}
    ]
    """#).array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
    let fixtureEntries = TranscriptBuilder.build(fixture)
    let fixtureDocuments = MessageSearch.documents(sessionKey: "k", items: fixture)
    var agrees = true
    for query in ["receipt", "hello world", "café", "the", "day 7?", "japan trip", "trip to", "world.", "x.example"] {
        let verified = Set(fixtureDocuments.filter { MessageSearch.verify(query: query, markdown: $0.text) }.map(\.match))
        let found = TranscriptSearch.matches(query, in: fixtureEntries)
        let firsts = Set(found.filter { $0.occurrence == 0 })
        if verified != firsts {
            agrees = false
            print("    \(query): verified \(verified.map(\.entryId).sorted()) vs Find \(firsts.map(\.entryId).sorted())")
        }
    }
    check(agrees, "verified hits are exactly the messages Find in Chat matches")

    let lobster = MessageSearch.snippet(query: "lobster", markdown: "🦞 **lobster** time and lobster again")
    check(lobster.text == "🦞 lobster time and lobster again"
          && lobster.highlights == [NSRange(location: 3, length: 7), NSRange(location: 20, length: 7)],
          "snippet highlights are UTF-16 ranges (\(lobster.highlights))")
    let far = MessageSearch.snippet(query: "target", markdown: String(repeating: "filler ", count: 60) + "the target word " + String(repeating: "tail ", count: 40))
    let farText = far.text as NSString
    check(far.text.hasPrefix("…") && far.text.hasSuffix("…") && far.highlights.count == 1
          && far.highlights.first.map { farText.substring(with: $0) } == "target", "far match: leading … and the match in view")
    check(farText.length <= 140, "snippet respects the length cap (\(farText.length))")
    let lines = MessageSearch.snippet(query: "two", markdown: "line one\nline two\n\n- item   three\n\n```\ncode  block\n```")
    check(!lines.text.contains("\n") && !lines.text.contains("\u{2028}") && !lines.text.contains("  ")
          && lines.text.contains("line one line two"), "snippet collapses newlines and spaces (\(lines.text.debugDescription))")
    let capped = MessageSearch.snippet(query: "start", markdown: "start " + String(repeating: "word ", count: 200), maxLength: 60)
    check((capped.text as NSString).length <= 60 && capped.text.hasPrefix("start") && capped.text.hasSuffix("…"),
          "custom cap, match at the start keeps no leading …")
    let emoji = MessageSearch.snippet(query: "end", markdown: String(repeating: "🦞", count: 100) + " end", maxLength: 50)
    check((emoji.text as NSString).length <= 50 && emoji.highlights.count == 1 && !emoji.text.unicodeScalars.contains { $0.value == 0xFFFD },
          "cuts never split a surrogate pair")

    let groups = MessageSearch.group([
        messageHit("A", "a1", at: 10), messageHit("B", "b1", at: 20), messageHit("A", "a2", at: 5),
        messageHit("A", "a3", at: 4), messageHit("A", "a4", at: 3), messageHit("C", "c1", at: 30),
        messageHit("B", "b0", at: nil),
    ], allowed: ["A", "B"])
    check(groups.map(\.sessionKey) == ["B", "A"], "chats ordered by newest hit; keys not allowed dropped")
    check(groups.last?.hits.map(\.entryId) == ["a1", "a2", "a3"] && groups.last?.hasMore == true, "3 per chat, the 4th sets hasMore")
    check(groups.first?.hits.map(\.entryId) == ["b1", "b0"] && groups.first?.hasMore == false, "undated hits sort last")
    let three = MessageSearch.group((1...3).map { messageHit("A", "a\($0)", at: Double($0)) }, allowed: ["A"])
    check(three.first?.hits.count == 3 && three.first?.hasMore == false, "exactly 3 hits: no More")
    let many = MessageSearch.group((0..<5).map { messageHit("K\($0)", "e", at: Double($0)) }, allowed: Set((0..<5).map { "K\($0)" }), maxChats: 2)
    check(many.map(\.sessionKey) == ["K4", "K3"], "maxChats caps the chats")
    let collected = MessageSearch.collect([
        messageHit("A", "x1", at: 9, text: "the Japan trip"), messageHit("A", "x2", at: 8, text: "Japan, trip"),
        messageHit("A", "x3", at: 7, text: "japan trip"), messageHit("A", "x4", at: 6, text: "JAPAN TRIP"),
        messageHit("A", "x5", at: 5, text: "japan trip"), messageHit("Z", "z1", at: 99, text: "japan trip"),
    ], query: "japan trip", allowed: ["A"])
    check(collected.count == 1 && collected[0].hits.map(\.entryId) == ["x1", "x3", "x4"] && collected[0].hasMore,
          "collect verifies, caps and drops other chats")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let locale = Locale(identifier: "en_US")
    let now = Date(timeIntervalSince1970: 1_790_434_800) // Sat Sep 26 2026 15:00 UTC
    func label(_ seconds: Double) -> String {
        MessageSearch.dateLabel(Date(timeIntervalSince1970: seconds), now: now, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    check(label(1_790_413_500) == "9:05 AM", "today: the time (\(label(1_790_413_500)))")
    check(label(1_790_434_800 - 86400) == "Yesterday", "yesterday (\(label(1_790_434_800 - 86400)))")
    check(label(1_790_434_800 - 2 * 86400) == "Thursday", "this week: the weekday (\(label(1_790_434_800 - 2 * 86400)))")
    check(label(1_790_434_800 - 7 * 86400) == "Sep 19", "a week ago: the date (\(label(1_790_434_800 - 7 * 86400)))")
    check(label(1_772_632_800) == "Mar 4", "this year: month and day (\(label(1_772_632_800)))")
    check(label(1_741_096_800) == "Mar 4, 2025", "older: with the year (\(label(1_741_096_800)))")

    let matches = [
        TranscriptSearch.Match(entryId: "u-1", section: .message(0), occurrence: 0),
        TranscriptSearch.Match(entryId: "a-2", section: .message(1), occurrence: 0),
        TranscriptSearch.Match(entryId: "a-3", section: .message(0), occurrence: 0),
    ]
    let rows = ["u-1": 0, "a-2": 1, "a-3": 2]
    check(TranscriptSearch.reselect(nil, in: matches, rowIndex: rows, near: nil, preferred: matches[0]) == 0,
          "the preferred match wins over the latest")
    check(TranscriptSearch.reselect(matches[2], in: matches, rowIndex: rows, near: 2, preferred: matches[1]) == 1,
          "the preferred match wins over the previous selection")
    let missing = TranscriptSearch.Match(entryId: "gone", section: .message(0), occurrence: 0)
    check(TranscriptSearch.reselect(nil, in: matches, rowIndex: rows, near: nil, preferred: missing) == 2
          && TranscriptSearch.reselect(matches[0], in: matches, rowIndex: rows, near: 0, preferred: missing) == 0,
          "a missing preferred match falls back to the usual rules")
    check(TranscriptSearch.messageMatchCount("receipt", markdown: "receipt, [receipt](https://receipt.example) **receipt**") == 3
          && TranscriptSearch.messageMatchCount("  ", markdown: "x") == 0, "messageMatchCount counts rendered occurrences")
}

/// Message results as palette rows.
@MainActor
func checkPaletteMessages() {
    let gateway = GatewayStore(profile: GatewayProfile(name: "Palette", url: "ws://127.0.0.1:1", authMode: .none))
    let prefix = gateway.id.uuidString
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_790_434_800)
    let userHit = MessageSearch.Hit(sessionKey: "trip", entryId: "u-1", section: 0, role: .user, via: "Discord",
                                    timestamp: Date(timeIntervalSince1970: 1_790_413_500), text: "ramen tonight")
    let agentHit = MessageSearch.Hit(sessionKey: "trip", entryId: "a-2", section: 1, role: .assistant,
                                     timestamp: Date(timeIntervalSince1970: 1_741_096_800), text: "more ramen")
    let oldHit = MessageSearch.Hit(sessionKey: "old", entryId: "u-9", section: 0, role: .user, timestamp: nil, text: "ramen")
    let snippet = MessageSearch.Snippet(text: "ramen tonight", highlights: [NSRange(location: 0, length: 5)])
    let results = MessageSearch.Results(query: "ramen", chats: [
        MessageSearch.Chat(sessionKey: "trip", title: "Japan trip", messages: [
            MessageSearch.Message(hit: userHit, sender: "via Discord", snippet: snippet),
            MessageSearch.Message(hit: agentHit, sender: "Main", snippet: snippet),
        ], hasMore: true),
        MessageSearch.Chat(sessionKey: "old", title: "Old", isArchived: true,
                           messages: [MessageSearch.Message(hit: oldHit, sender: "You", snippet: snippet)]),
    ])
    let items = CommandPalette.messageItems(results, gateway: gateway, now: now, calendar: calendar)
    let trip = Notifier.Target(gatewayId: gateway.id, sessionKey: "trip")
    check(items.map(\.id) == [
        "messages:chat:\(prefix):trip", "message:\(prefix):trip:u-1:0", "message:\(prefix):trip:a-2:1", "messages:more:\(prefix):trip",
        "messages:chat:\(prefix):old", "message:\(prefix):old:u-9:0",
    ] && Set(items.map(\.id)).count == items.count, "rows: header, messages, More; unique ids")
    check(items.allSatisfy { $0.section == .messages }, "all in the Messages section")
    check(items[0].isHeader && !items[0].isSelectable && items[0].title == "Japan trip" && items[4].title == "Old · Archived"
          && items.filter(\.isHeader).count == 2, "headers: chat title, archived marked, not selectable")
    check(items[1].title == "via Discord" && items[2].title == "Main" && items[1].snippet == snippet && items[1].isSelectable
          && items[1].date == userHit.timestamp && items[5].date == nil && items[5].shortcut == nil, "rows: sender, snippet, date")
    let today = items[1].shortcut?.replacingOccurrences(of: "\u{202F}", with: " ")
    check(today == MessageSearch.dateLabel(userHit.timestamp!, now: now, calendar: calendar).replacingOccurrences(of: "\u{202F}", with: " ")
          && items[2].shortcut == MessageSearch.dateLabel(agentHit.timestamp!, now: now, calendar: calendar), "rows: date label (\(today ?? "nil"))")
    check(items[1].action == .openMessage(trip, query: "ramen", match: TranscriptSearch.Match(entryId: "u-1", section: .message(0), occurrence: 0))
          && items[2].action == .openMessage(trip, query: "ramen", match: TranscriptSearch.Match(entryId: "a-2", section: .message(1), occurrence: 0)),
          "a row opens its chat at its match")
    check(items[3].action == .findInChat(trip, query: "ramen") && items[3].title.contains("Japan trip") && items[3].isSelectable,
          "More opens Find in the chat")
    check(CommandPalette.messageItems(MessageSearch.Results(query: "x"), gateway: gateway).isEmpty, "no results, no rows")

    check(CommandPalette.searchMessagesItem(query: "a") == nil && CommandPalette.searchMessagesItem(query: " a  ") == nil
          && CommandPalette.searchMessagesItem(query: "") == nil, "Search Messages needs 2 characters")
    let search = CommandPalette.searchMessagesItem(query: "  ab ")
    check(search?.action == .searchMessages("ab") && search?.title.contains("“ab”") == true, "Search Messages for “q”")
    func row(_ id: String, _ section: PaletteItem.Section) -> PaletteItem {
        PaletteItem(id: id, title: id, symbol: "x", section: section, action: .command(id))
    }
    let ranked = [row("chat1", .chats), row("chat2", .chats), row("new", .newChat), row("cmd", .commands)]
    check(CommandPalette.addingSearchMessages(to: ranked, query: "ab", gatewaySelected: true).map(\.id)
          == ["chat1", "chat2", "command:searchMessages", "new", "cmd"], "Search Messages right after the chats")
    check(CommandPalette.addingSearchMessages(to: [row("cmd", .commands)], query: "ab", gatewaySelected: true).map(\.id)
          == ["command:searchMessages", "cmd"], "first when no chat matches")
    check(CommandPalette.addingSearchMessages(to: [], query: "ab", gatewaySelected: true).map(\.id) == ["command:searchMessages"],
          "alone when nothing matches")
    check(CommandPalette.addingSearchMessages(to: ranked, query: "ab", gatewaySelected: false) == ranked
          && CommandPalette.addingSearchMessages(to: ranked, query: "a", gatewaySelected: true) == ranked,
          "not without a gateway or with a 1-character query")
}

/// Polls message search until `condition` holds.
@MainActor
func waitForSearch(_ gateway: GatewayStore, _ query: String, timeout: Double = 5,
                   _ condition: (MessageSearch.Results) -> Bool) async -> MessageSearch.Results?
{
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let results = try? await gateway.searchMessages(query), condition(results) { return results }
        try? await Task.sleep(for: .milliseconds(100))
    } while Date() < deadline
    print("    … timed out waiting for message search “\(query)”")
    return nil
}

/// Demo: older history found in its chat, only listed chats, back-to-back searches, and new messages.
@MainActor
func checkDemoMessageSearch(_ gateway: GatewayStore, trip: ChatStore) async {
    let tripKey = "agent:main:dashboard:trip"
    let findMatches = TranscriptSearch.matches("idea #12", in: trip.entries)
    let olderIndex = findMatches.first.flatMap { match in trip.entries.firstIndex { $0.id == match.entryId } } ?? .max
    check(findMatches.count == 1 && olderIndex < trip.entries.count - 120,
          "idea #12 is in older history (row \(olderIndex) of \(trip.entries.count))")
    let dayResults = await waitForSearch(gateway, "idea #12") { $0.chats.contains { $0.sessionKey == tripKey } }
    let dayChat = dayResults?.chats.first { $0.sessionKey == tripKey }
    let dayMessage = dayChat?.messages.first
    check(dayChat?.title == "Japan trip" && dayChat?.messages.count == 1 && dayMessage?.hit.entryId == findMatches.first?.entryId
          && dayMessage?.sender != "You", "older history is found in its chat (\(dayChat?.messages.map(\.hit.entryId) ?? []))")
    check(dayMessage.map { findMatches.contains($0.match) } == true, "the result is a match Find in Chat selects")
    check(dayMessage?.snippet.highlights.first.map { (dayMessage!.snippet.text as NSString).substring(with: $0) } == "Idea #12",
          "the snippet highlights the match")
    let ramen = await waitForSearch(gateway, "ramen") { $0.chats.first?.sessionKey == tripKey }
    check(ramen?.chats.first?.messages.count == 3 && ramen?.chats.first?.hasMore == true, "common word: newest 3 and More")

    let papers = await waitForSearch(gateway, "consistency models", timeout: 15) {
        $0.chats.contains { $0.sessionKey == "agent:research:dashboard:papers" }
    }
    check(papers != nil, "a chat never opened is found once prefetched")
    let subagent = (try? await gateway.searchMessages("retrieval-augmented")) ?? MessageSearch.Results(query: "")
    check(!subagent.chats.contains { $0.sessionKey.contains(":subagent:") }, "subagent runs never appear")

    let stale = Task { @MainActor in try await gateway.searchMessages("ramen") }
    stale.cancel()
    let latest = try? await gateway.searchMessages("consistency models")
    var staleCancelled = false
    if case let .failure(error) = await stale.result { staleCancelled = error is CancellationError }
    check(staleCancelled && latest?.chats.map(\.sessionKey) == ["agent:research:dashboard:papers"],
          "back-to-back searches: the replaced one is cancelled, the latest answers")
    await checkAsync({ await ((try? gateway.searchMessages("x"))?.isEmpty == true) }, "a 1-character search is empty")
}

/// Demo: the seeded search terms suggested in the docs hit the chats they're written into.
@MainActor
func checkDemoSeededSearchTerms(_ gateway: GatewayStore, trip: ChatStore) async {
    let tripKey = "agent:main:dashboard:trip", mainKey = "agent:main:main", homeLab = "agent:main:discord:channel:123"
    let forge = "agent:coder:main", scout = "agent:research:main"
    // Every chat is prefetched in the background; wait until the last of them is searchable.
    let backup = await waitForSearch(gateway, "backup", timeout: 20) { $0.chats.count >= 5 }
    let newestHits = backup?.chats.map { $0.messages.compactMap(\.hit.timestamp).max() ?? .distantPast } ?? []
    let longChat = "agent:main:dashboard:lab-migration"
    check(backup.map { Set($0.chats.map(\.sessionKey)) } == [mainKey, homeLab, forge, tripKey, longChat]
          && newestHits == newestHits.sorted(by: >),
          "“backup” is found in five chats, newest first (\(backup?.chats.map(\.title) ?? []))")
    check(backup?.chats.first { $0.sessionKey == homeLab }?.messages.contains { $0.sender == "via Discord" } == true,
          "a bridged message names its channel as the sender")
    let productSearch = await waitForSearch(gateway, "proxmox backup server", timeout: 20) {
        $0.chats.contains { $0.sessionKey == longChat }
    }
    check(productSearch?.chats.map(\.sessionKey) == [longChat],
          "the full Proxmox Backup Server product name is searchable in Home-lab migration")

    let ghibli = await waitForSearch(gateway, "ghibli") { !$0.isEmpty }
    let ghibliIds = ghibli?.chats.first?.messages.map(\.hit.entryId) ?? []
    let firstPage = Set(trip.entries.suffix(120).map(\.id))
    check(ghibli?.chats.map(\.sessionKey) == [tripKey] && ghibliIds.count == 3 && ghibli?.chats.first?.hasMore == true
          && ghibliIds.allSatisfy { !firstPage.contains($0) },
          "“ghibli” is only in the trip's older history (\(ghibliIds))")
    check(ghibli?.chats.first?.messages.first.map { message in
        message.snippet.highlights.map { (message.snippet.text as NSString).substring(with: $0) } == ["Ghibli"]
    } == true, "the Ghibli snippet highlights the word")
    let onsen = try? await gateway.searchMessages("onsen")
    check(onsen?.chats.map(\.sessionKey) == [tripKey], "“onsen” is found in the trip")

    for query in ["café", "cafe", "CAFE"] {
        let results = await waitForSearch(gateway, query) { $0.chats.count >= 2 }
        check(results.map { Set($0.chats.map(\.sessionKey)) } == [mainKey, tripKey],
              "“\(query)” matches Café in Main and the trip (\(results?.chats.map(\.title) ?? []))")
    }
    let lumiere = try? await gateway.searchMessages("cafe lumiere")
    let lumiereSnippet = lumiere?.chats.first?.messages.first?.snippet
    check(lumiere?.chats.map(\.sessionKey) == [mainKey] && lumiere?.chats.first?.messages.count == 3
          && lumiereSnippet.map { snippet in snippet.highlights.map { (snippet.text as NSString).substring(with: $0) } == ["Café Lumière"] } == true,
          "an accented phrase is found without accents and highlighted as written")
    let tokyo = try? await gateway.searchMessages("tokyo")
    check(tokyo.map { Set($0.chats.map(\.sessionKey)).isSuperset(of: [mainKey, tripKey, scout]) } == true,
          "“tokyo” spans Main, the trip and Scout (\(tokyo?.chats.map(\.title) ?? []))")
    let todai = try? await gateway.searchMessages("todai")
    check(todai?.chats.map(\.sessionKey) == [tripKey], "a macron is folded (todai finds Tōdai-ji)")
    let passport = try? await gateway.searchMessages("passport")
    check(passport?.chats.map(\.sessionKey) == [mainKey] && passport?.chats.first?.messages.count == 2,
          "“passport” finds the reminder in Main")
    let dated = backup?.chats.flatMap(\.messages).compactMap(\.hit.timestamp) ?? []
    check(!dated.isEmpty && dated.allSatisfy { $0 < Date().addingTimeInterval(-3 * 86400) },
          "seeded results carry their past dates")
}

/// Demo with the transcript cache off: the index lives in memory, so search still works.
@MainActor
func checkDemoSearchWithoutCache() async {
    // The demo GatewayStore (and its prefetch and search) resolves TranscriptCache.root on its own
    // and takes no root, so the cache is switched off through the environment for this check.
    let previous = ProcessInfo.processInfo.environment["PINCER_CACHE_DIR"]
    setenv("PINCER_CACHE_DIR", "off", 1)
    defer {
        if let previous { setenv("PINCER_CACHE_DIR", previous, 1) } else { unsetenv("PINCER_CACHE_DIR") }
    }
    let gateway = GatewayStore(profile: .demo())
    defer {
        gateway.stop()
        TranscriptCache.removeAll(gatewayId: gateway.id)
    }
    check(gateway.messageIndexProgress == .ready && MessageIndex.location(gatewayId: gateway.id) == .memory,
          "cache off: the demo keeps its index in memory")
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo connection (cache off)") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "cache off: demo connected")
    guard connected else { return }
    let backup = await waitForSearch(gateway, "backup", timeout: 20) { $0.chats.count >= 5 }
    check(backup?.chats.count == 5, "cache off: prefetched chats are searchable (\(backup?.chats.map(\.title) ?? []))")
    let ghibli = await waitForSearch(gateway, "ghibli") { !$0.isEmpty }
    check(ghibli?.chats.first?.messages.count == 3, "cache off: older history is searchable")
    let chat = gateway.chat(for: "agent:research:main")
    await chat.load()
    await checkDemoSentMessageSearch(gateway, chat)
    check(gateway.messageIndexProgress == .ready, "cache off: index ready (\(gateway.messageIndexProgress))")

    let other = GatewayStore(profile: GatewayProfile(name: "Plain", url: "ws://127.0.0.1:9", authMode: .none))
    check(other.messageIndexProgress == .unavailable && MessageIndex.location(gatewayId: other.id) == nil,
          "cache off: other gateways still have no search")
}

/// Demo: a message sent now is searchable within 3 s.
@MainActor
func checkDemoSentMessageSearch(_ gateway: GatewayStore, _ chat: ChatStore) async {
    let token = "qz" + String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(8))
    await chat.send("remember \(token) please")
    let sent = Date()
    let found = await waitForSearch(gateway, token, timeout: 3) { !$0.isEmpty }
    let elapsed = Date().timeIntervalSince(sent)
    check(found?.chats.first?.sessionKey == chat.sessionKey && found?.chats.first?.messages.first?.sender == "You",
          "a sent message is searchable in \(String(format: "%.1f", elapsed)) s")
    _ = await waitFor("reply after search check", timeout: 20) { !chat.isRunning }
}

/// Live: a filled chat's older history, and a chat only the background prefetch cached, are searchable.
@MainActor
func checkLiveMessageSearch(_ gateway: GatewayStore) async {
    let tripKey = "agent:main:dashboard:trip"
    let day = await waitForSearch(gateway, "day 7?", timeout: 10) { $0.chats.contains { $0.sessionKey == tripKey } }
    let message = day?.chats.first { $0.sessionKey == tripKey }?.messages.first
    check(message?.snippet.text == "Idea for day 7?" && message?.sender == "You", "live: older history of a filled chat is searchable")
    let prefetched = await waitForSearch(gateway, "diffusion papers", timeout: 20) { !$0.isEmpty }
    check(prefetched?.chats.allSatisfy { !$0.sessionKey.contains(":subagent:") } == true,
          "live: a chat cached by the background prefetch is searchable (\(prefetched?.chats.map(\.sessionKey) ?? []))")
    check(gateway.messageIndexProgress == .ready, "live: index ready after reconcile (\(gateway.messageIndexProgress))")
}

/// A quick end-to-end pass over the message index: save a transcript, search it, jump data.
@MainActor
func checkMessageSearchSmoke() async {
    await withScratchCache { root in
        await checkMessageSearchSmoke(root: root)
    }
}

@MainActor
private func checkMessageSearchSmoke(root: URL) async {
    let gatewayId = UUID()
    let items = [
        ChatItem(json(#"{"role":"user","content":"Planning the **Japan** trip to Tōkyō","__openclaw":{"id":"u1"}}"#), fallbackIndex: 0)!,
        ChatItem(json(#"{"role":"assistant","content":[{"type":"thinking","thinking":"secret zebra"},{"type":"text","text":"Try the café in [Kyoto](https://zebra.example)"}],"__openclaw":{"id":"a1"}}"#), fallbackIndex: 1)!,
    ]
    await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gatewayId, sessionKey: "chat-1", root: root)
    let index = MessageIndex.shared(gatewayId: gatewayId, root: root)
    let hits = (try? await index.search("tokyo")) ?? []
    check(hits.count == 1 && hits.first?.entryId == "u-u1", "saved transcript is searchable (accents folded)")
    let cafe = (try? await index.search("CAFE")) ?? []
    check(cafe.count == 1 && cafe.first?.entryId == "a-a1", "case and accents are ignored")
    let zebra = MessageSearch.collect((try? await index.search("zebra")) ?? [], query: "zebra", allowed: ["chat-1"])
    check(zebra.isEmpty, "thinking and link targets don't match")
    let groups = MessageSearch.collect((try? await index.search("kyoto")) ?? [], query: "kyoto", allowed: ["chat-1"])
    check(groups.first?.hits.first?.match == TranscriptSearch.Match(entryId: "a-a1", section: .message(0), occurrence: 0),
          "a verified hit is the match Find reports")
    check(MessageIndex.url(gatewayId: gatewayId, root: root).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == true,
          "index file sits next to the transcripts")
    TranscriptCache.removeAll(gatewayId: gatewayId, root: root)
    check(MessageIndex.url(gatewayId: gatewayId, root: root).map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == true,
          "removing the gateway deletes its index")
    let removed = (try? await MessageIndex.shared(gatewayId: gatewayId, root: root).search("tokyo")) ?? []
    check(removed.isEmpty, "search after removal is empty")
}
