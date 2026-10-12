#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #967: Markdown tables in the transcript are selectable and copyable like message prose.
@MainActor
@Suite("Transcript table selection (hosted)", .serialized)
struct TranscriptTableSelectionHostedTests {
    static let markdown = "| Name | Role | Notes |\n| --- | --- | --- |\n| **Ada** | Engineer | first |\n| Grace | Admiral | second |"
    static let plain = "Name\tRole\tNotes\nAda\tEngineer\tfirst\nGrace\tAdmiral\tsecond"

    @MainActor private final class Host {
        let fixture: (layout: TranscriptRowLayout, renderer: TranscriptRenderer, gateway: GatewayStore, scratch: ScratchDefaults)
        let row: TranscriptRowView
        let window: NSWindow
        let tableView: TranscriptMarkdownTableView
        let grid: TranscriptTableGridView

        init(id: String = "table-reply") throws {
            _ = NSApplication.shared
            self.fixture = try TableTextFixture.renderedLayout(TranscriptTableSelectionHostedTests.markdown, id: id)
            self.row = TranscriptRowView(frame: CGRect(x: 0, y: 0, width: 700, height: self.fixture.layout.height))
            self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: max(self.fixture.layout.height, 200)),
                                   styleMask: [.titled], backing: .buffered, defer: false)
            self.window.contentView = self.row
            self.row.apply(self.fixture.layout, actions: self.fixture.renderer)
            self.row.layoutSubtreeIfNeeded()
            self.tableView = try #require(Self.find(TranscriptMarkdownTableView.self, in: self.row))
            self.grid = try #require(Self.find(TranscriptTableGridView.self, in: self.row))
        }

        isolated deinit { self.fixture.scratch.remove() }

        static func find<V: NSView>(_: V.Type, in view: NSView) -> V? {
            if let match = view as? V { return match }
            for sub in view.subviews { if let match = find(V.self, in: sub) { return match } }
            return nil
        }

        func windowPoint(_ point: CGPoint) -> CGPoint { self.grid.convert(point, to: nil) }

        func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: self.windowPoint(point), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        func drag(from start: CGPoint, to end: CGPoint) {
            self.grid.mouseDown(with: self.event(.leftMouseDown, at: start))
            self.grid.mouseDragged(with: self.event(.leftMouseDragged, at: end))
            self.grid.mouseUp(with: self.event(.leftMouseUp, at: end))
        }
    }

    /// Runs `body` with the general pasteboard restored afterwards.
    private func preservingPasteboard(_ body: () throws -> Void) rethrows {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        try body()
    }

    @Test func rendersTheTableAsSelectableText() throws {
        let host = try Host()
        #expect(host.grid.acceptsFirstResponder)
        #expect(host.grid.textModel.string as String == Self.plain)
    }

    @Test func dragAcrossCellsSelectsTabAndNewlineSeparatedText() throws {
        let host = try Host()
        let model = host.grid.textModel
        let start = model.textRect(row: 1, column: 0)
        let end = model.textRect(row: 2, column: 1)
        host.drag(from: CGPoint(x: start.minX + 1, y: start.midY), to: CGPoint(x: end.maxX - 1, y: end.midY))
        #expect(host.grid.selectedText == "Ada\tEngineer\tfirst\nGrace\tAdmiral")
    }

    @Test func dragInsideOneCellSelectsPartOfItsText() throws {
        let host = try Host()
        let model = host.grid.textModel
        let rect = model.textRect(row: 1, column: 1)
        host.drag(from: CGPoint(x: rect.minX + 1, y: rect.midY), to: CGPoint(x: rect.maxX - 1, y: rect.midY))
        #expect(host.grid.selectedText == "Engineer")
    }

    @Test func doubleClickSelectsAWordAndTripleClickTheRow() throws {
        let host = try Host()
        let rect = host.grid.textModel.textRect(row: 2, column: 0)
        let point = CGPoint(x: rect.minX + 3, y: rect.midY)
        host.grid.mouseDown(with: host.event(.leftMouseDown, at: point, clicks: 2))
        host.grid.mouseUp(with: host.event(.leftMouseUp, at: point, clicks: 2))
        #expect(host.grid.selectedText == "Grace")
        host.grid.mouseDown(with: host.event(.leftMouseDown, at: point, clicks: 3))
        host.grid.mouseUp(with: host.event(.leftMouseUp, at: point, clicks: 3))
        #expect(host.grid.selectedText == "Grace\tAdmiral\tsecond")
    }

    @Test func selectAllSelectsTheWholeTable() throws {
        let host = try Host()
        host.grid.selectAll(nil)
        #expect(host.grid.selectedText == Self.plain)
    }

    @Test func copyWritesTheSelectionToThePasteboard() throws {
        try self.preservingPasteboard {
            let host = try Host()
            host.grid.selectedRange = host.grid.textModel.range(row: 1, column: 0)
            host.grid.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "Ada")
            host.grid.selectAll(nil)
            host.grid.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == Self.plain)
        }
    }

    @Test func commandCThroughTheResponderChainCopiesTabAndNewlineText() throws {
        try self.preservingPasteboard {
            let host = try Host()
            #expect(host.window.makeFirstResponder(host.grid))
            let model = host.grid.textModel
            let start = model.range(row: 0, column: 1).location + 1
            let end = model.range(row: 1, column: 1).location + 3
            host.grid.selectedRange = NSRange(location: start, length: end - start)
            NSPasteboard.general.clearContents()
            #expect(NSApp.sendAction(#selector(NSText.copy(_:)), to: host.window.firstResponder, from: nil))
            #expect(NSPasteboard.general.string(forType: .string) == "ole\tNotes\nAda\tEng")
        }
    }

    @Test func copyIsOnlyEnabledWithASelection() throws {
        let host = try Host()
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        host.grid.selectedRange = NSRange(location: 0, length: 0)
        #expect(!host.grid.validateUserInterfaceItem(item))
        host.grid.selectedRange = NSRange(location: 0, length: 4)
        #expect(host.grid.validateUserInterfaceItem(item))
    }

    @Test func contextMenuOffersCopyForASelectionAndStillCopyTable() throws {
        let host = try Host()
        let rect = host.grid.textModel.textRect(row: 1, column: 1)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let bare = try #require(host.grid.menu(for: host.event(.rightMouseDown, at: point)))
        let bareTitles = bare.items.map(\.title)
        #expect(bareTitles.contains(L("Copy Table")))
        #expect(!bareTitles.contains(L("Copy")))

        host.grid.selectedRange = host.grid.textModel.range(row: 1, column: 1)
        let menu = try #require(host.grid.menu(for: host.event(.rightMouseDown, at: point)))
        let titles = menu.items.map(\.title)
        let copy = try #require(titles.firstIndex(of: L("Copy")))
        let copyTable = try #require(titles.firstIndex(of: L("Copy Table")))
        #expect(copy < copyTable)
        try self.preservingPasteboard {
            _ = NSApp.sendAction(menu.items[copy].action!, to: menu.items[copy].target, from: menu.items[copy])
            #expect(NSPasteboard.general.string(forType: .string) == "Engineer")
            _ = NSApp.sendAction(menu.items[copyTable].action!, to: menu.items[copyTable].target, from: menu.items[copyTable])
            #expect(NSPasteboard.general.string(forType: .string) == host.grid.table?.plainText)
        }
    }

    @Test func reconfiguringTheSameRowKeepsTheSelection() throws {
        let host = try Host()
        host.grid.selectedRange = host.grid.textModel.range(row: 1, column: 1)
        host.row.apply(host.fixture.layout, actions: host.fixture.renderer)
        #expect(host.grid.selectedText == "Engineer")
    }

    @Test func reconfiguringForAnotherRowClearsTheSelection() throws {
        let host = try Host()
        host.grid.selectedRange = host.grid.textModel.range(row: 1, column: 1)
        let other = try TableTextFixture.renderedLayout(Self.markdown, id: "another-reply")
        defer { other.scratch.remove() }
        host.row.apply(other.layout, actions: other.renderer)
        #expect(host.grid.selectedRange.length == 0)
        #expect(host.grid.selectedText.isEmpty)
    }

    @Test func aShorterTableSameRowDropsAnOutOfBoundsSelection() throws {
        let host = try Host()
        host.grid.selectAll(nil)
        let short = try TableTextFixture.renderedLayout("| A |\n| --- |\n| b |", id: "table-reply")
        defer { short.scratch.remove() }
        host.row.apply(short.layout, actions: short.renderer)
        let length = host.grid.textModel.length
        #expect(NSMaxRange(host.grid.selectedRange) <= length)
    }

    @Test func configuringDoesNotSelectAnything() throws {
        let host = try Host()
        #expect(host.grid.selectedRange.length == 0)
        #expect(host.grid.selectedText.isEmpty)
    }
}
#endif
