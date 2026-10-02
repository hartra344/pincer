import Foundation
import Testing
@testable import PincerKit

@Suite("MCP tool server link resolution")
struct MCPToolServerResolverTests {
    @Test func exactEffectiveIdDisambiguatesSanitizedServerNames() {
        let effective = EffectiveTools(.object([
            "groups": .array([.object([
                "id": .string("mcp"),
                "source": .string("mcp"),
                "tools": .array([
                    .object([
                        "id": .string("foo-bar__search"),
                        "label": .string("search"),
                        "source": .string("mcp"),
                        "mcpServer": .string("foo.bar"),
                        "mcpToolName": .string("search"),
                    ]),
                    .object([
                        "id": .string("foo-bar-2__search"),
                        "label": .string("search"),
                        "source": .string("mcp"),
                        "mcpServer": .string("foo-bar"),
                        "mcpToolName": .string("search"),
                    ]),
                ]),
            ])]),
        ]))

        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar-2__search", effectiveTools: effective,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == "foo-bar")
        // The unsuffixed safe ID collides with the other server's exact configured name.
        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar__search", effectiveTools: effective,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == "foo.bar")
        #expect(MCPToolServerResolver.resolve(toolName: "mcp__foo-bar__search", effectiveTools: effective,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == "foo.bar")
        // If the original server was removed after the snapshot, don't fall through to the survivor.
        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar__search", effectiveTools: effective,
                                              configuredServerNames: ["foo-bar"]) == nil)
    }

    @Test func coldSessionKeepsSafeNameFallback() {
        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar__search", effectiveTools: nil,
                                              configuredServerNames: ["foo.bar"]) == "foo.bar")
        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar-2__search", effectiveTools: nil,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == nil)
    }
}
