import Foundation
import UniformTypeIdentifiers

// MARK: Agents

public struct AgentSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let emoji: String?
    public let avatarURL: String?

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.name = json["identity"]?["name"]?.text ?? json["name"]?.text ?? id.capitalized
        self.emoji = json["identity"]?["emoji"]?.text
        self.avatarURL = json["identity"]?["avatarUrl"]?.text
    }

    public init(id: String, name: String, emoji: String? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.avatarURL = nil
    }
}

// MARK: Sessions ("channels")

/// Gateway session row. Kept as raw JSON so new Gateway fields never break decoding.
public struct SessionRow: Identifiable, Hashable, Sendable {
    public let raw: JSONValue
    public var id: String { self.key }

    public init?(_ json: JSONValue) {
        guard json["key"]?.text != nil else { return nil }
        self.raw = json
    }

    public var key: String { self.raw["key"]?.string ?? "" }
    public var sessionId: String? { self.raw["sessionId"]?.text }
    public var agentId: String { self.raw["agentId"]?.text ?? SessionKey.agentId(from: self.key) ?? "main" }
    public var category: String? { self.raw["category"]?.text }
    public var color: String? { self.raw["color"]?.text }
    public var icon: String? { self.raw["icon"]?.text }
    public var channel: String? { self.raw["channel"]?.text }
    public var chatType: String? { self.raw["chatType"]?.text }
    public var isMain: Bool { self.raw["isMain"]?.bool ?? SessionKey.isMain(self.key) }
    public var isPinned: Bool { self.raw["pinned"]?.bool ?? false }
    public var isUnread: Bool { self.raw["unread"]?.bool ?? false }
    public var isArchived: Bool { self.raw["archived"]?.bool ?? (self.raw["archivedAt"]?.double != nil) }
    public var hasActiveRun: Bool { self.raw["hasActiveRun"]?.bool ?? false }
    public var status: String? { self.raw["status"]?.text }
    public var lastRunError: String? { self.raw["lastRunError"]?.text }
    /// The last message as one line of plain text. Gateways send the raw message, Markdown and
    /// line breaks included, which a one-line list row can't show.
    public var preview: String? {
        guard let text = self.raw["lastMessagePreview"]?.text else { return nil }
        let line = Self.plainLine(text)
        return line.isEmpty ? nil : line
    }
    public var parentKey: String? { self.raw["parentSessionKey"]?.text ?? self.raw["spawnedBy"]?.text }
    public var model: String? { self.raw["model"]?.text }
    public var modelProvider: String? { self.raw["modelProvider"]?.text }
    /// Selected model as a `provider/model` ref, the form `sessions.patch` accepts.
    public var modelRef: String? { self.model.map { ModelRef.qualified($0, provider: self.modelProvider) } }
    /// Model actually serving the session while it differs from the selected one (e.g. a fallback).
    public var activeModelRef: String? {
        self.raw["activeModel"]?.text.map { ModelRef.qualified($0, provider: self.raw["activeModelProvider"]?.text) }
    }
    /// `user` when someone picked the model for this session; `nil` when it follows the agent default.
    public var modelOverrideSource: String? { self.raw["modelOverrideSource"]?.text }
    /// The Gateway doesn't allow changing this session's model.
    public var isModelSelectionLocked: Bool { self.raw["modelSelectionLocked"]?.bool ?? false }
    public var reasoningLevel: String? { self.raw["reasoningLevel"]?.text }
    public var thinkingLevel: String? { self.raw["thinkingLevel"]?.text }

    /// Agent-spawned helper runs (as opposed to chats a person branched off another chat).
    public var isSubagent: Bool { self.key.contains(":subagent:") }
    public var isAutomation: Bool { self.key.contains(":cron:") && !self.isSubagent }
    public var isSlashCommands: Bool { self.key.contains(":slash:") }

    /// Candidate parents, most specific first. Automation runs aren't listed as sessions,
    /// so their subagents fall back to the automation (`…:cron:<job>:run:<run>` → `…:cron:<job>`).
    public var parentCandidates: [String] {
        guard let parent = self.parentKey, !self.isStandaloneChat else { return [] }
        if let run = parent.range(of: ":run:"), parent.contains(":cron:") {
            return [parent, String(parent[..<run.lowerBound])]
        }
        return [parent]
    }
    /// New chats started from the agent's main chat record it as their parent so follow-up notices
    /// have somewhere to go, but they're separate conversations, not replies. Mirrors the Control UI's
    /// `resolveSidebarSessionParentKey`: only branches, forks and delegated runs nest.
    public var isStandaloneChat: Bool {
        guard let parent = self.raw["parentSessionKey"]?.text, !self.isSubagent,
              self.raw["spawnedBy"]?.text == nil,
              self.raw["parentSessionId"]?.text == nil,
              self.raw["forkSource"] == nil || self.raw["forkSource"] == .null,
              self.raw["forkedFromParent"]?.bool != true,
              (self.raw["spawnDepth"]?.double ?? 0) == 0
        else { return false }
        let createdVia = self.raw["createdVia"]?.text
        guard createdVia == "operator" || (createdVia == nil && self.key.contains(":dashboard:")) else { return false }
        return SessionKey.isMain(parent)
    }

