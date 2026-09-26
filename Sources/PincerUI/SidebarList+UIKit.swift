#if os(iOS)
import PincerKit
import SwiftUI
import UIKit

/// Sidebar backed by a `UICollectionView` list: native rows, selection, collapsible sections,
/// swipe actions, context menus, pull to refresh, and drag and drop between groups.
struct SidebarList: UIViewRepresentable {
    let model: SidebarModel
    let selectedKey: String?
    let gateway: GatewayStore
    let actions: SidebarActions
    var theme = AppTheme()

    func makeCoordinator() -> Coordinator { Coordinator(gateway: self.gateway, actions: self.actions) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(model: self.model, selectedKey: self.selectedKey, actions: self.actions, theme: self.theme)
    }

    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        private let gateway: GatewayStore
        private var actions: SidebarActions
        private var model = SidebarModel()
        private var hasLoaded = false
        private var headers: [String: SidebarModel.Header] = [:]
        private var entries: [String: SidebarModel.Entry] = [:]
        private var selectedKey: String?
        private var isProgrammatic = false
        private var timer: Timer?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>?
        private weak var collectionView: UICollectionView?

        init(gateway: GatewayStore, actions: SidebarActions) {
            self.gateway = gateway
            self.actions = actions
        }

        func makeCollectionView() -> UICollectionView {
            let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
                var configuration = UICollectionLayoutListConfiguration(
                    appearance: environment.traitCollection.horizontalSizeClass == .compact ? .insetGrouped : .sidebar)
                configuration.headerMode = .firstItemInSection
                configuration.backgroundColor = .clear
                configuration.trailingSwipeActionsConfigurationProvider = { path in
                    MainActor.assumeIsolated { self?.trailingSwipe(path) }
                }
                configuration.leadingSwipeActionsConfigurationProvider = { path in
                    MainActor.assumeIsolated { self?.leadingSwipe(path) }
                }
                return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            }
            let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .clear
            view.delegate = self
            view.dragDelegate = self
            view.dropDelegate = self
            view.dragInteractionEnabled = true
            view.keyboardDismissMode = .onDrag
            view.allowsFocus = true
            view.selectionFollowsFocus = true

            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak self, weak refresh] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.actions.refresh()
                    refresh?.endRefreshing()
                }
            }, for: .valueChanged)
            view.refreshControl = refresh

            let header = UICollectionView.CellRegistration<SidebarHeaderListCell, String> { [weak self] cell, _, id in
                guard let self, let header = self.headers[id] else { return }
                cell.configure(header, actions: self.actions)
            }
            let chat = UICollectionView.CellRegistration<SidebarChatListCell, String> { [weak self] cell, _, id in
                guard let self, let entry = self.entries[id] else { return }
                cell.fill = self.rowFill
                cell.configure(entry, actions: self.actions)
            }
            let dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { [weak self] view, path, id in
                if self?.headers[id] != nil {
                    return view.dequeueConfiguredReusableCell(using: header, for: path, item: id)
                }
                return view.dequeueConfiguredReusableCell(using: chat, for: path, item: id)
            }
            dataSource.sectionSnapshotHandlers.willCollapseItem = { [weak self] id in
                self?.expansionChanged(id, collapsed: true)
            }
            dataSource.sectionSnapshotHandlers.willExpandItem = { [weak self] id in
                self?.expansionChanged(id, collapsed: false)
            }
            self.dataSource = dataSource
            self.collectionView = view

            // Relative times ("5m") move on without the sessions changing.
            self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconfigureVisible() }
            }
            return view
        }

        func stop() {
            self.timer?.invalidate()
            self.timer = nil
        }

        // MARK: Updates

        func update(model: SidebarModel, selectedKey: String?, actions: SidebarActions, theme: AppTheme) {
            self.actions = actions
            self.selectedKey = selectedKey
            if theme != self.theme {
                self.theme = theme
                self.themeChanged()
            }
            guard let dataSource else { return }
            if model != self.model || !self.hasLoaded {
                let old = self.model
                self.model = model
                self.rebuildIndex()
                self.programmatic {
                    self.apply(model, old: old, to: dataSource)
                }
                self.hasLoaded = true
            }
            self.syncSelection()
        }

        private func rebuildIndex() {
            self.headers = [:]
            self.entries = [:]
            for group in self.model.groups {
                self.headers[group.header.id] = group.header
                for entry in group.entries {
                    self.entries[entry.id] = entry
                }
            }
        }

        private func apply(_ model: SidebarModel, old: SidebarModel,
                           to dataSource: UICollectionViewDiffableDataSource<String, String>)
        {
            let animate = self.hasLoaded && self.collectionView?.window != nil
            let sections = model.groups.map(\.header.id)
            if dataSource.snapshot().sectionIdentifiers != sections {
                var snapshot = NSDiffableDataSourceSnapshot<String, String>()
                snapshot.appendSections(sections)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            let oldGroups = Dictionary(old.groups.map { ($0.header.id, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [String] = []
            for group in model.groups {
                let id = group.header.id
                let previous = oldGroups[id]
                let current = dataSource.snapshot(for: id)
                let structure = [id] + group.entries.map(\.id)
                if current.items != structure || current.isExpanded(id) == group.header.isCollapsed {
                    var section = NSDiffableDataSourceSectionSnapshot<String>()
                    section.append([id])
                    section.append(group.entries.map(\.id), to: id)
                    if group.header.isCollapsed { section.collapse([id]) } else { section.expand([id]) }
                    dataSource.apply(section, to: id, animatingDifferences: animate && previous != nil)
                }
                if let previous {
                    if previous.header != group.header { changed.append(id) }
                    let before = Dictionary(previous.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    for entry in group.entries where before[entry.id].map({ $0 != entry }) ?? false {
                        changed.append(entry.id)
                    }
                }
            }
            self.reconfigure(changed)
        }

        /// Refreshes rows in place. Cells size themselves, so a preview appearing or going away
        /// resizes its row.
        private func reconfigure(_ ids: [String]) {
            guard let view = self.collectionView, let dataSource else { return }
            for id in ids {
                guard let path = dataSource.indexPath(for: id), let cell = view.cellForItem(at: path) else { continue }
                if let header = self.headers[id], let cell = cell as? SidebarHeaderListCell {
                    cell.configure(header, actions: self.actions)
                } else if let entry = self.entries[id], let cell = cell as? SidebarChatListCell {
                    cell.fill = self.rowFill
                    cell.configure(entry, actions: self.actions)
                }
            }
        }

        private var theme = AppTheme()

        /// Grouped rows on iPhone sit on cards. With a themed sidebar the stock gray card clashes,
        /// so the card is the sidebar color raised a little.
        private var rowFill: UIColor? {
            guard let base = self.theme.platformColor(.sidebarBackground) else { return nil }
            return UIColor { traits in
                let color = base.resolvedColor(with: traits)
                return traits.userInterfaceStyle == .dark ? color.mixed(with: .white, amount: 0.07)
                    : color.mixed(with: .white, amount: 0.7)
            }
        }

        private func themeChanged() {
            self.collectionView?.tintColor = self.theme.platformColor(.accent)
            self.reconfigureVisible()
        }

        private func reconfigureVisible() {
            guard let view = self.collectionView, let dataSource else { return }
            self.reconfigure(view.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
        }

        private var isCompact: Bool {
            self.collectionView?.traitCollection.horizontalSizeClass == .compact
        }

        /// On iPad the open chat stays highlighted. On iPhone choosing a chat pushes it, and the
        /// list comes back with nothing selected, as in other iOS apps.
        private func syncSelection() {
            guard let view = self.collectionView, let dataSource else { return }
            let target = self.isCompact ? nil : self.selectedKey.flatMap { dataSource.indexPath(for: SidebarModel.entryId($0)) }
            let current = view.indexPathsForSelectedItems ?? []
            guard current != (target.map { [$0] } ?? []) else { return }
            self.programmatic {
                for path in current where path != target { view.deselectItem(at: path, animated: false) }
                if let target { view.selectItem(at: target, animated: false, scrollPosition: []) }
            }
        }

        private func programmatic(_ body: () -> Void) {
            let was = self.isProgrammatic
            self.isProgrammatic = true
            body()
            self.isProgrammatic = was
        }

        private func expansionChanged(_ id: String, collapsed: Bool) {
            guard !self.isProgrammatic, let header = self.headers[id] else { return }
            self.actions.setCollapsed(header.section.id, collapsed)
        }

        private func entry(at path: IndexPath) -> SidebarModel.Entry? {
            self.dataSource?.itemIdentifier(for: path).flatMap { self.entries[$0] }
        }

        // MARK: Selection

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            self.entry(at: indexPath) != nil
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !self.isProgrammatic, let entry = self.entry(at: indexPath) else { return }
            self.selectedKey = entry.row.key
            self.actions.select(entry.row.key)
            if self.isCompact {
                collectionView.deselectItem(at: indexPath, animated: true)
            }
        }

        func collectionView(_ collectionView: UICollectionView, shouldDeselectItemAt indexPath: IndexPath) -> Bool {
            // Tapping the open chat again keeps it open.
            self.isCompact
        }

        // MARK: Swipe actions

        private func trailingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
            guard let entry = self.entry(at: path), !entry.row.isMain else { return nil }
            let row = entry.row
            let archive = UIContextualAction(style: row.isArchived ? .normal : .destructive,
                                             title: row.isArchived ? "Unarchive" : "Archive") { [gateway] _, _, done in
                Task { @MainActor in
                    await gateway.patch(row.key, ["archived": .bool(!row.isArchived)])
                    done(true)
                }
            }
            archive.image = UIImage(systemName: "archivebox")
            archive.backgroundColor = .systemIndigo
            return UISwipeActionsConfiguration(actions: [archive])
        }

        private func leadingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
            guard let entry = self.entry(at: path) else { return nil }
            let row = entry.row
            let read = UIContextualAction(style: .normal, title: row.isUnread ? "Read" : "Unread") { [gateway] _, _, done in
                Task { @MainActor in
                    await gateway.patch(row.key, ["unread": .bool(!row.isUnread)])
                }
                done(true)
            }
            read.image = UIImage(systemName: row.isUnread ? "envelope.open" : "envelope.badge")
            read.backgroundColor = .systemBlue
            let pin = UIContextualAction(style: .normal, title: row.isPinned ? "Unpin" : "Pin") { [gateway] _, _, done in
                Task { @MainActor in
                    await gateway.patch(row.key, ["pinned": .bool(!row.isPinned)])
                }
                done(true)
            }
            pin.image = UIImage(systemName: row.isPinned ? "pin.slash" : "pin")
            pin.backgroundColor = .systemOrange
            return UISwipeActionsConfiguration(actions: entry.isThread ? [read] : [read, pin])
        }

        // MARK: Context menu

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration?
        {
            guard indexPaths.count == 1, let id = self.dataSource?.itemIdentifier(for: indexPaths[0]) else { return nil }
            let items: [SidebarMenuItem]
            if let entry = self.entries[id] {
                items = SidebarMenus.chat(entry.row, gateway: self.gateway, actions: self.actions)
            } else if let header = self.headers[id] {
                items = SidebarMenus.header(header.section, gateway: self.gateway, actions: self.actions)
            } else {
                return nil
            }
            guard !items.isEmpty else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                SidebarMenuBuilder.menu(items)
            }
        }

        // MARK: Drag and drop

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem]
        {
            guard let id = self.dataSource?.itemIdentifier(for: indexPath) else { return [] }
            let payload: SidebarDragPayload
            let type: String
            let value: String
            if let header = self.headers[id] {
                guard case let .group(name) = header.section.kind else { return [] }
                (payload, type, value) = (.group(name), SidebarDrag.groupTypeIdentifier, name)
            } else if let entry = self.entries[id], !entry.isThread, !entry.row.isSubagent {
                (payload, type, value) = (.chat(entry.row.key), SidebarDrag.typeIdentifier, entry.row.key)
            } else {
                return []
            }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
                completion(Data(value.utf8), nil)
                return nil
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = payload
            return [item]
        }

        func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
            session.localDragSession?.items.first?.localObject is SidebarDragPayload
        }

        /// Where a drop lands.
        private enum Drop {
            case group(String, before: String?)
            case chatInGroup(String, group: String, before: String?)
            case chatOnSection(String, SidebarSection)

            var isInsertion: Bool {
                if case .chatOnSection = self { return false }
                return true
            }
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal
        {
            guard let drop = self.drop(session, destinationIndexPath) else {
                return UICollectionViewDropProposal(operation: .forbidden)
            }
            return UICollectionViewDropProposal(operation: .move,
                                                intent: drop.isInsertion ? .insertAtDestinationIndexPath : .insertIntoDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            switch self.drop(coordinator.session, coordinator.destinationIndexPath) {
            case let .group(name, before):
                Task { await self.gateway.moveGroup(name, before: before) }
            case let .chatInGroup(key, group, before):
                Task { await self.gateway.moveChat(key, toGroup: group, before: before) }
            case let .chatOnSection(key, section):
                Task { await self.gateway.moveToGroup(key, droppedOn: section) }
            case nil:
                break
            }
        }

        private func drop(_ session: UIDropSession, _ path: IndexPath?) -> Drop? {
            guard let payload = session.localDragSession?.items.first?.localObject as? SidebarDragPayload, let path,
                  let group = self.model.groups[safe: path.section]
            else { return nil }
            switch payload {
            case let .group(name):
                let names = self.model.groupNamesInOrder
                guard let source = names.firstIndex(of: name) else { return nil }
                // Sections before the first group land in front of it; sections after the last one, at the end.
                let groupsBefore = self.model.groups[..<path.section].filter {
                    if case .group = $0.header.section.kind { return true }
                    return false
                }.count
                var target = groupsBefore
                if case .group = group.header.section.kind, groupsBefore > source { target += 1 }
                return .group(name, before: names[safe: target])
            case let .chat(key):
                guard let row = self.gateway.sessions[key], !row.isSubagent else { return nil }
                if case let .group(name) = group.header.section.kind, !group.header.isCollapsed, path.item > 0 {
                    return .chatInGroup(key, group: name,
                                        before: SidebarModel.chat(atOrAfter: path.item - 1, in: group.entries, excluding: key))
                }
                guard self.gateway.groupDropValue(for: key, onto: group.header.section) != nil else { return nil }
                return .chatOnSection(key, group.header.section)
            }
        }
    }
}

private extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: a1 + (a2 - a1) * amount)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: Cells

private final class SidebarChatListCell: UICollectionViewListCell {
    private let chip = UIButton(configuration: .plain())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let unreadDot = UIImageView(image: UIImage(systemName: "circle.fill"))
    private var onToggleThreads: (() -> Void)?
    var fill: UIColor? {
        didSet { if fill != oldValue { self.setNeedsUpdateConfiguration() } }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        var background = self.defaultBackgroundConfiguration().updated(for: state)
        if let fill, !state.isSelected, !state.isHighlighted, !state.isSwiped {
            background.backgroundColor = fill
        }
        self.backgroundConfiguration = background
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        var chip = UIButton.Configuration.plain()
        chip.image = UIImage(systemName: "sparkles")
        chip.imagePadding = 3
        chip.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption2)
        chip.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        chip.background.backgroundColor = .tertiarySystemFill
        chip.cornerStyle = .capsule
        self.chip.configuration = chip
        self.chip.addAction(UIAction { [weak self] _ in self?.onToggleThreads?() }, for: .primaryActionTriggered)
        self.spinner.hidesWhenStopped = false
        self.spinner.sizeToFit()
        self.unreadDot.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10)
        self.unreadDot.contentMode = .center
        self.unreadDot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        self.unreadDot.tintColor = .tintColor
        self.unreadDot.accessibilityLabel = "Unread"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: SidebarModel.Entry, actions: SidebarActions) {
        let row = entry.row
        var content = self.traitCollection.horizontalSizeClass == .compact
            ? UIListContentConfiguration.subtitleCell()
            : UIListContentConfiguration.sidebarSubtitleCell()
        let symbol = ChannelRowStyle.symbol(for: entry)
        content.image = UIImage(systemName: symbol) ?? UIImage(systemName: "number")
        content.imageProperties.tintColor = ChannelRowStyle.tint(for: entry)
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        content.imageProperties.reservedLayoutSize = CGSize(width: 26, height: 0)

        let unread = row.isUnread && !row.isSubagent
        let font = UIFont.preferredFont(forTextStyle: .body)
        let titleFont = unread
            ? UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: 0)
            : font
        let titleColor: UIColor = row.isSubagent || row.isArchived ? .secondaryLabel : .label
        let title = NSMutableAttributedString(string: row.title, attributes: [.font: titleFont, .foregroundColor: titleColor])
        if row.isPinned, !entry.isThread,
           let pin = UIImage(systemName: "pin.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2))?
               .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        {
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(attachment: NSTextAttachment(image: pin)))
        }
        content.attributedText = title
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingTail
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryText = entry.preview
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingTail
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textToSecondaryTextVerticalPadding = 2
        if entry.isThread {
            // Threads sit under their channel.
            content.directionalLayoutMargins.leading += 22
        }
        self.contentConfiguration = content

        var accessories: [UICellAccessory] = []
        let showChip = entry.showSubagentRuns && entry.subagentCount > 0
        if showChip {
            var chip = self.chip.configuration ?? .plain()
            var title = AttributedString("\(entry.subagentCount)")
            title.font = .preferredFont(forTextStyle: .caption1)
            chip.attributedTitle = title
            chip.baseForegroundColor = entry.hiddenUnreadThreads > 0 ? .tintColor : .secondaryLabel
            self.chip.configuration = chip
            self.chip.accessibilityLabel = entry.threadsExpanded ? "Hide subagent runs" : "Show \(entry.subagentCount) subagent runs"
            let key = row.key
            self.onToggleThreads = { actions.toggleThreads(key) }
            self.chip.sizeToFit()
            accessories.append(.customView(configuration: .init(customView: self.chip, placement: .trailing(),
                                                                reservedLayoutWidth: .actual, maintainsFixedSize: true)))
        }
        let working = row.hasActiveRun || (!entry.showSubagentRuns && entry.runningSubagents > 0)
        if working {
            self.spinner.startAnimating()
            self.spinner.accessibilityLabel = row.hasActiveRun ? "Working" : "\(entry.runningSubagents) helper runs working"
            accessories.append(.customView(configuration: .init(customView: self.spinner, placement: .trailing(),
                                                                reservedLayoutWidth: .actual, maintainsFixedSize: true)))
        } else {
            self.spinner.stopAnimating()
            if unread {
                accessories.append(.customView(configuration: .init(customView: self.unreadDot, placement: .trailing(),
                                                                    reservedLayoutWidth: .actual, maintainsFixedSize: true)))
            } else if let date = row.activityDate {
                accessories.append(.label(text: ChannelRowStyle.relativeDate(date),
                                          options: .init(tintColor: .tertiaryLabel, font: .preferredFont(forTextStyle: .caption1))))
            }
        }
        self.accessories = accessories

        var label = row.title
        if row.isPinned { label += ", pinned" }
        if unread { label += ", unread" }
        if working { label += ", working" }
        if let preview = entry.preview { label += ", \(preview)" }
        self.accessibilityLabel = label
        self.accessibilityHint = ChannelRowStyle.help(for: row)
        self.accessibilityTraits.insert(.button)
    }
}

