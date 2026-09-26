/// SF Symbol for a tool, guessed from its name.
enum ToolSymbols {
    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower == "ask_user" || lower.contains("question") { return "questionmark.bubble" }
        if lower.contains("exec") || lower.contains("bash") || lower.contains("shell") || lower.contains("process") { return "terminal" }
        if lower.contains("read") || lower.contains("view") { return "doc.text" }
        if lower.contains("write") || lower.contains("edit") || lower.contains("patch") { return "pencil" }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") || lower.contains("browser") { return "globe" }
        if lower.contains("image") || lower.contains("canvas") { return "photo" }
        if lower.contains("session") || lower.contains("spawn") || lower.contains("agent") { return "person.2" }
        if lower.contains("memory") { return "brain.head.profile" }
        if lower.contains("message") || lower.contains("send") { return "paperplane" }
        return "wrench.and.screwdriver"
    }
}
