import Foundation

/// Resolves a transcript MCP tool name to a configured server when the session's effective-tool
/// snapshot is available, while preserving the legacy safe-name fallback for cold sessions.
public enum MCPToolServerResolver {
    /// Builds the exact-ID lookup from one session's successful effective-tools snapshot.
    public static func serverIndex(from effectiveTools: EffectiveTools) -> [String: String] {
        var result: [String: String] = [:]
        for tool in effectiveTools.groups.lazy.flatMap(\.tools) where tool.source == .mcp {
            guard let server = tool.mcpServer, !server.isEmpty else { continue }
            result[tool.id] = server
        }
        return result
    }

    /// Reads only the small MCP identity fields from an already-decoded response. Call on a worker.
    static func serverIndex(from json: JSONValue) -> [String: String] {
        var result: [String: String] = [:]
        for group in json["groups"]?.array ?? [] {
            for tool in group["tools"]?.array ?? [] {
                guard tool["source"]?.text == "mcp",
                      let id = tool["id"]?.text, !id.isEmpty,
                      let server = tool["mcpServer"]?.text, !server.isEmpty
                else { continue }
                result[id] = server
            }
        }
        return result
    }

    /// Resolves exact effective IDs first. A known ID whose server was removed is authoritative
    /// and cannot fall through to another server with a colliding sanitized prefix.
    public static func resolve(toolName: String, effectiveServerNames: [String: String]?,
                               configuredServerNames: [String]) -> String? {
        if let effectiveServerNames {
            let exactIDs = toolName.hasPrefix("mcp__") ? [toolName, String(toolName.dropFirst(5))] : [toolName]
            for exactID in exactIDs {
                if let exactServer = effectiveServerNames[exactID] {
                    return configuredServerNames.contains(exactServer) ? exactServer : nil
                }
            }
        }
        let split = MCPToolName.split(toolName)
        guard let serverFragment = split.server ?? (toolName.isEmpty ? nil : toolName) else { return nil }
        return configuredServerNames.first { $0 == serverFragment }
            ?? configuredServerNames.first { MCPToolName.safeServerName($0) == serverFragment }
    }

    public static func resolve(toolName: String, effectiveTools: EffectiveTools?,
                               configuredServerNames: [String]) -> String? {
        self.resolve(toolName: toolName, effectiveServerNames: effectiveTools.map(Self.serverIndex(from:)),
                     configuredServerNames: configuredServerNames)
    }
}
