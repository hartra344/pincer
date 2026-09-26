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

        /// The symbol the header shows, if any.
        var symbol: String? {
            self.section.emoji == nil ? self.icon ?? ChannelRowStyle.headerSymbol(for: self.section.kind) : nil
        }

        static func == (lhs: Header, rhs: Header) -> Bool {
            lhs.id == rhs.id && lhs.isCollapsed == rhs.isCollapsed && lhs.newChatAgent == rhs.newChatAgent && lhs.icon == rhs.icon
                && lhs.section.title == rhs.section.title && lhs.section.emoji == rhs.section.emoji
                && lhs.section.kind == rhs.section.kind && lhs.section.unreadCount == rhs.section.unreadCount
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
    }

    struct Group: Equatable {
        let header: Header
        let entries: [Entry]
    }

    var groups: [Group] = []

    static func headerId(_ sectionId: String) -> String { "section:\(sectionId)" }
    static func entryId(_ key: String) -> String { "chat:\(key)" }

    @MainActor
    static func build(gateway: GatewayStore, search: String, collapsed: Set<String>,
                      expandedThreads: Set<String>, showSubagentRuns: Bool,
                      showPreviews: Bool) -> SidebarModel
    {
        let selected = gateway.selectedKey
        var model = SidebarModel()
        for section in gateway.sections(search: search) {
            var entries: [Entry] = []
            for channel in section.channels {
                let expanded = expandedThreads.contains(channel.row.key)
                let subagents = channel.threads.filter(\.isSubagent)
                entries.append(Entry(
                    id: self.entryId(channel.row.key),
                    row: channel.row,
                    icon: ChannelRowStyle.customSymbol(for: channel.row, gateway: gateway),
                    color: ChannelRowStyle.colorName(for: channel.row, gateway: gateway),
                    isThread: false,
                    subagentCount: subagents.count,
                    runningSubagents: subagents.filter(\.hasActiveRun).count,
                    hiddenUnreadThreads: expanded ? 0 : subagents.filter { $0.isUnread && !$0.hasActiveRun }.count,
                    threadsExpanded: expanded,
                    showSubagentRuns: showSubagentRuns,
                    preview: showPreviews ? channel.row.preview : nil))
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
                    entries.append(Entry(id: self.entryId(thread.key), row: thread,
                                         icon: ChannelRowStyle.customSymbol(for: thread, gateway: gateway),
                                         color: ChannelRowStyle.colorName(for: thread, gateway: gateway), isThread: true, subagentCount: 0,
                                         runningSubagents: 0, hiddenUnreadThreads: 0, threadsExpanded: false,
                                         showSubagentRuns: showSubagentRuns,
                                         preview: showPreviews ? thread.preview : nil))
                }
            }
            let newChatAgent = section.agentId ?? (gateway.organization == .recent ? gateway.defaultAgentId : nil)
            var icon: String?
            if case let .group(name) = section.kind { icon = SymbolCatalog.symbol(for: gateway.groupIcon(for: name)) }
            let header = Header(id: self.headerId(section.id), section: section,
                                isCollapsed: collapsed.contains(section.id), newChatAgent: newChatAgent, icon: icon)
            model.groups.append(Group(header: header, entries: entries))
        }
        return model
    }
}

