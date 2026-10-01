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
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:main:menu"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Main"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        var settings = TranscriptSettings(thinking: .live)
        settings.supportsMCPServers = true
        settings.mcpServerNames = ["filesystem"]
        let builder = TranscriptLayoutBuilder(context: context, settings: settings)
        let tool = ToolActivity(id: "mcp-call", name: "mcp__filesystem__read_file", arguments: nil,
                                result: nil, isError: false, isRunning: false)
        var turn = AssistantTurn(id: "turn-mcp-menu", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true // tool parts are laid out while the assistant turn is live
        let layout = builder.layout(.entry(.assistant(turn)), width: 500)
        let part = try #require(layout.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(tool) = placed.part { return tool }
            return nil
        }.first)
        #expect(!part.isExpanded, "the MCP card is collapsed in this layout")
        #expect(!part.controls.contains { if case .openMCPServer = $0.action { true } else { false } },
                "the existing Open control is only laid out when a card is expanded")

        let header = TranscriptToolHeaderView(frame: CGRect(x: 0, y: 0, width: 500, height: 30))
        header.configure(part, trailing: 10)
        var openedServer: String?
        header.onOpenMCPServer = { openedServer = $0 }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))

        let menu = header.menu(for: event)
        let titles = menu?.items.map(\.title) ?? []
        #expect(titles.contains(L("Open MCP Server")))
        #expect(titles.contains(L("Copy Tool Name")), "the menu must offer the unshortened tool name")
        if let menu, let index = menu.items.firstIndex(where: { $0.title == L("Open MCP Server") }) {
            menu.performActionForItem(at: index)
        }
        #expect(openedServer == "filesystem", "the native item routes to the exact in-card server action")

        #expect(header.contextMenu?.toolName == "mcp__filesystem__read_file", "copy retains the raw Gateway tool name")
        #expect(header.contextMenu?.openServerName == "filesystem" && header.contextMenu?.openServerTitle == L("Open MCP Server"),
                "the context action reuses the in-card server destination and label")
        #expect(TranscriptToolContextMenu.make(toolName: "exec", controls: part.controls) == nil,
                "non-MCP cards do not receive MCP context actions")

        let unconfiguredControl = TranscriptPart.Tool.Control(
            id: "open-mcp-server", title: L("Show MCP Servers"), symbol: "point.3.connected.trianglepath.dotted",
            frame: .zero, action: .openMCPServer("acme-docs"), spoken: L("Show MCP Servers"))
        let unconfigured = try #require(TranscriptToolContextMenu.make(toolName: "acme-docs__search", controls: [unconfiguredControl]))
        #expect(unconfigured.openServerName == "acme-docs" && unconfigured.openServerTitle == L("Show MCP Servers"),
                "unconfigured server names reuse the card’s Show MCP Servers action")
    }
}
#endif
