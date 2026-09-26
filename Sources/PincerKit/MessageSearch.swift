import Foundation
import Synchronization

/// Message search across a Gateway's cached chats: what gets indexed, how a query becomes an
/// FTS5 query, and how raw index hits are checked, grouped and shown. The index itself is
/// `MessageIndex`.
///
/// Matching is Find in Chat's (case and accents ignored, the query as a phrase in the text the
/// transcript shows), plus every query word has to start a word. So every result is also a
/// match Find reports when the chat is opened with the same query.
public enum MessageSearch {
    /// One message's text as indexed: the user's message, or one of an assistant turn's messages.
    public struct Document: Hashable, Sendable {
        public var sessionKey: String
        /// `TranscriptEntry.id` of the row.
        public var entryId: String
        /// Index of the message within the row (`TranscriptSearch.Section.message`).
        public var section: Int
        public var role: ChatRole
        /// e.g. "Discord" when a user message arrived through another channel.
        public var via: String?
        public var timestamp: Date?
        /// Markdown source.
        public var text: String

        public init(sessionKey: String, entryId: String, section: Int, role: ChatRole, via: String? = nil,
                    timestamp: Date? = nil, text: String)
        {
            self.sessionKey = sessionKey
            self.entryId = entryId
            self.section = section
            self.role = role
            self.via = via
            self.timestamp = timestamp
            self.text = text
        }

        /// The Find match for this message's first occurrence of the query.
        public var match: TranscriptSearch.Match {
            TranscriptSearch.Match(entryId: self.entryId, section: .message(self.section), occurrence: 0)
        }
    }

    /// An index result. Same shape as what was indexed.
    public typealias Hit = Document

    /// A result's text around the first match, with every match's range (UTF-16) for highlighting.
    public struct Snippet: Hashable, Sendable {
        public var text: String
        public var highlights: [NSRange]

        public init(text: String, highlights: [NSRange]) {
            self.text = text
            self.highlights = highlights
        }
    }

    /// One chat's newest hits.
    public struct ChatGroup: Hashable, Sendable {
        public var sessionKey: String
        /// Newest first, at most `perChat`.
        public var hits: [Hit]
        /// More hits than shown.
        public var hasMore: Bool

        public init(sessionKey: String, hits: [Hit], hasMore: Bool) {
            self.sessionKey = sessionKey
            self.hits = hits
            self.hasMore = hasMore
        }
    }

    /// A result as shown: the hit plus who sent it and its snippet.
    public struct Message: Hashable, Sendable, Identifiable {
        public var hit: Hit
        /// "You", "via Discord", or the agent's name.
        public var sender: String
        public var snippet: Snippet

        public init(hit: Hit, sender: String, snippet: Snippet) {
            self.hit = hit
            self.sender = sender
            self.snippet = snippet
        }

        public var id: String { "\(self.hit.entryId):\(self.hit.section)" }
        public var match: TranscriptSearch.Match { self.hit.match }
    }

    public struct Chat: Hashable, Sendable, Identifiable {
        public var sessionKey: String
        public var title: String
        public var isArchived: Bool
        public var messages: [Message]
        public var hasMore: Bool

        public init(sessionKey: String, title: String, isArchived: Bool = false, messages: [Message], hasMore: Bool = false) {
            self.sessionKey = sessionKey
            self.title = title
            self.isArchived = isArchived
            self.messages = messages
            self.hasMore = hasMore
        }

        public var id: String { self.sessionKey }
    }

    public struct Results: Hashable, Sendable {
        public var query: String
        public var chats: [Chat]
        /// The index couldn't be read; it's being rebuilt.
        public var failed: Bool

        public init(query: String, chats: [Chat] = [], failed: Bool = false) {
            self.query = query
            self.chats = chats
            self.failed = failed
        }

        public var isEmpty: Bool { self.chats.isEmpty }
    }

    /// Shortest query searched, after trimming.
    public static let minimumQueryLength = 2

    // MARK: Indexing

    /// The messages of a transcript that search covers: user and assistant message text, the
    /// same rows and sections Find in Chat searches by default. Thinking, tool calls, markers and
    /// pending messages are left out.
    public static func documents(sessionKey: String, items: [ChatItem]) -> [Document] {
        var documents: [Document] = []
        for entry in TranscriptBuilder.build(items.filter { !$0.isPending }) {
            switch entry {
            case let .user(item):
                let text = item.plainText
                guard !text.isEmpty else { continue }
                documents.append(Document(sessionKey: sessionKey, entryId: entry.id, section: 0, role: .user,
                                          via: item.via, timestamp: item.timestamp, text: text))
            case let .assistant(turn):
                for (index, text) in turn.text.enumerated() where !text.isEmpty {
                    let timestamp = index < turn.textTimestamps.count ? turn.textTimestamps[index] : turn.timestamp
                    documents.append(Document(sessionKey: sessionKey, entryId: entry.id, section: index, role: .assistant,
                                              timestamp: timestamp ?? turn.timestamp, text: text))
                }
            case .marker:
                continue
            }
        }
        return documents
    }

