import PincerKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Flattened sidebar contents for the native lists: one group per section, each holding its
/// channels and the subagent threads shown under them.
struct SidebarModel: Equatable {
    struct Header: Equatable {
        let id: String
        let section: SidebarSection
        let isCollapsed: Bool
        /// Agent a new chat started from this header's + button goes to, if it has one.
        let newChatAgent: String?
        /// Custom SF Symbol for a group (already checked for this OS).
        var icon: String?
        /// The agent's companion, shown instead of its emoji when animated avatars are on, and
        /// the still pose it holds for what the agent's chats are doing.
        var avatar: AvatarStyle?
        var avatarState = AvatarState.idle
        /// Name of the agent a nested group sits under.
        var agentName: String?
        /// Chats in a nested group (threads and subagent runs excluded).
        var chatCount = 0

        /// Outline depth: 0 for an agent or plain section, 1 for a group nested under an agent.
        var level: Int { self.isSubsection ? 1 : 0 }

        /// VoiceOver value for the disclosure state, which a custom label would otherwise hide.
        func accessibilityValue(isCollapsed: Bool) -> String { AccessibilityText.sectionState(isCollapsed: isCollapsed) }

        /// VoiceOver hint: what activating the header does.
        var accessibilityHint: String { AccessibilityText.sectionHint(isCollapsed: self.isCollapsed) }

        var accessibilityValue: String { self.accessibilityValue(isCollapsed: self.isCollapsed) }

        /// VoiceOver label for an agent header; nil for other sections.
        var agentAccessibilityLabel: String? {
            guard case .agent = self.section.kind else { return nil }
            let label = L("\(self.section.title), agent")
            let unread = self.isCollapsed ? self.section.unreadCount : 0
            return unread > 0 ? "\(label), \(L("\(unread) unread"))" : label
        }

        /// A group nested under an agent (by-agent mode).
        var isSubsection: Bool {
            if case .agentGroup = self.section.kind { return true }
            return false
        }

        var addAccessibilityLabel: String {
            if case .agent = self.section.kind { return AccessibilityText.newChatWith(agent: self.section.title) }
            guard self.isSubsection else { return L("New chat") }
            return self.agentName.map { L("New chat in \(self.section.title) with \($0)") } ?? L("New chat in \(self.section.title)")
        }

        /// What the header's + does: a new chat with the agent, and the group when this is one.
        @MainActor
        func addAction(_ actions: SidebarActions) -> (() -> Void)? {
            guard let agent = self.newChatAgent else { return nil }
            if case let .agentGroup(_, group) = self.section.kind { return { actions.newChatInGroup(group, agent) } }
            return { actions.newChat(agent) }
        }

        /// VoiceOver label for a nested group header, which has no avatar or agent name to lean on.
        var subsectionAccessibilityLabel: String {
            let title = self.section.title
            let count = self.chatCount
            var parts = [self.agentName.map { count == 1 ? L("\(title), group in \($0), 1 chat") : L("\(title), group in \($0), \(count) chats") }
                ?? (count == 1 ? L("\(title), group, 1 chat") : L("\(title), group, \(count) chats"))]
            if self.isCollapsed {
                let unread = self.section.unreadCount
                if unread > 0 { parts.append(L("\(unread) unread")) }
            }
            return parts.joined(separator: ", ")
        }

        /// The symbol the header shows, if any.
        var symbol: String? {
            self.section.emoji == nil ? self.icon ?? ChannelRowStyle.headerSymbol(for: self.section.kind) : nil
        }

        static func == (lhs: Header, rhs: Header) -> Bool {
            lhs.id == rhs.id && lhs.isCollapsed == rhs.isCollapsed && lhs.newChatAgent == rhs.newChatAgent && lhs.icon == rhs.icon
                && lhs.section.title == rhs.section.title && lhs.section.emoji == rhs.section.emoji
                && lhs.section.kind == rhs.section.kind && lhs.section.unreadCount == rhs.section.unreadCount
                && lhs.agentName == rhs.agentName && lhs.chatCount == rhs.chatCount && lhs.avatar == rhs.avatar && lhs.avatarState == rhs.avatarState
        }
    }

