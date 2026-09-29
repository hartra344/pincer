import Foundation
@testable import PincerKit
import Testing

@Suite struct MCPServersModelInternalTests {
    private func server(_ json: JSONValue) -> MCPServer { MCPServer(name: "s", json: json)! }

    @Test func switchingStdioToRemoteDropsStdioKeysInPatch() {
        let base: JSONValue = ["mcp": ["servers": ["s": ["command": "npx", "args": ["-y", "x"], "env": ["A": "1"], "cwd": "/tmp", "extra": true]]]]
        let original = MCPServers.servers(in: base)[0]
        var draft = MCPServerDraft(server: original)
        draft.transport = .streamableHTTP
        draft.url = "https://example.com/mcp"
        var edits = ConfigEdits(base: base)
        edits.set(["mcp", "servers", "s"], draft.json(original: original))
        let patch = edits.patch?["mcp"]?["servers"]?["s"]
        #expect(patch?["command"] == .null && patch?["args"] == .null && patch?["env"] == .null && patch?["cwd"] == .null)
        #expect(patch?["url"]?.string == "https://example.com/mcp")
        #expect(patch?["extra"] == nil)
    }

    @Test func removingServerPatchesNull() {
        let base: JSONValue = ["mcp": ["servers": ["s": ["command": "npx"], "t": ["command": "y"]]]]
        var edits = ConfigEdits(base: base)
        edits.set(["mcp", "servers", "s"], nil)
        #expect(edits.patch?["mcp"]?["servers"]?["s"] == .null)
    }

    @Test func unchangedRedactedValuesAreNotSent() {
        let base: JSONValue = ["mcp": ["servers": ["s": ["url": "https://a.b/mcp", "headers": ["Authorization": "__OPENCLAW_REDACTED__"]]]]]
        let original = MCPServers.servers(in: base)[0]
        var draft = MCPServerDraft(server: original)
        draft.url = "https://a.b/other"
        var edits = ConfigEdits(base: base)
        edits.set(["mcp", "servers", "s"], draft.json(original: original))
        #expect(edits.patch?["mcp"]?["servers"]?["s"]?["headers"] == nil)
        #expect(draft.problems(existingNames: ["s"]).isEmpty)
        draft.name = "t"
        #expect(draft.problems(existingNames: ["s"])["headers.Authorization"] != nil)
    }

    @Test func masksSecretArgs() {
        #expect(MCPServer.maskedArgs(["--url", "http://x", "--token", "abc", "--api-key=zzz", "PGPASSWORD=p", "-y"])
            == ["--url", "http://x", "--token", "••••", "--api-key=••••", "PGPASSWORD=••••", "-y"])
    }

    @Test func fallbackStatusesFromNotices() {
        let json: JSONValue = ["groups": [["id": "mcp", "label": "MCP", "source": "mcp", "tools": [
            ["id": "fs__read", "source": "mcp", "mcpServer": "fs", "mcpToolName": "read"]]]],
            "notices": [["id": "mcp-server-diagnostic:pg", "severity": "warning", "message": "spawn ENOENT"],
                        ["id": "mcp-not-yet-connected", "message": "", "servers": ["late"]]]]
        let statuses = MCPServersModel.statuses(from: EffectiveTools(json))
        #expect(statuses["fs"]?.state == .connected && statuses["fs"]?.toolCount == 1 && statuses["fs"]?.tools == ["read"])
        #expect(statuses["pg"]?.state == .error && statuses["pg"]?.lastError == "spawn ENOENT")
        #expect(statuses["late"]?.state == .connecting)
    }

    @Test func resetsSignInAndDroppedFields() {
        let json: JSONValue = ["url": "https://a.b/mcp", "auth": "oauth", "oauth": ["authProfileId": "p"]]
        let server = MCPServer(name: "s", json: json)!
        #expect(server.oauthAuthProfileId == "p")
        var draft = MCPServerDraft(server: server)
        #expect(!draft.resetsSignIn && draft.droppedFieldsOnTransportChange.isEmpty)
        draft.url = "https://a.b/other"
        #expect(draft.resetsSignIn)
        draft.transport = .stdio
        #expect(draft.droppedFieldsOnTransportChange == ["URL", "OAuth sign-in"])
    }
}
