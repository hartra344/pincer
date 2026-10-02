import Foundation
import PincerKit

/// #512: preserve exact effective IDs instead of trying to reverse collision suffixes.
@MainActor
func runMCPToolLinkChecks() {
    let effective = EffectiveTools([
        "agentId": "main", "profile": "full",
        "groups": [["id": "mcp", "label": "MCP tools", "source": "mcp", "tools": [
            ["id": "foo-bar__search", "label": "search", "description": "Find documents",
             "rawDescription": "Find documents", "source": "mcp", "mcpServer": "foo.bar", "mcpToolName": "search"],
            ["id": "foo-bar-2__search", "label": "search", "description": "Find issues",
             "rawDescription": "Find issues", "source": "mcp", "mcpServer": "foo-bar", "mcpToolName": "search"],
        ]]],
    ])
    let names = ["foo.bar", "foo-bar"]
    check(MCPToolServerResolver.resolve(toolName: "foo-bar__search", effectiveTools: effective,
                                       configuredServerNames: names) == "foo.bar",
          "exact effective ID outranks a different configured server with the same prefix")
    check(MCPToolServerResolver.resolve(toolName: "foo-bar-2__search", effectiveTools: effective,
                                       configuredServerNames: names) == "foo-bar",
          "collision-suffixed MCP ID resolves to its original configured server")
    check(MCPToolServerResolver.resolve(toolName: "foo-bar-2__search", effectiveTools: nil,
                                       configuredServerNames: names) == nil,
          "a cold session does not invent a collision assignment")
    let ambiguous = EffectiveTools([
        "agentId": "main", "profile": "full",
        "groups": [["id": "mcp", "label": "MCP tools", "source": "mcp", "tools": .array(names.map { name in
            JSONValue.object(["id": "foo-bar__search", "label": "search", "description": "Find documents",
                              "rawDescription": "Find documents", "source": "mcp", "mcpServer": .string(name),
                              "mcpToolName": "search"])
        })]],
    ])
    check(MCPToolServerResolver.resolve(toolName: "foo-bar__search", effectiveTools: ambiguous,
                                       configuredServerNames: names) == nil,
          "ambiguous effective IDs never pick a server by dictionary order or fallback")
}

@MainActor
func runDemoMCPToolLinks() async {
    await runGatewayMCPToolLinks(profile: .demo(), label: "demo MCP tool links")
}

@MainActor
func runLiveMCPToolLinks(url: String, token: String) async {
    let profile = GatewayProfile(name: "MCP links", url: url, authMode: .token, access: .admin)
    profile.secret = token
    await runGatewayMCPToolLinks(profile: profile, label: "live MCP tool links")
}

@MainActor
private func runGatewayMCPToolLinks(profile: GatewayProfile, label: String) async {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    defer { gateway.stop() }
    let connected = await waitFor(label, timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(connected, "\(label): connected")
    guard connected else { return }
    await gateway.settings.load()
    await gateway.mcp.load()
    let scratchNames = ["ACME-DOCS", "acme-docs"]
    for name in scratchNames {
        var draft = MCPServerDraft()
        draft.name = name
        draft.command = "node"
        draft.args = ["server.js"]
        draft.enabled = name != "ACME-DOCS"
        gateway.mcp.apply(draft)
    }
    let saved = await gateway.settings.save()
    check(saved, "\(label): saved temporary colliding servers")
    guard saved else { return }
    let settled = await waitFor("\(label) connected collision server", timeout: 10) {
        gateway.mcp.status(for: "acme-docs").state == .connected
    }
    check(settled, "\(label): colliding server connected")
    let sessionKey = "agent:main:main"
    let inspector = gateway.toolsInspector(sessionKey: sessionKey)
    await inspector.load()
    let tools = inspector.effective?.groups.flatMap(\.tools) ?? []
    let original = tools.first { $0.mcpServer == "acme.docs" && $0.mcpToolName == "search" }
    let collision = tools.first { $0.mcpServer == "acme-docs" && $0.mcpToolName == "echo" }
    check(original != nil && collision != nil && original?.id != collision?.id,
          "\(label): actual effective catalog preserves distinct server identities")
    check(!tools.contains { $0.mcpServer == "ACME-DOCS" }
          && [original?.id, collision?.id].compactMap { $0 }.contains { $0.contains("-2__") || $0.contains("-3__") },
          "\(label): disabled server is excluded and connected collisions retain distinct suffixed IDs")
    if let original, let collision {
        check(gateway.mcpServerName(forToolName: original.id, sessionKey: sessionKey) == "acme.docs",
              "\(label): warmed tool card opens the original dotted server")
        check(gateway.mcpServerName(forToolName: collision.id, sessionKey: sessionKey) == "acme-docs",
              "\(label): warmed collision tool card opens the exact hyphenated server")
        let suffixed = [original, collision].first { $0.id.contains("-2__") || $0.id.contains("-3__") }
        if let suffixed {
            check(gateway.mcpServerName(forToolName: suffixed.id, sessionKey: "agent:main:cold") == nil,
                  "\(label): another chat cannot borrow this session's effective-ID index")
        } else {
            check(false, "\(label): catalog assigns collision suffixes including disabled reservations")
        }
    }
    for name in scratchNames { gateway.mcp.remove(name) }
    let removed = await gateway.settings.save()
    check(removed, "\(label): removed temporary collision fixtures")
    if let collision {
        check(gateway.mcpServerName(forToolName: collision.id, sessionKey: sessionKey) == nil,
              "\(label): a cached ID for a removed server opens the list instead of a different server")
    }
}
