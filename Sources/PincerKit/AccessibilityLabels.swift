import Foundation

/// VoiceOver labels, values and announcements, composed from plain parts so they can be unit tested.
///
/// Localization: the fixed phrases ("Pinned", "3 unread", "Result 2 of 5") are keys in PincerUI's
/// String Catalog, looked up with `L(…)` (see `PincerStrings`); without a registered bundle, as in
/// unit tests, they're the English keys. Callers pass names, titles and message text as data
/// (already in the user's language, or not language-specific), and dates as a string the caller has
/// already formatted for the current locale.
///
/// Every builder is otherwise a pure function: no `Date()` and no state beyond the catalog lookup.
public enum AccessibilityText {
    /// Longest message excerpt spoken for a transcript row before it's cut with an ellipsis.
    public static let defaultSummaryLimit = 240

    /// Joins non-empty parts with `", "`, the pause VoiceOver makes between label parts.
    public static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Label for a sidebar section's show/hide chevron: `Collapse Moki`, `Expand Moki`.
    public static func sectionToggle(title: String, isCollapsed: Bool) -> String {
        isCollapsed ? L("Expand \(title)") : L("Collapse \(title)")
    }

    /// Spoken value of a collapsible section header.
    public static func sectionState(isCollapsed: Bool) -> String {
        isCollapsed ? L("Collapsed") : L("Expanded")
    }

    /// Spoken hint of a collapsible section header: what activating it will do.
    public static func sectionHint(isCollapsed: Bool) -> String {
        isCollapsed ? L("Expands the section") : L("Collapses the section")
    }

    /// Label for an agent header's "+" button: `New chat with Moki`.
    public static func newChatWith(agent: String) -> String {
        L("New chat with \(agent)")
    }

    /// Label for a plain group's "+" button: `New chat in Home`.
    public static func newChatIn(group: String) -> String {
        L("New chat in \(group)")
    }

    /// Session Manager run status, spoken as the screen shows it: `Queued`, `Running`, `Done`, `Error`,
    /// `Stopped`, `Timed Out`, or `Interrupted` (case-insensitive; `failed` is `Failed`). Anything
    /// else, such as an already-joined status, is returned unchanged.
    public static func runStatusLabel(_ status: String) -> String {
        switch status.lowercased() {
        case "queued": L("Queued")
        case "running": L("Running")
        case "done": L("Done")
        case "error": L("Error")
        case "failed": L("Failed")
        case "stopped": L("Stopped")
        case "timed out": L("Timed Out")
        case "interrupted": L("Interrupted")
        default: status
        }
    }

    /// One Session Manager row, e.g. `Research, Claude, Interrupted, 2 min 5 s, updated 3:04 PM`.
    /// `updated` is already phrased (`updated 3:04 PM`). `runStatus` is one of `running`, `done`, `failed`, `interrupted` (localized here).
    public static func sessionManagerRow(
        title: String,
        agentName: String?,
        runStatus: String?,
        duration: String?,
        updated: String?,
        extra: [String?] = []) -> String
    {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.join([
            trimmed.isEmpty ? L("Untitled session") : trimmed,
            agentName,
            runStatus.map(Self.runStatusLabel),
            duration,
            updated,
        ] + extra)
    }

    /// Label for a streaming reply: the START of the reply (stable while tokens arrive). Only the
    /// first `limit * 4` UTF-8 bytes are ever read, so the cost doesn't grow with reply length.
    public static func streamingExcerpt(_ body: String, limit: Int = AccessibilityText.defaultSummaryLimit) -> String {
        let cap = max(limit, 1) * 4
        let bytes = body.utf8.prefix(cap)
        // A cut through a multi-byte character decodes to a replacement char; drop it.
        var head = String(decoding: bytes, as: UTF8.self)
        if head.hasSuffix("\u{FFFD}") { head.removeLast() }
        let cutShort = !body.utf8.dropFirst(cap).isEmpty
        let text = Self.summary(head, limit: limit)
        return cutShort && !text.hasSuffix("…") ? text + "…" : text
    }