    struct Entry: Equatable {
        let id: String
        let row: SessionRow
        /// Custom SF Symbol (already checked for this OS), or `nil` for the default icon.
        let icon: String?
        /// The chat's color: a synced custom pick, or the session's named color.
        let color: String?
        let isThread: Bool
        let subagentCount: Int
        let runningSubagents: Int
        let hiddenUnreadThreads: Int
        let threadsExpanded: Bool
        let showSubagentRuns: Bool
        /// Last-message line under the title, or `nil` when previews are off or there's none.
        let preview: String?
        /// The dancing avatar that replaces the old spinner, or `nil` when the chat isn't working.
        let working: SidebarWorkingIndicator?
        /// What the trailing avatar shows: the working dance, or the gentle "has news" loop of an unread chat.
        /// `nil` when neither applies (the row falls back to the unread dot or nothing).
        let avatar: SidebarWorkingIndicator?
        /// The agent's companion style for `avatar` when animated avatars are on.
        let avatarStyle: AvatarStyle?
        /// Nesting under the section header: 1 for chats inside a group nested under an agent.
        var depth = 0
        /// Name of the nested group the chat sits in, if any.
        var groupName: String?
    }

    struct Group: Equatable {
        let header: Header
        /// The section's chats; in by-agent mode, the ones after the nested groups.
        let entries: [Entry]
        /// By-agent mode: the home chat(s) that come before the nested groups.
        var leadingEntries: [Entry] = []
        /// By-agent mode: groups nested under the agent, each with its chats.
        var subgroups: [Group] = []

        /// Every row id under the header, in display order (the header itself excluded).
        var childIds: [String] {
            self.leadingEntries.map(\.id) + self.subgroups.flatMap { [$0.header.id] + $0.childIds } + self.entries.map(\.id)
        }

        /// Every row under the header with the header it sits under, in display order. Unlike
        /// `childIds`, this changes when a chat moves into or out of a nested group without
        /// changing the flat order (#416).
        var placements: [Placement] {
            let parent = self.header.id
            return self.leadingEntries.map { Placement(id: $0.id, parent: parent) }
                + self.subgroups.flatMap { [Placement(id: $0.header.id, parent: parent)] + $0.placements }
                + self.entries.map { Placement(id: $0.id, parent: parent) }
        }

        var allEntries: [Entry] {
            self.leadingEntries + self.subgroups.flatMap(\.allEntries) + self.entries
        }

        /// This header and every nested one, in display order.
        var allHeaders: [Header] {
            [self.header] + self.subgroups.flatMap(\.allHeaders)
        }
    }

    var groups: [Group] = []

    /// Whether the native list has to rebuild its rows rather than refresh them in place. Rows are
    /// compared with their parent header: a chat moving into the group just above it keeps the
    /// flat order but changes parent, and a stale outline then shows it twice (#416).
    static func structureChanged(old: SidebarModel, new: SidebarModel) -> Bool {
        old.placements != new.placements
    }

    /// Every header and row, in display order, each with the header it sits under.
    var placements: [Placement] {
        self.groups.flatMap { [Placement(id: $0.header.id, parent: nil)] + $0.placements }
    }

    /// A row and the header it sits under (`nil` for a top-level header).
    struct Placement: Hashable {
        let id: String
        let parent: String?
    }

    static func headerId(_ sectionId: String) -> String { "section:\(sectionId)" }
    static func entryId(_ key: String) -> String { "chat:\(key)" }

