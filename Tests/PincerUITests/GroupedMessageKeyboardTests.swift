#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Grouped message keyboard actions", .serialized)
struct GroupedMessageKeyboardTests {
    @MainActor
    private final class Host {
        let scratch = ScratchDefaults()
        let gateway: GatewayStore
        let context: TranscriptContext
        let coordinator: TranscriptList.Coordinator
        let scroll: NSScrollView
        let table: NSTableView
        let window: NSWindow
        var menuTargets: [String?] = []
        var menus: [NSMenu] = []
        var replied: [String] = []
        var bookmarked: [String] = []

        init(ids: [String] = ["group-first", "group-second", "group-third"]) throws {
            _ = NSApplication.shared
            self.gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Keyboard fixture", url: "ws://127.0.0.1:1", authMode: .none),
                                        defaults: self.scratch.defaults, identity: UIFixtures.identity())
            self.gateway.cacheRoot = nil
            let chat = ChatStore(sessionKey: "keyboard", agentId: nil, gateway: self.gateway, headless: true)
            chat.items = ids.enumerated().map { index, id in
                var item = ChatItem(id: "local-\(id)", role: .assistant, blocks: [.text("Message part \(index + 1)")])
                item.transcriptId = id
                return item
            }
            chat.rebuild(itemsChanged: true)
            var context = TranscriptContext(gateway: self.gateway, disclosure: TranscriptDisclosure(),
                                            agent: AgentSummary(id: "main", name: "Claw"), sessionKey: "keyboard",
                                            previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
            // The actual menu handlers report their transcript IDs without mutating app state.
            var replies: ((String) -> Void)?
            var bookmarks: ((String) -> Void)?
            context.reply = { replies?($0) }
            context.toggleBookmark = { bookmarks?($0) }
            self.context = context
            self.coordinator = TranscriptList.Coordinator(context: context)
            self.scroll = self.coordinator.makeScrollView()
            guard let table = self.scroll.documentView as? NSTableView else {
                throw CocoaError(.coderReadCorrupt)
            }
            self.table = table
            self.window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 700, height: 700),
                                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            self.window.contentView = self.scroll
            self.scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
            self.window.orderBack(nil)
            var turn = AssistantTurn(id: "grouped-row", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
            turn.text = ids.indices.map { "Message part \($0 + 1)" }
            turn.textIds = ids.map(Optional.some)
            self.coordinator.update(rows: [.entry(.assistant(turn))], context: context, insets: (0, 0))
            self.scroll.layoutSubtreeIfNeeded()
            self.window.makeFirstResponder(self.table)
            replies = { [weak self] in self?.replied.append($0) }
            bookmarks = { [weak self] in self?.bookmarked.append($0) }
            self.coordinator.keyboardMenuProbe = { [weak self] id, menu in
                guard let self else { return true }
                if self.menuTargets.count < 16 { self.menuTargets.append(id); self.menus.append(menu) }
                return true // Suppress only native modal presentation, after real menu construction.
            }
            try self.key(125) // Establish the row through the existing actual Down-arrow path.
        }