    /// Text as indexed and queried: case and accents removed.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Query words: folded runs of letters and digits.
    static func tokens(_ query: String) -> [String] {
        self.folded(query).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// The FTS5 query for what was typed: every word as a quoted prefix (`"tok"*`), all required.
    /// One-letter words are dropped unless that leaves none. Nil when there's nothing to search.
    /// Quoting means nothing typed is ever read as FTS syntax (`AND`, `NEAR(`, `-`, `*`, `"`).
    public static func ftsQuery(_ query: String) -> String? {
        let trimmed = TranscriptSearch.normalized(query)
        guard trimmed.count >= self.minimumQueryLength else { return nil }
        let tokens = self.tokens(trimmed)
        let long = tokens.filter { $0.count >= 2 }
        guard !long.isEmpty else { return nil }
        return long.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    // MARK: Checking

    /// Whether Find in Chat finds `query` in this message.
    public static func verify(query: String, markdown: String) -> Bool {
        TranscriptSearch.messageMatchCount(query, markdown: markdown) > 0
    }

    /// Verifies `candidates` (newest first) and groups them, verifying only as many as the caps
    /// can show. Hits from chats not in `allowed` are dropped.
    public static func collect(_ candidates: [Hit], query: String, allowed: Set<String>, perChat: Int = 3,
                               maxChats: Int = 30) -> [ChatGroup]
    {
        var verified: [Hit] = []
        var counts: [String: Int] = [:]
        for hit in candidates {
            if Task.isCancelled { return [] }
            guard allowed.contains(hit.sessionKey) else { continue }
            let count = counts[hit.sessionKey]
            if count == nil, counts.count >= maxChats { continue }
            if let count, count > perChat { continue }
            guard self.verify(query: query, markdown: hit.text) else { continue }
            counts[hit.sessionKey, default: 0] += 1
            verified.append(hit)
        }
        return self.group(verified, allowed: allowed, perChat: perChat, maxChats: maxChats)
    }

    /// Verified hits by chat: chats ordered by their newest hit, each with its newest `perChat`
    /// hits. Hits without a date sort last.
    public static func group(_ hits: [Hit], allowed: Set<String>, perChat: Int = 3, maxChats: Int = 30) -> [ChatGroup] {
        let sorted = hits.enumerated()
            .filter { allowed.contains($0.element.sessionKey) }
            .sorted { lhs, rhs in
                let left = lhs.element.timestamp ?? .distantPast
                let right = rhs.element.timestamp ?? .distantPast
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        var order: [String] = []
        var byChat: [String: [Hit]] = [:]
        for hit in sorted {
            if byChat[hit.sessionKey] == nil { order.append(hit.sessionKey) }
            byChat[hit.sessionKey, default: []].append(hit)
        }
        return order.prefix(maxChats).map { key in
            let hits = byChat[key] ?? []
            return ChatGroup(sessionKey: key, hits: Array(hits.prefix(perChat)), hasMore: hits.count > perChat)
        }
    }

    // MARK: Display

    /// The message's shown text, whitespace collapsed, cut to about `maxLength` characters around
    /// the first match (starting at a word boundary, with `…` where it was cut).
    public static func snippet(query: String, markdown: String, maxLength: Int = 140) -> Snippet {
        let joined = TranscriptSearch.renderedTexts(markdown: markdown).joined(separator: " ")
        let text = joined.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let string = text as NSString
        let limit = max(maxLength, 8)
        guard string.length > limit else {
            return Snippet(text: text, highlights: TranscriptSearch.ranges(of: query, in: text))
        }
        let first = TranscriptSearch.ranges(of: query, in: text).first?.location ?? 0
        var start = 0
        if first > 30 {
            // The first word boundary at or after 30 characters before the match.
            start = first - 30
            while start < first, let scalar = UnicodeScalar(string.character(at: start - 1)),
                  !CharacterSet.whitespaces.contains(scalar)
            {
                start += 1
            }
            start = string.rangeOfComposedCharacterSequence(at: start).location
        }
        let lead = start > 0 ? "…" : ""
        var length = limit - (lead as NSString).length
        var trail = ""
        if start + length < string.length {
            trail = "…"
            length -= 1
        } else {
            length = string.length - start
        }
        var end = start + length
        if end < string.length {
            let composed = string.rangeOfComposedCharacterSequence(at: end)
            if composed.location < end { end = composed.location }
        }
        let body = string.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespaces)
        let result = lead + body + trail
        return Snippet(text: result, highlights: TranscriptSearch.ranges(of: query, in: result))
    }

    /// Today: the time. The past 6 days: the weekday. This year: "Mar 4". Older: "Mar 4, 2025".
    public static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                 locale: Locale = .current) -> String
    {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let template = if days == 0 {
            "jmm"
        } else if days > 0, days <= 6 {
            "EEEE"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            "MMMd"
        } else {
            "yMMMd"
        }
        let key = "\(template)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        return self.dateFormatters.withLock { formatters in
            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.locale = locale
                formatter.setLocalizedDateFormatFromTemplate(template)
                formatters[key] = formatter
            }
            return formatter.string(from: date)
        }
    }

    /// Formatters by template, locale, calendar and time zone; making one per row is slow.
    private static let dateFormatters = Mutex<[String: DateFormatter]>([:])
}