    @MainActor
    static func build(gateway: GatewayStore, search: String, collapsed: Set<String>,
                      expandedThreads: Set<String>, showSubagentRuns: Bool,
                      showPreviews: Bool) -> SidebarModel
    {
        let selected = gateway.selectedKey
        let avatarsOn = AvatarSettings.isEnabled
        let approvalKeys = avatarsOn ? Set(gateway.approvals.compactMap(\.sessionKey)) : []
        func working(_ row: SessionRow, runningSubagents: Int) -> (SidebarWorkingIndicator?, SidebarWorkingIndicator?, AvatarStyle?) {
            let agent = gateway.agent(row.agentId)
            var indicator: SidebarWorkingIndicator?
            if row.hasActiveRun || (!showSubagentRuns && runningSubagents > 0) {
                indicator = SidebarWorkingIndicator.resolve(
                    hasActiveRun: row.hasActiveRun, runningSubagents: runningSubagents, showSubagentRuns: showSubagentRuns,
                    agent: agent, companionsEnabled: avatarsOn, isUnread: row.isUnread && !row.isSubagent)
            }
            let avatar = indicator ?? SidebarWorkingIndicator.resolveUnread(
                isUnread: row.isUnread, isSubagent: row.isSubagent, agent: agent, companionsEnabled: avatarsOn)
            return (indicator, avatar, avatar != nil && avatarsOn ? AvatarSettings.style(for: agent, in: gateway) : nil)
        }
        func entries(_ channels: [SidebarChannel], depth: Int, groupName: String? = nil) -> [Entry] {
            var entries: [Entry] = []
            for channel in channels {
                let expanded = expandedThreads.contains(channel.row.key)
                let subagents = channel.threads.filter(\.isSubagent)
                let runningSubagents = subagents.filter(\.hasActiveRun).count
                let channelWorking = working(channel.row, runningSubagents: runningSubagents)
                entries.append(Entry(
                    id: self.entryId(channel.row.key),
                    row: channel.row,
                    icon: ChannelRowStyle.customSymbol(for: channel.row, gateway: gateway),
                    color: ChannelRowStyle.colorName(for: channel.row, gateway: gateway),
                    isThread: false,
                    subagentCount: subagents.count,
                    runningSubagents: runningSubagents,
                    hiddenUnreadThreads: expanded ? 0 : subagents.filter { $0.isUnread && !$0.hasActiveRun }.count,
                    threadsExpanded: expanded,
                    showSubagentRuns: showSubagentRuns,
                    preview: showPreviews ? channel.row.preview : nil,
                    working: channelWorking.0, avatar: channelWorking.1, avatarStyle: channelWorking.2, depth: depth, groupName: groupName))
                // Like Discord, helper runs live inside the conversation (as "Open run" on their
                // tool call) unless the sidebar is set to list them.
                let visible: [SessionRow]
                if !showSubagentRuns {
                    visible = channel.threads.filter { !$0.isSubagent || $0.key == selected }
                } else if expanded {
                    visible = channel.threads
                } else {
                    visible = channel.threads.filter { !$0.isSubagent || $0.hasActiveRun || $0.key == selected }
                }
                for thread in visible {
                    let threadWorking = working(thread, runningSubagents: 0)
                    entries.append(Entry(id: self.entryId(thread.key), row: thread,
                                         icon: ChannelRowStyle.customSymbol(for: thread, gateway: gateway),
                                         color: ChannelRowStyle.colorName(for: thread, gateway: gateway), isThread: true, subagentCount: 0,
                                         runningSubagents: 0, hiddenUnreadThreads: 0, threadsExpanded: false,
                                         showSubagentRuns: showSubagentRuns,
                                         preview: showPreviews ? thread.preview : nil,
                                         working: threadWorking.0, avatar: threadWorking.1, avatarStyle: threadWorking.2, depth: depth, groupName: groupName))
                }
            }
            return entries
        }
        func group(_ section: SidebarSection, depth: Int) -> Group {
            let newChatAgent = section.agentId ?? (gateway.organization == .recent ? gateway.defaultAgentId : nil)
            var icon: String?
            if let name = section.groupName, section.agentId == nil || depth > 0 {
                icon = SymbolCatalog.symbol(for: gateway.groupIcon(for: name))
            }
            var header = Header(id: self.headerId(section.id), section: section,
                                isCollapsed: collapsed.contains(section.id), newChatAgent: newChatAgent, icon: icon)
            if depth > 0, let agentId = section.agentId { header.agentName = gateway.agent(agentId).name }
            let nestedName: String? = depth > 0 ? section.title : nil
            if depth > 0 { header.chatCount = section.channels.count }
            if avatarsOn, case let .agent(agentId) = section.kind {
                header.avatar = AvatarSettings.style(for: gateway.agent(agentId), in: gateway)
                let rows = section.allChannels.flatMap { [$0.row] + $0.threads }
                if rows.contains(where: { approvalKeys.contains($0.key) }) {
                    header.avatarState = .awaitingApproval
                } else if rows.contains(where: \.hasActiveRun) {
                    header.avatarState = .thinking
                }
            }
            if section.subsections.isEmpty {
                return Group(header: header, entries: entries(section.channels, depth: depth, groupName: nestedName))
            }
            let leading = min(section.leadingChannelCount, section.channels.count)
            return Group(header: header,
                         entries: entries(Array(section.channels[leading...]), depth: depth, groupName: nestedName),
                         leadingEntries: entries(Array(section.channels[..<leading]), depth: depth, groupName: nestedName),
                         subgroups: section.subsections.map { group($0, depth: depth + 1) })
        }
        var model = SidebarModel()
        for section in gateway.sections(search: search) {
            model.groups.append(group(section, depth: 0))
        }
        return model
    }
}