    public var isChannelThread: Bool { self.key.contains(":thread:") || self.raw["origin"]?["threadId"] != nil }

    /// Native channel name without the leading `#`, e.g. `finances` for Discord `#finances`.
    public var channelName: String? {
        guard let raw = self.raw["groupChannel"]?.text else { return nil }
        let name = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        return name.isEmpty ? nil : name
    }

    /// Chat server (Discord guild, Slack workspace, …) this session's channel belongs to.
    public var server: ChatServer? {
        guard !self.isSubagent,
              self.raw["kind"]?.string == "group" || self.channelName != nil || self.chatType == "channel" || self.chatType == "group"
        else { return nil }
        // `origin.provider` follows the last sender (e.g. `webchat` after replying from the web UI),
        // so the delivery channel is the better signal for where the conversation lives.
        let provider = (self.channel ?? self.raw["lastChannel"]?.text ?? self.raw["origin"]?["provider"]?.text)?.lowercased()
        guard let provider, provider != "webchat", provider != "internal" else { return nil }
        let parsedName = self.raw["origin"]?["label"]?.text.flatMap(Self.serverName(fromOriginLabel:))
        guard let id = self.raw["space"]?.text ?? parsedName else { return nil }
        return ChatServer(provider: provider, id: id, name: parsedName)
    }

    /// Channel plugins label conversations as `<Server> #<channel> channel id:<id>`.
    static func serverName(fromOriginLabel label: String) -> String? {
        guard let hash = label.range(of: " #") else { return nil }
        let name = label[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "Guild" ? nil : name
    }

    /// Gateway fallback titles look like `<opaque server id> #channel`; those aren't worth showing.
    static func isGeneratedGroupTitle(_ title: String) -> Bool {
        if title.count >= 10, title.allSatisfy(\.isNumber) { return true }
        guard let space = title.firstIndex(of: " ") else { return false }
        let head = title[..<space]
        return head.count >= 10 && head.allSatisfy(\.isNumber) && title[space...].contains("#")
    }

    static func cleanedTitle(_ title: String) -> String {
        guard self.isGeneratedGroupTitle(title), let space = title.firstIndex(of: " ") else { return title }
        let rest = title[title.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("#") ? String(rest.dropFirst()) : rest
    }

    public var title: String {
        if let label = self.raw["label"]?.text, !Self.isGeneratedGroupTitle(label) {
            if self.isAutomation, label.hasPrefix("Automation: ") { return String(label.dropFirst("Automation: ".count)) }
            return label
        }
        if self.isSlashCommands { return "Slash commands" }
        if self.isChannelThread {
            if let derived = self.raw["derivedTitle"]?.text { return derived }
            if let auto = self.raw["autoLabel"]?.text { return auto }
        }
        if let channel = self.channelName { return channel }
        if let name = self.raw["displayName"]?.text { return Self.cleanedTitle(name) }
        if let derived = self.raw["derivedTitle"]?.text { return derived }
        if let auto = self.raw["autoLabel"]?.text { return auto }
        if self.isMain { return "main" }
        return SessionKey.shortName(self.key)
    }

    /// Latest activity in ms since epoch, falling back through the documented sort order.
    public var activityMs: Double {
        let candidates = ["lastActivityAt", "lastInteractionAt", "updatedAt", "createdAt"].compactMap { self.raw[$0]?.double }
        return candidates.max() ?? 0
    }

    public var activityDate: Date? {
        let ms = self.activityMs
        return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
    }

    /// Where the conversation originated, e.g. "discord" when it came from the Discord channel.
    public var originLabel: String? {
        guard let channel, channel != "webchat", channel != "internal" else { return nil }
        return channel.capitalized
    }
}

public struct ChatServer: Hashable, Sendable {
    public let provider: String
    public let id: String
    public let name: String?

    public init(provider: String, id: String, name: String?) {
        self.provider = provider
        self.id = id
        self.name = name
    }

    public var displayName: String { self.name ?? self.provider.capitalized }
}

// MARK: Models

/// Model references as the Gateway writes them: `provider/model`, or a bare model id.
public enum ModelRef {
    /// Mirrors the Control UI's `buildQualifiedChatModelValue`.
    public static func qualified(_ model: String, provider: String?) -> String {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard let provider = provider?.trimmingCharacters(in: .whitespaces), !provider.isEmpty, !model.isEmpty else { return model }
        return model.lowercased().hasPrefix(provider.lowercased() + "/") ? model : "\(provider)/\(model)"
    }

    /// The model part alone, e.g. `claude-opus-4-8` for `anthropic/claude-opus-4-8`.
    public static func shortName(_ ref: String) -> String {
        guard let slash = ref.lastIndex(of: "/") else { return ref }
        let tail = ref[ref.index(after: slash)...]
        return tail.isEmpty ? ref : String(tail)
    }
}

/// One entry of `models.list`.
public struct ModelChoice: Identifiable, Hashable, Sendable {
    public let modelId: String
    public let name: String
    public let provider: String
    public let alias: String?
    /// `false` when the provider is missing auth or cooling down.
    public let isAvailable: Bool
    public let manualSelectionAllowed: Bool

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text, let provider = json["provider"]?.text else { return nil }
        self.modelId = id
        self.provider = provider
        self.name = json["name"]?.text ?? id
        self.alias = json["alias"]?.text
        self.isAvailable = json["available"]?.bool ?? true
        self.manualSelectionAllowed = json["manualSelectionAllowed"]?.bool ?? true
    }

    /// `provider/id`, the value `sessions.patch { model }` takes.
    public var ref: String { ModelRef.qualified(self.modelId, provider: self.provider) }
    public var id: String { self.ref }
    public var displayName: String { self.alias ?? self.name }
}

public enum SessionKey {
    /// `agent:<agentId>:<rest>` → `<agentId>`
    public static func agentId(from key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    static func isMain(_ key: String) -> Bool {
        key == "main" || key == "global" || key.hasSuffix(":main")
    }

    static func shortName(_ key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.count >= 3, parts[0] == "agent" {
            return parts.dropFirst(2).joined(separator: ":")
        }
        return key
    }
}

// MARK: Transcript

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case toolResult
    case system
    case marker

