import Foundation

/// Formats a whole chat for export (#42) as Markdown or plain text. PDF is rendered from the
/// Markdown by the UI. Built from the same `TranscriptBuilder` rows the transcript shows, so an
/// assistant turn's thinking, tool calls and replies stay together.
public enum TranscriptExport {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case markdown, plainText, pdf

        public var id: String { self.rawValue }
        public var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .plainText: "txt"
            case .pdf: "pdf"
            }
        }
    }

    public struct Options: Hashable, Sendable {
        public var includeThinking: Bool
        public var includeToolCalls: Bool

        public init(includeThinking: Bool = false, includeToolCalls: Bool = false) {
            self.includeThinking = includeThinking
            self.includeToolCalls = includeToolCalls
        }
    }

    public struct Header: Sendable {
        public var title: String
        /// Who the assistant is, e.g. the agent's name; "Assistant" when nil.
        public var agentName: String?
        public var exportedAt: Date
        /// Names messages from other agents.
        public var agents: [AgentSummary]

        public init(title: String, agentName: String? = nil, exportedAt: Date = Date(), agents: [AgentSummary] = []) {
            self.title = title
            self.agentName = agentName
            self.exportedAt = exportedAt
            self.agents = agents
        }
    }

    /// Tool output is cut to this many characters per call so one huge read doesn't swamp the file.
    public static let toolOutputLimit = 4000

    // MARK: Markdown

    public static func markdown(_ items: [ChatItem], header: Header, options: Options = Options(),
                                timeZone: TimeZone = .current) -> String
    {
        var out: [String] = ["# \(header.title)"]
        out.append("_\(Self.exportedLine(header, timeZone: timeZone))_")
        for entry in TranscriptBuilder.build(items.filter { !$0.isPending }) {
            switch entry {
            case let .user(item):
                let text = item.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                let files = Self.attachmentNames(item)
                guard !text.isEmpty || !files.isEmpty else { continue }
                var section = "## \(Self.userName(item, header))\(Self.suffix(item.timestamp, timeZone: timeZone))"
                if !text.isEmpty { section += "\n\n\(text)" }
                if !files.isEmpty { section += "\n\n" + files.map { "- 📎 \($0)" }.joined(separator: "\n") }
                out.append(section)
            case let .assistant(turn):
                var parts: [String] = []
                if options.includeThinking {
                    for thought in turn.thinking where !thought.isBlank {
                        parts.append("<details><summary>\(Strings.thinking)</summary>\n\n\(thought.trimmed)\n\n</details>")
                    }
                }
                if options.includeToolCalls {
                    for tool in turn.tools { parts.append(Self.markdownTool(tool)) }
                }
                parts += turn.text.map(\.trimmed).filter { !$0.isEmpty }
                let files = turn.images.compactMap { $0.alt ?? $0.url } + turn.files.map(\.name)
                if !files.isEmpty { parts.append(files.map { "- 📎 \($0)" }.joined(separator: "\n")) }
                guard !parts.isEmpty else { continue }
                let name = turn.sender?.displayName(agents: header.agents) ?? header.agentName ?? Strings.assistant
                out.append("## \(name)\(Self.suffix(turn.timestamp, timeZone: timeZone))\n\n" + parts.joined(separator: "\n\n"))
            case let .marker(_, label):
                out.append("---\n\n_\(label)_")
            }
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    static func markdownTool(_ tool: ToolActivity) -> String {
        let presentation = ToolCallPresentation.make(tool, limit: Self.toolOutputLimit)
        var title = "🔧 **\(presentation.displayName)**"
        if let headline = presentation.headline?.trimmed, !headline.isEmpty {
            title += " `\(headline.replacingOccurrences(of: "`", with: "'").prefix(200))`"
        }
        if presentation.output?.isError == true || tool.isError { title += " — \(Strings.failed)" }
        var body = ""
        if let args = presentation.argumentsText, presentation.headline == nil || presentation.arguments.count > 1 {
            body += "\n\n" + Self.fence(args.replacingOccurrences(of: "\t", with: ": "))
        }
        if let output = presentation.output?.text.trimmed, !output.isEmpty {
            body += "\n\n\(Strings.output)\n\n" + Self.fence(output)
        }
        return title + body
    }

    /// A code fence that can't be closed early by backticks inside `text`.
    static func fence(_ text: String) -> String {
        var ticks = "```"
        while text.contains(ticks) { ticks += "`" }
        return "\(ticks)\n\(text)\n\(ticks)"
    }

    // MARK: Plain text

    public static func plainText(_ items: [ChatItem], header: Header, options: Options = Options(),
                                 timeZone: TimeZone = .current) -> String
    {
        var out: [String] = [header.title, Self.exportedLine(header, timeZone: timeZone)]
        for entry in TranscriptBuilder.build(items.filter { !$0.isPending }) {
            switch entry {
            case let .user(item):
                let text = item.plainText.trimmed
                let files = Self.attachmentNames(item)
                guard !text.isEmpty || !files.isEmpty else { continue }
                var lines = ["\(Self.userName(item, header))\(Self.suffix(item.timestamp, timeZone: timeZone)):"]
                if !text.isEmpty { lines.append(text) }
                lines += files.map { "[\(Strings.attachment(named: $0))]" }
                out.append(lines.joined(separator: "\n"))
            case let .assistant(turn):
                var parts: [String] = []
                if options.includeThinking {
                    for thought in turn.thinking where !thought.isBlank { parts.append("[\(Strings.thinking)]\n\(thought.trimmed)") }
                }
                if options.includeToolCalls {
                    for tool in turn.tools { parts.append(Self.plainTool(tool)) }
                }
                parts += turn.text.map(\.trimmed).filter { !$0.isEmpty }
                parts += (turn.images.compactMap { $0.alt ?? $0.url } + turn.files.map(\.name)).map { "[\(Strings.attachment(named: $0))]" }
                guard !parts.isEmpty else { continue }
                let name = turn.sender?.displayName(agents: header.agents) ?? header.agentName ?? Strings.assistant
                out.append("\(name)\(Self.suffix(turn.timestamp, timeZone: timeZone)):\n" + parts.joined(separator: "\n\n"))
            case let .marker(_, label):
                out.append("— \(label) —")
            }
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    static func plainTool(_ tool: ToolActivity) -> String {
        let presentation = ToolCallPresentation.make(tool, limit: Self.toolOutputLimit)
        var line = "[\(Strings.tool(named: presentation.displayName))"
        if let headline = presentation.headline?.trimmed, !headline.isEmpty { line += " \(headline.prefix(200))" }
        if presentation.output?.isError == true || tool.isError { line += " (\(Strings.failed))" }
        line += "]"
        if let output = presentation.output?.text.trimmed, !output.isEmpty {
            line += "\n" + output.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n")
        }
        return line
    }

    // MARK: Helpers

    /// A file name for the export, e.g. `Trip planning.md`. Characters no file system allows become `-`.
    public static func fileName(title: String, format: Format) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? Strings.chat : String(cleaned.prefix(80))
        return "\(base).\(format.fileExtension)"
    }

    private static func userName(_ item: ChatItem, _ header: Header) -> String {
        item.sender?.displayName(agents: header.agents) ?? Strings.you
    }

    private static func attachmentNames(_ item: ChatItem) -> [String] {
        item.blocks.compactMap { block in
            switch block {
            case let .image(ref): ref.alt ?? ref.url ?? "image"
            case let .file(file): file.name
            default: nil
            }
        }
    }

    private static func suffix(_ date: Date?, timeZone: TimeZone) -> String {
        date.map { " · \(Self.stamp($0, timeZone: timeZone))" } ?? ""
    }

    static func exportedLine(_ header: Header, timeZone: TimeZone) -> String {
        let stamp = Self.stamp(header.exportedAt, timeZone: timeZone)
        return L("Exported \(stamp)", comment: "Transcript export header: when the chat was exported")
    }

    enum Strings {
        static var you: String { L("You", comment: "Transcript export: name for the user's own messages") }
        static var assistant: String { L("Assistant", comment: "Transcript export: name for the agent when it has none") }
        static var thinking: String { L("Thinking", comment: "Transcript export: label for the agent's thinking") }
        static var output: String { L("Output:", comment: "Transcript export: label before a tool call's output") }
        static var failed: String { L("failed", comment: "Transcript export: a tool call that failed") }
        static var chat: String { L("Chat", comment: "Transcript export: file name when the chat has no title") }
        static func tool(named name: String) -> String {
            L("Tool: \(name)", comment: "Transcript export (plain text): a tool call, e.g. Tool: exec")
        }
        static func attachment(named name: String) -> String {
            L("Attachment: \(name)", comment: "Transcript export (plain text): an attached file")
        }
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private extension String {
    var trimmed: String { self.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { self.trimmed.isEmpty }
}
