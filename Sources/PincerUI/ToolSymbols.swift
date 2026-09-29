import PincerKit

/// SF Symbol for a tool, guessed from its name.
enum ToolSymbols {
    static func symbol(for name: String) -> String {
        // MCP tools are `server__tool`; the name's words (search, list…) say nothing about the plug.
        if name.contains("__") { return "powerplug" }
        return AvatarTool.kind(forToolName: name).symbolName
    }

    /// Symbol for a chip from `ToolCallPresentation`, restyled or replaced when a name isn't a symbol.
    @MainActor
    static func chipSymbol(_ name: String) -> String {
        let mapped = name == "moon.zzz" ? "clock.arrow.circlepath" : name
        return TranscriptSymbols.image(mapped, size: 10) == nil ? "circle.fill" : mapped
    }
}
