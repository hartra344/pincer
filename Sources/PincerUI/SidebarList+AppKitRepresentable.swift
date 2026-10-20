#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Sidebar backed by a source-list `NSOutlineView`: native rows, selection, keyboard navigation,
/// collapsible sections, context menus, and drag and drop between groups.
extension SidebarList: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(gateway: self.gateway, actions: self.actions) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(model: self.model, selectedKey: self.selectedKey, actions: self.actions, theme: self.theme)
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
        private let controller = SidebarController()
        private var nodes: [String: Node] = [:]
        private var children: [String: [Node]] = [:]
        private var roots: [Node] = []
        /// NSOutlineView won't expand or collapse a row without an outline cell, so headers
        /// report one only while we change their expansion.
        private var allowsHeaderOutlineCell = false
        /// A keyboard-focused header occupies the native selected row, but never changes the
        /// Gateway's selected chat. Mouse selection continues to reject headers.
        private var keyboardFocusedHeaderID: String?
        private var theme = AppTheme()
        private var timer: Timer?
        private var headers: [String: SidebarModel.Header] { self.controller.headers }
        private var entries: [String: SidebarModel.Entry] { self.controller.entries }
        private weak var outline: NSOutlineView?

        private static let dragType = NSPasteboard.PasteboardType(SidebarDrag.typeIdentifier)
        private static let groupDragType = NSPasteboard.PasteboardType(SidebarDrag.groupTypeIdentifier)

        init(gateway: GatewayStore, actions: SidebarActions) {
            self.gateway = gateway
            self.actions = actions
        }

        func makeScrollView() -> NSScrollView {
            let outline = SidebarOutlineView()
            outline.hidesOutlineCell = { [weak self, weak outline] row in
                guard let node = outline?.item(atRow: row) as? Node else { return false }
                return self?.headers[node.id]?.isSubsection == true
            }
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
            outline.registerForDraggedTypes([Self.dragType, Self.groupDragType])
            outline.setDraggingSourceOperationMask(.move, forLocal: true)
            outline.draggingDestinationFeedbackStyle = .sourceList
            let menu = NSMenu()
            menu.delegate = self
            outline.menu = menu
            // Double-click or ⌘-click opens the chat in a window of its own (#48).
            outline.target = self
            outline.doubleAction = #selector(self.openClickedInNewWindow)
            outline.commandClick = { [weak self] row in self?.openInNewWindow(row: row) ?? false }
            outline.keyboardCommand = { [weak self, weak outline] event in
                guard let self, let outline else { return .pass }
                return self.keyboardCommand(event, in: outline)
            }

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

        func update(model: SidebarModel, selectedKey: String?, actions: SidebarActions, theme: AppTheme) {
            self.actions = actions
            if self.controller.selectedKey != selectedKey { self.keyboardFocusedHeaderID = nil }
            self.controller.selectedKey = selectedKey
            if theme != self.theme {
                self.theme = theme
                self.themeChanged()
            }
            guard let outline else { return }
            if let update = self.controller.accept(model: model) {
                self.rebuildIndex()
                if let focused = self.keyboardFocusedHeaderID, self.headers[focused] == nil {
                    self.keyboardFocusedHeaderID = nil
                }
                self.programmatic {
                    if update.isInitial {
                        self.controller.markLoaded()
                        outline.reloadData()
                    } else if SidebarModel.structureChanged(old: update.old, new: model) {
                        // A few rows in or out keep every other row's view; a reload makes them all again.
                        if let edits = SidebarModel.rowEdits(old: update.old.placements, new: model.placements),
                           edits.keys.allSatisfy({ $0.isEmpty || self.nodes[$0] != nil }) {
                            outline.beginUpdates()
                            for (parent, edit) in edits {
                                let node = parent.isEmpty ? nil : self.nodes[parent]
                                if !edit.removed.isEmpty { outline.removeItems(at: edit.removed, inParent: node, withAnimation: []) }
                                if !edit.inserted.isEmpty { outline.insertItems(at: edit.inserted, inParent: node, withAnimation: []) }
                            }
                            outline.endUpdates()
                            self.reconfigure(changedFrom: update.old)
                        } else {
                            self.controller.markLoaded()
                            outline.reloadData()
                        }
                    } else {
                        self.reconfigure(changedFrom: update.old)
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
            self.children = [:]
            func index(_ group: SidebarModel.Group) -> Node {
                let header = node(group.header.id)
                func entryNodes(_ list: [SidebarModel.Entry]) -> [Node] { list.map { node($0.id) } }
                self.children[group.header.id] = entryNodes(group.leadingEntries) + group.subgroups.map(index)
                    + entryNodes(group.entries)
                return header
            }
            self.roots = self.controller.model.groups.map(index)
            self.nodes = nodes
        }

        /// Same rows as before: refresh the ones that changed in place.
        private func reconfigure(changedFrom old: SidebarModel) {
            guard let outline else { return }
            let oldEntries = Dictionary(old.groups.flatMap(\.allEntries).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var resized = IndexSet()
            for id in SidebarModel.changedRowKeys(old: old, new: self.controller.model) {
                guard let node = self.nodes[id] else { continue }
                let row = outline.row(forItem: node)
                guard row >= 0 else { continue }
                if let header = self.headers[id] {
                    (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell)?
                        .configure(header, actions: self.actions) { [weak self] in self?.toggle(id) }
                } else if let entry = self.entries[id], let previous = oldEntries[id] {
                    (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarChatCell)?
                        .configure(entry, actions: self.actions)
                    if (entry.preview == nil) != (previous.preview == nil) { resized.insert(row) }
                }
            }
            if !resized.isEmpty { outline.noteHeightOfRows(withIndexesChanged: resized) }
        }

        private func themeChanged() {
            guard let outline else { return }
            self.reconfigureVisible()
            outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
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
            self.allowsHeaderOutlineCell = true
            defer { self.allowsHeaderOutlineCell = false }
            self.applyExpansion(to: self.roots)
        }

        /// Headers are expanded parent first, then their nested headers, so a group stays as the
        /// user left it when its agent is collapsed and opened again.
        private func applyExpansion(to nodes: [Node]) {
            guard let outline else { return }
            for node in nodes {
                guard let header = self.headers[node.id] else { continue }
                if header.isCollapsed, outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                } else if !header.isCollapsed {
                    if !outline.isItemExpanded(node) { outline.expandItem(node) }
                    self.applyExpansion(to: self.children[node.id] ?? [])
                }
            }
        }

        private func syncSelection() {
            guard let outline else { return }
            if let focused = self.keyboardFocusedHeaderID {
                let row = self.nodes[focused].map { outline.row(forItem: $0) } ?? -1
                guard row >= 0 else {
                    self.keyboardFocusedHeaderID = nil
                    // The focused header may have disappeared or become hidden inside a collapsed parent.
                    return self.syncSelection()
                }
                if row != outline.selectedRow {
                    guard let keyboardOutline = outline as? SidebarOutlineView else { return }
                    self.programmatic {
                        keyboardOutline.allowsKeyboardHeaderSelection = true
                        defer { keyboardOutline.allowsKeyboardHeaderSelection = false }
                        outline.selectRowIndexes([row], byExtendingSelection: false)
                    }
                }
                return
            }
            let row = self.controller.selectionTarget().flatMap { self.nodes[$0] }.map { outline.row(forItem: $0) } ?? -1
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

        private func programmatic(_ body: () -> Void) { self.controller.programmatic(body) }

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

        /// Only top-level headers get source-list group styling; nested groups are ordinary rows.
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let node = item as? Node, let header = self.headers[node.id] else { return false }
            return !header.isSubsection
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? Node else { return 24 }
            if self.headers[node.id] != nil { return 30 }
            // macOS 26 sidebars use roomier rows with rounded, inset selection.
            return self.entries[node.id]?.preview == nil ? 30 : 42
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if let header = self.headers[node.id] {
                let cell = outlineView.makeView(withIdentifier: SidebarHeaderCell.reuseIdentifier, owner: nil) as? SidebarHeaderCell
                    ?? SidebarHeaderCell()
                let id = node.id
                cell.configure(header, actions: self.actions) { [weak self] in self?.toggle(id) }
                return cell
            }
            guard let entry = self.entries[node.id] else { return nil }
            let cell = outlineView.makeView(withIdentifier: SidebarChatCell.reuseIdentifier, owner: nil) as? SidebarChatCell
                ?? SidebarChatCell()
            cell.configure(entry, actions: self.actions)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            SidebarRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return self.entries[node.id] != nil
                || ((outlineView as? SidebarOutlineView)?.allowsKeyboardHeaderSelection == true && self.headers[node.id] != nil)
        }

        /// Headers draw their own always-visible chevron (#239). The native one only appears on
        /// hover and pushes the + button aside when it does.
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = item as? Node else { return true }
            // Nested group headers keep their outline cell so they expand and collapse (and answer
            // the arrow keys), but SidebarOutlineView never lets its triangle show.
            return self.allowsHeaderOutlineCell || self.headers[node.id] == nil || self.headers[node.id]?.isSubsection == true
        }

        private func toggle(_ id: String) {
            guard let outline, let node = self.nodes[id] else { return }
            self.allowsHeaderOutlineCell = true
            defer { self.allowsHeaderOutlineCell = false }
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !self.controller.isProgrammatic, let outline else { return }
            let node = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Node : nil
            if let node, self.headers[node.id] != nil {
                self.keyboardFocusedHeaderID = node.id
                return
            }
            self.keyboardFocusedHeaderID = nil
            guard let key = self.controller.userSelected(node.flatMap { self.entries[$0.id] }) else {
                // Clicking empty space doesn't close the open chat.
                self.syncSelection()
                return
            }
            self.actions.select(key)
        }

        /// Native outline row navigation is unchanged, except that it may land on a header.
        /// Disclosure keys and + are handled only when the selected row is a keyboard-focused header.
        private func keyboardCommand(_ event: NSEvent, in outline: SidebarOutlineView) -> SidebarOutlineView.KeyboardHandling {
            let node = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Node : nil
            let focusedHeader = node.flatMap { self.headers[$0.id] }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            switch event.keyCode {
            case 126, 125: // Up / Down: allow native row navigation to land on headers.
                return modifiers.isEmpty ? .nativeNavigation : .pass
            case 123, 124: // Left / Right
                guard modifiers.isEmpty else { return .pass }
                guard let node, focusedHeader != nil, let headerNode = self.nodes[node.id] else {
                    return .nativeNavigation
                }
                if event.keyCode == 123 {
                    if outline.isItemExpanded(headerNode) { self.toggle(node.id) }
                    return .handled
                }
                if !outline.isItemExpanded(headerNode) {
                    self.toggle(node.id)
                    return .handled
                }
                return .nativeNavigation
            case 36, 76: // Return / keypad Enter
                guard modifiers.isEmpty, let node, focusedHeader != nil else { return .pass }
                self.toggle(node.id)
                return .handled
            default:
                break
            }

            // The literal plus is local to the focused header. It does not replace the app's
            // user-configurable New Chat shortcut (⌘N) or intercept composer input.
            guard let node, let header = focusedHeader,
                  event.characters == "+", modifiers == .shift else { return .pass }
            header.addAction(self.actions)?()
            return .handled
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            self.expansionChanged(notification, collapsed: false)
            // Nested groups come back in their own state.
            if let node = notification.userInfo?["NSObject"] as? Node, let children = self.children[node.id] {
                self.allowsHeaderOutlineCell = true
                self.programmatic { self.applyExpansion(to: children) }
                self.allowsHeaderOutlineCell = false
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            self.expansionChanged(notification, collapsed: true)
        }

        private func expansionChanged(_ notification: Notification, collapsed: Bool) {
            guard let node = notification.userInfo?["NSObject"] as? Node,
                  let section = self.controller.sectionToggled(headerId: node.id) else { return }
            self.actions.setCollapsed(section, collapsed)
            // The selected chat may have just come back into view.
            self.syncSelection()
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            guard let payload = self.controller.dragPayload(forId: node.id) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(payload.value, forType: NSPasteboard.PasteboardType(payload.typeIdentifier))
            return pasteboardItem
        }

        /// Where a drop lands once retargeted.
        private enum Drop {
            /// A group moved in front of another group, or to the end.
            case group(String, before: String?, rootIndex: Int)
            /// A chat placed at a position in a group.
            case chatInGroup(String, header: Node, group: String, childIndex: Int)
            /// A chat dropped on a section as a whole.
            case chatOnSection(String, header: Node, SidebarSection)
        }

        private func drop(_ info: NSDraggingInfo, item: Any?, index: Int) -> Drop? {
            let pasteboard = info.draggingPasteboard
            if let name = pasteboard.string(forType: Self.groupDragType) {
                return self.groupDrop(name, item: item, index: index)
            }
            guard let key = pasteboard.string(forType: Self.dragType), let row = self.gateway.sessions[key]
            else { return nil }
            // Between sections: the end of the section above.
            if item == nil {
                guard index > 0, let above = self.roots[safe: index - 1], let header = self.headers[above.id],
                      case let .group(group) = header.section.kind, !header.isCollapsed
                else { return nil }
                return .chatInGroup(key, header: above, group: group, childIndex: self.children[above.id]?.count ?? 0)
            }
            guard let target = self.headerNode(for: item), let header = self.headers[target.id] else { return nil }
            if let group = SidebarController.groupAccepting(row, in: header) {
                if let node = item as? Node, node !== target {
                    // Dropped on a chat: go in front of it, or after it when moving down its own group.
                    guard var childIndex = self.children[target.id]?.firstIndex(where: { $0 === node }) else { return nil }
                    let current = self.children[target.id]?.firstIndex { self.entries[$0.id]?.row.key == key }
                    if let current, current < childIndex { childIndex += 1 }
                    return .chatInGroup(key, header: target, group: group, childIndex: childIndex)
                }
                if index >= 0 {
                    return .chatInGroup(key, header: target, group: group, childIndex: index)
                }
            }
            guard case .chatOnSection = SidebarController.dropOnSection(key, header.section, gateway: self.gateway) else { return nil }
            return .chatOnSection(key, header: target, header.section)
        }

        private func groupDrop(_ name: String, item: Any?, index: Int) -> Drop? {
            let roots = self.roots.compactMap { self.headers[$0.id] }
            guard roots.count == self.roots.count else { return nil }
            let target = self.headerNode(for: item)
            let reorder = SidebarController.groupReorder(name, among: roots) { source in
                guard item != nil else { return index >= 0 ? index : nil }
                guard let target, let targetIndex = self.roots.firstIndex(where: { $0 === target }) else { return nil }
                return targetIndex > source ? targetIndex + 1 : targetIndex
            }
            guard let reorder, case let .group(_, before) = reorder.drop else { return nil }
            return .group(name, before: before, rootIndex: reorder.rootIndex)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation
        {
            switch self.drop(info, item: item, index: index) {
            case let .group(_, _, rootIndex):
                outlineView.setDropItem(nil, dropChildIndex: rootIndex)
            case let .chatInGroup(_, header, _, childIndex):
                outlineView.setDropItem(header, dropChildIndex: childIndex)
            case let .chatOnSection(_, header, _):
                // Highlight the whole section rather than a gap between rows.
                outlineView.setDropItem(header, dropChildIndex: NSOutlineViewDropOnItemIndex)
            case nil:
                return []
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            switch self.drop(info, item: item, index: index) {
            case let .group(name, before, _):
                SidebarController.perform(.group(name, before: before), gateway: self.gateway)
            case let .chatInGroup(key, header, group, childIndex):
                let entries = (self.children[header.id] ?? []).compactMap { self.entries[$0.id] }
                let before = SidebarModel.chat(atOrAfter: childIndex, in: entries, excluding: key)
                SidebarController.perform(.chatInGroup(key, group: group, before: before), gateway: self.gateway)
            case let .chatOnSection(key, _, section):
                SidebarController.perform(.chatOnSection(key, section), gateway: self.gateway,
                                          expandThreads: self.actions.expandThreads)
            case nil:
                return false
            }
            return true
        }

        private func headerNode(for item: Any?) -> Node? {
            guard let node = item as? Node, let outline else { return nil }
            if self.headers[node.id] != nil { return node }
            return outline.parent(forItem: node) as? Node
        }

        @objc private func openClickedInNewWindow() {
            guard let outline else { return }
            _ = self.openInNewWindow(row: outline.clickedRow)
        }

        private func openInNewWindow(row: Int) -> Bool {
            guard let open = self.actions.openInNewWindow, let outline, row >= 0,
                  let node = outline.item(atRow: row) as? Node, let entry = self.entries[node.id]
            else { return false }
            open(entry.row.key)
            return true
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if let entry = self.entries[node.id] {
                SidebarMenuBuilder.populate(menu, SidebarMenus.chat(entry.row, gateway: self.gateway,
                                                                     organization: self.gateway.organization,
                                                                     actions: self.actions))
            } else if let header = self.headers[node.id] {
                SidebarMenuBuilder.populate(menu, SidebarMenus.header(header.section, gateway: self.gateway, actions: self.actions))
            }
        }
    }
}

#endif
