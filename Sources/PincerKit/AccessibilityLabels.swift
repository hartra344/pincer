import Foundation

/// VoiceOver labels, values and announcements, composed from plain parts so they can be unit tested.
///
/// Localization: PincerKit ships no resource bundle, so these builders compose **English** text.
/// Callers pass names, titles and message text as data (already in the user's language, or not
/// language-specific), and dates as a string the caller has already formatted for the current locale.
/// When a translation is added, move the fixed phrases into PincerUI's `Localizable.xcstrings` and
/// pass them in; the composition rules here (order, separators, truncation) stay the same.
///
/// Every builder is a pure function: no `Date()`, no locale lookups, no global state.
public enum AccessibilityText {
    /// Longest message excerpt spoken for a transcript row before it's cut with an ellipsis.
    public static let defaultSummaryLimit = 240

    /// Joins non-empty parts with `", "`, the pause VoiceOver makes between label parts.
    public static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// `1 tool call`, `3 tool calls`. Returns nil for zero so it drops out of a `join`.
    public static func count(_ value: Int, singular: String, plural: String) -> String? {
        guard value > 0 else { return nil }
        return "\(value) \(value == 1 ? singular : plural)"
    }

    /// Plain-text excerpt of a message for speech: Markdown markers and code fences dropped,
    /// whitespace collapsed to single spaces, cut at a word boundary with `…` past `limit`.
    public static func summary(_ text: String, limit: Int = AccessibilityText.defaultSummaryLimit) -> String {
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            while let first = line.first, "#>".contains(first) { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line.removeFirst(2) }
            lines.append(line)
        }
        var flat = lines.joined(separator: " ")
        for marker in ["**", "__", "`", "~~"] {
            flat = flat.replacingOccurrences(of: marker, with: "")
        }
        flat = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard limit > 0, flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        // Cut mid-word: back up to the last whole word.
        let endsOnWord = flat[cut.endIndex] == " "
        let head = endsOnWord ? cut : (cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
        return head.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// Who wrote a transcript row: `You`, the agent's name (or `Assistant`), `Tool result`, `System`.
    public static func speaker(role: ChatRole, author: String? = nil) -> String {
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty,
           role != .user
        {
            return author
        }
        switch role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .toolResult: return "Tool result"
        case .system, .marker: return "System"
        }
    }

    /// One transcript row, e.g.
    /// `Claude, Here is the plan…, 2 tool calls, 1 attachment, 3:04 PM` or
    /// `Claude, Responding, Here is…` while streaming.
    ///
    /// - Parameters:
    ///   - author: agent name for assistant rows; ignored for the user's own rows (always `You`).
    ///   - via: channel a user turn arrived through, e.g. `Discord`.
    ///   - timestamp: already formatted for the current locale (the caller owns `DateFormatter`).
    public static func messageRow(
        role: ChatRole,
        author: String? = nil,
        text: String,
        timestamp: String? = nil,
        toolCount: Int = 0,
        attachmentCount: Int = 0,
        isStreaming: Bool = false,
        isError: Bool = false,
        isPending: Bool = false,
        via: String? = nil,
        summaryLimit: Int = AccessibilityText.defaultSummaryLimit) -> String
    {
        let body = Self.summary(text, limit: summaryLimit)
        return Self.join([
            Self.speaker(role: role, author: author),
            via.map { "via \($0)" },
            isStreaming ? "Responding" : nil,
            isError ? "Error" : nil,
            isPending ? "Sending" : nil,
            body.isEmpty ? (isStreaming ? nil : "No text") : body,
            Self.count(toolCount, singular: "tool call", plural: "tool calls"),
            Self.count(attachmentCount, singular: "attachment", plural: "attachments"),
            timestamp,
        ])
    }

