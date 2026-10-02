import Foundation

public enum MCPToolServerIndexEntry: Equatable, Sendable {
    case server(String)
    case ambiguous
}

/// One session's bounded effective-tool projection. Incomplete snapshots are never used to guess
/// from a lossy server prefix.
public struct MCPToolServerIndex: Equatable, Sendable {
    public let serversByToolID: [String: MCPToolServerIndexEntry]
    public let isComplete: Bool
    public let cost: Int

    fileprivate init(serversByToolID: [String: MCPToolServerIndexEntry], isComplete: Bool, cost: Int) {
        self.serversByToolID = serversByToolID
        self.isComplete = isComplete
        self.cost = cost
    }

    fileprivate static let incomplete = Self(serversByToolID: [:], isComplete: false, cost: 0)
}

/// Resolves a transcript MCP tool name to a configured server when the session's effective-tool
/// snapshot is available, while preserving the legacy safe-name fallback for cold sessions.
public enum MCPToolServerResolver {
    private static let maximumIndexedEntries = 1_024
    private static let maximumIndexCost = 64 * 1024

    /// Builds the exact-ID lookup from one session's successful effective-tools snapshot.
    public static func serverIndex(from effectiveTools: EffectiveTools) -> MCPToolServerIndex {
        var result: [String: MCPToolServerIndexEntry] = [:]
        var cost = 0
        var visited = 0
        for tool in effectiveTools.groups.lazy.flatMap(\.tools) where tool.source == .mcp {
            guard let server = tool.mcpServer, !server.isEmpty else { continue }
            visited += 1
            cost += tool.id.utf8.count + server.utf8.count
            guard visited <= Self.maximumIndexedEntries, cost <= Self.maximumIndexCost else { return .incomplete }
            if result[tool.id] == nil { result[tool.id] = .server(server) }
            else { result[tool.id] = .ambiguous }
        }
        return MCPToolServerIndex(serversByToolID: result, isComplete: true, cost: cost)
    }

    /// Reads only the small MCP identity fields from an already-decoded response. Call on a worker.
    static func serverIndex(from json: JSONValue) -> MCPToolServerIndex {
        var result: [String: MCPToolServerIndexEntry] = [:]
        var cost = 0
        var visited = 0
        for group in json["groups"]?.array ?? [] {
            for tool in group["tools"]?.array ?? [] {
                guard tool["source"]?.string == "mcp",
                      let id = tool["id"]?.string, !id.isEmpty,
                      let server = tool["mcpServer"]?.string, !server.isEmpty
                else { continue }
                visited += 1
                cost += id.utf8.count + server.utf8.count
                guard visited <= Self.maximumIndexedEntries, cost <= Self.maximumIndexCost else { return .incomplete }
                if result[id] == nil { result[id] = .server(server) }
                else { result[id] = .ambiguous }
            }
        }
        return MCPToolServerIndex(serversByToolID: result, isComplete: true, cost: cost)
    }

    /// Resolves exact effective IDs first. A known ID whose server was removed is authoritative
    /// and cannot fall through to another server with a colliding sanitized prefix.
    public static func resolve(toolName: String, effectiveIndex: MCPToolServerIndex?,
                               configuredServerNames: [String]) -> String? {
        if let effectiveIndex {
            for exactID in Self.exactIDs(for: toolName) {
                if let entry = effectiveIndex.serversByToolID[exactID] {
                    guard case let .server(name) = entry else { return nil }
                    return configuredServerNames.contains(name) ? name : nil
                }
            }
            if !effectiveIndex.isComplete { return nil }
        }
        let split = MCPToolName.split(toolName)
        guard let serverFragment = split.server ?? (toolName.isEmpty ? nil : toolName) else { return nil }
        return configuredServerNames.first { $0 == serverFragment }
            ?? configuredServerNames.first { MCPToolName.safeServerName($0) == serverFragment }
    }

    public static func resolve(toolName: String, effectiveTools: EffectiveTools?,
                               configuredServerNames: [String]) -> String? {
        self.resolve(toolName: toolName, effectiveIndex: effectiveTools.map(Self.serverIndex(from:)),
                     configuredServerNames: configuredServerNames)
    }

    static func exactIDs(for toolName: String) -> [String] {
        toolName.hasPrefix("mcp__") ? [toolName, String(toolName.dropFirst(5))] : [toolName]
    }
}
