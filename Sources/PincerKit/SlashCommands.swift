import Foundation

// MARK: Catalog

/// One value an argument of a slash command can take.
public struct SlashCommandChoice: Hashable, Sendable {
    public let value: String
    public let label: String
    /// Secondary text, such as a model's provider.
    public let detail: String?

    public init(value: String, label: String? = nil, detail: String? = nil) {
        self.value = value
        self.label = label?.nilIfEmpty ?? value
        self.detail = detail?.nilIfEmpty
    }
}

public struct SlashCommandArg: Hashable, Sendable {
    public let name: String
    public let description: String
    public let isRequired: Bool
    public let choices: [SlashCommandChoice]
    /// The Gateway computes the choices per session and doesn't list them in `commands.list`.
    public let isDynamic: Bool

    public init(name: String, description: String = "", isRequired: Bool = false,
                choices: [SlashCommandChoice] = [], isDynamic: Bool = false)
    {
        self.name = name
        self.description = description
        self.isRequired = isRequired
        self.choices = choices
        self.isDynamic = isDynamic
    }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.text?.nilIfEmpty else { return nil }
        let choices: [SlashCommandChoice] = json["choices"]?.array?.compactMap { choice in
            if let value = choice.string?.nilIfEmpty { return SlashCommandChoice(value: value) }
            guard let value = choice["value"]?.text?.nilIfEmpty else { return nil }
            return SlashCommandChoice(value: value, label: choice["label"]?.text)
        } ?? []
        self.init(name: name, description: json["description"]?.text ?? "", isRequired: json["required"]?.bool ?? false,
                  choices: choices, isDynamic: json["dynamic"]?.bool ?? false)
    }
}

/// A command the Gateway runs when a message starts with `/name`, from `commands.list`.
public struct SlashCommand: Identifiable, Hashable, Sendable {
    /// Name without the slash, as typed (`think`).
    public let name: String
    /// Other names without the slash (`thinking`, `t`).
    public let aliases: [String]
    public let description: String
    public let category: String?
    /// `native`, `skill`, `plugin`, or `client` for commands Pincer rewrites before sending.
    public let source: String
    public let acceptsArgs: Bool
    public let args: [SlashCommandArg]

    public var id: String { self.name }

    public init(name: String, aliases: [String] = [], description: String, category: String? = nil,
                source: String = "native", acceptsArgs: Bool? = nil, args: [SlashCommandArg] = [])
    {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.category = category
        self.source = source
        self.acceptsArgs = acceptsArgs ?? !args.isEmpty
        self.args = args
    }

    public init?(_ json: JSONValue) {
        // Text commands only; native-only ones (Discord/Slack menus) can't be typed.
        if json["scope"]?.string == "native" { return nil }
        let textNames = (json["textAliases"]?.array ?? []).compactMap { alias -> String? in
            guard let text = alias.text else { return nil }
            return Self.normalized(text)
        }
        guard let name = textNames.first ?? json["name"]?.text.flatMap(Self.normalized) else { return nil }
        var aliases: [String] = []
        for alias in textNames.dropFirst() where alias != name && !aliases.contains(alias) {
            aliases.append(alias)
        }
        self.init(
            name: name,
            aliases: aliases,
            description: json["description"]?.text ?? "",
            category: json["category"]?.text,
            source: json["source"]?.text ?? "native",
            acceptsArgs: json["acceptsArgs"]?.bool ?? false,
            args: json["args"]?.array?.compactMap(SlashCommandArg.init) ?? [])
    }

    private static func normalized(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/") { name.removeFirst() }
        name = name.lowercased()
        guard !name.isEmpty, !name.contains(where: \.isWhitespace), !name.contains("/") else { return nil }
        return name
    }

