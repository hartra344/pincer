#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Sidebar backed by a source-list `NSOutlineView`: native rows, selection, keyboard navigation,
/// collapsible sections, context menus, and drag and drop between groups.
struct SidebarList: NSViewRepresentable {
    let model: SidebarModel
    let selectedKey: String?
    let gateway: GatewayStore
    let actions: SidebarActions

    func makeCoordinator() -> Coordinator { Coordinator(gateway: self.gateway, actions: self.actions) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(model: self.model, selectedKey: self.selectedKey, actions: self.actions)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Outline items must keep their identity across reloads, so each id maps to one object.
    final class Node: NSObject {
        let id: String
        init(_ id: String) { self.id = id }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        private let gateway: GatewayStore
        private var actions: SidebarActions
        private var model = SidebarModel()
        private var hasLoaded = false
        private var nodes: [String: Node] = [:]
        private var headers: [String: SidebarModel.Header] = [:]
        private var entries: [String: SidebarModel.Entry] = [:]
        private var children: [String: [Node]] = [:]
        private var roots: [Node] = []
        private var selectedKey: String?
        private var isProgrammatic = false
        private var timer: Timer?
        private weak var outline: NSOutlineView?

        private static let dragType = NSPasteboard.PasteboardType(SidebarDrag.typeIdentifier)

        init(gateway: GatewayStore, actions: SidebarActions) {
            self.gateway = gateway
            self.actions = actions
        }

        func makeScrollView() -> NSScrollView {
            let outline = NSOutlineView()
            outline.style = .sourceList
            outline.selectionHighlightStyle = .sourceList
            outline.headerView = nil
            outline.rowSizeStyle = .custom
            outline.floatsGroupRows = false
            outline.indentationPerLevel = 0
            outline.allowsEmptySelection = true
            outline.allowsMultipleSelection = false
            outline.backgroundColor = .clear
            let column = NSTableColumn(identifier: .init("chat"))
            column.resizingMask = .autoresizingMask
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            outline.dataSource = self
            outline.delegate = self
            outline.registerForDraggedTypes([Self.dragType])
            outline.setDraggingSourceOperationMask(.move, forLocal: true)
            outline.draggingDestinationFeedbackStyle = .sourceList
            let menu = NSMenu()
            menu.delegate = self
            outline.menu = menu

            let scroll = NSScrollView()
            scroll.documentView = outline
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            self.outline = outline

            // Relative times ("5m") move on without the sessions changing.
            self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconfigureVisible() }
            }
            return scroll
        }

        func stop() {
            self.timer?.invalidate()
            self.timer = nil
        }

        // MARK: Updates

        func update(model: SidebarModel, selectedKey: String?, actions: SidebarActions) {
            self.actions = actions
            self.selectedKey = selectedKey
            guard let outline else { return }
            if model != self.model || !self.hasLoaded {
                let old = self.model
                self.model = model
                self.rebuildIndex()
                let structure = { (model: SidebarModel) in model.groups.flatMap { [$0.header.id] + $0.entries.map(\.id) } }
                self.programmatic {
                    if !self.hasLoaded || structure(old) != structure(model) {
                        self.hasLoaded = true
                        outline.reloadData()
                    } else {
                        self.reconfigure(changedFrom: old)
                    }
                    self.applyExpansion()
                }
            }
            self.syncSelection()
        }

        private func rebuildIndex() {
            var nodes: [String: Node] = [:]
            func node(_ id: String) -> Node {
                let node = self.nodes[id] ?? Node(id)
                nodes[id] = node
                return node
            }
            self.headers = [:]
            self.entries = [:]
            self.children = [:]
            self.roots = self.model.groups.map { group in
                let header = node(group.header.id)
                self.headers[group.header.id] = group.header
                self.children[group.header.id] = group.entries.map { entry in
                    self.entries[entry.id] = entry
                    return node(entry.id)
                }
                return header
            }
            self.nodes = nodes
        }

