import Foundation

/// Find in chat: every occurrence of a query in the transcript, in the order the rows show them.
/// Matching ignores case and diacritics, the same way the transcript highlights them.
public enum TranscriptSearch {
    public struct Options: Hashable, Sendable {
        /// Search the agent's reasoning.
        public var includeThinking: Bool
        /// Search tool call arguments and output.
        public var includeTools: Bool
        /// Tool text past this many characters isn't shown, so isn't searched either.
        public var toolTextLimit: Int

        public init(includeThinking: Bool = false, includeTools: Bool = false, toolTextLimit: Int = .max) {
            self.includeThinking = includeThinking
            self.includeTools = includeTools
            self.toolTextLimit = toolTextLimit
        }
    }

    /// Where in a row a match is. Rows show thinking first, then tool calls, then messages.
    public enum Section: Hashable, Sendable {
        case thinking
        /// A tool call's input, then its output, by tool call id.
        case tool(String)
        /// One message's text: the user's message, or the assistant turn's message at this index.
        case message(Int)
    }

    public struct Match: Hashable, Sendable {
        /// `TranscriptEntry.id` of the row.
        public let entryId: String
        public let section: Section
        /// Which occurrence within the section, from 0.
        public let occurrence: Int

        public init(entryId: String, section: Section, occurrence: Int) {
            self.entryId = entryId
            self.section = section
            self.occurrence = occurrence
        }
    }

    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The query as searched: surrounding whitespace dropped. Empty means no search.
    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Occurrences of `query` in `text`, non-overlapping, as UTF-16 ranges (for attributed strings).
    public static func ranges(of query: String, in text: String) -> [NSRange] {
        let query = self.normalized(query)
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let string = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(of: query, options: self.compareOptions, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return ranges
    }

    static func count(of query: String, in text: String) -> Int {
        guard text.range(of: query, options: self.compareOptions) != nil else { return 0 }
        return self.ranges(of: query, in: text).count
    }

    /// Text of a tool call as its card shows it: input, then output, each cut at the limit.
    public static func toolTexts(_ tool: ToolActivity, limit: Int) -> [String] {
        [tool.arguments, tool.result].compactMap { text in
            guard let text, !text.isEmpty else { return nil }
            return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
        }
    }

    /// A message's text as the transcript draws it, one string per text view in drawing order:
    /// Markdown syntax removed, link targets dropped, list markers added, one string per table
    /// cell. SVG code blocks are left out, since they're usually shown as the image. Matches are
    /// counted in these, so the highlighted match is always the counted one.
    public static func renderedTexts(markdown source: String) -> [String] {
        if let cached = self.renderedCache.value(for: source) { return cached }
        var texts: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { texts.append(current) }
            current = ""
        }
        func append(_ paragraph: String) {
            if !current.isEmpty { current += "\n" }
            current += paragraph
        }
        func inline(_ text: String) -> String {
            MarkdownBlock.softBreaks(String(MarkdownBlock.inline(text).characters))
        }
        for block in MarkdownBlock.parse(source) {
            switch block {
            case let .paragraph(text), let .heading(_, text):
                append(inline(text))
            case let .list(items, ordered):
                for (index, item) in items.enumerated() {
                    append((ordered ? "\(index + 1)." : "•") + "\t" + inline(item.text))
                }
            case let .quote(text):
                flush()
                texts.append(inline(text))
            case let .code(language, code):
                flush()
                if SVGRasterizer.inlineSource(language: language?.isEmpty == false ? language! : "code", code: code) == nil {
                    texts.append(code)
                }
            case .rule:
                flush()
            case let .table(header, _, rows):
                flush()
                for row in [header] + rows {
                    for column in header.indices {
                        texts.append(column < row.count ? inline(row[column]) : "")
                    }
                }
            }
        }
        flush()
        self.renderedCache.set(texts, for: source)
        return texts
    }

    /// Parsing Markdown is most of a search's cost, and messages rarely change, so searching
    /// again as the query is typed reuses the text.
    private static let renderedCache = TextCache()