private final class SidebarHeaderListCell: UICollectionViewListCell {
    private let badge = UILabel()
    private let add = UIButton(configuration: .plain())
    private var onAdd: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        self.badge.textColor = .white
        self.badge.textAlignment = .center
        self.badge.backgroundColor = .systemRed
        self.badge.layer.cornerRadius = 9
        self.badge.layer.masksToBounds = true
        var add = UIButton.Configuration.plain()
        add.image = UIImage(systemName: "plus")
        add.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        add.baseForegroundColor = .secondaryLabel
        add.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        self.add.configuration = add
        self.add.accessibilityLabel = "New chat"
        self.add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .primaryActionTriggered)
        self.add.sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ header: SidebarModel.Header, actions: SidebarActions) {
        let section = header.section
        var content = self.traitCollection.horizontalSizeClass == .compact
            ? UIListContentConfiguration.groupedHeader()
            : UIListContentConfiguration.sidebarHeader()
        let title = section.emoji.map { "\($0)  \(section.title)" } ?? section.title
        content.text = title
        content.textProperties.numberOfLines = 1
        if let symbol = header.symbol {
            content.image = UIImage(systemName: symbol)
            content.imageProperties.tintColor = .secondaryLabel
        }
        self.contentConfiguration = content

        var accessories: [UICellAccessory] = []
        let unread = header.isCollapsed ? section.unreadCount : 0
        if unread > 0 {
            self.badge.text = "\(unread)"
            let width = max(18, ceil(self.badge.intrinsicContentSize.width) + 10)
            self.badge.frame = CGRect(x: 0, y: 0, width: width, height: 18)
            self.badge.accessibilityLabel = "\(unread) unread"
            accessories.append(.customView(configuration: .init(customView: self.badge, placement: .trailing(),
                                                                reservedLayoutWidth: .custom(width), maintainsFixedSize: true)))
        }
        if let agent = header.newChatAgent {
            self.onAdd = { actions.newChat(agent) }
            accessories.append(.customView(configuration: .init(customView: self.add, placement: .trailing(),
                                                                reservedLayoutWidth: .actual, maintainsFixedSize: true)))
        }
        accessories.append(.outlineDisclosure(options: .init(style: .header)))
        self.accessories = accessories
    }
}

// MARK: Menus

@MainActor
enum SidebarMenuBuilder {
    static func menu(_ items: [SidebarMenuItem]) -> UIMenu {
        // Dividers split the items into inline groups.
        var groups: [[UIMenuElement]] = [[]]
        for item in items {
            switch item {
            case .divider:
                groups.append([])
            case let .action(title, image, checked, destructive, handler):
                let action = UIAction(title: title, image: image.flatMap { UIImage(systemName: $0) }) { _ in handler() }
                action.state = checked ? .on : .off
                if destructive { action.attributes = .destructive }
                groups[groups.count - 1].append(action)
            case let .submenu(title, image, children):
                let submenu = self.menu(children)
                groups[groups.count - 1].append(UIMenu(title: title, image: image.flatMap { UIImage(systemName: $0) },
                                                       children: submenu.children))
            }
        }
        let nonEmpty = groups.filter { !$0.isEmpty }
        if nonEmpty.count == 1 { return UIMenu(children: nonEmpty[0]) }
        return UIMenu(children: nonEmpty.map { UIMenu(options: .displayInline, children: $0) })
    }
}
#endif