        /// Same rows as before: refresh the ones that changed in place.
        private func reconfigure(changedFrom old: SidebarModel) {
            guard let outline else { return }
            let oldHeaders = Dictionary(old.groups.map { ($0.header.id, $0.header) }, uniquingKeysWith: { a, _ in a })
            let oldEntries = Dictionary(old.groups.flatMap(\.entries).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var resized = IndexSet()
            for (id, node) in self.nodes {
                let row = outline.row(forItem: node)
                guard row >= 0 else { continue }
                if let header = self.headers[id], header != oldHeaders[id] {
                    (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell)?
                        .configure(header, actions: self.actions)
                } else if let entry = self.entries[id], let previous = oldEntries[id], entry != previous {
                    (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarChatCell)?
                        .configure(entry, actions: self.actions)
                    if (entry.row.preview == nil) != (previous.row.preview == nil) { resized.insert(row) }
                }
            }
            if !resized.isEmpty { outline.noteHeightOfRows(withIndexesChanged: resized) }
        }

        private func reconfigureVisible() {
            guard let outline else { return }
            let visible = outline.rows(in: outline.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                guard let node = outline.item(atRow: row) as? Node, let entry = self.entries[node.id] else { continue }
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarChatCell)?
                    .configure(entry, actions: self.actions)
            }
        }

        private func applyExpansion() {
            guard let outline else { return }
            for root in self.roots {
                guard let header = self.headers[root.id] else { continue }
                if header.isCollapsed, outline.isItemExpanded(root) {
                    outline.collapseItem(root)
                } else if !header.isCollapsed, !outline.isItemExpanded(root) {
                    outline.expandItem(root)
                }
            }
        }

        private func syncSelection() {
            guard let outline else { return }
            let row = self.selectedKey.flatMap { self.nodes[SidebarModel.entryId($0)] }.map { outline.row(forItem: $0) } ?? -1
            guard row != outline.selectedRow else { return }
            self.programmatic {
                if row >= 0 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                } else {
                    outline.deselectAll(nil)
                }
            }
        }

        private func programmatic(_ body: () -> Void) {
            let was = self.isProgrammatic
            self.isProgrammatic = true
            body()
            self.isProgrammatic = was
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return self.roots.count }
            return self.children[node.id]?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return self.roots[index] }
            return self.children[node.id]?[index] ?? Node("")
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return self.headers[node.id] != nil
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return self.headers[node.id] != nil
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? Node else { return 24 }
            if self.headers[node.id] != nil { return 30 }
            // macOS 26 sidebars use roomier rows with rounded, inset selection.
            return self.entries[node.id]?.row.preview == nil ? 30 : 42
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if let header = self.headers[node.id] {
                let cell = outlineView.makeView(withIdentifier: SidebarHeaderCell.reuseIdentifier, owner: nil) as? SidebarHeaderCell
                    ?? SidebarHeaderCell()
                cell.configure(header, actions: self.actions)
                return cell
            }
            guard let entry = self.entries[node.id] else { return nil }
            let cell = outlineView.makeView(withIdentifier: SidebarChatCell.reuseIdentifier, owner: nil) as? SidebarChatCell
                ?? SidebarChatCell()
            cell.configure(entry, actions: self.actions)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return self.entries[node.id] != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !self.isProgrammatic, let outline else { return }
            guard outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? Node,
                  let entry = self.entries[node.id]
            else {
                // Clicking empty space doesn't close the open chat.
                self.syncSelection()
                return
            }
            self.selectedKey = entry.row.key
            self.actions.select(entry.row.key)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            self.expansionChanged(notification, collapsed: false)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            self.expansionChanged(notification, collapsed: true)
        }

        private func expansionChanged(_ notification: Notification, collapsed: Bool) {
            guard !self.isProgrammatic, let node = notification.userInfo?["NSObject"] as? Node,
                  let header = self.headers[node.id] else { return }
            self.actions.setCollapsed(header.section.id, collapsed)
            // The selected chat may have just come back into view.
            self.syncSelection()
        }

        // MARK: Drag and drop between groups

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node, let entry = self.entries[node.id], !entry.isThread, !entry.row.isSubagent else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(entry.row.key, forType: Self.dragType)
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation
        {
            guard let key = info.draggingPasteboard.string(forType: Self.dragType),
                  let target = self.headerNode(for: item), let header = self.headers[target.id],
                  self.gateway.groupDropValue(for: key, onto: header.section) != nil
            else { return [] }
            // Highlight the whole section rather than a gap between rows.
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let key = info.draggingPasteboard.string(forType: Self.dragType),
                  let target = self.headerNode(for: item), let header = self.headers[target.id],
                  self.gateway.groupDropValue(for: key, onto: header.section) != nil
            else { return false }
            Task { await self.gateway.moveToGroup(key, droppedOn: header.section) }
            return true
        }

        private func headerNode(for item: Any?) -> Node? {
            guard let node = item as? Node, let outline else { return nil }
            if self.headers[node.id] != nil { return node }
            return outline.parent(forItem: node) as? Node
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if let entry = self.entries[node.id] {
                SidebarMenuBuilder.populate(menu, SidebarMenus.chat(entry.row, gateway: self.gateway, actions: self.actions))
            } else if let header = self.headers[node.id] {
                SidebarMenuBuilder.populate(menu, SidebarMenus.header(header.section, gateway: self.gateway, actions: self.actions))
            }
        }
    }
}