    init(_ raw: String?) {
        switch raw?.lowercased() {
        case "user": self = .user
        case "assistant": self = .assistant
        case "toolresult", "tool_result", "tool": self = .toolResult
        default: self = .system
        }
    }
}

public struct ImageRef: Hashable, Codable, Sendable {
    public let artifactId: String?
    public let base64: String?
    public let url: String?
    public let mimeType: String?
    public let alt: String?
    public let width: Int?
    public let height: Int?

    public var cacheKey: String {
        // Inline images often share a long header (SVG's xmlns), so a prefix alone would collide.
        self.artifactId ?? self.url ?? self.base64.map { "inline:\($0.count):\(Self.stableHash($0))" } ?? "image"
    }

    public init(artifactId: String?, base64: String?, url: String?, mimeType: String?, alt: String?, width: Int?, height: Int?) {
        self.artifactId = artifactId
        self.base64 = base64
        self.url = url
        self.mimeType = mimeType
        self.alt = alt
        self.width = width
        self.height = height
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 36)
    }

    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

/// A non-image attachment, with where to fetch it from when the Gateway said.
public struct FileRef: Hashable, Codable, Sendable {
    public let name: String
    public let url: String?
    public let artifactId: String?
    public let mimeType: String?

    public init(name: String, url: String? = nil, artifactId: String? = nil, mimeType: String? = nil) {
        self.name = name
        self.url = url
        self.artifactId = artifactId
        self.mimeType = mimeType
    }

    public var cacheKey: String { self.artifactId ?? self.url ?? self.name }
    public var isDownloadable: Bool { self.artifactId != nil || self.url != nil }

    /// Plain text or source code, which can be shown inline.
    public var isText: Bool {
        if let mime = self.mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           mime != "application/octet-stream"
        {
            if mime.hasPrefix("text/") { return true }
            if Self.textMimeTypes.contains(mime) || mime.hasSuffix("+json") || mime.hasSuffix("+xml") { return true }
        }
        let name = self.name.lowercased()
        if Self.textFileNames.contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && Self.textExtensions.contains(ext)
    }

