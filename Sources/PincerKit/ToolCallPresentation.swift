import Foundation

/// A tool call laid out for its expanded card: what was asked, and what came back.
/// Built only when a card is expanded (and by Find), never while the transcript scrolls.
public struct ToolCallPresentation: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case exec, read, webFetch, webSearch, mcp, generic }

    public struct Chip: Hashable, Sendable {
        public let symbol: String
        public let label: String
        public let value: String

        public init(symbol: String, label: String, value: String) {
            self.symbol = symbol
            self.label = label
            self.value = value
        }
    }

    public struct Argument: Hashable, Sendable {
        public let key: String
        public let value: String
        public let isNested: Bool

        public init(key: String, value: String, isNested: Bool) {
            self.key = key
            self.value = value
            self.isNested = isNested
        }
    }

    public struct Output: Hashable, Sendable {
        public let text: String
        public let lineCount: Int
        public let imageCount: Int
        public let exitCode: Int?
        public let durationMs: Int?
        public let status: String?
        public let isError: Bool

        public init(text: String, lineCount: Int, imageCount: Int, exitCode: Int?, durationMs: Int?,
                    status: String?, isError: Bool)
        {
            self.text = text
            self.lineCount = lineCount
            self.imageCount = imageCount
            self.exitCode = exitCode
            self.durationMs = durationMs
            self.status = status
            self.isError = isError
        }
    }

    public let kind: Kind
    public let displayName: String
    public let mcpServer: String?
    public let headline: String?
    public let chips: [Chip]
    public let arguments: [Argument]
    public let rawArguments: String?
    public let output: Output?
    public let rawResult: String?

    /// Exactly the searchable strings the formatted card draws, in draw order.
    public var searchTexts: [String] {
        var texts: [String] = []
        if let headline, !headline.isEmpty { texts.append(headline) }
        if let argumentsText, !argumentsText.isEmpty { texts.append(argumentsText) }
        if let text = self.output?.text, !text.isEmpty { texts.append(text) }
        return texts
    }

    /// The arguments as one string of `key\tvalue` lines.
    public var argumentsText: String? {
        guard !self.arguments.isEmpty else { return nil }
        return self.arguments.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
    }

    public static func make(_ tool: ToolActivity, limit: Int = 20_000) -> ToolCallPresentation {
        let parsedArgs = tool.arguments.flatMap { OrderedJSON.parse($0) }
        var pairs: [(key: String, value: OrderedJSON)] = []
        if case let .object(items)? = parsedArgs { pairs = items }
        func arg(_ key: String) -> OrderedJSON? { pairs.last { $0.key == key }?.value }
        func argString(_ keys: String...) -> String? {
            for key in keys {
                if let text = arg(key)?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            return nil
        }

        let unwrapped = tool.result.map(ToolOutputText.unwrap)
        let details = mergedDetails(tool.details, unwrapped?.details)

        let (kind, server, display) = classify(name: tool.name, hasCommand: argString("command", "cmd") != nil)

        var headline: String?
        var chips: [Chip] = []
        var consumed: Set<String> = []
        switch kind {
        case .exec:
            for key in ["command", "cmd"] where argString(key) != nil {
                headline = headline ?? argString(key)
                consumed.insert(key)
            }
            consumed.insert("title")
            let workdir = details?["cwd"]?.text ?? argString("workdir")
            consumed.insert("workdir")
            if let workdir { chips.append(Chip(symbol: "folder", label: "Working directory", value: workdir)) }
            for key in ["timeoutSeconds", "timeout"] {
                guard let value = arg(key) else { continue }
                consumed.insert(key)
                if case let .number(raw) = value, chips.allSatisfy({ $0.symbol != "timer" }) {
                    chips.append(Chip(symbol: "timer", label: "Timeout", value: raw + "s"))
                }
            }
            for (key, symbol, label) in [("background", "moon.zzz", "Background"),
                                         ("pty", "terminal", "Pseudo-terminal"),
                                         ("elevated", "lock.open", "Elevated")]
            {
                guard let value = arg(key) else { continue }
                consumed.insert(key)
                if case .bool(true) = value { chips.append(Chip(symbol: symbol, label: label, value: key)) }
            }
        case .read:
            for key in ["path", "file_path"] where argString(key) != nil {
                if headline == nil { headline = argString(key) }
                consumed.insert(key)
            }
        case .webFetch:
            if let url = argString("url") { headline = url; consumed.insert("url") }
            if let mode = arg("extractMode") {
                consumed.insert("extractMode")
                if let text = mode.stringValue, !text.isEmpty {
                    chips.append(Chip(symbol: "doc.plaintext", label: "Extract mode", value: text))
                }
            }
        case .webSearch:
            if let query = argString("query") { headline = query; consumed.insert("query") }
            if let count = arg("count") {
                consumed.insert("count")
                if case let .number(raw) = count {
                    chips.append(Chip(symbol: "number", label: "Result count", value: raw))
                }
            }
        case .mcp:
            if let server { chips.append(Chip(symbol: "server.rack", label: "Server", value: server)) }
        case .generic:
            break
        }

        let arguments: [Argument] = pairs.filter { !consumed.contains($0.key) }.map { pair in
            switch pair.value {
            case let .string(text): Argument(key: pair.key, value: text, isNested: false)
            case .array, .object: Argument(key: pair.key, value: pair.value.compact, isNested: true)
            default: Argument(key: pair.key, value: pair.value.compact, isNested: false)
            }
        }

        var output: Output?
        if tool.result != nil, let unwrapped {
            var text = ToolOutputText.stripANSI(unwrapped.text)
            while let last = text.last, last.isWhitespace { text.removeLast() }
            let lineCount = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
            if text.count > limit { text = String(text.prefix(limit)) + "\n…" }
            output = Output(text: text, lineCount: lineCount, imageCount: unwrapped.imageCount,
                            exitCode: details?["exitCode"]?.int,
                            durationMs: (kind == .webFetch || kind == .webSearch
                                ? details?["tookMs"]?.int : details?["durationMs"]?.int)
                                ?? details?["tookMs"]?.int,
                            status: status(kind: kind, details: details), isError: tool.isError)
        }

        return ToolCallPresentation(
            kind: kind, displayName: display, mcpServer: server, headline: headline, chips: chips,
            arguments: arguments, rawArguments: parsedArgs == nil ? nil : tool.arguments,
            output: output, rawResult: tool.result)
    }

    private static func classify(name: String, hasCommand: Bool) -> (Kind, String?, String) {
        if name.contains("__") {
            var parts = name.components(separatedBy: "__")
            if parts.first == "mcp" { parts.removeFirst() }
            if parts.count >= 2 {
                return (.mcp, parts[0].isEmpty ? nil : parts[0], parts.dropFirst().joined(separator: "__"))
            }
            return (.mcp, nil, parts.first ?? name)
        }
        let lower = name.lowercased()
        let execNames: Set<String> = ["exec", "bash", "shell", "sh", "run_command", "run_shell_command",
                                      "execute_command", "terminal", "run_terminal_cmd"]
        if hasCommand, execNames.contains(lower) || lower.hasSuffix("exec") || lower.contains("bash")
            || lower.contains("shell")
        {
            return (.exec, nil, name)
        }
        switch lower {
        case "read", "read_file": return (.read, nil, name)
        case "web_fetch": return (.webFetch, nil, name)
        case "web_search": return (.webSearch, nil, name)
        default: return (.generic, nil, name)
        }
    }

    private static func mergedDetails(_ base: JSONValue?, _ envelope: JSONValue?) -> JSONValue? {
        guard let envelope = envelope?.object else { return base }
        guard var merged = base?.object else { return .object(envelope) }
        merged.merge(envelope) { _, new in new }
        return .object(merged)
    }

    private static func status(kind: Kind, details: JSONValue?) -> String? {
        guard let details else { return nil }
        switch kind {
        case .exec:
            if details["timedOut"]?.bool == true { return "timed out" }
            if let signal = details["exitSignal"], !signal.isNull {
                if let text = signal.text { return "signal \(text)" }
                if let number = signal.int { return "signal \(number)" }
            }
            switch details["failureKind"]?.text {
            case "no-output-timeout": return "no output timeout"
            case "overall-timeout": return "timed out"
            case "shell-command-not-found": return "command not found"
            default: break
            }
            switch details["status"]?.text {
            case "running": return "running"
            case "approval-pending": return "approval pending"
            case "approval-unavailable": return "approval unavailable"
            default: return nil
            }
        case .webFetch:
            return details["status"]?.int.map(String.init)
        default:
            return nil
        }
    }
}
