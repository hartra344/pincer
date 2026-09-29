import Foundation

/// What a sidebar row shows while its chat is working: the owning agent's avatar dancing where
/// the system spinner used to be, and the label that goes with it.
public struct SidebarWorkingIndicator: Hashable, Sendable {
    /// The picture the dancing avatar draws.
    public enum Source: Hashable, Sendable {
        /// The agent's animated-avatar companion (animated avatars are on).
        case companion
        /// The agent's identity emoji on a colored disc.
        case emoji(String)
        /// The first letter of the agent's name on a colored disc.
        case initials(String)
    }

    /// Whether the avatar shows a working dance or the still idle "unread" pose.
    public enum Mode: Hashable, Sendable { case working, unread }

    public let mode: Mode
    /// The chat is unread; shows the unread mark when there is no helper badge.
    public let isUnread: Bool
    public let agentId: String
    public let agentName: String
    public let source: Source
    /// Helper (subagent) runs this row stands for when it has no run of its own; 0 means the
    /// chat's own run. Shown as a small count badge on the avatar.
    public let helperRuns: Int
    /// Accessibility label and tooltip, like "Moki is working" or "Moki: 2 helper runs working".
    public let label: String

    /// The indicator for a row, or `nil` when the row isn't working. A row is working exactly
    /// when the old spinner showed: its own run, or running helper runs the sidebar doesn't list.
    public static func resolve(hasActiveRun: Bool, runningSubagents: Int, showSubagentRuns: Bool,
                               agent: AgentSummary, companionsEnabled: Bool,
                               isUnread: Bool = false) -> SidebarWorkingIndicator?
    {
        let helpers = hasActiveRun || showSubagentRuns ? 0 : max(runningSubagents, 0)
        guard hasActiveRun || helpers > 0 else { return nil }
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? agent.id : name
        return SidebarWorkingIndicator(
            mode: .working, isUnread: isUnread, agentId: agent.id, agentName: displayName,
            source: self.source(for: agent, displayName: displayName, companionsEnabled: companionsEnabled),
            helperRuns: helpers, label: self.label(agentName: displayName, helperRuns: helpers))
    }

    /// The indicator for an idle unread chat: nil unless unread, not a subagent row, and avatars are on.
    public static func resolveUnread(isUnread: Bool, isSubagent: Bool, agent: AgentSummary,
                                     companionsEnabled: Bool) -> SidebarWorkingIndicator?
    {
        guard isUnread, !isSubagent, companionsEnabled else { return nil }
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? agent.id : name
        return SidebarWorkingIndicator(
            mode: .unread, isUnread: true, agentId: agent.id, agentName: displayName, source: .companion,
            helperRuns: 0, label: String(localized: "Unread", comment: "Sidebar: idle unread chat avatar tooltip"))
    }

    public static func source(for agent: AgentSummary, displayName: String, companionsEnabled: Bool) -> Source {
        if companionsEnabled { return .companion }
        if let emoji = agent.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty { return .emoji(emoji) }
        let initial = displayName.first.map { String($0).uppercased() } ?? "?"
        return .initials(initial)
    }

    public static func label(agentName: String, helperRuns: Int) -> String {
        switch helperRuns {
        case 0: String(localized: "\(agentName) is working", comment: "Sidebar: a chat's agent is running")
        case 1: String(localized: "\(agentName): 1 helper run working", comment: "Sidebar: one subagent run is working")
        default: String(localized: "\(agentName): \(helperRuns) helper runs working",
                        comment: "Sidebar: several subagent runs are working")
        }
    }

    public var showsUnreadMark: Bool { self.isUnread && self.badge == nil }
    public var isWorking: Bool { self.mode == .working }

    /// The badge text for helper runs, or `nil` for the chat's own run.
    public var badge: String? {
        switch self.helperRuns {
        case 0: nil
        case 1 ... 9: "\(self.helperRuns)"
        default: "9+"
        }
    }
}
