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

    @Test func duplicateEffectiveIdsAreAmbiguous() {
        let effective = EffectiveTools(.object([
            "groups": .array([.object([
                "id": .string("mcp"), "source": .string("mcp"),
                "tools": .array([
                    ["id": .string("shared__search"), "source": .string("mcp"), "mcpServer": .string("foo.bar")],
                    ["id": .string("shared__search"), "source": .string("mcp"), "mcpServer": .string("foo-bar")],
                ].map(JSONValue.object)),
            ])]),
        ]))
        #expect(MCPToolServerResolver.resolve(toolName: "shared__search", effectiveTools: effective,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == nil)
    }

    @Test func coldSessionKeepsSafeNameFallback() {
        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar__search", effectiveTools: nil,
                                              configuredServerNames: ["foo.bar"]) == "foo.bar")
        #expect(MCPToolServerResolver.resolve(toolName: "foo-bar-2__search", effectiveTools: nil,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == nil)
    }
}

@MainActor
@Suite("Gateway MCP tool index cache")
struct GatewayMCPToolIndexTests {
    let scratch = ScratchDefaults()

    private func gateway(_ name: String) -> GatewayStore {
        GatewayStore(profile: GatewayProfile(name: name, url: "ws://127.0.0.1:1", authMode: .none),
                     defaults: self.scratch.defaults, identity: Fixtures.identity())
    }

    private func configureCollision(_ gateway: GatewayStore) {
        gateway.settings.set(["mcp", "servers", "foo.bar"], .object(["url": .string("https://foo.example")]))
        gateway.settings.set(["mcp", "servers", "foo-bar"], .object(["url": .string("https://bar.example")]))
    }

    private func response(_ pairs: [(id: String, server: String)]) -> JSONValue {
        .object(["groups": .array([.object([
            "id": .string("mcp"), "source": .string("mcp"),
            "tools": .array(pairs.map { pair in
                .object(["id": .string(pair.id), "source": .string("mcp"), "mcpServer": .string(pair.server)])
            }),
        ])])])
    }

    @Test func sessionGatewayOrderingEmptyAndBudget() async throws {
        defer { self.scratch.remove() }
        let gateway = self.gateway("First")
        self.configureCollision(gateway)

        let first = try #require(gateway.beginEffectiveMCPToolRead(sessionKey: "chat"))
        await gateway.finishEffectiveMCPToolRead(self.response([(id: "foo-bar-2__search", server: "foo-bar")]),
                                                 sessionKey: "chat", version: first)
        #expect(gateway.mcpServerName(forToolName: "foo-bar-2__search", sessionKey: "chat") == "foo-bar")
        #expect(gateway.mcpServerName(forToolName: "foo-bar-2__search", sessionKey: "other-chat") == nil)

        let secondGateway = self.gateway("Second")
        self.configureCollision(secondGateway)
        #expect(secondGateway.mcpServerName(forToolName: "foo-bar-2__search", sessionKey: "chat") == nil)

        let older = try #require(gateway.beginEffectiveMCPToolRead(sessionKey: "chat"))
        let newer = try #require(gateway.beginEffectiveMCPToolRead(sessionKey: "chat"))
        await gateway.finishEffectiveMCPToolRead(self.response([(id: "foo-bar-2__search", server: "foo.bar")]),
                                                 sessionKey: "chat", version: newer)
        await gateway.finishEffectiveMCPToolRead(self.response([(id: "foo-bar-2__search", server: "foo-bar")]),
                                                 sessionKey: "chat", version: older)
        #expect(gateway.mcpServerName(forToolName: "foo-bar-2__search", sessionKey: "chat") == "foo.bar",
                "a slower older index must not overwrite a later-started read")

        let empty = try #require(gateway.beginEffectiveMCPToolRead(sessionKey: "chat"))
        await gateway.finishEffectiveMCPToolRead(.object(["groups": .array([])]), sessionKey: "chat", version: empty)
        let cleared = gateway.mcpToolServerIndexes.value(for: "chat")
        #expect(cleared?.serversByToolID.isEmpty == true && cleared?.isComplete == true,
                "a successful empty snapshot replaces the previous mapping")

        let huge = String(repeating: "x", count: 64 * 1024 + 1)
        let oversized = try #require(gateway.beginEffectiveMCPToolRead(sessionKey: "chat"))
        await gateway.finishEffectiveMCPToolRead(self.response([(id: huge, server: "foo.bar")]),
                                                 sessionKey: "chat", version: oversized)
        let bounded = gateway.mcpToolServerIndexes.value(for: "chat")
        #expect(bounded?.isComplete == false && bounded?.serversByToolID.isEmpty == true)
        #expect(gateway.mcpToolServerIndexes.totalCost <= gateway.mcpToolServerIndexes.costLimit)
        #expect(MCPToolServerResolver.resolve(toolName: huge, effectiveIndex: bounded,
                                              configuredServerNames: ["foo.bar", "foo-bar"]) == nil,
                "an oversized partial index must not fall back to a possibly colliding prefix")

        for number in 0..<17 {
            let key = "session-\(number)"
            let version = try #require(gateway.beginEffectiveMCPToolRead(sessionKey: key))
            await gateway.finishEffectiveMCPToolRead(self.response([(id: "server__tool", server: "foo.bar")]),
                                                     sessionKey: key, version: version)
        }
        #expect(gateway.mcpToolServerIndexes.count == 16)
        #expect(gateway.mcpToolServerIndexes.value(for: "session-0") == nil)
        #expect(gateway.mcpToolServerIndexes.value(for: "session-16") != nil)
    }
}