/// The companion on an agent's section header: a still pose, no timeline.
enum SidebarAvatar {
    /// One point per pixel cell, so the pixel style stays crisp.
    static let side: CGFloat = 18
}

/// Things the sidebar asks its SwiftUI owner to do (sheets and view state live there).
@MainActor
struct SidebarActions {
    var select: (String) -> Void
    var newChat: (String) -> Void
    /// Opens New Chat with a group already picked.
    /// The agent is the one the chat goes to, or `nil` for the default.
    var newChatInGroup: (_ group: String, _ agentId: String?) -> Void
    var rename: (SessionRow) -> Void
    var changeIcon: (SessionRow) -> Void
    var changeGroupIcon: (String) -> Void
    var pickColor: (SessionRow) -> Void
    var prompt: (TextPrompt) -> Void
    var confirm: (ConfirmPrompt) -> Void
    var toggleThreads: (String) -> Void
    var setCollapsed: (String, Bool) -> Void
    var refresh: () async -> Void
    var openAutomations: () -> Void
    /// Opens a chat in a window of its own; nil where there are none (iOS).
    var openInNewWindow: ((String) -> Void)?
    /// Shows a chat beside the selected one; nil where there's no room (iPhone).
    var openInSplit: ((String) -> Void)?
}

// MARK: Row appearance

enum ChannelRowStyle {
    /// The chat's chosen icon: this app's synced pick first, then a session `icon` other
    /// OpenClaw clients set, if it maps to an SF Symbol available here.
    @MainActor
    static func customSymbol(for row: SessionRow, gateway: GatewayStore) -> String? {
        SymbolCatalog.symbol(for: gateway.customIcon(for: row.key)) ?? SymbolCatalog.symbol(for: row.icon)
    }

    @MainActor
    static func colorName(for row: SessionRow, gateway: GatewayStore) -> String? {
        gateway.customColor(for: row.key) ?? row.color
    }

    @MainActor
    static func color(for row: SessionRow, gateway: GatewayStore) -> Color? {
        Theme.color(named: self.colorName(for: row, gateway: gateway))
    }

    static func symbol(for entry: SidebarModel.Entry) -> String {
        entry.icon ?? self.defaultSymbol(for: entry.row, isThread: entry.isThread)
    }

    static func defaultSymbol(for row: SessionRow, isThread: Bool) -> String {
        if isThread { return row.isSubagent ? "sparkles" : "bubble.left.and.text.bubble.right" }
        if row.isAutomation { return "clock.arrow.circlepath" }
        if row.isSlashCommands { return "command" }
        if row.server != nil, !row.isChannelThread { return "number" }
        if let origin = self.origin(of: row) { return self.symbol(origin) }
        if row.isMain { return "house" }
        return "number"
    }

