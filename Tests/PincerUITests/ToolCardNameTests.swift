import PincerKit
import Testing
@testable import PincerUI

/// The tool card header (`ToolCardName`) and the Kit presentation split MCP tool names the same way (#360).
@Suite("Tool card MCP name")
struct ToolCardNameTests {
    @Test func headerAgreesWithKit() {
        for name in ["github__search_issues", "mcp__github__search_issues", "fs__read__file", "mcp__my.srv__a-b",
                     "home-assistant__turn_on", "mcp__mcp__x"]
        {
            let header = ToolCardName(name)
            let kit = MCPToolName.split(name)
            #expect(header.server == kit.server, "\(name)")
            #expect(header.tool == kit.tool, "\(name)")
        }
    }

    @Test func nonMCPNamesHaveNoServer() {
        for name in ["exec", "web_fetch", "a_b", "__tool", "server__", "mcp__"] {
            let header = ToolCardName(name)
            #expect(header.server == nil, "\(name)")
            #expect(header.tool == name, "\(name)")
        }
    }
}
