import CryptoKit
import Foundation

// MARK: Replies

/// The message the composer is replying to. `senderLabel` and `preview` are what the chip and the
/// optimistic quote show until the Gateway's own `replyToPreview` arrives.
public struct ReplyTarget: Hashable, Sendable {
    public var messageId: String
    public var senderLabel: String
    public var preview: String
    public var isAssistant: Bool

    public init(messageId: String, senderLabel: String, preview: String, isAssistant: Bool) {
        self.messageId = messageId
        self.senderLabel = senderLabel
        self.preview = preview
        self.isAssistant = isAssistant
    }
}

/// The quote card above a user turn that replies to another message.
public struct ReplyQuote: Hashable, Sendable {
    public enum Sender: Hashable, Sendable {
        case you
        case agent
        /// A name: another agent, a bridged channel sender, or the Gateway's `senderLabel` when the original isn't loaded.
        case label(String)
    }

    public var targetId: String
    public var sender: Sender?
    /// Nil when neither the original nor a preview is known ("Original message").
    public var text: String?
}

/// Who an assistant message answers, as the agent's `[[reply_to…]]` directive names it.
public enum ReplyDirective: Hashable, Sendable {
    case id(String)
    case current
}

public enum Replies {
    /// Longest preview quoted into the message text when the Gateway can't take `replyToId`.
    public static let fallbackPreviewLimit = 280

    /// One line of `text` for the composer chip and quote cards: Markdown markers dropped,
    /// whitespace collapsed.
    public static func previewLine(_ text: String) -> String {
        SessionRow.plainLine(text)
    }

    /// `text` with the original quoted above it as a Markdown blockquote, for Gateways that reject
    /// `replyToId` (so the agent still sees what's being answered):
    /// `> **Sender:** first line`, one `> ` line per further line, a blank line, then `text`.
    public static func quotedFallback(sender: String, preview: String, text: String) -> String {
        // Headings, quote markers and code fences would break out of the quote.
        var lines = preview.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var line = line.drop(while: \.isWhitespace)
                if line.hasPrefix("```") || line.hasPrefix("~~~") { return "" }
                while let first = line.first, "#>".contains(first) { line = line.dropFirst().drop(while: \.isWhitespace) }
                return line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        var remaining = self.fallbackPreviewLimit
        var kept: [String] = []
        var truncated = false
        for line in lines {
            if remaining <= 0 {
                truncated = true
                break
            }
            if line.count > remaining {
                kept.append(String(line.prefix(remaining)).trimmingCharacters(in: .whitespaces))
                truncated = true
                break
            }
            kept.append(line)
            remaining -= line.count
        }
        if truncated { kept[kept.count - 1] += "…" }
        lines = kept.isEmpty ? [""] : kept
        let senderName = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = senderName.isEmpty ? "> \(lines[0])" : "> **\(senderName):** \(lines[0])"
        let quote = ([first] + lines.dropFirst().map { "> \($0)" }).joined(separator: "\n")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? quote : "\(quote)\n\n\(text)"
    }

    /// `text` without its `[[reply_to:<id>]]` / `[[reply_to_current]]` directives (the syntax the Gateway
    /// strips before delivery, matched case-insensitively; ones in code spans or fences are literal),
    /// and the first target they named.
    public static func extractDirective(_ text: String) -> (text: String, target: ReplyDirective?) {
        guard text.contains("[[") else { return (text, nil) }
        var out = ""
        var target: ReplyDirective?
        var index = text.startIndex
        var lineStart = true
        var fenced = false
        var inlineTicks = 0
        while index < text.endIndex {
            let rest = text[index...]
            if lineStart {
                let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            }
            let ch = text[index]
            if !fenced, ch == "`" {
                var run = 0
                var end = index
                while end < text.endIndex, text[end] == "`" {
                    run += 1
                    end = text.index(after: end)
                }
                inlineTicks = inlineTicks == 0 ? run : (inlineTicks == run ? 0 : inlineTicks)
                out += text[index..<end]
                index = end
                lineStart = false
                continue
            }
            if !fenced, inlineTicks == 0, rest.hasPrefix("[["), let tag = Self.parseTag(rest) {
                if target == nil { target = tag.target }
                index = tag.end
                var trailing = index
                while trailing < text.endIndex, text[trailing] == " " || text[trailing] == "\t" { trailing = text.index(after: trailing) }
                let atStart = out.allSatisfy(\.isWhitespace)
                index = atStart ? trailing : (trailing < text.endIndex && text[trailing] != "\n" ? index : trailing)
                continue
            }
            out.append(ch)
            lineStart = ch == "\n"
            if ch == "\n" { inlineTicks = 0 }
            index = text.index(after: index)
        }
        guard target != nil else { return (text, nil) }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), target)
    }

    private static func parseTag(_ rest: Substring) -> (target: ReplyDirective, end: String.Index)? {
        var cursor = rest.dropFirst(2)
        cursor = cursor.drop(while: \.isWhitespace)
        let lower = cursor.lowercased()
        if lower.hasPrefix("reply_to_current") {
            let after = cursor.dropFirst("reply_to_current".count).drop(while: \.isWhitespace)
            guard after.hasPrefix("]]") else { return nil }
            return (.current, after.index(after.startIndex, offsetBy: 2))
        }
        guard lower.hasPrefix("reply_to") else { return nil }
        var after = cursor.dropFirst("reply_to".count).drop(while: \.isWhitespace)
        guard after.first == ":" else { return nil }
        after = after.dropFirst()
        guard let close = after.range(of: "]]") else { return nil }
        let value = after[after.startIndex..<close.lowerBound]
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains("\n") else { return nil }
        return (.id(id), close.upperBound)
    }

    /// Whether a `chat.send` failure is an older Gateway refusing the `replyToId` param.
    public static func isReplyToRejection(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error else { return false }
        return code == "INVALID_REQUEST" && message.contains("replyToId")
    }
}

