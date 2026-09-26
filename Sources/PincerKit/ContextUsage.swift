import Foundation

/// How full a session's context window is, from its `sessions.list` row. Mirrors the Control UI's
/// composer meter: `totalTokens` is the latest context snapshot, the limit is the pre-reserve prompt
/// budget when the Gateway measured one, else the session's (or model's) context window.
public struct ContextUsage: Equatable, Sendable {
    public enum Level: Sendable {
        case normal
        case warning
        case critical
    }

    public static let warningRatio = 0.85
    public static let criticalRatio = 0.95

    public let used: Int
    public let limit: Int
    /// `totalTokensFresh == false`: the total predates the latest run (it may already have compacted).
    public let isApproximate: Bool
    /// The limit is the prompt budget the Gateway measured before the last prompt, not the raw window.
    public let isPromptBudget: Bool

    public init(used: Int, limit: Int, isApproximate: Bool = false, isPromptBudget: Bool = false) {
        self.used = used
        self.limit = limit
        self.isApproximate = isApproximate
        self.isPromptBudget = isPromptBudget
    }

    /// `nil` when the row has no context snapshot or no limit is known.
    public init?(row: SessionRow?, fallbackLimit: Int? = nil) {
        guard let row, let used = row.totalTokens, used >= 0 else { return nil }
        let budget = row.promptBudgetTokens
        guard let limit = budget ?? row.contextTokens ?? fallbackLimit, limit > 0 else { return nil }
        self.init(used: used, limit: limit, isApproximate: !row.totalTokensFresh, isPromptBudget: budget != nil)
    }

    public var ratio: Double { Double(self.used) / Double(self.limit) }
    public var percent: Int { min(Int((self.ratio * 100).rounded()), 100) }
    public var remaining: Int { max(self.limit - self.used, 0) }

    /// A stale total still orients, but mustn't drive warnings: the session may already have compacted.
    public var level: Level {
        guard !self.isApproximate else { return .normal }
        if self.ratio >= Self.criticalRatio { return .critical }
        if self.ratio >= Self.warningRatio { return .warning }
        return .normal
    }

    /// e.g. `172k / 200k`, with `~` on an approximate total.
    public var summary: String {
        "\(self.isApproximate ? "~" : "")\(TokenCount.format(self.used)) / \(TokenCount.format(self.limit))"
    }

    public var percentLabel: String { "\(self.isApproximate ? "~" : "")\(self.percent)%" }
}

public enum TokenCount {
    /// Compact token counts: `950`, `12.3k`, `172k`, `1.2M`.
    public static func format(_ count: Int) -> String {
        let value = Double(count)
        switch abs(count) {
        case ..<1000: return "\(count)"
        case ..<100_000: return Self.trimmed(value / 1000) + "k"
        case ..<999_500: return "\(Int((value / 1000).rounded()))k"
        default: return Self.trimmed(value / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

/// Where a "Compact now" request is, for the composer's context meter.
public enum CompactionState: Equatable, Sendable {
    case running(before: Int?)
    case finished(before: Int?, after: Int?)
    /// The Gateway had nothing to compact, with its reason.
    case skipped(String)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// e.g. `Compacted 172k → 31k tokens.`
    public var message: String {
        switch self {
        case .running: "Compacting context…"
        case let .finished(before?, after?): "Compacted \(TokenCount.format(before)) → \(TokenCount.format(after)) tokens."
        case let .finished(_, after?): "Compacted to \(TokenCount.format(after)) tokens."
        case .finished: "Context compacted."
        case let .skipped(reason): reason
        case let .failed(message): message
        }
    }
}
