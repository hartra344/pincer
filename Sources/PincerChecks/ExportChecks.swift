import Foundation
import PincerKit

/// Export chat and bookmarks (#42), against the built-in demo.
@MainActor
func checkExportAndBookmarks(_ gateway: GatewayStore) async {
    let toolsKey = "agent:main:dashboard:tool-cards"
    let chat = gateway.chat(for: toolsKey)
    let items = await chat.exportItems()
    check(items != nil && !(items?.isEmpty ?? true), "export loads the tool-heavy demo chat (\(items?.count ?? 0) messages)")
    guard let items else { return }
    let header = TranscriptExport.Header(title: "MCP servers", agentName: "Claw", exportedAt: Date(timeIntervalSince1970: 0))
    let utc = TimeZone(identifier: "UTC")!
    let userText = items.first { $0.role == .user }?.plainText ?? ""
    let assistantText = "Checking the status of each server."

    let plain = TranscriptExport.markdown(items, header: header, timeZone: utc)
    check(plain.hasPrefix("# MCP servers") && plain.contains(userText) && plain.contains(assistantText),
          "Markdown export has the title, the user's message and the assistant's reply")
    check(!plain.contains("🔧") && !plain.contains("Thinking</summary>"), "tool calls and thinking are left out by default")
    let withTools = TranscriptExport.markdown(items, header: header, options: .init(includeToolCalls: true), timeZone: utc)
    check(withTools.contains("🔧") && withTools.contains("openclaw mcp") && withTools.count > plain.count,
          "tool calls appear when asked for")
    let withThinking = TranscriptExport.markdown(items, header: header, options: .init(includeThinking: true), timeZone: utc)
    let thinkingCount = items.reduce(0) { $0 + $1.blocks.filter { if case .thinking = $0 { true } else { false } }.count }
    check((thinkingCount > 0) == withThinking.contains("Thinking</summary>"), "thinking appears only when the chat has some and it's asked for")
    let text = TranscriptExport.plainText(items, header: header, options: .init(includeToolCalls: true), timeZone: utc)
    check(text.contains("[Tool: ") && text.contains(assistantText) && !text.contains("🔧"), "plain text export")

    // The whole trip history comes through, not just the latest page.
    let trip = gateway.chat(for: DemoBookmarks.tripSessionKey)
    let tripItems = await trip.exportItems()
    check(tripItems?.count == 302, "export pages the whole trip history (\(tripItems?.count ?? 0))")

    // Seeded bookmarks point at real messages.
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = BookmarkStore(gatewayId: gateway.id, defaults: defaults)
    DemoBookmarks.seed(into: store)
    check(store.bookmarks.count >= 2, "demo seeds bookmarks (\(store.bookmarks.count))")
    let before = store.bookmarks
    DemoBookmarks.seed(into: store)
    check(store.bookmarks == before, "seeding again leaves them alone")
    for bookmark in store.bookmarks {
        let ids = Set((await gateway.chat(for: bookmark.sessionKey).exportItems() ?? []).compactMap(\.transcriptId))
        check(ids.contains(bookmark.messageId), "bookmark \(bookmark.messageId) exists in \(bookmark.sessionKey)")
    }
}
