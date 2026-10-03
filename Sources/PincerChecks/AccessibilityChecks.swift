import Foundation
import PincerKit

// #308/#209/#269/#349/#195: the accessibility pass's labels and shortcuts, driven from the demo.

@MainActor
func runDemoAccessibilityPass() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for accessibility pass") {
        gateway.state.isConnected && !gateway.sessions.isEmpty && !gateway.agents.isEmpty
    }
    check(connected, "demo for accessibility pass connected")
    guard connected else { return }
    defer { gateway.stop() }

    gateway.organization = .agent
    let agentSections = gateway.sections().filter { if case .agent = $0.kind { true } else { false } }
    check(!agentSections.isEmpty, "a11y pass: demo has agent sections")
    for section in agentSections {
        let label = AccessibilityText.newChatWith(agent: section.title)
        check(label == "New chat with \(section.title)", "a11y pass: + on \(section.title) is named (\(label))")
    }
    gateway.organization = .group
    let plainGroups = gateway.sections().filter { if case .group = $0.kind { true } else { false } }
    check(plainGroups.contains { $0.title == "Home" } && plainGroups.contains { $0.title == "Personal" },
          "a11y pass: demo supplies Home and Personal plain-group headers")
    for section in plainGroups {
        let label = AccessibilityText.newChatIn(group: section.title)
        check(label == "New chat in \(section.title)", "a11y pass: plain-group + names \(section.title) (\(label))")
    }
    gateway.organization = .agent
    check(AccessibilityText.sectionState(isCollapsed: true) == "Collapsed"
          && AccessibilityText.sectionState(isCollapsed: false) == "Expanded", "a11y pass: section state values")

#if DEBUG
    let thinkingID = "demo-main-thinking"
    ChatItem.resetThinkingTextJoinProbe(tracking: thinkingID)
    defer { ChatItem.unregisterThinkingTextJoinProbe(tracking: thinkingID) }
#endif
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    _ = await waitFor("demo chat history") { chat.hasLoaded && !chat.entries.isEmpty }
#if DEBUG
    let thinkingJoins = ChatItem.thinkingTextJoinProbeStats(for: thinkingID)
    check(chat.items.first(where: \.hasThinkingContent)?.id == thinkingID,
          "a11y pass: the actual history presence scan reaches the tracked seeded reasoning row")
    check(chat.sawThinking, "a11y pass: demo history detects its seeded thinking block")
    check(thinkingJoins.mainThreadJoins == 0,
          "a11y pass: demo thinking presence does not join transcript text on main (joins \(thinkingJoins.mainThreadJoins))")
#endif
    let replies = chat.entries.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry { turn } else { nil }
    }
    check(!replies.isEmpty, "a11y pass: demo chat has replies to navigate (\(chat.entries.count) entries)")
    let excerptCache = MessagePartExcerptCache()
    var checkedGroupedReplies = 0
    for turn in replies where !turn.body.isEmpty {
        let excerpt = AccessibilityText.streamingExcerpt(turn.body)
        check(!excerpt.isEmpty && excerpt.count <= 241, "a11y pass: streaming label of \(turn.id) starts with the reply")
        let count = turn.text.count
        if count > 1 {
            checkedGroupedReplies += 1
            check(AccessibilityText.messagePartAction("Reply", part: 1, of: count) == "Reply, part 1 of \(count)",
                  "a11y pass: multi-message reply numbers its actions")
            let sources = turn.text.map(MessagePartExcerptSource.init)
            for source in sources { _ = excerptCache.excerpt(for: source) }
            let prepared = await waitFor("a11y opening excerpts for \(turn.id)") {
                sources.allSatisfy { excerptCache.excerpt(for: $0) != nil }
            }
            let excerpts = sources.map { excerptCache.excerpt(for: $0) ?? "" }
            let spokenActions = excerpts.enumerated().map {
                AccessibilityText.messagePartAction("Reply", part: $0.offset + 1, of: count, openingExcerpt: $0.element)
            }
            let identifyOpenings = zip(spokenActions, excerpts).enumerated().allSatisfy { item in
                !item.element.1.isEmpty && item.element.0.contains("part \(item.offset + 1) of \(count)")
                    && item.element.0.contains(item.element.1)
            }
            check(prepared && spokenActions.count == count && identifyOpenings,
                  "a11y pass: each seeded multi-message action identifies its own opening")
            check(excerptCache.cachedCount <= MessagePartExcerptCache.entryLimit
                  && excerptCache.cachedByteCount <= MessagePartExcerptCache.byteLimit
                  && excerptCache.activeCount <= 1 && excerptCache.pendingCount <= 32
                  && excerptCache.pendingByteCount <= MessagePartExcerptSource.snapshotByteLimit * 32,
                  "a11y pass: opening excerpts use bounded cache and worker budgets")
        }
    }
    check(checkedGroupedReplies > 0, "a11y pass: demo includes a grouped reply for part-specific action labels")

    check(ShortcutCommand.nextMessage.defaultCombo?.displayString == "⌥⌘↓"
          && ShortcutCommand.previousMessage.defaultCombo?.displayString == "⌥⌘↑", "a11y pass: message navigation shortcuts")
    var seen: [KeyCombo: ShortcutCommand] = [:]
    var clashes: [String] = []
    for command in ShortcutCommand.allCases {
        guard let combo = command.defaultCombo else { continue }
        if let other = seen[combo] { clashes.append("\(other)/\(command)") }
        seen[combo] = command
    }
    check(clashes.isEmpty, "a11y pass: no default shortcut clashes (\(clashes))")

    // #564: ⌃⌘S toggles the sidebar; on macOS it stays the system's View menu item.
    await MainActor.run {
        let store = ShortcutStore(defaults: UserDefaults(suiteName: "pincer.checks.sidebar-toggle.\(UUID())")!)
        let combo = KeyCombo("s", [.control, .command])
        check(ShortcutCommand.toggleSidebar.defaultCombo == combo && combo.displayString == "⌃⌘S",
              "a11y pass: Toggle Sidebar defaults to ⌃⌘S")
        #if os(macOS)
        check(!ShortcutCommand.listed(in: .view).contains(.toggleSidebar) && store.commands(using: combo).isEmpty
              && store.validate(combo, for: .newChat) != .ok,
              "a11y pass: macOS keeps the system Show/Hide Sidebar and reserves ⌃⌘S")
        #else
        check(ShortcutCommand.listed(in: .view).contains(.toggleSidebar) && store.commands(using: combo) == [.toggleSidebar],
              "a11y pass: iPad lists Toggle Sidebar with ⌃⌘S")
        #endif
    }
}