    /// `<level>` / `[instructions]` hints shown next to the name.
    public var usage: String {
        self.args.map { $0.isRequired ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
    }

    public func matches(_ name: String) -> Bool {
        let name = name.lowercased()
        return self.name == name || self.aliases.contains(name)
    }

    public static func parse(_ result: JSONValue) -> [SlashCommand] {
        var seen = Set<String>()
        return (result["commands"]?.array ?? []).compactMap(SlashCommand.init).filter { seen.insert($0.name).inserted }
    }

    // MARK: Client commands

    /// `/clear` isn't a Gateway command; like the Control UI, Pincer sends it as `/reset`.
    public static let clear = SlashCommand(
        name: "clear", description: "Clear the chat history (runs /reset).", category: "session", source: "client",
        acceptsArgs: false)

    /// The Gateway catalog plus client commands it doesn't already provide.
    public static func withClientCommands(_ commands: [SlashCommand]) -> [SlashCommand] {
        commands.contains { $0.matches("clear") } ? commands : commands + [self.clear]
    }

    /// Text to send for a composer message, after rewriting client-only commands.
    public static func outgoingText(_ text: String, commands: [SlashCommand]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() == "/clear", !commands.contains(where: { $0.matches("clear") && $0.source != "client" })
        else { return text }
        return "/reset"
    }

    // MARK: Fallback

    /// Used until `commands.list` answers, and for Gateways that don't have it.
    public static let fallback: [SlashCommand] = {
        let onOff = ["on", "off"].map { SlashCommandChoice(value: $0) }
        return [
            SlashCommand(name: "help", description: "Show available commands.", category: "status"),
            SlashCommand(name: "commands", description: "List all slash commands.", category: "status"),
            SlashCommand(name: "status", description: "Show current status.", category: "status"),
            SlashCommand(name: "new", description: "Start a new session.", category: "session", acceptsArgs: true,
                         args: [SlashCommandArg(name: "model", description: "Model for the new session")]),
            SlashCommand(name: "reset", description: "Reset the current session.", category: "session", acceptsArgs: true),
            SlashCommand(name: "compact", description: "Compact the session context.", category: "session",
                         args: [SlashCommandArg(name: "instructions", description: "Extra compaction instructions")]),
            SlashCommand(name: "stop", description: "Stop the current run.", category: "session"),
            SlashCommand(name: "restart", description: "Restart OpenClaw.", category: "tools"),
            SlashCommand(name: "model", description: "Show or set the model.", category: "options",
                         args: [SlashCommandArg(name: "model", description: "Model id", isDynamic: true)]),
            SlashCommand(name: "models", description: "List model providers/models.", category: "options", acceptsArgs: true),
            SlashCommand(name: "think", aliases: ["thinking", "t"], description: "Set thinking level.", category: "options",
                         args: [SlashCommandArg(name: "level", description: "Thinking level", isDynamic: true)]),
            SlashCommand(name: "verbose", aliases: ["v"], description: "Toggle verbose mode.", category: "options",
                         args: [SlashCommandArg(name: "mode", description: "on, off, or full",
                                                choices: onOff + [SlashCommandChoice(value: "full")])]),
            SlashCommand(name: "reasoning", aliases: ["reason"], description: "Toggle reasoning visibility.", category: "options",
                         args: [SlashCommandArg(name: "mode", description: "on, off, or stream",
                                                choices: onOff + [SlashCommandChoice(value: "stream")])]),
            SlashCommand(name: "fast", description: "Toggle fast mode.", category: "options",
                         args: [SlashCommandArg(name: "mode", description: "on, off, auto, default, or status",
                                                choices: (["on", "off", "auto", "default", "status"]).map { SlashCommandChoice(value: $0) })]),
            SlashCommand(name: "usage", description: "Usage footer or cost summary.", category: "status", acceptsArgs: true),
            SlashCommand(name: "name", description: "Name or rename the current session.", category: "session",
                         args: [SlashCommandArg(name: "title", description: "New session name")]),
        ]
    }()

    /// Thinking levels to offer for `/think` when the session doesn't list its own.
    public static let fallbackThinkingLevels = ["off", "minimal", "low", "medium", "high"]
}

extension SessionRow {
    /// Thinking levels the session's model supports, when the Gateway projects them.
    public var thinkingLevelChoices: [SlashCommandChoice]? {
        if let levels = self.raw["thinkingLevels"]?.array {
            return levels.compactMap { level in
                guard let id = level["id"]?.text?.nilIfEmpty else { return nil }
                return SlashCommandChoice(value: id, label: level["label"]?.text)
            }
        }
        return self.raw["thinkingOptions"]?.array?.compactMap { $0.text?.nilIfEmpty }.map { SlashCommandChoice(value: $0.lowercased(), label: $0) }
    }
}

// MARK: Completion

public struct SlashSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case command(SlashCommand)
        case argument(SlashCommandChoice, command: SlashCommand, arg: SlashCommandArg)
    }

    public let kind: Kind
    /// Composer text after accepting this suggestion.
    public let replacement: String

    public var id: String {
        switch self.kind {
        case let .command(command): "cmd:\(command.name)"
        case let .argument(choice, command, _): "arg:\(command.name):\(choice.value)"
        }
    }

    /// Accepting wouldn't change the message (other than a trailing space), so Return should send.
    public func isComplete(for text: String) -> Bool {
        Self.trimmedTrailing(self.replacement).lowercased() == Self.trimmedTrailing(text).lowercased()
    }

    private static func trimmedTrailing(_ text: String) -> Substring {
        text[..<(text.lastIndex { !$0.isWhitespace }.map { text.index(after: $0) } ?? text.startIndex)]
    }
}