    /// Per-message action name on a multi-message row: `Reply, part 1 of 3, Opening words…`;
    /// unchanged for one part. `openingExcerpt` should already be a bounded, plain-text excerpt.
    public static func messagePartAction(
        _ action: String,
        part: Int,
        of total: Int,
        openingExcerpt: String? = nil
    ) -> String {
        guard total > 1 else { return action }
        return Self.join([L("\(action), part \(part) of \(total)"), openingExcerpt])
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
    public static func speaker(role: ChatRole, author: String? = nil, userAuthor: String? = nil) -> String {
        if role == .user,
           let userAuthor = userAuthor?.trimmingCharacters(in: .whitespacesAndNewlines), !userAuthor.isEmpty
        {
            return userAuthor
        }
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty,
            role != .user
        {
            return author
        }
        switch role {
        case .user: return L("You")
        case .assistant: return L("Assistant")
        case .toolResult: return L("Tool result")
        case .system, .marker: return L("System")
        }
    }

    /// One transcript row, e.g.
    /// `Claude, Here is the plan…, 2 tool calls, 1 attachment, 3:04 PM` or
    /// `Claude, Responding, Here is…` while streaming.
    ///
    /// - Parameters:
    ///   - author: agent name for assistant rows; ignored for user rows.
    ///   - userAuthor: bridged sender name for a user row; absent names remain `You`.
    ///   - via: channel a user turn arrived through, e.g. `Discord`.
    ///   - timestamp: already formatted for the current locale (the caller owns `DateFormatter`).
    public static func messageRow(
        role: ChatRole,
        author: String? = nil,
        userAuthor: String? = nil,
        text: String,
        timestamp: String? = nil,
        toolCount: Int = 0,
        attachmentCount: Int = 0,
        isStreaming: Bool = false,
        isError: Bool = false,
        isPending: Bool = false,
        isBookmarked: Bool = false,
        via: String? = nil,
        summaryLimit: Int = AccessibilityText.defaultSummaryLimit) -> String
    {
        let body = Self.summary(text, limit: summaryLimit)
        return Self.join([
            Self.speaker(role: role, author: author, userAuthor: userAuthor),
            isBookmarked ? L("Bookmarked", comment: "VoiceOver: the message is bookmarked") : nil,
            via.map { L("via \($0)") },
            isStreaming ? L("Responding") : nil,
            isError ? L("Error") : nil,
            isPending ? L("Sending") : nil,
            body.isEmpty ? (isStreaming ? nil : L("No text")) : body,
            toolCount > 0 ? (toolCount == 1 ? L("1 tool call") : L("\(toolCount) tool calls")) : nil,
            attachmentCount > 0 ? (attachmentCount == 1 ? L("1 attachment") : L("\(attachmentCount) attachments")) : nil,
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
        let unread: String? = unreadCount > 0 ? L("\(unreadCount) unread") : (isUnread ? L("Unread") : nil)
        return Self.join([
            trimmedTitle.isEmpty ? L("Untitled session") : trimmedTitle,
            agentName,
            isPinned ? L("Pinned") : nil,
            isArchived ? L("Archived") : nil,
            isRunning ? (workingLabel.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? L("Working")) : nil,
            hasError ? L("Last run failed") : nil,
            unread,
            preview.map { Self.summary($0, limit: previewLimit) },
        ])
    }

    /// Accessibility label for the composer's context meter.
    public static var contextMeterLabel: String { L("Context window") }

    /// Accessibility value for the context meter, e.g. `86 percent used, 172k of 200k tokens`,
    /// `About 40 percent used, …` for a stale total, and `, nearly full` / `, almost full` past the
    /// warning and critical thresholds.
    public static func contextMeterValue(_ usage: ContextUsage) -> String {
        let percent = usage.isApproximate ? L("About \(usage.percent) percent used") : L("\(usage.percent) percent used")
        let tokens = L("\(TokenCount.format(usage.used)) of \(TokenCount.format(usage.limit)) tokens")
        let level: String? = switch usage.level {
        case .normal: nil
        case .warning: L("nearly full")
        case .critical: L("almost full")
        }
        return Self.join([percent, tokens, level])
    }

    /// Spoken when an assistant reply finishes streaming, e.g. `Claude replied: Here is the plan…`.
    public static func replyFinishedAnnouncement(author: String?, text: String, limit: Int = 120) -> String {
        let name = Self.speaker(role: .assistant, author: author)
        let body = Self.summary(text, limit: limit)
        return body.isEmpty ? L("\(name) replied") : L("\(name) replied: \(body)")
    }

    /// Spoken when a run fails, e.g. `Claude: reply failed`.
    public static func replyFailedAnnouncement(author: String?) -> String {
        L("\(Self.speaker(role: .assistant, author: author)): reply failed")
    }

    /// Transcript find status, e.g. `Result 2 of 5`, `No results`.
    public static func findStatus(current: Int?, total: Int) -> String {
        guard total > 0 else { return L("No results") }
        guard let current, current >= 1 else { return total == 1 ? L("1 result") : L("\(total) results") }
        return L("Result \(min(current, total)) of \(total)")
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

    /// A link in rendered transcript text, with optional site context for a web-search result.
    /// `webHost` is supplied by the producer only for web-search result and citation links; ordinary
    /// Markdown links leave it nil and keep their existing VoiceOver wording.
    public struct LinkActionRun: Sendable {
        public let text: String
        public let url: URL
        public let webHost: String?

        public init(text: String, url: URL, webHost: String? = nil) {
            self.text = text
            self.url = url
            self.webHost = webHost
        }
    }

    /// A deduplicated link action, preserving its originating host when it is a web result.
    public struct LinkAction: Sendable {
        /// Nil when a web result has no useful title or its visible link text is the full URL;
        /// callers can then speak the safe host alone rather than exposing URL details.
        public let title: String?
        public let webHost: String?
        public let url: URL
    }

    /// The links a transcript row offers as actions while retaining web-result host context.
    /// The first run for each URL wins, in reading order, with the same cap as `linkActions`.
    public static func linkActionsWithWebHosts(_ runs: [LinkActionRun],
                                               limit: Int = maxLinkActions) -> [LinkAction] {
        var seen: Set<URL> = []
        var result: [LinkAction] = []
        for run in runs where result.count < limit && seen.insert(run.url).inserted {
            let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = run.webHost?.trimmingCharacters(in: .whitespacesAndNewlines)
            let webHost = host?.isEmpty == false ? host : nil
            let title: String?
            if webHost != nil, text.isEmpty || text == run.url.absoluteString {
                title = nil
            } else {
                title = text.isEmpty ? run.url.absoluteString : text
            }
            result.append(LinkAction(title: title, webHost: webHost, url: run.url))
        }
        return result
    }

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
            L("Tool \(name)"),
            isRunning ? L("running") : (isError ? L("failed") : L("finished")),
            summary.map { Self.summary($0, limit: 80) },
        ])
    }
}
