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
        let part = try self.toolPart()
        #expect(!part.isExpanded, "the MCP card is collapsed in this layout")
        #expect(!part.controls.contains { if case .openMCPServer = $0.action { true } else { false } },
                "the existing Open control is only laid out when a card is expanded")
        #expect(part.mcpContextMenu?.toolName == "mcp__filesystem__read_file")
        #expect(part.mcpContextMenu?.openServerName == "filesystem")
        #expect(part.mcpContextMenu?.openServerTitle == L("Open MCP Server"))

        let header = TranscriptToolHeaderView(frame: CGRect(x: 0, y: 0, width: 500, height: 30))
        header.configure(part, trailing: 10, contextMenu: part.mcpContextMenu)
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

        let expanded = try self.toolPart(expanded: true)
        let expandedOpen = try #require(expanded.controls.first { if case .openMCPServer = $0.action { true } else { false } })
        #expect(expanded.isExpanded)
        #expect(expanded.mcpContextMenu?.openServerTitle == expandedOpen.title,
                "expanded controls and the collapsed context menu share the same configured-server label")

        let unknownServer = try self.toolPart(serverName: "acme-docs", mcpServerNames: [])
        #expect(unknownServer.mcpContextMenu?.openServerName == "acme-docs")
        #expect(unknownServer.mcpContextMenu?.openServerTitle == L("Show MCP Servers"),
                "unknown servers route to the server list")
        header.configure(unknownServer, trailing: 10, contextMenu: unknownServer.mcpContextMenu)
        #expect(header.menu(for: event)?.items.map(\.title) == [L("Show MCP Servers"), L("Copy Tool Name")])

        let unavailable = try self.toolPart(supportsMCPServers: false)
        #expect(unavailable.mcpContextMenu?.toolName == "mcp__filesystem__read_file")
        #expect(unavailable.mcpContextMenu?.openServerName == nil,
                "Copy remains available when the Gateway cannot open MCP server settings")
        header.configure(unavailable, trailing: 10, contextMenu: unavailable.mcpContextMenu)
        #expect(header.menu(for: event)?.items.map(\.title) == [L("Copy Tool Name")])
    }

    private func toolPart(supportsMCPServers: Bool = true, serverName: String = "filesystem",
                          mcpServerNames: Set<String>? = ["filesystem"], expanded: Bool = false) throws -> TranscriptPart.Tool
    {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:main:menu"
        let disclosure = TranscriptDisclosure()
        if expanded { disclosure.set("tool:mcp-call", expanded: true) }
        let context = TranscriptContext(gateway: gateway, disclosure: disclosure,
                                        agent: AgentSummary(id: "main", name: "Main"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        var settings = TranscriptSettings(thinking: .live)
        settings.supportsMCPServers = supportsMCPServers
        settings.mcpServerNames = mcpServerNames
        let builder = TranscriptLayoutBuilder(context: context, settings: settings)
        let tool = ToolActivity(id: "mcp-call", name: "mcp__\(serverName)__read_file", arguments: nil,
                                result: nil, isError: false, isRunning: false)
        var turn = AssistantTurn(id: "turn-mcp-menu", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true // tool parts are laid out while the assistant turn is live
        let layout = builder.layout(.entry(.assistant(turn)), width: 500)
        return try #require(layout.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(tool) = placed.part { return tool }
            return nil
        }.first)
    }
}
#elseif os(iOS)
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Transcript MCP tool context menu")
struct TranscriptToolContextMenuTests {
    @Test func collapsedHeaderEnablesOneNativeInteractionAndClearsOnReuse() throws {
        let tool = ToolActivity(id: "mcp-call", name: "mcp__filesystem__read_file", arguments: nil,
                                result: nil, isError: false, isRunning: false)
        let part = TranscriptPart.Tool(tool: tool, key: "tool:mcp-call", isExpanded: false,
                                       run: nil, headerHeight: 30, sections: [], runningY: nil,
                                       edit: nil, diff: nil, decor: [], controls: [], notes: [])
        let header = TranscriptToolHeaderView(frame: CGRect(x: 0, y: 0, width: 500, height: 30))
        header.configure(part, trailing: 10, contextMenu: TranscriptToolContextMenu.make(
            toolName: tool.name, supportsMCPServers: true, mcpServerNames: ["filesystem"]))
        #expect(header.isContextMenuInteractionEnabled)
        let interaction = try #require(header.contextMenuInteraction)
        #expect(header.interactions.compactMap { $0 as? UIContextMenuInteraction }.count == 1)
        #expect(header.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) != nil)
        var ordinaryTool = tool
        ordinaryTool.name = "exec"
        let ordinary = TranscriptPart.Tool(tool: ordinaryTool, key: "tool:ordinary", isExpanded: false,
                                           run: nil, headerHeight: 30, sections: [], runningY: nil,
                                           edit: nil, diff: nil, decor: [], controls: [], notes: [])
        header.configure(ordinary, trailing: 10)
        #expect(header.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) == nil,
                "recycled ordinary tool headers must clear MCP actions")
    }
}
#endif
