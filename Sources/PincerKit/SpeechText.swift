import Foundation
import Synchronization

/// Turns transcript markdown into text worth speaking.
public enum SpeechText {
    /// A reply normalized for the Read Aloud command. The full spoken text is retained so the
    /// command can start immediately after readiness is published.
    public struct PreparedReply: Sendable, Equatable {
        public let messageId: String
        public let text: String

        public init(messageId: String, text: String) {
            self.messageId = messageId
            self.text = text
        }
    }

#if DEBUG
    struct SpeakabilityDebugStats: Sendable, Equatable {
        var mainThreadNormalizations = 0
        var offMainNormalizations = 0
    }

    private struct SpeakabilityDebugRecord: Sendable {
        var stats = SpeakabilityDebugStats()
        var lastUse: UInt64
    }

    private struct SpeakabilityDebugState: Sendable {
        static let capacity = 16
        var records: [String: SpeakabilityDebugRecord] = [:]
        var clock: UInt64 = 0

        mutating func tick() -> UInt64 {
            self.clock &+= 1
            return self.clock
        }
    }

    private static let speakabilityDebug = Mutex(SpeakabilityDebugState())

    /// Bounded, payload-free instrumentation for the actual Read Aloud eligibility path.
    static func speakabilityDebugStats(for itemID: String) -> SpeakabilityDebugStats {
        self.speakabilityDebug.withLock { state in
            guard var record = state.records[itemID] else { return SpeakabilityDebugStats() }
            record.lastUse = state.tick()
            state.records[itemID] = record
            return record.stats
        }
    }

    static func resetSpeakabilityDebugStats(tracking itemID: String) {
        self.speakabilityDebug.withLock { state in
            if state.records[itemID] == nil, state.records.count >= SpeakabilityDebugState.capacity,
               let oldest = state.records.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            {
                state.records[oldest] = nil
            }
            state.records[itemID] = SpeakabilityDebugRecord(stats: SpeakabilityDebugStats(), lastUse: state.tick())
        }
    }

    static func unregisterSpeakabilityDebugStats(tracking itemID: String) {
        self.speakabilityDebug.withLock { $0.records[itemID] = nil }
    }

    private static func recordSpeakabilityNormalization(for item: ChatItem) {
        self.speakabilityDebug.withLock { state in
            guard var record = state.records[item.id] else { return }
            if Thread.isMainThread { record.stats.mainThreadNormalizations += 1 }
            else { record.stats.offMainNormalizations += 1 }
            record.lastUse = state.tick()
            state.records[item.id] = record
        }
    }
#endif

    public static func plain(fromMarkdown markdown: String) -> String {
        var text = MediaDirectives.extract(from: markdown).text.replacingOccurrences(of: "\r\n", with: "\n")
        text = self.removingBlocks(text)
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil, line.contains("-"), line.contains("|") { continue }
            if line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { flush(); continue }
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            line = self.inline(line)
            if line.hasPrefix("|") || line.contains(" | ") || line.hasSuffix("|") {
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
                if !line.isEmpty { line += "." }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.range(of: #"[.!?:;,…]$"#, options: .regularExpression) == nil, self.isListOrHeading(String(raw)) { line += "." }
            current.append(line)
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListOrHeading(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        return line.range(of: #"^(#{1,6}\s|([-*+]|\d+[.)])\s)"#, options: .regularExpression) != nil
    }

    /// Fenced code, mermaid and math blocks, and `$$…$$` display math.
    private static func removingBlocks(_ text: String) -> String {
        var out: [Substring] = []
        var fence: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first! }) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(1))
                let count = trimmed.prefix { String($0) == marker }.count
                let rest = trimmed.dropFirst(count)
                // A one-line fence (```code```) opens and closes on the same line.
                if !rest.contains(marker) { fence = String(repeating: marker, count: count) }
                continue
            }
            out.append(line)
        }
        return String(out.joined(separator: "\n"))
            .replacingOccurrences(of: #"\$\$[\s\S]*?\$\$"#, with: "", options: .regularExpression)
    }

    private static func inline(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(https?://|www\.)\S+"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"`+([^`]*)`+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\$)\$(?![\d\s$])([^$\n]*[^$\s\n])\$(?![\d$])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\", with: "")
        return s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }

    /// Cuts `s` to at most `limit` characters at a sentence, else word, boundary.
    public static func truncated(_ s: String, limit: Int = 4000) -> String {
        guard limit > 0, s.count > limit else { return s }
        let head = String(s.prefix(limit))
        let floor = head.index(head.startIndex, offsetBy: limit / 2)
        let enders: Set<Character> = [".", "!", "?", "…", "\n"]
        if let end = head[floor...].lastIndex(where: { enders.contains($0) }) {
            return String(head[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let space = head[floor...].lastIndex(where: { $0.isWhitespace }) {
            return String(head[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return head
    }

    /// What Read Aloud speaks for `item`: an assistant message's text blocks, never tool or thinking content.
    public static func speakableText(for item: ChatItem) -> String? {
        guard item.role == .assistant, !item.isPending, !item.isError else { return nil }
#if DEBUG
        self.recordSpeakabilityNormalization(for: item)
#endif
        let text = self.plain(fromMarkdown: item.plainText)
        return text.isEmpty ? nil : text
    }

    /// Prepares only the newest reply the command can read. Call this from a worker; each candidate
    /// is normalized once, and cancellation stops the backward scan between messages.
    public static func latestSpeakableReply(in items: [ChatItem]) -> PreparedReply? {
        for item in items.reversed() {
            if Task.isCancelled { return nil }
            guard let text = self.speakableText(for: item) else { continue }
            return PreparedReply(messageId: item.transcriptId ?? item.id, text: text)
        }
        return nil
    }

    /// Prepares one message for the renderer cache. Call this from its off-main worker so both
    /// normalization and the retained-string cost measurement stay away from the interaction path.
    public static func prepare(_ item: ChatItem) -> SpeechEligibilityCache.Prepared {
        let text = self.speakableText(for: item)
        return SpeechEligibilityCache.Prepared(isEligible: text != nil, speechText: text,
                                               utf8ByteCount: text?.utf8.count ?? 0)
    }
}
