import PincerKit

/// The MCP-specific actions offered from a tool card's native context menu.
struct TranscriptToolContextMenu: Equatable {
    /// The exact Gateway tool name, including its server prefix.
    let toolName: String
    /// Nil when the current Gateway cannot open MCP server settings from this row.
    let openServerName: String?
    /// Reuses the configured-server / unknown-server label from the in-card control.
    let openServerTitle: String?

    /// Builds the row metadata without parsing tool arguments or loading settings. The name set is
    /// the same cached snapshot used while laying out expanded-card controls.
    static func make(toolName: String, supportsMCPServers: Bool, mcpServerNames: Set<String>?) -> Self? {
        guard let server = ToolCardName(toolName).server else { return nil }
        guard supportsMCPServers else {
            return Self(toolName: toolName, openServerName: nil, openServerTitle: nil)
        }
        let known = mcpServerNames?.contains(server) ?? true
        return Self(toolName: toolName, openServerName: server,
                    openServerTitle: Self.title(forKnownServer: known))
    }

    static func title(forKnownServer known: Bool) -> String {
        known ? L("Open MCP Server") : L("Show MCP Servers")
    }

    static func make(toolName: String, controls: [TranscriptPart.Tool.Control]) -> Self? {
        guard ToolCardName(toolName).server != nil else { return nil }
        var openServerName: String?
        var openServerTitle: String?
        for control in controls {
            guard case let .openMCPServer(name) = control.action else { continue }
            openServerName = name
            openServerTitle = control.title
            break
        }
        return Self(toolName: toolName, openServerName: openServerName, openServerTitle: openServerTitle)
    }
}
