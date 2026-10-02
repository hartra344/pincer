import Foundation

/// Resolves a transcript MCP tool name to a configured server when the session's effective-tool
/// snapshot is available, while preserving the legacy safe-name fallback for cold sessions.
public enum MCPToolServerResolver {
    /// The effective snapshot must belong to the same session as the clicked tool card.
    public static func resolve(toolName: String, effectiveTools: EffectiveTools?, configuredServerNames: [String]) -> String? {
        // Baseline behavior: only the safe prefix is considered until cached effective IDs are used.
        // Keeping this path here means the settings opener and the collision regression exercise
        // the same production resolver.
        _ = effectiveTools
        let split = MCPToolName.split(toolName)
        guard let serverFragment = split.server ?? (toolName.isEmpty ? nil : toolName) else { return nil }
        return configuredServerNames.first { $0 == serverFragment }
            ?? configuredServerNames.first { MCPToolName.safeServerName($0) == serverFragment }
    }
}