    /// Language hint for the preview header: the extension, or "text".
    public var language: String {
        let ext = (self.name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "text" : ext
    }

    static let textMimeTypes: Set<String> = [
        "application/json", "application/xml", "application/yaml", "application/x-yaml", "application/toml",
        "application/javascript", "application/x-javascript", "application/typescript", "application/x-sh",
        "application/x-shellscript", "application/sql", "application/graphql", "application/x-httpd-php",
        "application/x-python", "application/x-ruby", "application/x-perl", "application/ld+json", "application/ndjson",
        "application/x-ndjson", "application/csv", "application/x-tex", "application/rtf", "image/svg+xml",
    ]
    static let textFileNames: Set<String> = [
        "dockerfile", "makefile", "gemfile", "rakefile", "podfile", "procfile", "license", "readme", "changelog",
        ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig", ".env", ".npmrc", ".prettierrc", ".eslintrc",
    ]
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdx", "rst", "adoc", "org", "log", "csv", "tsv", "json", "jsonl", "ndjson",
        "json5", "yaml", "yml", "toml", "ini", "cfg", "conf", "config", "env", "properties", "xml", "plist", "html",
        "htm", "xhtml", "css", "scss", "sass", "less", "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "vue",
        "svelte", "astro", "py", "pyi", "ipynb", "rb", "erb", "go", "rs", "swift", "kt", "kts", "java", "scala",
        "groovy", "gradle", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cs", "fs", "fsx", "vb", "php",
        "pl", "pm", "lua", "r", "jl", "dart", "ex", "exs", "erl", "hrl", "elm", "clj", "cljs", "edn", "hs", "ml",
        "mli", "nim", "zig", "v", "sv", "vhd", "sol", "sh", "bash", "zsh", "fish", "ps1", "psm1", "bat", "cmd",
        "sql", "graphql", "gql", "proto", "tf", "tfvars", "hcl", "nix", "cmake", "mk", "dockerfile", "diff", "patch",
        "tex", "bib", "srt", "vtt", "svg", "lock", "gitignore", "editorconfig", "rtf",
    ]
}

public enum ContentBlock: Hashable, Codable, Sendable {
    case text(String)
    case thinking(String)
    case image(ImageRef)
    case toolCall(id: String, name: String, arguments: String?)
    case file(FileRef)

    static func parse(_ json: JSONValue) -> ContentBlock? {
        let type = json["type"]?.string?.lowercased() ?? "text"
        switch type {
        case "text", "output_text", "input_text":
            guard let text = json["text"]?.string, !text.isEmpty else { return nil }
            return .text(text)
        case "thinking", "reasoning", "redacted_thinking":
            guard let thinking = json["thinking"]?.text ?? json["text"]?.text,
                  !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .thinking(thinking)
        case "image", "input_image":
            let source = json["source"]
            // The Gateway strips bytes from large tool-result images (`omitted: true`); there's nothing to show.
            guard json["artifactId"]?.text != nil || json["data"]?.text != nil || json["content"]?.text != nil
                || source?["data"]?.text != nil || json["url"]?.text != nil || json["openUrl"]?.text != nil
            else { return nil }
            return .image(ImageRef(
                artifactId: json["artifactId"]?.text,
                base64: json["data"]?.text ?? json["content"]?.text ?? source?["data"]?.text,
                url: json["url"]?.text ?? json["openUrl"]?.text,
                mimeType: json["mimeType"]?.text ?? source?["media_type"]?.text,
                alt: json["alt"]?.text ?? json["fileName"]?.text,
                width: json["width"]?.int,
                height: json["height"]?.int))
        case "toolcall", "tool_call", "tool_use", "functioncall":
            let arguments = json["arguments"] ?? json["input"] ?? json["args"]
            return .toolCall(
                id: json["id"]?.text ?? UUID().uuidString,
                name: json["name"]?.text ?? "tool",
                arguments: arguments.flatMap(Self.prettyJSON))
        case "file", "attachment", "audio", "video":
            // Control UI shape: `{type: "attachment", attachment: {url, kind, label, mimeType, artifactId}}`.
            if let attachment = json["attachment"], attachment["url"]?.text != nil || attachment["artifactId"]?.text != nil {
                let url = attachment["url"]?.text
                let mimeType = attachment["mimeType"]?.text
                let label = attachment["label"]?.text ?? url.flatMap(MediaDirectives.fileName)
                let isImage = attachment["kind"]?.text == "image" || mimeType?.hasPrefix("image/") == true
                    || url.map(MediaDirectives.isImage) == true
                if isImage {
                    return .image(ImageRef(
                        artifactId: attachment["artifactId"]?.text, base64: nil, url: url, mimeType: mimeType, alt: label,
                        width: attachment["width"]?.int, height: attachment["height"]?.int))
                }
                return .file(FileRef(name: label ?? "attachment", url: url, artifactId: attachment["artifactId"]?.text, mimeType: mimeType))
            }
            if json["mimeType"]?.string?.hasPrefix("image/") == true,
               json["artifactId"]?.text != nil || json["content"]?.text != nil || json["url"]?.text != nil {
                return .image(ImageRef(
                    artifactId: json["artifactId"]?.text,
                    base64: json["content"]?.text,
                    url: json["url"]?.text,
                    mimeType: json["mimeType"]?.text,
                    alt: json["fileName"]?.text,
                    width: json["width"]?.int,
                    height: json["height"]?.int))
            }
            let url = json["url"]?.text ?? json["openUrl"]?.text
            return .file(FileRef(
                name: json["fileName"]?.text ?? json["label"]?.text ?? url.flatMap(MediaDirectives.fileName) ?? "attachment",
                url: url, artifactId: json["artifactId"]?.text, mimeType: json["mimeType"]?.text))
        default:
            if let text = json["text"]?.text { return .text(text) }
            return nil
        }
    }