    private final class TextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String: [String]] = [:]

        func value(for source: String) -> [String]? {
            self.lock.withLock { self.texts[source] }
        }

        func set(_ value: [String], for source: String) {
            self.lock.withLock {
                if self.texts.count > 40000 { self.texts.removeAll(keepingCapacity: true) }
                self.texts[source] = value
            }
        }
    }

    /// Occurrences of `query` in one message as the transcript shows it (Markdown rendered, link
    /// targets dropped). What Find counts for a `.message` section.
    public static func messageMatchCount(_ query: String, markdown: String) -> Int {
        let query = self.normalized(query)
        guard !query.isEmpty else { return 0 }
        return self.markdownCount(of: query, words: self.prefilterWords(query), in: markdown)
    }

    /// Rendering Markdown only removes or adds punctuation (and renumbers ordered lists), so a
    /// message can only match if every run of letters in the query is in its source. That skips
    /// parsing almost every message.
    private static func prefilterWords(_ query: String) -> [String] {
        query.rangeOfCharacter(from: .decimalDigits) != nil ? []
            : query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func markdownCount(of query: String, words: [String], in source: String) -> Int {
        guard words.allSatisfy({ source.range(of: $0, options: self.compareOptions) != nil }) else { return 0 }
        return self.renderedTexts(markdown: source).reduce(0) { $0 + self.count(of: query, in: $1) }
    }

    public static func matches(_ query: String, in entries: [TranscriptEntry], options: Options = Options()) -> [Match] {
        let query = self.normalized(query)
        guard !query.isEmpty else { return [] }
        var matches: [Match] = []
        let words = self.prefilterWords(query)
        func addMarkdown(_ source: String, entry: String, section: Section) {
            let count = self.markdownCount(of: query, words: words, in: source)
            for occurrence in 0..<count {
                matches.append(Match(entryId: entry, section: section, occurrence: occurrence))
            }
        }
        func add(_ text: String, entry: String, section: Section, from start: Int = 0) -> Int {
            let count = self.count(of: query, in: text)
            for occurrence in start..<(start + count) {
                matches.append(Match(entryId: entry, section: section, occurrence: occurrence))
            }
            return count
        }
        for entry in entries {
            switch entry {
            case let .user(item):
                addMarkdown(item.plainText, entry: entry.id, section: .message(0))
            case let .assistant(turn):
                if options.includeThinking, !turn.thinking.isEmpty {
                    _ = add(turn.thinking.joined(separator: "\n\n"), entry: entry.id, section: .thinking)
                }
                if options.includeTools {
                    for tool in turn.tools {
                        var found = 0
                        for text in self.toolTexts(tool, limit: options.toolTextLimit) {
                            found += add(text, entry: entry.id, section: .tool(tool.id), from: found)
                        }
                    }
                }
                for (index, message) in turn.text.enumerated() {
                    addMarkdown(message, entry: entry.id, section: .message(index))
                }
            case .marker:
                continue
            }
        }
        return matches
    }

    /// The match after (or before) `index`, wrapping around. Nil when there are none.
    public static func step(from index: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let index, index >= 0, index < count else { return forward ? 0 : count - 1 }
        return forward ? (index + 1) % count : (index - 1 + count) % count
    }

    /// Which match to select when the matches change (the query was edited, a message arrived):
    /// the same match if it's still there; else the latest match at or above the row the reader
    /// was on (`near`, a row index); else the first. With no reference, the latest match, since
    /// the newest messages are the likeliest target. A `preferred` match (a message search result
    /// being opened) wins over all of these when it's there.
    public static func reselect(_ previous: Match?, in matches: [Match], rowIndex: [String: Int], near row: Int?,
                                preferred: Match? = nil) -> Int?
    {
        guard !matches.isEmpty else { return nil }
        if let preferred, let index = matches.firstIndex(of: preferred) { return index }
        if let previous, let same = matches.firstIndex(of: previous) { return same }
        guard let row else { return matches.count - 1 }
        return matches.lastIndex(where: { (rowIndex[$0.entryId] ?? .max) <= row }) ?? 0
    }
}
