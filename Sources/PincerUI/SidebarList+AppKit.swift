#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

// MARK: Cells

final class SidebarChatCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarChatCell")

    private let threadArrow = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let preview = NSTextField(labelWithString: "")
    private let chip = NSButton()
    private let workingAvatar = SidebarWorkingAvatarView()
    private let unreadDot = NSImageView()
    private let splitPaneIndicator = NSImageView()
    private let date = NSTextField(labelWithString: "")
    private var onToggleThreads: (() -> Void)?
    private var leading: NSLayoutConstraint?
    /// Indent per nesting level; the outline itself uses none.
    static let indentPerDepth: CGFloat = 14

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
        // The row's label already says pinned and unread.
        self.pin.setAccessibilityElement(false)
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
        self.unreadDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unread")
        self.unreadDot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        self.unreadDot.contentTintColor = .labelColor
        self.unreadDot.setAccessibilityElement(false)
        self.splitPaneIndicator.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        self.splitPaneIndicator.identifier = NSUserInterfaceItemIdentifier("sidebar-split-pane-indicator")
        self.splitPaneIndicator.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        self.splitPaneIndicator.contentTintColor = .tertiaryLabelColor
        self.splitPaneIndicator.setAccessibilityElement(false)
        self.date.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        self.date.textColor = .tertiaryLabelColor
        for view in [self.chip, self.workingAvatar, self.unreadDot, self.splitPaneIndicator, self.date] as [NSView] {
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
        let row = NSStackView(views: [self.threadArrow, self.icon, text, spacer, self.chip, self.workingAvatar,
                                      self.unreadDot, self.splitPaneIndicator, self.date])
        row.spacing = 7
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setCustomSpacing(0, after: text)
        row.setCustomSpacing(4, after: spacer)
        self.addSubview(row)
        let leading = row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
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
        self.leading?.constant = 6 + CGFloat(entry.depth) * Self.indentPerDepth
        self.threadArrow.isHidden = !entry.isThread
        self.icon.image = NSImage(systemSymbolName: ChannelRowStyle.symbol(for: entry), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "number", accessibilityDescription: nil)
        self.icon.contentTintColor = ChannelRowStyle.tint(for: entry)
        self.title.stringValue = row.title
        self.title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: row.isUnread && !row.isNestedHelper ? .semibold : .regular)
        self.title.textColor = row.isNestedHelper || row.isArchived ? .secondaryLabelColor : .labelColor
        self.pin.isHidden = !(row.isPinned && !entry.isThread)
        self.preview.stringValue = entry.preview ?? ""
        self.preview.isHidden = entry.preview == nil
        self.toolTip = ChannelRowStyle.help(for: row)

        let showChip = entry.showSubagentRuns && entry.subagentCount > 0
        self.chip.isHidden = !showChip
        if showChip {
            self.chip.title = "\(entry.subagentCount) \(entry.threadsExpanded ? "▴" : "▾")"
            self.chip.contentTintColor = entry.hiddenUnreadThreads > 0 ? TranscriptColors.tint : .secondaryLabelColor
            self.chip.toolTip = entry.threadsExpanded ? L("Hide subagent runs") : L("Show \(entry.subagentCount) subagent runs")
            self.chip.setAccessibilityLabel(self.chip.toolTip)
            let key = row.key
            self.onToggleThreads = { actions.toggleThreads(key) }
        }

        let working = entry.working != nil
        self.workingAvatar.isHidden = entry.avatar == nil
        if let indicator = entry.avatar {
            self.workingAvatar.configure(indicator, companion: entry.avatarStyle, phaseSeed: row.key)
        } else {
            self.workingAvatar.stop()
        }
        self.unreadDot.isHidden = entry.avatar != nil || !(row.isUnread && !row.isNestedHelper)
        self.splitPaneIndicator.isHidden = !entry.isShownInSplitPane
        let activity = entry.avatar != nil || !self.unreadDot.isHidden ? nil : row.activityDate
        self.date.isHidden = activity == nil
        self.date.stringValue = activity.map(ChannelRowStyle.relativeDate) ?? ""

        self.setAccessibilityLabel(AccessibilityText.sessionRow(
            title: row.title, isUnread: row.isUnread && !row.isNestedHelper, isPinned: !self.pin.isHidden,
            isRunning: working, workingLabel: entry.working?.label, preview: entry.preview))
        self.setAccessibilityHelp(ChannelRowStyle.accessibilityHint(for: entry))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { self.workingAvatar.isEmphasized = self.backgroundStyle == .emphasized }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.workingAvatar.stop()
    }

    @objc private func toggleThreads() {
        self.onToggleThreads?()
    }
}

