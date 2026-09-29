import Foundation
import UniformTypeIdentifiers

// MARK: Agents

public struct AgentSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let emoji: String?
    public let avatarURL: String?
    /// The configured avatar (path, URL or data URI), as `agents.update` takes it.
    public let avatar: String?
    /// The workspace folder on the Gateway host.
    public let workspace: String?
    /// The primary model ref; nil uses the Gateway default.
    public let model: String?
    /// `agent` or `system` (OpenClaw's own agents, which can't be managed).
    public let kind: String?

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.name = json["identity"]?["name"]?.text ?? json["name"]?.text ?? id.capitalized
        self.emoji = json["identity"]?["emoji"]?.text
        self.avatarURL = json["identity"]?["avatarUrl"]?.text
        self.avatar = json["identity"]?["avatar"]?.text
        self.workspace = json["workspace"]?.text
        self.model = json["model"]?["primary"]?.text ?? json["model"]?.text
        self.kind = json["kind"]?.text
    }

    public init(id: String, name: String, emoji: String? = nil, avatar: String? = nil,
                workspace: String? = nil, model: String? = nil, kind: String? = nil)
    {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.avatarURL = nil
        self.avatar = avatar
        self.workspace = workspace
        self.model = model
        self.kind = kind
    }

    public var isSystem: Bool { self.kind == "system" }
    /// "🔭 Scout".
    public var title: String { self.emoji.map { "\($0) \(self.name)" } ?? self.name }
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
    /// An agent's home chat the Gateway hasn't stored yet (no messages), listed so the agent shows.
    public var isPlaceholder: Bool { self.raw[Self.placeholderField]?.bool ?? false }
    static let placeholderField = "pincerPlaceholder"
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
    /// Incremental Gateway rows often leave out the last-message preview; keep the one we had
    /// so the sidebar doesn't flicker between showing and hiding it.
    public func keepingPreview(of previous: SessionRow?) -> SessionRow {
        guard case var .object(fields) = self.raw, fields["lastMessagePreview"]?.text == nil,
              let preview = previous?.raw["lastMessagePreview"], preview.text != nil,
              let merged = SessionRow(.object({ fields["lastMessagePreview"] = preview; return fields }()))
        else { return self }
        return merged
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

    // Token accounting. `totalTokens` is the context snapshot; input/output are the latest run's.
    public var totalTokens: Int? { Self.tokens(self.raw["totalTokens"]) }
    /// `false` when `totalTokens` predates the latest run.
    public var totalTokensFresh: Bool { self.raw["totalTokensFresh"]?.bool ?? true }
    public var inputTokens: Int? { Self.tokens(self.raw["inputTokens"]) }
    public var outputTokens: Int? { Self.tokens(self.raw["outputTokens"]) }
    /// The session's effective context window.
    public var contextTokens: Int? { Self.tokens(self.raw["contextTokens"]).flatMap { $0 > 0 ? $0 : nil } }
    /// Prompt budget before the reply reserve, measured before the last prompt (`contextBudgetStatus`).
    public var promptBudgetTokens: Int? {
        Self.tokens(self.raw["contextBudgetStatus"]?["promptBudgetBeforeReserve"]).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func tokens(_ value: JSONValue?) -> Int? {
        guard let count = value?.int, count >= 0 else { return nil }
        return count
    }

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
    /// Effective context cap (`contextTokens`, sent with `includeDetails`), else the model's window.
    public let contextTokens: Int?

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text, let provider = json["provider"]?.text else { return nil }
        self.modelId = id
        self.provider = provider
        self.name = json["name"]?.text ?? id
        self.alias = json["alias"]?.text
        self.isAvailable = json["available"]?.bool ?? true
        self.manualSelectionAllowed = json["manualSelectionAllowed"]?.bool ?? true
        self.contextTokens = [json["contextTokens"]?.int, json["contextWindow"]?.int].lazy.compactMap { $0 }.first { $0 > 0 }
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
