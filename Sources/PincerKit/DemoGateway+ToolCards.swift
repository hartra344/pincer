import Foundation

/// The demo's "Check the MCP servers" chat: expanded tool cards with upstream-shaped calls and
/// results (`exec` with its `details` envelope, a failed `exec`, an `edit`, a bundle-MCP
/// `server__tool` call, `web_fetch` and `read`), mirrored by `mock-gateway/tool-cards.mjs`.
extension DemoGateway {
    static let toolCardsKey = "agent:main:dashboard:tool-cards"
    static let toolCardsTitle = "Check the MCP servers"
    static let toolCardsPreview = "Era needs a sign-in; the other servers are healthy."

    static let toolCardsExecCall = "call_demo_exec_mcp"
    static let toolCardsFailedCall = "call_demo_exec_failed"
    static let toolCardsEditCall = "call_demo_edit_config"
    static let toolCardsMCPCall = "call_demo_mcp_issues"
    static let toolCardsFetchCall = "call_demo_web_fetch"
    static let toolCardsReadCall = "call_demo_read_config"

    static let toolCardsExecCommand = "openclaw mcp status --verbose 2>&1 | grep -A4 \"^- Era\""
    static let toolCardsExecOutput = """
    MCP servers (4 configured)

    - github
      transport: stdio (npx -y @modelcontextprotocol/server-github)
      status: connected
      tools: 26
      last ping: 212 ms ago
    - Era
      transport: streamable-http (https://mcp.era.example/v1)
      status: authorization required (OAuth pending)
      tools: 0
      last error: 401 Unauthorized — run `openclaw mcp auth Era` to sign in
    - filesystem
      transport: stdio (npx -y @modelcontextprotocol/server-filesystem ~/src)
      status: connected
      tools: 11
      last ping: 187 ms ago
    - postgres
      transport: stdio (uvx mcp-server-postgres)
      status: connected
      tools: 5
      last ping: 341 ms ago

    3 connected, 1 needs attention.
    """
    static let toolCardsFailedOutput = """
    error: Era: OAuth authorization is required but no browser session is available
    hint: run `openclaw mcp auth Era` from a machine with a browser
    openclaw: failed to refresh 1 server (exit 1)
    """
    static let toolCardsIssuesJSON = """
    [
      {"number": 318, "title": "Tool call output shows the raw JSON envelope", "state": "open", "labels": ["bug", "ui"], "author": "alex"},
      {"number": 324, "title": "Redesign expanded tool-call cards", "state": "open", "labels": ["enhancement", "ui"], "author": "alex"},
      {"number": 301, "title": "Failed tool calls need a clearer error state", "state": "open", "labels": ["ui"], "author": "sam"}
    ]
    """
    static let toolCardsConfigPath = "src/mcp/servers.json"
    static let toolCardsConfigOld = """
        "url": "https://mcp.era.example/v1",
        "auth": "none"
    """
    static let toolCardsConfigNew = """
        "url": "https://mcp.era.example/v1",
        "auth": "oauth"
    """
    static let toolCardsConfigText = """
    {
      "servers": {
        "Era": {
          "url": "https://mcp.era.example/v1",
          "auth": "oauth"
        }
      }
    }
    """
    static let toolCardsFetchText = """
    # Connecting MCP servers

    OpenClaw can load tools from any Model Context Protocol server. Add the server under `mcp.servers`
    and run `openclaw mcp status` to check it.

    ## OAuth servers

    Servers that use OAuth report `authorization required` until you run `openclaw mcp auth <server>`.
    """