    static func prettyJSON(_ value: JSONValue) -> String? {
        if case let .string(text) = value { return text }
        guard let data = try? JSONEncoder.pretty.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

public struct ChatItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var transcriptId: String?
    public var role: ChatRole
    public var blocks: [ContentBlock]
    public var timestamp: Date?
    public var runId: String?
    public var toolCallId: String?
    public var toolName: String?
    public var isError: Bool
    public var errorMessage: String?
    /// e.g. "Discord" when a user turn arrived through another channel.
    public var via: String?
    public var markerKind: String?
    public var idempotencyKey: String?
    public var isPending: Bool = false
    /// Model that generated this message, as recorded by the Gateway (assistant messages only).
    public var model: String?
    public var provider: String?
    /// The Gateway cut this message's text to its history cap; the full copy comes from
    /// `chat.message.get`.
    public var isCapped: Bool = false

    /// `provider/model`, or nil when the Gateway didn't record a model.
    public var modelRef: String? { self.model.map { ModelRef.qualified($0, provider: self.provider) } }
    public init(
        id: String = UUID().uuidString,
        role: ChatRole,
        blocks: [ContentBlock],
        timestamp: Date? = Date(),
        idempotencyKey: String? = nil,
        isPending: Bool = false)
    {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.isError = false
        self.idempotencyKey = idempotencyKey
        self.isPending = isPending
    }

    public init?(_ json: JSONValue, fallbackIndex: Int) {
        let meta = json["__openclaw"]
        self.transcriptId = meta?["id"]?.text
        self.markerKind = meta?["kind"]?.text
        self.runId = meta?["runId"]?.text
        self.idempotencyKey = meta?["idempotencyKey"]?.text ?? json["idempotencyKey"]?.text
        let baseId = self.transcriptId ?? "idx-\(fallbackIndex)"
        // Stable across reloads and older pages, so rows keep their identity and scroll position.
        self.id = baseId
        self.role = self.markerKind != nil ? .marker : ChatRole(json["role"]?.string)
        self.toolCallId = json["toolCallId"]?.text ?? json["tool_call_id"]?.text
        self.toolName = json["toolName"]?.text ?? json["tool_name"]?.text
        self.isError = json["isError"]?.bool ?? json["is_error"]?.bool ?? false
        self.errorMessage = json["errorMessage"]?.text
        if let ts = json["timestamp"]?.double {
            self.timestamp = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
        } else {
            self.timestamp = nil
        }
        let provenance = json["provenance"]
        self.via = provenance?["sourceChannel"]?.text.map { $0.capitalized }
        if self.role == .assistant, let model = json["model"]?.text, !Self.syntheticModels.contains(model) {
            self.model = model
            self.provider = json["provider"]?.text
        }
        // Only the Gateway marker proves a cap; the sentinel text alone could be literal.
        let recoverable = self.role == .assistant || self.transcriptId?.hasPrefix(Self.pendingInputPrefix) == true
        self.isCapped = recoverable && meta?["truncated"]?.bool == true
            && json["openclawMessageToolMirror"]?.bool != true

        if let text = json["content"]?.string {
            self.blocks = text.isEmpty ? [] : [.text(text)]
        } else {
            self.blocks = (json["content"]?.array ?? []).compactMap(ContentBlock.parse)
        }
        self.blocks += Self.mediaFactBlocks(meta?["media"], existing: self.blocks)
        if self.blocks.isEmpty, self.role == .assistant, let errorMessage {
            self.blocks = [.text(errorMessage)]
            self.isError = true
        }
        if self.blocks.isEmpty, self.role != .marker, self.role != .toolResult {
            return nil
        }
    }

    /// Placeholders the Gateway writes for messages no model produced (injected notices, errors).
    static let syntheticModels: Set<String> = ["gateway-injected"]

    /// Transcript id prefix of queued user inputs the Gateway hasn't committed yet.
    static let pendingInputPrefix = "pending:"

    /// Uploads (composer attachments, channel media) live in `__openclaw.media` facts, not in
    /// `content`: history strips their bytes and points at `media://inbound/<id>` instead.
    static func mediaFactBlocks(_ facts: JSONValue?, existing: [ContentBlock]) -> [ContentBlock] {
        var seen = Set(existing.compactMap { block -> String? in
            if case let .image(ref) = block { return ref.url }
            return nil
        })
        return (facts?.array ?? []).compactMap { fact in
            guard let source = fact["path"]?.text ?? fact["url"]?.text, !source.isEmpty, seen.insert(source).inserted else { return nil }
            let mimeType = fact["contentType"]?.text
            let fileName = fact["fileName"]?.text
            let isImage = mimeType.map { $0.hasPrefix("image/") }
                ?? (fact["kind"]?.text == "image"
                    || UTType(filenameExtension: (source as NSString).pathExtension)?.conforms(to: .image) == true)
            if isImage {
                return .image(ImageRef(
                    artifactId: nil, base64: nil, url: source, mimeType: mimeType, alt: fileName,
                    width: fact["width"]?.int, height: fact["height"]?.int))
            }
            return .file(FileRef(name: fileName ?? (source as NSString).lastPathComponent, url: source, mimeType: mimeType))
        }
    }

    public var plainText: String {
        self.blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    public var thinkingText: String? {
        let parts = self.blocks.compactMap { block -> String? in
            if case let .thinking(text) = block { return text }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

// MARK: Presentation

/// A tool invocation paired with its result, rendered as one card.
public struct ToolActivity: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var arguments: String? { didSet { self.derive() } }
    public var result: String? { didSet { self.derive() } }
    public var isError: Bool
    public var isRunning: Bool
    /// One-line hint (command, path, query) for the collapsed card. Derived once, not per render.
    public private(set) var summary: String?
    /// Subagent session this call started, when the call names one.
    public private(set) var spawnedSessionKey: String?
    /// `label` argument of a spawn call, for matching the run when no key is echoed back.
    public private(set) var spawnLabel: String?

    public init(id: String, name: String, arguments: String?, result: String?, isError: Bool, isRunning: Bool) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.isRunning = isRunning
        self.derive()
    }

    private mutating func derive() {
        let object = self.arguments?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let object {
            self.summary = ["command", "cmd", "path", "file_path", "url", "query", "pattern", "action"]
                .lazy.compactMap { object[$0] as? String }.first
        } else {
            self.summary = self.arguments.map { String($0.prefix(80)) }
        }
        self.spawnLabel = self.name.lowercased().contains("spawn") ? object?["label"] as? String : nil
        let text = [self.arguments, self.result].compactMap { $0 }.joined(separator: "\n")
        self.spawnedSessionKey = text.contains(":subagent:")
            ? text.firstMatch(of: /agent:[A-Za-z0-9_.-]+:subagent:[A-Za-z0-9-]+/).map { String($0.output) }
            : nil
    }
}

/// One visual row in the transcript. Assistant turns fold their thinking, tool calls
/// and tool results together, the way the OpenClaw native UI does.
public enum TranscriptEntry: Identifiable, Hashable, Sendable {
    case user(ChatItem)
    case assistant(AssistantTurn)
    case marker(id: String, label: String)

    public var id: String {
        switch self {
        case let .user(item): "u-\(item.id)"
        case let .assistant(turn): "a-\(turn.id)"
        case let .marker(id, _): "m-\(id)"
        }
    }
}

public struct AssistantTurn: Identifiable, Hashable, Sendable {
    public var id: String
    public var thinking: [String] = []
    public var tools: [ToolActivity] = []
    /// One entry per assistant message, so back-to-back messages in a turn stay distinct.
    public var text: [String] = []
    /// When each entry of `text` was sent, in the same order.
    public var textTimestamps: [Date?] = []
    /// Short name of the model that wrote each entry of `text`, when the Gateway recorded one.
    public var textModelNames: [String?] = []
    public var images: [ImageRef] = []
    public var files: [FileRef] = []
    public var timestamp: Date?
    public var isError = false
    public var isStreaming = false
    /// Model that generated the turn (the latest assistant message's, if a fallback switched
    /// models mid-turn). Comes from the Gateway's transcript, so it survives reloads and doesn't
    /// change when the session's model does. Nil when the Gateway didn't record one.
    public var model: String?
    public var provider: String?

    public var body: String { self.text.joined(separator: "\n\n") }
    /// `provider/model`, e.g. `anthropic/claude-opus-4-8`.
    public var modelRef: String? { self.model.map { ModelRef.qualified($0, provider: self.provider) } }
    /// Short label for display, e.g. `claude-opus-4-8`.
    public var modelName: String? { self.modelRef.map(ModelRef.shortName) }
}

public enum TranscriptBuilder {
    public static func build(_ items: [ChatItem]) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var current: AssistantTurn?
        var currentRunId: String?
        var toolIndex: [String: Int] = [:]

        func flush() {
            if let turn = current {
                entries.append(.assistant(turn))
            }
            current = nil
            currentRunId = nil
            toolIndex.removeAll()
        }

        for item in items {
            switch item.role {
            case .user:
                flush()
                entries.append(.user(item))
            case .marker:
                flush()
                let label = switch item.markerKind {
                case "compaction": "Context compacted"
                case "reset": "New session"
                default: item.markerKind?.capitalized ?? "—"
                }
                entries.append(.marker(id: item.id, label: label))
            case .system:
                continue
            case .assistant:
                // A reply from another run (a cron job, a follow-up) is its own row, not part of this one.
                if let runId = item.runId, let currentRunId, runId != currentRunId { flush() }
                if let runId = item.runId { currentRunId = runId }
                var turn = current ?? AssistantTurn(id: item.id, timestamp: item.timestamp)
                turn.timestamp = item.timestamp ?? turn.timestamp
                turn.isError = turn.isError || item.isError
                if let model = item.model {
                    turn.model = model
                    turn.provider = item.provider
                }
                var message: [String] = []
                for block in item.blocks {
                    switch block {
                    case let .text(text):
                        let parsed = MediaDirectives.extract(from: text)
                        if !parsed.text.isEmpty { message.append(parsed.text) }
                        turn.images += parsed.images
                        turn.files += parsed.files
                    case let .thinking(text): turn.thinking.append(text)
                    case let .image(ref): turn.images.append(ref)
                    case let .file(file): turn.files.append(file)
                    case let .toolCall(id, name, arguments):
                        toolIndex[id] = turn.tools.count
                        turn.tools.append(ToolActivity(id: id, name: name, arguments: arguments, result: nil, isError: false, isRunning: false))
                    }
                }
                if !message.isEmpty {
                    turn.text.append(message.joined(separator: "\n\n"))
                    turn.textTimestamps.append(item.timestamp)
                    turn.textModelNames.append(item.modelRef.map(ModelRef.shortName))
                }
                current = turn
            case .toolResult:
                var turn = current ?? AssistantTurn(id: item.id, timestamp: item.timestamp)
                let resultText = item.plainText
                if let callId = item.toolCallId, let index = toolIndex[callId] {
                    turn.tools[index].result = resultText
                    turn.tools[index].isError = item.isError
                } else {
                    turn.tools.append(ToolActivity(
                        id: item.toolCallId ?? item.id,
                        name: item.toolName ?? "tool",
                        arguments: nil,
                        result: resultText,
                        isError: item.isError,
                        isRunning: false))
                }
                for block in item.blocks {
                    if case let .image(ref) = block { turn.images.append(ref) }
                }
                current = turn
            }
        }
        flush()
        return entries
    }
}

// MARK: Approvals

public struct ExecApproval: Identifiable, Hashable, Sendable {
    public let id: String
    public let command: String
    public let cwd: String?
    public let sessionKey: String?
    public let agentId: String?
    public let warning: String?
    public let expiresAt: Date?

    public init?(_ payload: JSONValue) {
        let request = payload["request"] ?? payload
        guard let id = payload["id"]?.text ?? request["id"]?.text else { return nil }
        self.id = id
        let argv = request["commandArgv"]?.array?.compactMap(\.string).joined(separator: " ")
        self.command = request["command"]?.text ?? request["systemRunPlan"]?["rawCommand"]?.text ?? argv ?? "(command)"
        self.cwd = request["cwd"]?.text ?? request["systemRunPlan"]?["cwd"]?.text
        self.sessionKey = request["sessionKey"]?.text ?? payload["sessionKey"]?.text
        self.agentId = request["agentId"]?.text ?? payload["agentId"]?.text
        self.warning = request["warningText"]?.text
        self.expiresAt = (payload["expiresAtMs"]?.double).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}


// MARK: Media directives

/// Agents attach media by emitting `MEDIA:<source>` lines (OpenClaw's reply directive).
/// OpenClaw's own UIs render those as attachments rather than text; so do we.
public enum MediaDirectives {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var images: [ImageRef]
        public var files: [FileRef]
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif", "svg"]
    static let otherMediaExtensions: Set<String> = [
        "mp3", "m4a", "wav", "ogg", "opus", "flac", "aac", "mp4", "mov", "webm", "mkv", "pdf", "zip", "txt", "csv", "json", "md",
    ]

    public static func extract(from text: String) -> Result {
        guard text.range(of: "MEDIA:", options: .caseInsensitive) != nil else {
            return Result(text: text, images: [], files: [])
        }
        var kept: [Substring] = []
        var images: [ImageRef] = []
        var files: [FileRef] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            guard !inFence, let source = self.source(fromLine: trimmed) else {
                kept.append(line)
                continue
            }
            if self.isImage(source) {
                images.append(ImageRef(artifactId: nil, base64: nil, url: source, mimeType: nil, alt: self.fileName(source), width: nil, height: nil))
            } else {
                files.append(FileRef(name: self.fileName(source) ?? source, url: source))
            }
        }
        let joined = kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(text: joined, images: images, files: files)
    }

    /// Mid-stream, the last line may be a directive that hasn't finished arriving.
    public static func withoutPartialDirective(_ text: String) -> String {
        guard !text.hasSuffix("\n") else { return text }
        let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? text
        let head = lastLine.trimmingCharacters(in: .whitespaces).prefix(6).uppercased()
        guard !head.isEmpty, "MEDIA:".hasPrefix(head) else { return text }
        return String(text.dropLast(lastLine.count))
    }

    static func source(fromLine line: String) -> String? {
        guard line.count > 6, line.prefix(6).uppercased() == "MEDIA:" else { return nil }
        var value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let wrappers = CharacterSet(charactersIn: "`\"'<>[](){}")
        value = value.trimmingCharacters(in: wrappers)
        guard !value.isEmpty, !value.contains(" ") || value.hasPrefix("/") || value.hasPrefix("~") else { return nil }
        return value
    }

    static func pathExtension(_ source: String) -> String {
        let path = URL(string: source)?.path ?? source
        return (path as NSString).pathExtension.lowercased()
    }

    static func isImage(_ source: String) -> Bool {
        if source.lowercased().hasPrefix("data:image/") { return true }
        let ext = self.pathExtension(source)
        if self.imageExtensions.contains(ext) { return true }
        // Extensionless web URLs are usually image endpoints; fall back to a link if decoding fails.
        return ext.isEmpty && source.lowercased().hasPrefix("https://") && !self.otherMediaExtensions.contains(ext)
    }

    static func fileName(_ source: String) -> String? {
        if source.hasPrefix("data:") { return nil }
        let path = URL(string: source)?.path ?? source
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name.removingPercentEncoding ?? name
    }
}

extension SessionRow {
    static func plainLine(_ text: String) -> String {
        var parts: [Substring] = []
        var length = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.drop(while: \.isWhitespace)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            if line.allSatisfy({ "-*_=| ".contains($0) }) { continue }
            while let first = line.first, "#>".contains(first) { line = line.dropFirst().drop(while: \.isWhitespace) }
            if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
                line = line.dropFirst(2)
            } else if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot != line.startIndex,
                      line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].first == " " {
                line = line[line.index(dot, offsetBy: 2)...]
            }
            guard !line.isEmpty else { continue }
            parts.append(line)
            length += line.count
            if length > 240 { break }
        }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: Progress card

/// The agent's durable task checklist for a session (`progress_card` tool), read with
/// `progressCard.get` and invalidated by `progressCard.changed`. Older Gateways only stream it as
/// `agent` events on the `plan` stream.
public struct ProgressCard: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public struct Step: Sendable, Hashable {
        public var text: String
        public var status: Status

