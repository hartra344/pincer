import PincerKit

/// SF Symbol for a tool, guessed from its name.
enum ToolSymbols {
    static func symbol(for name: String) -> String {
        AvatarTool.kind(forToolName: name).symbolName
    }
}
