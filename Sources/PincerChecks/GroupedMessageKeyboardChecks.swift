import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runGroupedMessageKeyboardChecks() {
    #if DEBUG
    var selection = TranscriptMessagePartSelection()
    let ids = ["first", "second", "third"]
    check(selection.reconcile(rowID: "row", messageIDs: ids) == "first", "grouped keyboard starts at first message")
    check(selection.move(forward: true, rowID: "row", messageIDs: ids) == "second", "Right selects the next message identity")
    check(selection.reconcile(rowID: "row", messageIDs: ["third", "second", "first"]) == "second", "same-row edits and reorder preserve selection")
    check(selection.reconcile(rowID: "row", messageIDs: ["third", "first"]) == "third", "deleted selected message falls back to first")
    check(selection.move(forward: false, rowID: "row", messageIDs: ["third", "first"]) == "third", "Left clamps at first message")
    check(selection.move(forward: true, rowID: "row", messageIDs: ["third", "first"]) == "first"
          && selection.move(forward: true, rowID: "row", messageIDs: ["third", "first"]) == "first", "Right clamps at last message")
    check(selection.reconcile(rowID: "single", messageIDs: ["only"]) == "only", "row transition resets to the new first message")
    selection.reconcile(rowID: nil, messageIDs: [])
    check(selection.rowID == nil && selection.messageID == nil, "context reset clears both identities")
    #endif
}

@MainActor
func runDemoGroupedMessageKeyboardChecks() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.cacheRoot = nil
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("grouped keyboard demo connection", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "grouped keyboard connects to seeded Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:tool-cards")
    await chat.load()
    let loaded = await waitFor("grouped keyboard seeded history") {
        chat.items.contains { $0.transcriptId == DemoBookmarks.toolsSummaryMessageId }
    }
    check(loaded, "grouped keyboard loads the real seeded multi-message tool turn")
    guard loaded else { return }
    let snapshot = chat.items
    let entries = await Task.detached { TranscriptBuilder.build(snapshot) }.value
    guard let grouped = entries.first(where: { entry in
        guard case let .assistant(turn) = entry else { return false }
        return turn.textIds.contains(DemoBookmarks.toolsExecMessageId) && turn.textIds.contains(DemoBookmarks.toolsSummaryMessageId)
    }), case let .assistant(turn) = grouped else {
        check(false, "Demo transcript builder groups both stable seeded assistant IDs")
        return
    }
    let ids = turn.textIds.compactMap { $0 }
    check(ids.count >= 2 && ids.first == DemoBookmarks.toolsExecMessageId, "Demo grouped row retains normal first-message order")
    var selection = TranscriptMessagePartSelection()
    check(selection.reconcile(rowID: grouped.id, messageIDs: ids) == ids.first, "Demo actual selector starts at first seeded span")
    check(selection.move(forward: true, rowID: grouped.id, messageIDs: ids) == ids[1], "Demo Right targets the next real seeded message")
    let selected = selection.messageID
    check(selection.reconcile(rowID: grouped.id, messageIDs: Array(ids.reversed())) == selected, "Demo same-row reorder preserves actual selected ID")
    let remaining = ids.filter { $0 != selected }
    check(selection.reconcile(rowID: grouped.id, messageIDs: remaining) == remaining.first, "Demo selected-message deletion uses deterministic first fallback")
    if let other = entries.first(where: { $0.id != grouped.id }), case let .user(item) = other, let id = item.transcriptId {
        check(selection.reconcile(rowID: other.id, messageIDs: [id]) == id, "Demo row navigation targets its real user message")
        check(selection.reconcile(rowID: grouped.id, messageIDs: ids) == ids.first, "Demo returning to grouped row resets selection")
    } else {
        check(false, "Demo includes an ordinary user row with stable identity")
    }
    #endif
}