    /// One sidebar session row, e.g. `Research, Claude, Pinned, Working, 3 unread`.
    ///
    /// - Parameters:
    ///   - unreadCount: exact count when known; `isUnread` alone speaks `Unread`.
    ///   - workingLabel: spoken instead of `Working` while running, e.g. "Moki is working".
    ///   - preview: last message preview; summarized to `previewLimit` characters.
    public static func sessionRow(
        title: String,
        agentName: String? = nil,
        unreadCount: Int = 0,
        isUnread: Bool = false,
        isPinned: Bool = false,
        isRunning: Bool = false,
        workingLabel: String? = nil,
        hasError: Bool = false,
        isArchived: Bool = false,
        preview: String? = nil,
        previewLimit: Int = 80) -> String
    {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let unread: String? = unreadCount > 0 ? "\(unreadCount) unread" : (isUnread ? "Unread" : nil)
        return Self.join([
            trimmedTitle.isEmpty ? "Untitled session" : trimmedTitle,
            agentName,
            isPinned ? "Pinned" : nil,
            isArchived ? "Archived" : nil,
            isRunning ? (workingLabel.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Working") : nil,
            hasError ? "Last run failed" : nil,
            unread,
            preview.map { Self.summary($0, limit: previewLimit) },
        ])
    }

    /// Accessibility label for the composer's context meter.
    public static let contextMeterLabel = "Context window"

    /// Accessibility value for the context meter, e.g. `86 percent used, 172k of 200k tokens`,
    /// `About 40 percent used, …` for a stale total, and `, nearly full` / `, almost full` past the
    /// warning and critical thresholds.
    public static func contextMeterValue(_ usage: ContextUsage) -> String {
        let percent = "\(usage.isApproximate ? "About " : "")\(usage.percent) percent used"
        let tokens = "\(TokenCount.format(usage.used)) of \(TokenCount.format(usage.limit)) tokens"
        let level: String? = switch usage.level {
        case .normal: nil
        case .warning: "nearly full"
        case .critical: "almost full"
        }
        return Self.join([percent, tokens, level])
    }

    /// Spoken when an assistant reply finishes streaming, e.g. `Claude replied: Here is the plan…`.
    public static func replyFinishedAnnouncement(author: String?, text: String, limit: Int = 120) -> String {
        let name = Self.speaker(role: .assistant, author: author)
        let body = Self.summary(text, limit: limit)
        return body.isEmpty ? "\(name) replied" : "\(name) replied: \(body)"
    }

    /// Spoken when a run fails, e.g. `Claude: reply failed`.
    public static func replyFailedAnnouncement(author: String?) -> String {
        "\(Self.speaker(role: .assistant, author: author)): reply failed"
    }

    /// Transcript find status, e.g. `Result 2 of 5`, `No results`.
    public static func findStatus(current: Int?, total: Int) -> String {
        guard total > 0 else { return "No results" }
        guard let current, current >= 1 else { return total == 1 ? "1 result" : "\(total) results" }
        return "Result \(min(current, total)) of \(total)"
    }

    /// An SF Symbol name as words, e.g. `bubble.left.and.bubble.right.fill` → `Bubble left and bubble right`.
    /// Style suffixes (`fill`) are dropped; the symbol's shape words are kept.
    public static func symbolName(_ symbol: String) -> String {
        let words = symbol.split(separator: ".").filter { $0 != "fill" }.map(String.init)
        guard let first = words.first else { return symbol }
        let text = ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
        return text
    }

    /// Most "Open …" link actions offered on one transcript row.
    public static let maxLinkActions = 10

    /// The links a transcript row offers as "Open …" actions, from its text's link runs in reading
    /// order: one per URL (first run wins), trimmed text or else the URL as the title, capped at `limit`.
    public static func linkActions(_ runs: [(text: String, url: URL)],
                                   limit: Int = maxLinkActions) -> [(title: String, url: URL)] {
        var seen: Set<URL> = []
        var result: [(title: String, url: URL)] = []
        for run in runs where result.count < limit && seen.insert(run.url).inserted {
            let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append((text.isEmpty ? run.url.absoluteString : text, run.url))
        }
        return result
    }

    /// A tool-call card, e.g. `Tool exec, running, ls -la` or `Tool read, failed`.
    public static func toolCall(name: String, summary: String? = nil, isRunning: Bool, isError: Bool) -> String {
        Self.join([
            "Tool \(name)",
            isRunning ? "running" : (isError ? "failed" : "finished"),
            summary.map { Self.summary($0, limit: 80) },
        ])
    }
}
