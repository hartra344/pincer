import Foundation

/// What a `web_search` result card shows, read from the result's `details` (upstream's payload,
/// see openclaw `web-search-output.ts`). `ToolActivity.fileEditDetails` keeps a trimmed copy.
public struct WebSearch: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case results, answer, error }

    public struct Result: Hashable, Sendable {
        public let title: String
        public let url: URL
        public let siteName: String?
        public let snippet: String?
        /// `YYYY-MM-DD`, when the provider gave a date.
        public let published: String?

        public var host: String { self.url.host(percentEncoded: false) ?? self.url.absoluteString }

        /// "Site · host · date": the site name is left out when it only repeats the host.
        public var metaLine: String {
            var parts: [String] = []
            if let siteName, siteName.caseInsensitiveCompare(self.host) != .orderedSame { parts.append(siteName) }
            parts.append(self.host)
            if let published { parts.append(published) }
            return parts.joined(separator: " · ")
        }

        /// Exactly what the card draws: title, meta line, snippet.
        public var text: String { [self.title, self.metaLine, self.snippet].compactMap { $0 }.joined(separator: "\n") }
    }

    public struct Citation: Hashable, Sendable {
        public let url: URL
        public let title: String?

        /// The link text: its title, else the URL.
        public var label: String { self.title ?? self.url.absoluteString }
    }

    public let kind: Kind
    public let provider: String?
    public let count: Int?
    public let cached: Bool
    public let truncated: Bool
    public let results: [Result]
    public let answer: String?
    public let citations: [Citation]
    /// Provider error text (envelope removed) and its docs link, for `.error`.
    public let message: String?
    public let docs: URL?

    /// True when there is a list (or an answer) to draw instead of the raw output text.
    public var isListable: Bool {
        switch self.kind {
        case .results: !self.results.isEmpty
        case .answer: self.answer != nil
        case .error: self.message != nil
        }
    }

    /// What goes on the clipboard: "title\nurl" lines, or the answer and its sources.
    public var copyText: String {
        switch self.kind {
        case .results: self.results.map { "\($0.title)\n\($0.url.absoluteString)" }.joined(separator: "\n")
        case .answer: ([self.answer].compactMap { $0 } + self.citations.map { "\($0.label)\n\($0.url.absoluteString)" })
                .joined(separator: "\n")
        case .error: [self.message, self.docs?.absoluteString].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// The strings the card draws, in draw order (Find counts matches in these).
    public var searchTexts: [String] {
        switch self.kind {
        case .results: self.results.map(\.text)
        case .answer: ([self.answer].compactMap { $0 } + self.citations.map(\.label))
        case .error: [self.message].compactMap { $0 } + (self.docs.map { [$0.absoluteString] } ?? [])
        }
    }

    enum Limits {
        static let rows = 10
        static let title = 160
        static let snippetStored = 300
        static let snippetShown = 180
        static let answer = 4000
        static let message = 600
    }

    static func url(_ value: JSONValue?) -> URL? {
        guard let text = value?.text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func wrapped(_ value: JSONValue?, limit: Int) -> String? {
        guard let text = value?.string else { return nil }
        let clean = ExternalContent.unwrap(text, limit: limit)
        return clean.isEmpty ? nil : clean
    }

    /// Reads `details`; nil when it isn't a web_search payload.
    public static func parse(_ details: JSONValue?) -> WebSearch? {
        guard let details, let kind = details["kind"]?.text.flatMap(Kind.init(rawValue:)),
              details["provider"]?.text != nil || kind == .error || details["results"] != nil else { return nil }
        let results: [Result] = (details["results"]?.array ?? []).lazy.compactMap { row -> Result? in
            guard let url = Self.url(row["url"]) else { return nil }
            let site = Self.wrapped(row["siteName"], limit: 80)
            let published = row["published"]?.text.map { String($0.prefix(10)) }
            return Result(title: Self.wrapped(row["title"], limit: Limits.title) ?? url.absoluteString, url: url,
                          siteName: site, snippet: Self.wrapped(row["snippet"], limit: Limits.snippetShown),
                          published: published)
        }.prefix(Limits.rows).map { $0 }
        let citations: [Citation] = (details["citations"]?.array ?? []).lazy.compactMap { row -> Citation? in
            guard let url = Self.url(row["url"]) else { return nil }
            return Citation(url: url, title: Self.wrapped(row["title"], limit: Limits.title))
        }.prefix(Limits.rows).map { $0 }
        return WebSearch(kind: kind, provider: details["provider"]?.text, count: details["count"]?.int,
                         cached: details["cached"]?.bool ?? false, truncated: details["truncated"]?.bool ?? false,
                         results: results, answer: kind == .answer ? Self.wrapped(details["content"], limit: Limits.answer) : nil,
                         citations: citations, message: kind == .error ? Self.wrapped(details["message"], limit: Limits.message) : nil,
                         docs: kind == .error ? Self.url(details["docs"]) : nil)
    }

    /// Whether `object` looks like a web_search payload worth keeping a trimmed copy of.
    static func isPayload(_ object: [String: JSONValue]) -> Bool {
        guard let kind = object["kind"]?.text, kind == "results" || kind == "answer" || kind == "error" else { return false }
        return object["provider"]?.text != nil
            && (object["results"]?.array != nil || object["content"]?.string != nil || object["message"]?.string != nil)
    }

    /// The payload cut to what the card draws: at most 10 rows, envelopes removed, snippets and answer capped.
    static func trimmed(_ object: [String: JSONValue]) -> [String: JSONValue] {
        var kept: [String: JSONValue] = [:]
        for key in ["kind", "provider", "count", "cached", "truncated"] {
            if let value = object[key], value.object == nil, value.array == nil { kept[key] = value }
        }
        func clean(_ value: JSONValue?, _ limit: Int) -> JSONValue? {
            wrapped(value, limit: limit).map(JSONValue.string)
        }
        if let rows = object["results"]?.array {
            kept["results"] = .array(rows.lazy.compactMap { row -> JSONValue? in
                guard let url = row["url"]?.text else { return nil }
                var item: [String: JSONValue] = ["url": .string(url)]
                item["title"] = clean(row["title"], Limits.title)
                item["siteName"] = clean(row["siteName"], 80)
                item["snippet"] = clean(row["snippet"], Limits.snippetStored)
                if let published = row["published"]?.text { item["published"] = .string(String(published.prefix(10))) }
                return .object(item)
            }.prefix(Limits.rows).map { $0 })
        }
        if let rows = object["citations"]?.array {
            kept["citations"] = .array(rows.lazy.compactMap { row -> JSONValue? in
                guard let url = row["url"]?.text else { return nil }
                var item: [String: JSONValue] = ["url": .string(url)]
                item["title"] = clean(row["title"], Limits.title)
                return .object(item)
            }.prefix(Limits.rows).map { $0 })
        }
        if object["kind"]?.text == "error" {
            kept["message"] = clean(object["message"], Limits.message)
            if let docs = object["docs"]?.text { kept["docs"] = .string(docs) }
        }
        if object["kind"]?.text == "answer" { kept["content"] = clean(object["content"], Limits.answer) }
        return kept
    }
}