    static func help(for row: SessionRow) -> String? {
        if row.server != nil, !row.isChannelThread { return L("\(row.server?.provider.capitalized ?? "Server") channel") }
        if let origin = self.origin(of: row) { return L("From \(origin.capitalized)") }
        return nil
    }

    private static func origin(of row: SessionRow) -> String? {
        guard let origin = row.channel?.lowercased(),
              ["discord", "slack", "telegram", "imessage", "whatsapp"].contains(origin) else { return nil }
        return origin
    }

    static func symbol(_ origin: String) -> String {
        switch origin {
        case "imessage": "message"
        case "whatsapp", "telegram": "paperplane"
        default: "bubble.left.and.bubble.right"
        }
    }

    static func headerSymbol(for kind: SidebarSection.Kind) -> String? {
        switch kind {
        case let .server(server): self.symbol(server.provider)
        case .group, .agentGroup: "chevron.down.square"
        case .automations: "clock.arrow.circlepath"
        case .agent, .other: nil
        }
    }

    static func relativeDate(_ date: Date) -> String {
        SidebarActivityDate.relativeDate(date)
    }

    #if os(macOS)
    static func tint(for entry: SidebarModel.Entry) -> NSColor {
        Theme.color(named: entry.color).map { NSColor($0) } ?? .secondaryLabelColor
    }
    #else
    static func tint(for entry: SidebarModel.Entry) -> UIColor {
        Theme.color(named: entry.color).map { UIColor($0) } ?? .secondaryLabel
    }
    #endif
}

// MARK: Menus

/// A context menu described once and rendered as `NSMenu` or `UIMenu`.
indirect enum SidebarMenuItem {
    case action(String, image: String? = nil, checked: Bool = false, destructive: Bool = false, @MainActor () -> Void)
    case submenu(String, image: String? = nil, [SidebarMenuItem])
    case divider
}

@MainActor
enum SidebarMenus {
    static func chat(_ row: SessionRow, gateway: GatewayStore, actions: SidebarActions) -> [SidebarMenuItem] {
        func patch(_ fields: [String: JSONValue]) {
            Task { await gateway.patch(row.key, fields) }
        }
        var groups: [SidebarMenuItem] = gateway.groupNames.map { name in
            .action(name, checked: row.category == name) {
                guard row.category != name else { return }
                Task { await gateway.moveChat(row.key, toGroup: name, before: nil) }
            }
        }
        if !groups.isEmpty { groups.append(.divider) }
        groups.append(.action(L("New Group…")) {
            self.newGroup(gateway: gateway, actions: actions) { name in
                await gateway.moveChat(row.key, toGroup: name, before: nil)
            }
        })
        if row.category != nil {
            groups.append(.action(L("Remove from Group")) { patch(["category": .null]) })
        }
        let custom = gateway.customColor(for: row.key)
        var colors: [SidebarMenuItem] = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"].map { color in
            .action(self.colorName(color), checked: custom == nil && row.color == color) {
                gateway.setColor(nil, for: row.key)
                patch(["color": .string(color)])
            }
        }
        colors += [
            .divider,
            .action(L("Custom…"), image: "eyedropper", checked: custom != nil) { actions.pickColor(row) },
            .action(L("None")) {
                gateway.setColor(nil, for: row.key)
                patch(["color": .null])
            },
        ]