// MARK: Reactions

public enum ReactionActor: Hashable, Sendable {
    case you
    case agent(String)

    public var name: String {
        switch self {
        case .you: "You"
        case let .agent(name): name
        }
    }
}

/// One emoji's reactions on a message: who added it, in order.
public struct ReactionGroup: Hashable, Sendable, Identifiable {
    public var emoji: String
    public var actors: [ReactionActor]

    public init(emoji: String, actors: [ReactionActor]) {
        self.emoji = emoji
        self.actors = actors
    }

    public var id: String { self.emoji }
    public var count: Int { self.actors.count }
    public var includesYou: Bool { self.actors.contains(.you) }

    /// Who reacted, you first (as in "You and Claw").
    private var namedActors: [ReactionActor] {
        self.actors.filter { $0 == .you } + self.actors.filter { $0 != .you }
    }

    /// "You and Claw", "Claw", "You, Claw and Scout".
    public var reactorsText: String {
        let names = self.namedActors.map(\.name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// VoiceOver: "👍, 2 reactions, you and Claw".
    public var accessibilityLabel: String {
        let who = self.namedActors.map { $0 == .you ? "you" : $0.name }
        let list = who.count > 1 ? who.dropLast().joined(separator: ", ") + " and " + who[who.count - 1] : (who.first ?? "")
        return "\(self.emoji), \(self.count) reaction\(self.count == 1 ? "" : "s"), \(list)"
    }
}

public enum Reactions {
    /// `users.prefs` key holding your reactions across devices.
    public static let prefKey = "pincer.reactions"
    /// Device-local most-recently-used emoji.
    public static let recentDefaultsKey = "pincer.recentReactions"
    public static let recentLimit = 8
    public static let quickCount = 6
    public static let quickDefaults = ["👍", "❤️", "😂", "🎉", "👀", "✅"]
    /// The picker's fixed grid.
    public static let catalog = [
        "👍", "👎", "❤️", "😂", "🎉", "👀", "✅", "❌",
        "🙏", "🔥", "💯", "🚀", "😮", "😢", "😡", "🤔",
        "👏", "🙌", "💪", "🤝", "✨", "⭐️", "💡", "📌",
        "😊", "😍", "🥳", "😅", "🙃", "😬", "🤯", "😴",
        "☕️", "🍕", "🐛", "🛠️", "📈", "⚠️", "🦞", "👋",
    ]
    /// The emoji a channel ACK uses while an agent works on a message.
    public static let ackEmoji = "👀"

    // MARK: Pref codec

    /// `"<sessionKey>|<transcriptId>"`.
    public static func prefEntryKey(sessionKey: String, messageId: String) -> String {
        "\(sessionKey)|\(messageId)"
    }

    /// Your emoji for one message, in the order added.
    public static func decode(_ value: String?) -> [String] {
        var seen = Set<String>()
        return (value ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The pref value for `emoji`, or nil (delete the key) when there are none.
    public static func encode(_ emoji: [String]) -> String? {
        emoji.isEmpty ? nil : emoji.joined(separator: " ")
    }

    /// Adds `emoji` at the end, or removes it when it's already there.
    public static func toggling(_ emoji: String, in current: [String]) -> [String] {
        current.contains(emoji) ? current.filter { $0 != emoji } : current + [emoji]
    }

    // MARK: Recent emoji

    /// `recent` with `emoji` moved to the front, deduped, at most `recentLimit`.
    public static func recording(_ emoji: String, in recent: [String]) -> [String] {
        Array(([emoji] + recent.filter { $0 != emoji }).prefix(self.recentLimit))
    }

    /// The quick-react bar: recent emoji first, padded with the defaults to `quickCount`.
    public static func quickBar(recent: [String]) -> [String] {
        var bar: [String] = []
        for emoji in recent + self.quickDefaults where !bar.contains(emoji) {
            bar.append(emoji)
            if bar.count == self.quickCount { break }
        }
        return bar
    }

    public static var recent: [String] { self.recent(in: .standard) }

    public static func recent(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: self.recentDefaultsKey) ?? []
    }

    static func noteRecent(_ emoji: String, defaults: UserDefaults = .standard) {
        defaults.set(self.recording(emoji, in: self.recent(in: defaults)), forKey: self.recentDefaultsKey)
    }

    // MARK: Groups

    /// Agent reactions (transcript order) then yours (pref order), one group per emoji.
    public static func groups(agent: [String], agentName: String, mine: [String]) -> [ReactionGroup] {
        var groups: [ReactionGroup] = []
        func add(_ emoji: String, _ actor: ReactionActor) {
            if let index = groups.firstIndex(where: { $0.emoji == emoji }) {
                if !groups[index].actors.contains(actor) { groups[index].actors.append(actor) }
            } else {
                groups.append(ReactionGroup(emoji: emoji, actors: [actor]))
            }
        }
        for emoji in agent { add(emoji, .agent(agentName)) }
        for emoji in mine { add(emoji, .you) }
        return groups
    }

    // MARK: Agent reactions

    /// Reactions the agent added with its `message` tool (`action: "react"`), by the transcript id
    /// of the message they're on, in the order added. `messageId` names a bridged channel's message
    /// (matched to `channelMessageId`) or a transcript id; without one (or no match) the reaction
    /// is on the latest user message before the call. Failed calls and `remove: true` pairs cancel out.
    public static func agentReactions(in items: [ChatItem]) -> [String: [String]] {
        var failed = Set<String>()
        for item in items where item.role == .toolResult && item.isError {
            if let id = item.toolCallId { failed.insert(id) }
        }
        var byChannelId: [String: String] = [:]
        var transcriptIds = Set<String>()
        for item in items {
            guard let id = item.transcriptId else { continue }
            transcriptIds.insert(id)
            if item.role == .user, let channelId = item.channelMessageId, byChannelId[channelId] == nil {
                byChannelId[channelId] = id
            }
        }
        var result: [String: [String]] = [:]
        var latestUser: String?
        for item in items {
            if item.role == .user, !item.isPending, let id = item.transcriptId { latestUser = id }
            guard item.role == .assistant else { continue }
            for block in item.blocks {
                guard case let .toolCall(callId, name, arguments) = block, name == "message", !failed.contains(callId),
                      let args = arguments?.data(using: .utf8)
                        .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      (args["action"] as? String)?.lowercased() == "react",
                      let emoji = (args["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty
                else { continue }
                let messageId = (args["messageId"] as? String) ?? (args["messageId"] as? NSNumber)?.stringValue
                let target = messageId.flatMap { byChannelId[$0] ?? (transcriptIds.contains($0) ? $0 : nil) } ?? latestUser
                guard let target else { continue }
                let remove = (args["remove"] as? Bool) == true
                var list = result[target] ?? []
                list.removeAll { $0 == emoji }
                if !remove { list.append(emoji) }
                result[target] = list.isEmpty ? nil : list
            }
        }
        return result
    }

    // MARK: ACK

    /// Your latest message, while a run is working on it and the agent hasn't reacted 👀 itself.
    /// Nothing once anything outside `runId` (another reply) follows it, or a newer send is pending.
    public static func ackTarget(items: [ChatItem], isRunning: Bool, runId: String?,
                                 agentReactions: [String: [String]]) -> String?
    {
        guard isRunning,
              let index = items.lastIndex(where: { $0.role == .user })
        else { return nil }
        let item = items[index]
        guard item.isReplyable, let id = item.transcriptId else { return nil }
        for later in items[(index + 1)...] where later.role == .assistant || later.role == .toolResult {
            if let laterRun = later.runId {
                if laterRun != runId { return nil }
            } else if later.role == .assistant, !later.plainText.isEmpty {
                return nil
            }
        }
        if agentReactions[id]?.contains(self.ackEmoji) == true { return nil }
        return id
    }

    // MARK: Forwarding

    /// `message.action` params that add (or remove) a reaction on a bridged channel's message.
    public static func messageActionParams(
        channel: String, sessionKey: String, channelMessageId: String, emoji: String, remove: Bool,
        conversationRef: String?, idempotencyKey: String) -> [String: JSONValue]
    {
        var inner: [String: JSONValue] = ["messageId": .string(channelMessageId), "emoji": .string(emoji)]
        if remove { inner["remove"] = true }
        if let conversationRef, !conversationRef.isEmpty { inner["to"] = .string(conversationRef) }
        return [
            "channel": .string(channel),
            "action": "react",
            "sessionKey": .string(sessionKey),
            "params": .object(inner),
            "idempotencyKey": .string(idempotencyKey),
        ]
    }

    /// Whether a `message.action` failure means the channel can't react at all (so stop trying).
    static func isUnsupported(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error else { return false }
        let lowered = message.lowercased()
        return code == "UNKNOWN_METHOD" || code == "INVALID_REQUEST"
            || lowered.contains("unsupported") || lowered.contains("not supported") || lowered.contains("unknown action")
    }
}

// MARK: Reaction store

/// One gateway's reactions in `UserDefaults`, one bucket per session so a change rewrites only that
/// session's entries instead of the whole map. Keys are `"<sessionKey>|<transcriptId>"` as in `Reactions`.
public struct ReactionStore: @unchecked Sendable {
    public let gatewayId: String
    private let defaults: UserDefaults

    public init(gatewayId: String, defaults: UserDefaults = .standard) {
        self.gatewayId = gatewayId
        self.defaults = defaults
    }

    /// The pre-bucket key holding the whole map.
    var legacyKey: String { "pincer.reactions.\(self.gatewayId)" }
    var indexKey: String { "pincer.reactions.\(self.gatewayId).index" }
    private var bucketPrefix: String { "pincer.reactions.\(self.gatewayId).s." }

    /// The bucket an entry lives in: the first 16 hex digits of the SHA-256 of its session key.
    static func bucketName(forEntry key: String) -> String {
        let sessionKey = key.lastIndex(of: "|").map { String(key[..<$0]) } ?? key
        return SHA256.hash(data: Data(sessionKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func bucketKey(_ name: String) -> String { self.bucketPrefix + name }

    private var bucketNames: [String] { self.defaults.stringArray(forKey: self.indexKey) ?? [] }

    /// Every stored reaction, migrating the legacy map first.
    public func load() -> [String: String] {
        self.migrateIfNeeded()
        var all: [String: String] = [:]
        for name in self.bucketNames {
            guard let bucket = self.defaults.dictionary(forKey: self.bucketKey(name)) as? [String: String] else { continue }
            all.merge(bucket) { _, new in new }
        }
        return all
    }

    /// Writes the buckets of the entries that differ between `old` and `new`, leaving the rest alone.
    public func apply(old: [String: String], new: [String: String]) {
        guard old != new else { return }
        var changed = Set<String>()
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            changed.insert(Self.bucketName(forEntry: key))
        }
        var contents = Dictionary(uniqueKeysWithValues: changed.map { ($0, [String: String]()) })
        for (key, value) in new {
            let name = Self.bucketName(forEntry: key)
            if changed.contains(name) { contents[name]?[key] = value }
        }
        var names = Set(self.bucketNames)
        let live = Set(contents.filter { !$0.value.isEmpty }.keys)
        // The index goes first when it grows, so a crash never leaves a bucket `load` can't see.
        if !live.isSubset(of: names) { self.defaults.set(Array(names.union(live)).sorted(), forKey: self.indexKey) }
        for name in changed {
            if let bucket = contents[name], !bucket.isEmpty {
                self.defaults.set(bucket, forKey: self.bucketKey(name))
            } else {
                self.defaults.removeObject(forKey: self.bucketKey(name))
            }
        }
        names = names.union(live).subtracting(changed.subtracting(live))
        if names.isEmpty {
            self.defaults.removeObject(forKey: self.indexKey)
        } else if names != Set(self.bucketNames) {
            self.defaults.set(names.sorted(), forKey: self.indexKey)
        }
    }

    /// Moves the legacy single-key map into buckets. Buckets and index are written before the legacy
    /// key is removed, so an interrupted run repeats safely and loses nothing.
    public func migrateIfNeeded() {
        guard let legacy = self.defaults.dictionary(forKey: self.legacyKey) as? [String: String] else {
            if self.defaults.object(forKey: self.legacyKey) != nil { self.defaults.removeObject(forKey: self.legacyKey) }
            return
        }
        var buckets: [String: [String: String]] = [:]
        for (key, value) in legacy { buckets[Self.bucketName(forEntry: key), default: [:]][key] = value }
        for (name, bucket) in buckets { self.defaults.set(bucket, forKey: self.bucketKey(name)) }
        let names = Set(self.bucketNames).union(buckets.keys)
        if !names.isEmpty { self.defaults.set(names.sorted(), forKey: self.indexKey) }
        self.defaults.removeObject(forKey: self.legacyKey)
    }

    /// Forgets this device's reactions for the gateway (when it's removed).
    public func removeAll() {
        for name in self.bucketNames { self.defaults.removeObject(forKey: self.bucketKey(name)) }
        self.defaults.removeObject(forKey: self.indexKey)
        self.defaults.removeObject(forKey: self.legacyKey)
    }
}