public enum SlashCompletion {
    public static let limit = 50

    /// Suggestions for a composer whose caret is at the end of `text`. `choices` supplies the values
    /// of an argument (at its position) when they aren't in the catalog, such as models.
    public static func suggestions(
        for text: String,
        commands: [SlashCommand],
        choices: (SlashCommand, Int, SlashCommandArg?) -> [SlashCommandChoice] = { _, _, arg in arg?.choices ?? [] }
    ) -> [SlashSuggestion] {
        guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return [] }
        let body = text.dropFirst()
        guard let space = body.firstIndex(where: \.isWhitespace) else {
            return self.commandSuggestions(String(body), commands: commands)
        }
        let name = String(body[..<space])
        guard let command = commands.first(where: { $0.matches(name) }), command.acceptsArgs else { return [] }
        let rest = body[space...]
        var tokens = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        let partial = rest.last?.isWhitespace == true ? "" : (tokens.popLast() ?? "")
        let index = tokens.count
        let arg = command.args.indices.contains(index) ? command.args[index] : nil
        let options = choices(command, index, arg)
        guard !options.isEmpty else { return [] }
        let prefix = String(text.dropLast(partial.count))
        let needsSpace = index < command.args.count - 1
        let query = partial.lowercased()
        let ranked = options.compactMap { choice -> (Int, SlashCommandChoice)? in
            // `provider/model` values also match on the model part.
            let names = [choice.value, choice.label] + (choice.value.split(separator: "/").last.map { [String($0)] } ?? [])
            guard let rank = self.rank(query, names: names, description: choice.detail) else { return nil }
            return (rank, choice)
        }
        let placeholder = arg ?? SlashCommandArg(name: "value")
        return self.sorted(ranked).prefix(self.limit).map { choice in
            SlashSuggestion(
                kind: .argument(choice, command: command, arg: placeholder),
                replacement: prefix + choice.value + (needsSpace ? " " : ""))
        }
    }

    private static func commandSuggestions(_ query: String, commands: [SlashCommand]) -> [SlashSuggestion] {
        guard !query.contains("/") else { return [] }
        let query = query.lowercased()
        let ranked = commands.compactMap { command -> (Int, SlashCommand)? in
            guard let rank = self.rank(query, names: [command.name] + command.aliases, description: command.description)
            else { return nil }
            return (rank, command)
        }
        return self.sorted(ranked).prefix(self.limit).map { command in
            SlashSuggestion(kind: .command(command), replacement: "/\(command.name)" + (command.acceptsArgs ? " " : ""))
        }
    }

    /// 0 exact, 1 prefix, 2 substring, 3 description; nil when it doesn't match.
    private static func rank(_ query: String, names: [String], description: String?) -> Int? {
        guard !query.isEmpty else { return 1 }
        let names = names.map { $0.lowercased() }
        if names.contains(query) { return 0 }
        if names.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if names.contains(where: { $0.contains(query) }) { return 2 }
        if query.count >= 3, description?.lowercased().contains(query) == true { return 3 }
        return nil
    }

    /// Stable within a rank, so the Gateway's (or catalog's) order is kept.
    private static func sorted<T>(_ items: [(Int, T)]) -> [T] {
        items.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
    }
}