        var items: [SidebarMenuItem] = []
        if let openInNewWindow = actions.openInNewWindow {
            items.append(.action(L("Open in New Window"), image: "macwindow.badge.plus") { openInNewWindow(row.key) })
        }
        if let openInSplit = actions.openInSplit, row.key != gateway.selectedKey {
            items.append(.action(L("Open in Split View"), image: "rectangle.split.2x1") { openInSplit(row.key) })
        }
        if !items.isEmpty { items.append(.divider) }
        items += [
            .action(row.isPinned ? L("Unpin") : L("Pin"), image: row.isPinned ? "pin.slash" : "pin") {
                patch(["pinned": .bool(!row.isPinned)])
            },
            .action(row.isUnread ? L("Mark as Read") : L("Mark as Unread"), image: "circle.fill") {
                patch(["unread": .bool(!row.isUnread)])
            },
            .action(L("Rename…"), image: "pencil") { actions.rename(row) },
            .action(L("Change Icon…"), image: "face.smiling") { actions.changeIcon(row) },
        ]
        if gateway.customIcon(for: row.key) != nil {
            items.append(.action(L("Reset Icon"), image: "arrow.uturn.backward") { gateway.setIcon(nil, for: row.key) })
        }
        items += [
            .submenu(L("Move to Group"), image: "folder", groups),
            .submenu(L("Color"), image: "paintpalette", colors),
            self.reasoning(row, gateway: gateway),
        ]
        if !row.isMain {
            items += [
                .divider,
                .action(row.isArchived ? L("Unarchive") : L("Archive"), image: "archivebox") {
                    patch(["archived": .bool(!row.isArchived)])
                },
            ]
        }
        return items
    }

    private static func colorName(_ color: String) -> String {
        switch color {
        case "red": L("Red")
        case "orange": L("Orange")
        case "yellow": L("Yellow")
        case "green": L("Green")
        case "cyan": L("Cyan")
        case "blue": L("Blue")
        case "purple": L("Purple")
        case "pink": L("Pink")
        default: color.capitalized
        }
    }

    static func reasoning(_ row: SessionRow, gateway: GatewayStore) -> SidebarMenuItem {
        .submenu(L("Gateway Reasoning"), image: "brain", [("on", L("Save & Stream")), ("stream", L("Stream Only")), ("off", L("Off"))].map { value, label in
            .action(label, checked: row.reasoningLevel == value) {
                Task { await gateway.patch(row.key, ["reasoningLevel": .string(value)]) }
            }
        })
    }

    static func header(_ section: SidebarSection, gateway: GatewayStore, actions: SidebarActions) -> [SidebarMenuItem] {
        switch section.kind {
        case let .server(server):
            return [.action(L("Rename Server…"), image: "pencil") {
                actions.prompt(TextPrompt(title: L("Rename Server"), field: L("Name"), initial: section.title) { name in
                    gateway.renameServer(server, to: name)
                })
            }]
        case let .group(name):
            return self.groupMenu(name, agent: nil, gateway: gateway, actions: actions)
        case let .agentGroup(agent, name):
            return self.groupMenu(name, agent: agent, gateway: gateway, actions: actions)
        case let .agent(agent):
            guard gateway.organization == .agent else { return [] }
            // Every group, so an agent's first chat in a group can start here.
            var groups: [SidebarMenuItem] = gateway.groupNames.map { name in
                .action(name) { actions.newChatInGroup(name, agent) }
            }
            if !groups.isEmpty { groups.append(.divider) }
            groups.append(.action(L("New Group…")) {
                self.newGroup(gateway: gateway, actions: actions) { name in actions.newChatInGroup(name, agent) }
            })
            return [.submenu(L("New Chat in Group"), image: "square.and.pencil", groups)]
        case .automations:
            return [.action(L("Manage Automations…"), image: "clock.arrow.circlepath") { actions.openAutomations() }]
        case .other where section.id == "group:":
            return [.action(L("New Group…"), image: "folder.badge.plus") { self.newGroup(gateway: gateway, actions: actions) }]
        default:
            return []
        }
    }

    /// The menu of a group header. Nested under an agent (`agent` set) it starts chats with that
    /// agent and leaves group ordering to the by-group view.
    static func groupMenu(_ name: String, agent: String?, gateway: GatewayStore, actions: SidebarActions) -> [SidebarMenuItem] {
        let names = gateway.groupNames
        let index = names.firstIndex(of: name) ?? 0
        var items: [SidebarMenuItem] = [
            .action(L("New Chat in Group…"), image: "square.and.pencil") { actions.newChatInGroup(name, agent) },
            .action(L("Rename Group…"), image: "pencil") {
                actions.prompt(TextPrompt(title: L("Rename Group"), field: L("Name"), initial: name) { newName in
                    Task { await gateway.renameGroup(name, to: newName) }
                })
            },
            .action(L("Change Icon…"), image: "face.smiling") { actions.changeGroupIcon(name) },
        ]
        if gateway.groupIcon(for: name) != nil {
            items.append(.action(L("Reset Icon"), image: "arrow.uturn.backward") { gateway.setGroupIcon(nil, for: name) })
        }
        if agent == nil, index > 0 {
            items.append(.action(L("Move Up"), image: "arrow.up") {
                Task { await gateway.moveGroup(name, before: names[index - 1]) }
            })
        }
        if agent == nil, index < names.count - 1 {
            items.append(.action(L("Move Down"), image: "arrow.down") {
                Task { await gateway.moveGroup(name, before: index + 2 < names.count ? names[index + 2] : nil) }
            })
        }
        items += [
            .divider,
            .action(L("New Group…"), image: "folder.badge.plus") { self.newGroup(gateway: gateway, actions: actions) },
            .divider,
            .action(L("Delete Group…"), image: "trash", destructive: true) {
                let count = gateway.groupOrder(name).count
                guard count > 0 else {
                    Task { await gateway.deleteGroup(name) }
                    return
                }
                actions.confirm(ConfirmPrompt(
                    title: L("Delete “\(name)”?"),
                    message: (count == 1 ? L("Its chat won’t be deleted; it just won’t be in a group.")
                        : L("Its \(count) chats won’t be deleted; they just won’t be in a group."))
                        + (agent == nil ? "" : " " + L("This group is shared by all agents.")),
                    action: L("Delete Group")) {
                    Task { await gateway.deleteGroup(name) }
                })
            },
        ]
        return items
    }

    /// Asks for a name and creates an empty group, then runs `then` with it.
    static func newGroup(gateway: GatewayStore, actions: SidebarActions, then: (@MainActor (String) async -> Void)? = nil) {
        actions.prompt(TextPrompt(title: L("New Group"), field: L("Name"), initial: "") { name in
            let value = name.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            Task {
                if !gateway.groupNames.contains(value) { await gateway.createGroup(value) }
                await then?(value)
            }
        })
    }
}