// MARK: Cells

private final class SidebarChatCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarChatCell")

    private let threadArrow = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let preview = NSTextField(labelWithString: "")
    private let chip = NSButton()
    private let spinner = NSProgressIndicator()
    private let unreadDot = NSImageView()
    private let date = NSTextField(labelWithString: "")
    private var onToggleThreads: (() -> Void)?

    init() {
        super.init(frame: .zero)
        self.identifier = Self.reuseIdentifier

        self.threadArrow.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)
        self.threadArrow.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        self.threadArrow.contentTintColor = .tertiaryLabelColor
        self.icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        self.icon.setContentHuggingPriority(.required, for: .horizontal)
        self.icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        self.title.font = .systemFont(ofSize: NSFont.systemFontSize)
        self.title.lineBreakMode = .byTruncatingTail
        self.title.usesSingleLineMode = true
        self.title.maximumNumberOfLines = 1
        self.title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        self.pin.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        self.pin.contentTintColor = .tertiaryLabelColor
        self.preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        self.preview.textColor = .secondaryLabelColor
        self.preview.lineBreakMode = .byTruncatingTail
        self.preview.usesSingleLineMode = true
        self.preview.maximumNumberOfLines = 1
        self.preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        self.chip.bezelStyle = .inline
        self.chip.controlSize = .mini
        self.chip.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        self.chip.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        self.chip.imagePosition = .imageLeading
        self.chip.target = self
        self.chip.action = #selector(self.toggleThreads)
        self.spinner.style = .spinning
        self.spinner.controlSize = .mini
        self.spinner.isDisplayedWhenStopped = false
        self.unreadDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unread")
        self.unreadDot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        self.unreadDot.contentTintColor = .labelColor
        self.date.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        self.date.textColor = .tertiaryLabelColor
        for view in [self.chip, self.spinner, self.unreadDot, self.date] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let titleRow = NSStackView(views: [self.title, self.pin])
        titleRow.spacing = 4
        let text = NSStackView(views: [titleRow, self.preview])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Soaks up the free width so the accessories sit against the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [self.threadArrow, self.icon, text, spacer, self.chip, self.spinner, self.unreadDot, self.date])
        row.spacing = 7
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setCustomSpacing(0, after: text)
        row.setCustomSpacing(4, after: spacer)
        self.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
        self.textField = self.title
        self.imageView = self.icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(_ entry: SidebarModel.Entry, actions: SidebarActions) {
        let row = entry.row
        self.threadArrow.isHidden = !entry.isThread
        self.icon.image = NSImage(systemSymbolName: ChannelRowStyle.symbol(for: row, isThread: entry.isThread), accessibilityDescription: nil)
        self.icon.contentTintColor = ChannelRowStyle.tint(for: row)
        self.title.stringValue = row.title
        self.title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: row.isUnread && !row.isSubagent ? .semibold : .regular)
        self.title.textColor = row.isSubagent || row.isArchived ? .secondaryLabelColor : .labelColor
        self.pin.isHidden = !(row.isPinned && !entry.isThread)
        self.preview.stringValue = row.preview ?? ""
        self.preview.isHidden = row.preview == nil
        self.toolTip = ChannelRowStyle.help(for: row)

        let showChip = entry.showSubagentRuns && entry.subagentCount > 0
        self.chip.isHidden = !showChip
        if showChip {
            self.chip.title = "\(entry.subagentCount) \(entry.threadsExpanded ? "▴" : "▾")"
            self.chip.contentTintColor = entry.hiddenUnreadThreads > 0 ? .controlAccentColor : .secondaryLabelColor
            self.chip.toolTip = entry.threadsExpanded ? "Hide subagent runs" : "Show \(entry.subagentCount) subagent runs"
            let key = row.key
            self.onToggleThreads = { actions.toggleThreads(key) }
        }

        let working = row.hasActiveRun || (!entry.showSubagentRuns && entry.runningSubagents > 0)
        if working {
            self.spinner.startAnimation(nil)
            self.spinner.toolTip = row.hasActiveRun ? "Working" : "\(entry.runningSubagents) helper runs working"
        } else {
            self.spinner.stopAnimation(nil)
        }
        self.spinner.isHidden = !working
        self.unreadDot.isHidden = working || !(row.isUnread && !row.isSubagent)
        let activity = working || !self.unreadDot.isHidden ? nil : row.activityDate
        self.date.isHidden = activity == nil
        self.date.stringValue = activity.map(ChannelRowStyle.relativeDate) ?? ""

        var label = row.title
        if row.isUnread, !row.isSubagent { label += ", unread" }
        if working { label += ", working" }
        self.setAccessibilityLabel(label)
    }

    @objc private func toggleThreads() {
        self.onToggleThreads?()
    }
}

