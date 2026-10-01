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
    check(AccessibilityText.sectionState(isCollapsed: true) == "Collapsed"
          && AccessibilityText.sectionState(isCollapsed: false) == "Expanded", "a11y pass: section state values")

    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    _ = await waitFor("demo chat history") { chat.hasLoaded && !chat.entries.isEmpty }
    let replies = chat.entries.compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry { turn } else { nil }
    }
    check(!replies.isEmpty, "a11y pass: demo chat has replies to navigate (\(chat.entries.count) entries)")
    for turn in replies where !turn.body.isEmpty {
        let excerpt = AccessibilityText.streamingExcerpt(turn.body)
        check(!excerpt.isEmpty && excerpt.count <= 241, "a11y pass: streaming label of \(turn.id) starts with the reply")
        let count = turn.text.count
        if count > 1 {
            check(AccessibilityText.messagePartAction("Reply", part: 1, of: count) == "Reply, part 1 of \(count)",
                  "a11y pass: multi-message reply numbers its actions")
        }
    }

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
