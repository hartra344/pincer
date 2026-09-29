import Foundation
import UniformTypeIdentifiers

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

    /// Computed once at init; hashing a megabyte payload on every access dominated layout.
    public let cacheKey: String

    public init(artifactId: String?, base64: String?, url: String?, mimeType: String?, alt: String?, width: Int?, height: Int?) {
        self.artifactId = artifactId
        self.base64 = base64
        self.url = url
        self.mimeType = mimeType
        self.alt = alt
        self.width = width
        self.height = height
        // Inline images often share a long header (SVG's xmlns), so a prefix alone would collide.
        self.cacheKey = artifactId ?? url ?? base64.map { "inline:\($0.utf8.count):\(Self.stableHash($0))" } ?? "image"
    }

    private enum CodingKeys: String, CodingKey {
        case artifactId, base64, url, mimeType, alt, width, height
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            artifactId: try c.decodeIfPresent(String.self, forKey: .artifactId),
            base64: try c.decodeIfPresent(String.self, forKey: .base64),
            url: try c.decodeIfPresent(String.self, forKey: .url),
            mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType),
            alt: try c.decodeIfPresent(String.self, forKey: .alt),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(self.artifactId, forKey: .artifactId)
        try c.encodeIfPresent(self.base64, forKey: .base64)
        try c.encodeIfPresent(self.url, forKey: .url)
        try c.encodeIfPresent(self.mimeType, forKey: .mimeType)
        try c.encodeIfPresent(self.alt, forKey: .alt)
        try c.encodeIfPresent(self.width, forKey: .width)
        try c.encodeIfPresent(self.height, forKey: .height)
    }

    public static func == (a: ImageRef, b: ImageRef) -> Bool {
        a.cacheKey == b.cacheKey && a.artifactId == b.artifactId && a.url == b.url && a.mimeType == b.mimeType
            && a.alt == b.alt && a.width == b.width && a.height == b.height && a.base64 == b.base64
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.cacheKey)
        hasher.combine(self.artifactId)
        hasher.combine(self.url)
        hasher.combine(self.mimeType)
        hasher.combine(self.alt)
        hasher.combine(self.width)
        hasher.combine(self.height)
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

/// What the Gateway recorded of the message a user turn replies to (`__openclaw.replyToPreview`),
/// shown when the original isn't loaded.
public struct ReplyPreview: Hashable, Codable, Sendable {
    public var text: String
    public var senderLabel: String?

    public init(text: String, senderLabel: String? = nil) {
        self.text = text
        self.senderLabel = senderLabel
    }
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
    /// The parts of a file-changing tool result's `details` a diff card reads (`diff`, `changed`, `created`).
    public var toolDetails: JSONValue?
    public var isError: Bool
    public var errorMessage: String?
    /// e.g. "Discord" when a user turn arrived through another channel.
    public var via: String?
    public var markerKind: String?
    public var idempotencyKey: String?
    /// Not committed to the transcript yet: an optimistic send, including queued and failed ones.
    public var isPending: Bool = false
    /// Where an unsent message is in the outbox; nil for committed items and for sends the
    /// Gateway accepted that the transcript hasn't caught up with yet.
    public var outboxState: OutboxState?
    /// Model that generated this message, as recorded by the Gateway (assistant messages only).
    public var model: String?
    public var provider: String?
    /// The Gateway cut this message's text to its history cap; the full copy comes from
    /// `chat.message.get`.
    public var isCapped: Bool = false
    /// Transcript id of the message this user turn replies to (`__openclaw.replyToId`).
    public var replyToId: String?
    public var replyToPreview: ReplyPreview?
    /// The bridged channel's own id for this message (`__openclaw.transport.messageId`), e.g. a
    /// Discord snowflake. Agent `message` tool reactions name it.
    public var channelMessageId: String?
    /// Channel the message arrived through (`__openclaw.transport.channel`).
    public var transportChannel: String?
    /// Conversation it arrived in (`__openclaw.transport.conversationRef`), e.g. `channel:123`.
    public var conversationRef: String?
    /// Set when another agent, an automation or a helper wrote this message (it's shown as
    /// theirs, not as yours or this chat's agent's).
    public var sender: MessageSender?

    /// An optimistic send on its way: in flight, or accepted and waiting for the transcript. Not
    /// a queued or failed one.
    public var isAwaitingDelivery: Bool {
        guard self.isPending else { return false }
        return self.outboxState == nil || self.outboxState == .sending
    }

    /// A queued or failed message that hasn't gone out.
    public var isUnsent: Bool {
        switch self.outboxState {
        case .queued?, .failed?: true
        default: false
        }
    }