final class SidebarHeaderCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")

    private let emoji = NSTextField(labelWithString: "")
    private let creature = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let add = NSButton()
    private let chevron = NSButton()
    private var onAdd: (() -> Void)?
    private var onToggle: (() -> Void)?
    private var leading: NSLayoutConstraint?
    private(set) var isNested = false
    /// Width of each trailing button slot. Every header keeps both slots, so + and the chevron
    /// line up across sections and never move.
    static let buttonSlot: CGFloat = 22
    private var avatar: (style: AvatarStyle, state: AvatarState)?

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
        self.add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("New chat"))
        self.add.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        self.add.contentTintColor = .secondaryLabelColor
        self.add.toolTip = L("New chat")
        self.add.target = self
        self.add.action = #selector(self.addChat)
        self.chevron.bezelStyle = .accessoryBarAction
        self.chevron.isBordered = false
        self.chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        self.chevron.contentTintColor = .secondaryLabelColor
        self.chevron.target = self
        self.chevron.action = #selector(self.toggleSection)
        for button in [self.add, self.chevron] {
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: Self.buttonSlot).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.buttonSlot).isActive = true
        }
        self.creature.imageScaling = .scaleNone
        self.creature.widthAnchor.constraint(equalToConstant: SidebarAvatar.side).isActive = true
        self.creature.heightAnchor.constraint(equalToConstant: SidebarAvatar.side).isActive = true
        for view in [self.emoji, self.creature, self.icon, self.badge, self.add, self.chevron] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [self.emoji, self.creature, self.icon, self.title, self.badge, spacer, self.add, self.chevron])
        row.spacing = 5
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(row)
        let leading = row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 2)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
        self.textField = self.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(_ header: SidebarModel.Header, actions: SidebarActions, toggle: @escaping () -> Void) {
        let section = header.section
        self.isNested = header.isSubsection
        self.leading?.constant = header.isSubsection ? 2 + SidebarChatCell.indentPerDepth : 2
        self.superview?.needsLayout = true
        self.onToggle = toggle
        self.avatar = header.avatar.map { ($0, header.avatarState) }
        self.drawAvatar()
        self.emoji.stringValue = section.emoji ?? ""
        self.emoji.isHidden = section.emoji == nil || header.avatar != nil
        let symbol = header.symbol
        self.icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        self.icon.isHidden = symbol == nil
        self.title.stringValue = section.title
        let unread = header.isCollapsed ? section.unreadCount : 0
        self.badge.stringValue = " \(unread) "
        self.badge.isHidden = unread == 0
        // A section without + keeps an empty slot, so the chevron stays in line.
        let canAdd = header.newChatAgent != nil
        self.add.alphaValue = canAdd ? 1 : 0
        self.add.isEnabled = canAdd
        self.add.setAccessibilityElement(canAdd)
        self.add.setAccessibilityRole(.button)
        self.onAdd = header.addAction(actions)
        self.add.toolTip = header.addAccessibilityLabel
        self.add.setAccessibilityLabel(header.addAccessibilityLabel)
        self.setAccessibilityLabel(header.isSubsection ? header.subsectionAccessibilityLabel
            : header.agentAccessibilityLabel ?? section.title)
        self.setAccessibilityHelp(header.accessibilityHint)
        self.isExpanded = !header.isCollapsed
        let label = AccessibilityText.sectionToggle(title: section.title, isCollapsed: header.isCollapsed)
        self.chevron.image = NSImage(systemSymbolName: header.isCollapsed ? "chevron.right" : "chevron.down",
                                     accessibilityDescription: label)
        self.chevron.toolTip = header.isCollapsed ? L("Show") : L("Hide")
        self.chevron.setAccessibilityLabel(label)
    }

    @objc private func addChat() {
        self.onAdd?()
    }

    @objc private func toggleSection() {
        self.onToggle?()
    }

    private var isExpanded = false

    override func isAccessibilityExpanded() -> Bool { self.isExpanded }

    override func accessibilityPerformPress() -> Bool {
        guard let onToggle else { return false }
        onToggle()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.drawAvatar()
    }

    private func drawAvatar() {
        self.creature.isHidden = self.avatar == nil
        guard let avatar else { self.creature.image = nil; return }
        var image: NSImage?
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let accent = TranscriptColors.tint.cgColor
            let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            image = AvatarArt.still(avatar.style, state: avatar.state, dark: dark, accent: accent, side: SidebarAvatar.side, scale: scale)
                .map { NSImage(cgImage: $0, size: NSSize(width: SidebarAvatar.side, height: SidebarAvatar.side)) }
        }
        self.creature.image = image
    }
}