    static func seedToolCardsTranscript() -> [JSONValue] {
        let minute = 60.0
        let start = 12 * minute
        func result(_ id: String, _ tool: String, _ text: String, ago: Double, isError: Bool = false,
                    details: JSONValue? = nil) -> JSONValue
        {
            var extra: Row = ["toolCallId": .string(id), "toolName": .string(tool), "isError": .bool(isError)]
            if let details { extra["details"] = details }
            return Self.message("toolResult", [Self.text(text)], ago: ago, extra: extra)
        }
        let fetchURL = "https://docs.openclaw.example/mcp/connecting"
        return [
            Self.message("user", [Self.text("Check the MCP servers. Era looks stuck.")], ago: start),
            Self.message("assistant", [
                Self.text("Checking the status of each server."),
                Self.toolCall(Self.toolCardsExecCall, "exec", [
                    "command": .string(Self.toolCardsExecCommand), "workdir": "~/src/pincer", "timeoutSeconds": 30,
                ]),
            ], ago: start - 20),
            result(Self.toolCardsExecCall, "exec", Self.toolCardsExecOutput, ago: start - 22, details: [
                "status": "completed", "exitCode": 0, "durationMs": 1240, "cwd": "/Users/alex/src/pincer",
                "aggregated": .string(Self.toolCardsExecOutput),
            ]),
            Self.message("assistant", [
                Self.text("Era is waiting on OAuth. I'll try refreshing it."),
                Self.toolCall(Self.toolCardsFailedCall, "exec", [
                    "command": "openclaw mcp refresh Era", "workdir": "~/src/pincer",
                ]),
            ], ago: start - 60),
            result(Self.toolCardsFailedCall, "exec", Self.toolCardsFailedOutput, ago: start - 62, isError: true, details: [
                "status": "failed", "exitCode": 1, "durationMs": 830, "cwd": "/Users/alex/src/pincer",
                "aggregated": .string(Self.toolCardsFailedOutput),
            ]),
            Self.message("assistant", [
                Self.text("That needs an interactive sign-in. Let me look at the config; Era has no auth set."),
                Self.toolCall(Self.toolCardsReadCall, "read", [
                    "path": .string(Self.toolCardsConfigPath), "offset": 1, "limit": 40,
                ]),
            ], ago: start - 100),
            result(Self.toolCardsReadCall, "read", Self.toolCardsConfigText.replacingOccurrences(of: "oauth", with: "none"),
                   ago: start - 101),
            Self.message("assistant", [
                Self.toolCall(Self.toolCardsEditCall, "edit", [
                    "file_path": .string(Self.toolCardsConfigPath),
                    "old_string": .string(Self.toolCardsConfigOld),
                    "new_string": .string(Self.toolCardsConfigNew),
                ]),
            ], ago: start - 130),
            result(Self.toolCardsEditCall, "edit", "Successfully replaced 1 block(s) in \(Self.toolCardsConfigPath).",
                   ago: start - 131, details: [
                       "changed": true,
                       "diff": "  1 {\n  2   \"servers\": {\n  3     \"Era\": {\n  4       \"url\": \"https://mcp.era.example/v1\",\n- 5       \"auth\": \"none\"\n+ 5       \"auth\": \"oauth\"\n  6     }\n  7   }\n  8 }",
                   ]),
            Self.message("assistant", [
                Self.text("Config updated. Checking for known issues with OAuth servers."),
                Self.toolCall(Self.toolCardsMCPCall, "github__search_issues", [
                    "query": "MCP OAuth authorization required", "repo": "hartra344/pincer", "state": "open",
                ]),
            ], ago: start - 170),
            result(Self.toolCardsMCPCall, "github__search_issues", Self.toolCardsIssuesJSON, ago: start - 172),
            Self.message("assistant", [
                Self.toolCall(Self.toolCardsFetchCall, "web_fetch", ["url": .string(fetchURL), "extractMode": "markdown"]),
            ], ago: start - 200),
            result(Self.toolCardsFetchCall, "web_fetch", Self.toolCardsFetchText, ago: start - 202, details: [
                "url": .string(fetchURL), "finalUrl": .string(fetchURL), "status": 200, "contentType": "text/html",
                "title": "Connecting MCP servers", "tookMs": 412, "truncated": false,
                "length": .number(Double(Self.toolCardsFetchText.count)), "rawLength": 18_204,
                "extractMode": "markdown", "extractor": "readability", "fetchedAt": "2026-09-29T14:40:00.000Z",
            ]),
            Self.message("assistant", [Self.text("""
            \(Self.toolCardsPreview) Run `openclaw mcp auth Era` on a machine with a browser to finish the sign-in.
            """)], ago: start - 240),
        ]
    }
}