/// Pasteboard types for things dragged within the sidebar.
enum SidebarDrag {
    static let typeIdentifier = "chat.pincer.session-key"
    static let groupTypeIdentifier = "chat.pincer.group-name"
}

/// What a sidebar drag carries (the local object of a UIKit drag).
enum SidebarDragPayload: Equatable {
    case chat(String)
    case group(String)
}

extension SidebarModel {
    /// Ids of headers and entries present in both models whose values differ.
    static func changedRowKeys(old: SidebarModel, new: SidebarModel) -> [String] {
        var oldHeaders: [String: Header] = [:]
        var oldEntries: [String: Entry] = [:]
        var changed: [String] = []
        for group in old.groups {
            for header in group.allHeaders { oldHeaders[header.id] = header }
            for entry in group.allEntries { oldEntries[entry.id] = entry }
        }
        for group in new.groups {
            for header in group.allHeaders {
                if let previous = oldHeaders[header.id], previous != header { changed.append(header.id) }
            }
            for entry in group.allEntries {
                if let previous = oldEntries[entry.id], previous != entry { changed.append(entry.id) }
            }
        }
        return changed
    }

    var groupNamesInOrder: [String] {
        self.groups.compactMap { group in
            if case let .group(name) = group.header.section.kind { return name }
            return nil
        }
    }

    /// The first chat at or after `index` in a section's entries that isn't `excluding`, which a
    /// chat dropped at `index` goes in front of. `nil` means the end of the group.
    static func chat(atOrAfter index: Int, in entries: [Entry], excluding key: String) -> String? {
        guard index < entries.count else { return nil }
        return entries[max(0, index)...].first { !$0.isThread && $0.row.key != key }?.row.key
    }
}