/// Things the sidebar asks its SwiftUI owner to do (sheets and view state live there).
@MainActor
struct SidebarActions {
    var select: (String) -> Void
    var newChat: (String) -> Void
    /// Opens New Chat with a group already picked.
    var newChatInGroup: (String) -> Void
    var rename: (SessionRow) -> Void
    var changeIcon: (SessionRow) -> Void
    var changeGroupIcon: (String) -> Void
    var pickColor: (SessionRow) -> Void
    var prompt: (TextPrompt) -> Void
    var confirm: (ConfirmPrompt) -> Void
    var toggleThreads: (String) -> Void
    var setCollapsed: (String, Bool) -> Void
    var refresh: () async -> Void
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
        if row.server != nil, !row.isChannelThread { return "\(row.server?.provider.capitalized ?? "Server") channel" }
        if let origin = self.origin(of: row) { return "From \(origin.capitalized)" }
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
        case .group: "chevron.down.square"
        case .automations: "clock.arrow.circlepath"
        case .agent, .other: nil
        }
    }

    static func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
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
        groups.append(.action("New Group…") {
            self.newGroup(gateway: gateway, actions: actions) { name in
                await gateway.moveChat(row.key, toGroup: name, before: nil)
            }
        })
        if row.category != nil {
            groups.append(.action("Remove from Group") { patch(["category": .null]) })
        }
        let custom = gateway.customColor(for: row.key)
        var colors: [SidebarMenuItem] = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"].map { color in
            .action(color.capitalized, checked: custom == nil && row.color == color) {
                gateway.setColor(nil, for: row.key)
                patch(["color": .string(color)])
            }
        }
        colors += [
            .divider,
            .action("Custom…", image: "eyedropper", checked: custom != nil) { actions.pickColor(row) },
            .action("None") {
                gateway.setColor(nil, for: row.key)
                patch(["color": .null])
            },
        ]

        var items: [SidebarMenuItem] = [
            .action(row.isPinned ? "Unpin" : "Pin", image: row.isPinned ? "pin.slash" : "pin") {
                patch(["pinned": .bool(!row.isPinned)])
            },
            .action(row.isUnread ? "Mark as Read" : "Mark as Unread", image: "circle.fill") {
                patch(["unread": .bool(!row.isUnread)])
            },
            .action("Rename…", image: "pencil") { actions.rename(row) },
            .action("Change Icon…", image: "face.smiling") { actions.changeIcon(row) },
        ]
        if gateway.customIcon(for: row.key) != nil {
            items.append(.action("Reset Icon", image: "arrow.uturn.backward") { gateway.setIcon(nil, for: row.key) })
        }
        items += [
            .submenu("Move to Group", image: "folder", groups),
            .submenu("Color", image: "paintpalette", colors),
            self.reasoning(row, gateway: gateway),
        ]
        if !row.isMain {
            items += [
                .divider,
                .action(row.isArchived ? "Unarchive" : "Archive", image: "archivebox") {
                    patch(["archived": .bool(!row.isArchived)])
                },
            ]
        }
        return items
    }

    static func reasoning(_ row: SessionRow, gateway: GatewayStore) -> SidebarMenuItem {
        .submenu("Gateway Reasoning", image: "brain", [("on", "Save & Stream"), ("stream", "Stream Only"), ("off", "Off")].map { value, label in
            .action(label, checked: row.reasoningLevel == value) {
                Task { await gateway.patch(row.key, ["reasoningLevel": .string(value)]) }
            }
        })
    }

    static func header(_ section: SidebarSection, gateway: GatewayStore, actions: SidebarActions) -> [SidebarMenuItem] {
        switch section.kind {
        case let .server(server):
            return [.action("Rename Server…", image: "pencil") {
                actions.prompt(TextPrompt(title: "Rename Server", field: "Name", initial: section.title) { name in
                    gateway.renameServer(server, to: name)
                })
            }]
        case let .group(name):
            let names = gateway.groupNames
            let index = names.firstIndex(of: name) ?? 0
            var items: [SidebarMenuItem] = [
                .action("New Chat in Group…", image: "square.and.pencil") { actions.newChatInGroup(name) },
                .action("Rename Group…", image: "pencil") {
                    actions.prompt(TextPrompt(title: "Rename Group", field: "Name", initial: name) { newName in
                        Task { await gateway.renameGroup(name, to: newName) }
                    })
                },
                .action("Change Icon…", image: "face.smiling") { actions.changeGroupIcon(name) },
            ]
            if gateway.groupIcon(for: name) != nil {
                items.append(.action("Reset Icon", image: "arrow.uturn.backward") { gateway.setGroupIcon(nil, for: name) })
            }
            if index > 0 {
                items.append(.action("Move Up", image: "arrow.up") {
                    Task { await gateway.moveGroup(name, before: names[index - 1]) }
                })
            }
            if index < names.count - 1 {
                items.append(.action("Move Down", image: "arrow.down") {
                    Task { await gateway.moveGroup(name, before: index + 2 < names.count ? names[index + 2] : nil) }
                })
            }
            items += [
                .divider,
                .action("New Group…", image: "folder.badge.plus") { self.newGroup(gateway: gateway, actions: actions) },
                .divider,
                .action("Delete Group…", image: "trash", destructive: true) {
                    let count = gateway.groupOrder(name).count
                    guard count > 0 else {
                        Task { await gateway.deleteGroup(name) }
                        return
                    }
                    actions.confirm(ConfirmPrompt(
                        title: "Delete “\(name)”?",
                        message: count == 1 ? "Its chat won’t be deleted; it just won’t be in a group."
                            : "Its \(count) chats won’t be deleted; they just won’t be in a group.",
                        action: "Delete Group") {
                        Task { await gateway.deleteGroup(name) }
                    })
                },
            ]
            return items
        case .other where section.id == "group:":
            return [.action("New Group…", image: "folder.badge.plus") { self.newGroup(gateway: gateway, actions: actions) }]
        default:
            return []
        }
    }

    /// Asks for a name and creates an empty group, then runs `then` with it.
    static func newGroup(gateway: GatewayStore, actions: SidebarActions, then: (@MainActor (String) async -> Void)? = nil) {
        actions.prompt(TextPrompt(title: "New Group", field: "Name", initial: "") { name in
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
enum SidebarDragPayload {
    case chat(String)
    case group(String)
}

extension SidebarModel {
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
