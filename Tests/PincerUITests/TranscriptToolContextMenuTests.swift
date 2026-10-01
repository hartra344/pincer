#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #514: MCP tool names remain available from the collapsed card's native header menu.
@MainActor
@Suite("Transcript MCP tool context menu")
struct TranscriptToolContextMenuTests {
    @Test func headerMenuOffersServerAndRawToolName() throws {
        let tool = ToolActivity(id: "mcp-call", name: "mcp__filesystem__read_file", arguments: nil,
                                result: nil, isError: false, isRunning: false)
        let control = TranscriptPart.Tool.Control(
            id: "open-mcp-server", title: L("Open MCP Server"), symbol: "point.3.connected.trianglepath.dotted",
            frame: .zero, action: .openMCPServer("filesystem"), spoken: L("Open MCP Server"))
        var part = TranscriptPart.Tool(tool: tool, key: "tool:mcp-call", isExpanded: false, run: nil,
                                       headerHeight: 30, sections: [], runningY: nil)
        part.controls = [control]
        let header = TranscriptToolHeaderView(frame: CGRect(x: 0, y: 0, width: 500, height: 30))
        header.configure(part, trailing: 10)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))

        let menu = header.menu(for: event)
        let titles = menu?.items.map(\.title) ?? []
        #expect(titles.contains(L("Open MCP Server")))
        #expect(titles.contains(L("Copy Tool Name")), "the menu must offer the unshortened tool name")
    }
}
#endif
