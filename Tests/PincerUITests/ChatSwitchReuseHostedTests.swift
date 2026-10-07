#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

/// #571: switching chats in the real `RootView` keeps the transcript's table and only swaps its context.
@MainActor
@Suite("Chat switch reuses the chat view", .serialized, .timeLimit(.minutes(2)))
struct ChatSwitchReuseHostedTests {
    private func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor { found.append(table) }
        for sub in view.subviews { found += self.tables(in: sub) }
        return found
    }

    private func transcript(in window: NSWindow, key: String) -> (NSTableView, TranscriptList.Coordinator)? {
        guard let content = window.contentView else { return nil }
        for table in self.tables(in: content) {
            if let coordinator = table.delegate as? TranscriptList.Coordinator,
               coordinator.controller.context.sessionKey == key { return (table, coordinator) }
        }
        return nil
    }

    @Test func switchingChatsKeepsTheTranscriptTable() async throws {
        _ = NSApplication.shared
        let scratch = ScratchDefaults()
        GatewayProfileStore.save([.demo()], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults, identity: UIFixtures.identity())
        let gateway = try #require(app.gateways.first)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        app.selectedGatewayId = gateway.id
        gateway.start(); gateway.reconnectIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView().environment(app))
        window.orderFront(nil)
        defer { gateway.stop(); window.orderOut(nil); window.contentView = nil; window.close(); scratch.remove() }

        try #require(await eventually(timeout: .seconds(5)) { gateway.state.isConnected && gateway.bootstrapped })
        let candidates = gateway.sessions.values
            .filter { !$0.isSubagent && !$0.isPlaceholder && !$0.isArchived }
            .map(\.key).sorted()
        // Warm chats only: a chat still loading shows a skeleton instead of the table.
        var warm: [String] = []
        for key in candidates where warm.count < 2 {
            gateway.selectedKey = key
            let chat = gateway.chat(for: key)
            if await eventually(timeout: .seconds(5), { chat.hasLoaded && !chat.entries.isEmpty }) { warm.append(key) }
        }
        try #require(warm.count == 2)
        let (a, b) = (warm[0], warm[1])

        gateway.selectedKey = a
        try #require(await eventually(timeout: .seconds(5)) { window.contentView?.layoutSubtreeIfNeeded(); return self.transcript(in: window, key: a) != nil })
        let (tableA, coordinatorA) = try #require(self.transcript(in: window, key: a))

        gateway.selectedKey = b
        try #require(await eventually(timeout: .seconds(5)) { window.contentView?.layoutSubtreeIfNeeded(); return self.transcript(in: window, key: b) != nil })
        let (tableB, coordinatorB) = try #require(self.transcript(in: window, key: b))

        #expect(tableA === tableB, "the chat view must keep its identity across a switch")
        #expect(coordinatorA === coordinatorB)
        #expect(coordinatorB.controller.context.sessionKey == b)
        #expect(self.transcript(in: window, key: a) == nil)
    }
}
#endif