    /// A committed message that replies and reactions can point at.
    public var isReplyable: Bool {
        guard !self.isPending, let transcriptId, !transcriptId.hasPrefix(Self.pendingInputPrefix) else { return false }
        return self.role == .user || self.role == .assistant
    }

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

    /// The Gateway stores a sent user turn under `<clientKey>:user` (upstream `buildRunUserTurnIdempotencyKey`),
    /// so strip that suffix to match the key Pincer sent with `chat.send` (#429).
    static func clientIdempotencyKey(_ stored: String?) -> String? {
        guard let stored, stored.hasSuffix(":user") else { return stored }
        let bare = String(stored.dropLast(":user".count))
        return bare.isEmpty ? stored : bare
    }

    public init?(_ json: JSONValue, fallbackIndex: Int) {
        let meta = json["__openclaw"]
        self.transcriptId = meta?["id"]?.text
        self.markerKind = meta?["kind"]?.text
        self.runId = meta?["runId"]?.text
        self.idempotencyKey = Self.clientIdempotencyKey(meta?["idempotencyKey"]?.text ?? json["idempotencyKey"]?.text)
        let baseId = self.transcriptId ?? "idx-\(fallbackIndex)"
        // Stable across reloads and older pages, so rows keep their identity and scroll position.
        self.id = baseId
        self.role = self.markerKind != nil ? .marker : ChatRole(json["role"]?.string)
        if self.role != .marker, let sender = MessageSender.parse(json) {
            self.sender = sender
            // Another agent's message is shown as theirs, never as yours (upstream projects it the same way).
            self.role = .assistant
        }
        self.toolCallId = json["toolCallId"]?.text ?? json["tool_call_id"]?.text
        self.toolName = json["toolName"]?.text ?? json["tool_name"]?.text
        if self.role == .toolResult { self.toolDetails = ToolActivity.fileEditDetails(json["details"]) }
        self.isError = json["isError"]?.bool ?? json["is_error"]?.bool ?? false
        self.errorMessage = json["errorMessage"]?.text
        if let ts = json["timestamp"]?.double {
            self.timestamp = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
        } else {
            self.timestamp = nil
        }
        let provenance = json["provenance"]
        self.via = self.sender == nil ? provenance?["sourceChannel"]?.text.map { $0.capitalized } : nil
        if self.role == .assistant, self.sender == nil, let model = json["model"]?.text, !Self.syntheticModels.contains(model) {
            self.model = model
            self.provider = json["provider"]?.text
        }
        self.replyToId = meta?["replyToId"]?.text
        if let preview = meta?["replyToPreview"], let text = preview["text"]?.text {
            self.replyToPreview = ReplyPreview(text: text, senderLabel: preview["senderLabel"]?.text)
        }
        let transport = meta?["transport"]
        self.channelMessageId = transport?["messageId"]?.text
        self.transportChannel = transport?["channel"]?.text
        self.conversationRef = transport?["conversationRef"]?.text
        // Only the Gateway marker proves a cap; the sentinel text alone could be literal.
        let recoverable = self.role == .assistant || self.transcriptId?.hasPrefix(Self.pendingInputPrefix) == true
        self.isCapped = recoverable && meta?["truncated"]?.bool == true
            && json["openclawMessageToolMirror"]?.bool != true

        if let text = json["content"]?.string {
            self.blocks = text.isEmpty ? [] : [.text(text)]
        } else {
            self.blocks = (json["content"]?.array ?? []).compactMap(ContentBlock.parse)
        }
        if self.sender != nil || provenance?["kind"]?.text == "inter_session" {
            self.blocks = self.blocks.map { block in
                guard case let .text(text) = block else { return block }
                return .text(MessageSender.displayText(text, provenance: provenance))
            }.filter { if case let .text(text) = $0 { !text.isEmpty } else { true } }
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
        guard self.mayContainDirective(text), text.range(of: "MEDIA:", options: .caseInsensitive) != nil else {
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

    /// A byte scan that rules out "MEDIA:" in almost every message, much faster than a
    /// case-insensitive search. Only true negatives: any non-ASCII text just before a colon
    /// counts as a maybe.
    static func mayContainDirective(_ text: String) -> Bool {
        let media: UInt64 = 0x6D_65_64_69_61 // "media"
        var last: UInt64 = 0
        var sinceNonASCII = 0
        for byte in text.utf8 {
            if byte == 0x3A, sinceNonASCII < 5 || last & 0xFF_FFFF_FFFF == media { return true }
            sinceNonASCII = byte >= 0x80 ? 0 : sinceNonASCII + 1
            last = last << 8 | UInt64(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
        }
        return false
    }

    /// Mid-stream, the last line may be a directive that hasn't finished arriving.
    public static func withoutPartialDirective(_ text: String) -> String {
        guard !text.hasSuffix("\n") else { return text }
        let lastLine = text[(text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex)...]
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