        func update(_ groups: [(String, [String])], editedText: String = "Updated message") {
            if let chat = self.context.chat {
                chat.items = groups.flatMap { $0.1 }.map { id in
                    var item = ChatItem(id: "local-\(id)", role: .assistant, blocks: [.text(editedText)])
                    item.transcriptId = id
                    return item
                }
                chat.rebuild(itemsChanged: true)
            }
            let rows: [TranscriptRow] = groups.map { rowID, ids in
                var turn = AssistantTurn(id: rowID, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
                turn.text = ids.map { _ in editedText }
                turn.textIds = ids.map(Optional.some)
                return .entry(.assistant(turn))
            }
            self.coordinator.update(rows: rows, context: self.context, insets: (0, 0))
            self.scroll.layoutSubtreeIfNeeded()
        }

        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let characters: String
            switch code {
            case 123: characters = "\u{F702}"
            case 124: characters = "\u{F703}"
            case 125: characters = "\u{F701}"
            case 126: characters = "\u{F700}"
            case 49: characters = " "
            case 53: characters = "\u{1B}"
            default: characters = "\r"
            }
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: self.window.windowNumber, context: nil,
                                                     characters: characters, charactersIgnoringModifiers: characters,
                                                     isARepeat: false, keyCode: code))
            self.table.keyDown(with: event)
        }

        func stop() {
            self.coordinator.keyboardMenuProbe = nil
            self.window.orderOut(nil)
            self.gateway.stop()
            self.scratch.remove()
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: [UInt16(36), UInt16(49), UInt16(76)])
    func actualRightArrowChangesTheMessageTargetOfReturnAndSpace(_ menuKey: UInt16) throws {
        let host = try Host()
        defer { host.stop() }
        #expect(host.window.firstResponder === host.table)
        try host.key(124) // Actual AppKit responder path; no test-owned selection state.
        try host.key(menuKey)
        #expect(host.menuTargets == ["group-second"],
                "Right followed by a menu key must target the second message inside the grouped row")
    }

    @Test(.timeLimit(.minutes(2))) func actualFirstPartMenuIsInstrumentedAndRoutesItsCommands() throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(36)
        #expect(host.menuTargets == ["group-first"], "The probe must observe a real constructed native menu")
        let menu = try #require(host.menus.first)
        #expect(Array(menu.items.filter { !$0.isSeparatorItem }.prefix(3).map(\.title)) == [L("Reply"), L("Copy Link"), L("Bookmark")])
        let reply = try #require(menu.items.firstIndex { $0.title == L("Reply") })
        let bookmark = try #require(menu.items.firstIndex { $0.title == L("Bookmark") })
        menu.performActionForItem(at: reply)
        menu.performActionForItem(at: bookmark)
        #expect(host.replied == ["group-first"])
        #expect(host.bookmarked == ["group-first"])
    }

    @Test(.timeLimit(.minutes(2))) func aSingleMessageKeepsItsExistingKeyboardMenuTarget() throws {
        let host = try Host(ids: ["single-message"])
        defer { host.stop() }
        try host.key(124)
        try host.key(123)
        try host.key(36)
        #expect(host.menuTargets == ["single-message"])
    }
    @Test(.timeLimit(.minutes(2))) func actualArrowsClampAndSelectedCommandsKeepTheirTarget() throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(123)
        try host.key(36)
        for _ in 0..<4 { try host.key(124) }
        try host.key(49)
        try host.key(123)
        try host.key(76)
        #expect(host.menuTargets == ["group-first", "group-third", "group-second"])
        let menu = try #require(host.menus.last)
        #expect(Array(menu.items.filter { !$0.isSeparatorItem }.prefix(3).map(\.title)) == [L("Reply"), L("Copy Link"), L("Bookmark")])
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == L("Reply") }))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == L("Bookmark") }))
        #expect(host.replied == ["group-second"])
        #expect(host.bookmarked == ["group-second"])
    }

    @Test(.timeLimit(.minutes(2)), arguments: [NSEvent.ModifierFlags.command, .option, .control, .shift])
    func modifiedArrowsAndMenuKeysPreserveExistingHandling(_ modifier: NSEvent.ModifierFlags) throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(124, modifiers: modifier)
        try host.key(36, modifiers: modifier)
        #expect(host.menuTargets.isEmpty)
        try host.key(36)
        #expect(host.menuTargets == ["group-first"])
    }

    @Test(.timeLimit(.minutes(2))) func sameRowEditReorderAndDeletionReconcileByMessageIdentity() throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(124)
        host.update([("grouped-row", ["group-third", "group-second", "group-first"])], editedText: "Edited same-ID content")
        try host.key(36)
        host.update([("grouped-row", ["group-third", "group-first"])])
        try host.key(49)
        #expect(host.menuTargets == ["group-second", "group-third"])
    }

    @Test(.timeLimit(.minutes(2))) func movingToAnotherRowAndBackStartsAtItsFirstMessage() throws {
        let host = try Host()
        defer { host.stop() }
        host.update([("grouped-row", ["group-first", "group-second"]), ("next-row", ["next-first", "next-second"])])
        try host.key(124)
        try host.key(125)
        try host.key(36)
        try host.key(124)
        try host.key(126)
        try host.key(49)
        #expect(host.menuTargets == ["next-first", "group-first"])
    }

    @Test(.timeLimit(.minutes(2))) func deletingTheFocusedRowCannotKeepItsOldMenuTarget() throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(124)
        host.update([("remaining-row", ["remaining-first", "remaining-second"])])
        try host.key(125)
        try host.key(36)
        #expect(host.menuTargets == ["remaining-first"])
    }

    @Test(.timeLimit(.minutes(2))) func changingChatWithCollidingRowIDsResetsTheSelectedPart() throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(124)
        let nextContext = TranscriptContext(gateway: host.gateway, disclosure: TranscriptDisclosure(),
                                            agent: AgentSummary(id: "main", name: "Claw"), sessionKey: "another-chat",
                                            previewImage: { _ in }, saveFile: { _, _ in })
        var turn = AssistantTurn(id: "grouped-row", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        turn.text = ["First new chat part", "Second new chat part"]
        turn.textIds = ["group-first", "group-second"]
        host.coordinator.update(rows: [.entry(.assistant(turn))], context: nextContext, insets: (0, 0))
        host.scroll.layoutSubtreeIfNeeded()
        try host.key(125)
        try host.key(36)
        #expect(host.menuTargets == ["group-first"])
    }

    private func expectRing(_ cell: NSView, messageID: String) throws {
        let content = try #require(cell.subviews.compactMap { $0 as? TranscriptRowView }.first)
        let layout = try #require(content.layout)
        let span = try #require(layout.messages.first { $0.id == messageID })
        let ring = try #require(cell.subviews.last)
        try #require(ring !== content)
        cell.frame = NSRect(x: 0, y: 0, width: layout.width, height: layout.height)
        #expect(!ring.isHidden, "The real native focus ring must be visible")
        #expect(ring.frame == NSRect(x: 0, y: span.minY, width: cell.bounds.width, height: max(0, span.maxY - span.minY)),
                "The actual ring child must enclose the selected finished message span")
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func aColdFocusedCellUsesTheActualSelectedSpanGeometry(_ selectSecond: Bool) throws {
        let host = try Host()
        defer { host.stop() }
        if selectSecond { try host.key(124) }
        let selected = selectSecond ? "group-second" : "group-first"
        let existing = try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        try self.expectRing(existing, messageID: selected)
        // The displayed cell remains retained, so the real delegate must create another cell.
        // This exercises viewFor's cold-cell setup without a test-owned selection proxy.
        let cold = try #require(host.coordinator.tableView(host.table, viewFor: host.table.tableColumns.first, row: 0))
        try #require(cold !== existing)
        try self.expectRing(cold, messageID: selected)
    }

    @Test(.timeLimit(.minutes(2))) func aColdCellAfterContextCollisionCannotExposeTheOldSelectedSpan() throws {
        let host = try Host()
        defer { host.stop() }
        try host.key(124)
        let old = try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        try self.expectRing(old, messageID: "group-second")
        let nextContext = TranscriptContext(gateway: host.gateway, disclosure: TranscriptDisclosure(),
                                            agent: AgentSummary(id: "main", name: "Claw"), sessionKey: "ring-next-chat",
                                            previewImage: { _ in }, saveFile: { _, _ in })
        var turn = AssistantTurn(id: "grouped-row", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        turn.text = ["First fresh chat part with a longer opening", "Second fresh chat part"]
        turn.textIds = ["group-first", "group-second"]
        host.coordinator.update(rows: [.entry(.assistant(turn))], context: nextContext, insets: (0, 0))
        host.scroll.layoutSubtreeIfNeeded()
        try host.key(125)
        let existing = try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        let cold = try #require(host.coordinator.tableView(host.table, viewFor: host.table.tableColumns.first, row: 0))
        try #require(cold !== existing)
        try self.expectRing(cold, messageID: "group-first")
    }

}
#endif