private final class SidebarHeaderCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")

    private let emoji = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let add = NSButton()
    private var onAdd: (() -> Void)?

    init() {
        super.init(frame: .zero)
        self.identifier = Self.reuseIdentifier
        self.emoji.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        self.icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        self.icon.contentTintColor = .secondaryLabelColor
        self.title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        self.title.textColor = .secondaryLabelColor
        self.title.lineBreakMode = .byTruncatingTail
        self.title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.badge.font = .systemFont(ofSize: 10, weight: .bold)
        self.badge.textColor = .white
        self.badge.alignment = .center
        self.badge.wantsLayer = true
        self.badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        self.badge.layer?.cornerRadius = 7
        self.badge.heightAnchor.constraint(equalToConstant: 14).isActive = true
        self.badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        self.add.bezelStyle = .accessoryBarAction
        self.add.isBordered = false
        self.add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New chat")
        self.add.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        self.add.contentTintColor = .secondaryLabelColor
        self.add.toolTip = "New chat"
        self.add.target = self
        self.add.action = #selector(self.addChat)
        for view in [self.emoji, self.icon, self.badge, self.add] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [self.emoji, self.icon, self.title, self.badge, spacer, self.add])
        row.spacing = 5
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 2),
            // Leaves room for the section's show/hide chevron.
            row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -22),
            row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
        self.textField = self.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(_ header: SidebarModel.Header, actions: SidebarActions) {
        let section = header.section
        self.emoji.stringValue = section.emoji ?? ""
        self.emoji.isHidden = section.emoji == nil
        let symbol = section.emoji == nil ? ChannelRowStyle.headerSymbol(for: section.kind) : nil
        self.icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        self.icon.isHidden = symbol == nil
        self.title.stringValue = section.title
        let unread = header.isCollapsed ? section.unreadCount : 0
        self.badge.stringValue = " \(unread) "
        self.badge.isHidden = unread == 0
        self.add.isHidden = header.newChatAgent == nil
        if let agent = header.newChatAgent {
            self.onAdd = { actions.newChat(agent) }
        }
    }

    @objc private func addChat() {
        self.onAdd?()
    }
}

// MARK: Menus

@MainActor
enum SidebarMenuBuilder {
    static func populate(_ menu: NSMenu, _ items: [SidebarMenuItem]) {
        for item in items {
            switch item {
            case .divider:
                menu.addItem(.separator())
            case let .action(title, image, checked, _, handler):
                let menuItem = ClosureMenuItem(title: title, handler: handler)
                menuItem.image = image.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                menuItem.state = checked ? .on : .off
                menu.addItem(menuItem)
            case let .submenu(title, image, children):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.image = image.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                let submenu = NSMenu(title: title)
                self.populate(submenu, children)
                menuItem.submenu = submenu
                menu.addItem(menuItem)
            }
        }
    }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        self.handler()
    }
}
/// The sidebar's filter field.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = self.prompt
        field.sendsSearchStringImmediately = true
        // The large size is the capsule field macOS 26 sidebars use (Messages, Mail, Notes).
        if #available(macOS 26, *) {
            field.controlSize = .large
        } else {
            field.controlSize = .regular
        }
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = self.$text
        if field.stringValue != self.text { field.stringValue = self.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: self.$text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            self.text.wrappedValue = field.stringValue
        }
    }
}

#endif