/// An outline that can keep an expandable row's disclosure triangle out of sight.
final class SidebarOutlineView: NSOutlineView {
    enum KeyboardHandling {
        case handled
        case nativeNavigation
        case pass
    }

    var hidesOutlineCell: ((Int) -> Bool)?
    /// Handles a ⌘-click on a row; true when it did, so the selection stays put.
    var commandClick: ((Int) -> Bool)?
    var keyboardCommand: ((NSEvent) -> KeyboardHandling)?
    var allowsKeyboardHeaderSelection = false

    override func keyDown(with event: NSEvent) {
        switch self.keyboardCommand?(event) ?? .pass {
        case .handled:
            return
        case .nativeNavigation:
            self.allowsKeyboardHeaderSelection = true
            defer { self.allowsKeyboardHeaderSelection = false }
            super.keyDown(with: event)
        case .pass:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let commandClick,
           commandClick(self.row(at: self.convert(event.locationInWindow, from: nil))) { return }
        super.mouseDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        self.hidesOutlineCell?(row) == true ? .zero : super.frameOfOutlineCell(atRow: row)
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

/// Draws the selection in the theme's accent when it sets one; otherwise the system's source-list
/// highlight.
final class SidebarRowView: NSTableRowView {
    /// The outline draws nested rows inset from the trailing edge. A nested group header's cell
    /// reaches out to where its agent header's cell ends, so its + and chevron sit in the same
    /// slots and stay inside the cell (clickable).
    override func layout() {
        super.layout()
        guard let cell = self.subviews.lazy.compactMap({ $0 as? SidebarHeaderCell }).first, cell.isNested else { return }
        var ancestor = self.superview
        while let view = ancestor, !(view is NSOutlineView) { ancestor = view.superview }
        guard let outline = ancestor as? NSOutlineView else { return }
        let row = outline.row(for: self)
        guard row >= 0, var top = outline.item(atRow: row) else { return }
        while let parent = outline.parent(forItem: top) { top = parent }
        let topRow = outline.row(forItem: top)
        guard topRow >= 0, topRow != row else { return }
        let topEdge: CGFloat
        if let topCell = outline.view(atColumn: 0, row: topRow, makeIfNecessary: false) {
            topEdge = outline.convert(topCell.bounds, from: topCell).maxX
        } else {
            topEdge = outline.frameOfCell(atColumn: 0, row: topRow).maxX
        }
        let edge = self.convert(NSPoint(x: topEdge, y: 0), from: outline).x
        let width = max(cell.frame.width, edge - cell.frame.minX)
        if cell.frame.width != width { cell.frame.size.width = width }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let accent = AppTheme.current.platformColor(.accent) else {
            super.drawSelection(in: dirtyRect)
            return
        }
        let rect = self.bounds.insetBy(dx: 10, dy: 1)
        let fill = self.isEmphasized ? accent : accent.withAlphaComponent(0.35)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}
#endif