        public init(text: String, status: Status) {
            self.text = text
            self.status = status
        }
    }

    public var revision: Int
    public var updatedAt: Date?
    public var markdown: String?
    public var steps: [Step]

    public init(revision: Int, updatedAt: Date? = nil, markdown: String? = nil, steps: [Step]) {
        self.revision = revision
        self.updatedAt = updatedAt
        let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.markdown = trimmed?.isEmpty == false ? trimmed : nil
        self.steps = steps
    }

    /// A `card` object from `progressCard.get`. Nil for `null` or a card with nothing to show.
    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        let steps = (json["steps"]?.array ?? []).compactMap(Self.step)
        self.init(
            revision: json["revision"]?.int ?? 0,
            updatedAt: json["updatedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
            markdown: json["markdown"]?.string,
            steps: steps)
        if self.markdown == nil, self.steps.isEmpty { return nil }
    }

    /// The `data` of a legacy `plan`-stream agent event (`phase: "update"`). Steps may be plain
    /// strings; only the first in-progress step is kept.
    public init?(legacyPlan data: JSONValue, revision: Int) {
        var sawInProgress = false
        let steps = (data["steps"]?.array ?? []).compactMap { raw -> Step? in
            let step: Step? = if let text = raw.string {
                Self.step(text: text, status: .pending)
            } else {
                Self.step(raw)
            }
            if step?.status == .inProgress {
                if sawInProgress { return nil }
                sawInProgress = true
            }
            return step
        }
        guard !steps.isEmpty else { return nil }
        self.init(revision: revision, updatedAt: Date(), markdown: data["explanation"]?.string, steps: steps)
    }

    private static func step(_ json: JSONValue) -> Step? {
        guard let text = json["step"]?.string, let status = json["status"]?.string.flatMap(Status.init) else {
            return nil
        }
        return self.step(text: text, status: status)
    }

    private static func step(text: String, status: Status) -> Step? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Step(text: trimmed, status: status)
    }

    public var completedCount: Int { self.steps.count { $0.status == .completed } }
    public var isComplete: Bool { !self.steps.isEmpty && self.completedCount == self.steps.count }

    /// The step being worked on, else the next pending one, else the last finished one.
    public var currentStep: Step? {
        self.steps.first { $0.status == .inProgress }
            ?? self.steps.first { $0.status == .pending }
            ?? self.steps.last
    }

    /// 1-based position of `currentStep`.
    public var currentPosition: Int {
        guard let current = self.currentStep, let index = self.steps.firstIndex(of: current) else { return 0 }
        return index + 1
    }

    /// First non-empty Markdown line without heading/list/quote markers, for the collapsed header.
    public var markdownSummary: String? {
        guard let line = self.markdown?.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let stripped = line.drop { $0.isWhitespace || "#-*>".contains($0) }
        let summary = stripped.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? nil : summary
    }
}
