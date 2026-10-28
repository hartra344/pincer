import Foundation

/// Thinking levels a session runs at (`sessions.patch { thinkingLevel }`). OpenClaw's vocabulary is
/// off, minimal, low, medium, high, xhigh, adaptive, max and ultra; models list their own subset.
public enum ThinkingLevel {
    /// Levels that make replies noticeably slower and more expensive.
    public static let expensiveLevels: Set<String> = ["high", "xhigh", "max", "ultra"]

    /// Whether a level id is one of the slow, costly ones. `adaptive` isn't: the model decides.
    public static func isExpensive(_ id: String?) -> Bool {
        guard let id = id?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty else { return false }
        return self.expensiveLevels.contains(id)
    }

    /// The label for a level id: the Gateway's own label when it lists the level with one that
    /// differs from the id, else Pincer's label for a known level, else the id capitalized.
    public static func label(for id: String, in choices: [SlashCommandChoice]?) -> String {
        let normalized = id.trimmingCharacters(in: .whitespaces).lowercased()
        if let choice = choices?.first(where: { $0.value.lowercased() == normalized }),
           !choice.label.isEmpty, choice.label.lowercased() != choice.value.lowercased() {
            return choice.label
        }
        return self.canonicalLabel(for: normalized) ?? (id.prefix(1).uppercased() + id.dropFirst())
    }

    /// Pincer's label for one of OpenClaw's level ids; nil for an id it doesn't know.
    public static func canonicalLabel(for id: String) -> String? {
        switch id.lowercased() {
        case "off": L("Off")
        case "minimal": L("Minimal")
        case "low": L("Low")
        case "medium": L("Medium")
        case "high": L("High")
        case "xhigh": L("Extra High")
        case "adaptive": L("Adaptive")
        case "max": L("Max")
        case "ultra": L("Ultra")
        default: nil
        }
    }
}

extension ThinkingLevel {
    /// "Ultra thinking, may be slower and cost more" when the row's effective level is a slow,
    /// costly one, else nil. Cheap: reads the row only. The compact Chat Options button uses it.
    public static func expensiveWarning(for row: SessionRow) -> String? {
        guard let level = row.effectiveThinkingLevel, self.isExpensive(level) else { return nil }
        let label = self.label(for: level, in: row.thinkingLevelChoices)
        return L("\(label) thinking, may be slower and cost more")
    }
}

extension SessionRow {
    /// The thinking level picked for this session; nil when it follows the inherited default.
    public var thinkingLevel: String? { self.raw["thinkingLevel"]?.text?.nilIfEmpty }
    /// The level the session inherits (agent or Gateway default) when it has no override.
    public var thinkingDefault: String? { self.raw["thinkingDefault"]?.text?.nilIfEmpty }
    /// The level new messages run at: the override, else the inherited default.
    public var effectiveThinkingLevel: String? { self.thinkingLevel ?? self.thinkingDefault }

    /// This row with `thinkingLevel` set (nil removes it, so the row follows its default). Used
    /// for the optimistic update before `sessions.patch` answers.
    public func settingThinkingLevel(_ level: String?) -> SessionRow {
        guard case var .object(fields) = self.raw else { return self }
        if let level { fields["thinkingLevel"] = .string(level) } else { fields.removeValue(forKey: "thinkingLevel") }
        return SessionRow(.object(fields)) ?? self
    }
}

/// Everything the header's thinking-level picker shows for a session, worked out from its row.
public struct ThinkingLevelMenu: Equatable, Sendable {
    public struct Item: Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let isExpensive: Bool
        public let isSelected: Bool
        /// False for a current level the Gateway didn't list; it's shown checked but can't be picked.
        public let isEnabled: Bool
    }

    /// The inherited default's label, for "Default (Medium)"; nil when the Gateway doesn't report one.
    public let defaultLabel: String?
    /// The session follows its inherited default (no override).
    public let followsDefault: Bool
    /// The levels to offer, in the Gateway's order, plus a current level it didn't list.
    public let items: [Item]
    /// Whether the Gateway reported the model's thinking levels (`thinkingLevels`/`thinkingOptions`).
    public let reportsLevels: Bool
    /// The effective level's label; nil when neither an override nor a default is known.
    public let currentLabel: String?
    /// The effective level's id.
    public let currentLevel: String?
    /// Whether the effective level is one of the slow, costly ones.
    public let currentIsExpensive: Bool

    public init(row: SessionRow) {
        let choices = row.thinkingLevelChoices ?? []
        let override = row.thinkingLevel
        let current = row.effectiveThinkingLevel
        self.followsDefault = override == nil
        self.defaultLabel = row.thinkingDefault.map { ThinkingLevel.label(for: $0, in: choices) }
        self.reportsLevels = !choices.isEmpty
        self.currentLevel = current
        self.currentLabel = current.map { ThinkingLevel.label(for: $0, in: choices) }
        self.currentIsExpensive = ThinkingLevel.isExpensive(current)
        var items = choices.map { choice in
            Item(id: choice.value, label: ThinkingLevel.label(for: choice.value, in: choices), isExpensive: ThinkingLevel.isExpensive(choice.value),
                 isSelected: override.map { $0.lowercased() == choice.value.lowercased() } ?? false, isEnabled: true)
        }
        if let override, !items.contains(where: \.isSelected) {
            items.append(Item(id: override, label: ThinkingLevel.label(for: override, in: choices),
                              isExpensive: ThinkingLevel.isExpensive(override), isSelected: true, isEnabled: false))
        }
        self.items = items
    }
}
