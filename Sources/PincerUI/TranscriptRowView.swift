import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Row view

/// A transcript row drawn natively. Holds a pool of part views per kind and reuses them in order,
/// so configuring a recycled row for another message creates nothing new in the common case.
final class TranscriptRowView: TranscriptBaseView {
    private var pool: [TranscriptPart.Kind: [TranscriptBaseView]] = [:]
    private(set) var layout: TranscriptRowLayout?
    private weak var actions: TranscriptRowActions?
    #if os(iOS)
    private let menuDelegate = TranscriptRowMenuDelegate()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        self.menuDelegate.row = self
        self.addInteraction(UIContextMenuInteraction(delegate: self.menuDelegate))
        #endif
    }

    /// Theme the pooled views last drew with. Parts only redraw when their own content changes,
    /// so a theme change has to be pushed to them.
    private var drawnTheme: AppTheme?

    func apply(_ layout: TranscriptRowLayout, actions: TranscriptRowActions) {
        self.layout = layout
        self.actions = actions
        let theme = AppTheme.current
        if let drawnTheme, drawnTheme != theme {
            for view in self.pool.values.joined() { view.appearanceChanged() }
        }
        self.drawnTheme = theme
        var used: [TranscriptPart.Kind: Int] = [:]
        for placed in layout.parts {
            let kind = placed.part.kind
            let index = used[kind, default: 0]
            used[kind] = index + 1
            let view: TranscriptBaseView
            if let existing = self.pool[kind], index < existing.count {
                view = existing[index]
            } else {
                view = Self.make(kind)
                self.pool[kind, default: []].append(view)
                self.addSubview(view)
            }
            if view.isHidden { view.isHidden = false }
            if view.frame != placed.frame { view.frame = placed.frame }
            view.configure(placed.part, row: layout, actions: actions)
            view.layoutContent()
        }
        for (kind, views) in self.pool {
            for view in views.dropFirst(used[kind] ?? 0) where !view.isHidden {
                view.isHidden = true
                view.didHide()
            }
        }
        if self.viewAlpha != layout.alpha { self.viewAlpha = layout.alpha }
        self.applySendActions(layout.sendStatus)
    }

    /// Retry and Delete for an unsent message, as accessibility actions on the row.
    private func applySendActions(_ status: TranscriptPart.SendStatus?) {
        #if os(macOS)
        let actions = self.sendActions(status).map { action in
            NSAccessibilityCustomAction(name: action.title) { action.run(); return true }
        }
        self.setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
        #else
        let actions = self.sendActions(status).map { action in
            UIAccessibilityCustomAction(name: action.title) { _ in action.run(); return true }
        }
        self.accessibilityCustomActions = actions.isEmpty ? nil : actions
        #endif
    }

    struct SendAction {
        let title: String
        let symbol: String
        let isDestructive: Bool
        let run: () -> Void
    }

    func sendActions(_ status: TranscriptPart.SendStatus? = nil) -> [SendAction] {
        guard let status = status ?? self.layout?.sendStatus, let actions else { return [] }
        var result: [SendAction] = []
        if status.canRetry {
            result.append(SendAction(title: L("Retry"), symbol: "arrow.clockwise", isDestructive: false) { [weak actions] in
                actions?.retrySend(status.id)
            })
        }
        if status.canDelete {
            result.append(SendAction(title: L("Delete"), symbol: "trash", isDestructive: true) { [weak actions] in
                actions?.deleteSend(status.id)
            })
        }
        return result
    }

    private static func make(_ kind: TranscriptPart.Kind) -> TranscriptBaseView {
        switch kind {
        case .avatar: TranscriptAvatarView()
        case .header: TranscriptHeaderView()
        case .text, .quote, .thinkingBody: TranscriptTextPartView()
        case .rule: TranscriptRuleView()
        case .code: TranscriptCodeView()
        case .table: TranscriptMarkdownTableView()
        case .thinkingHeader: TranscriptThinkingHeaderView()
        case .tool: TranscriptToolView()
        case .image: TranscriptImagePartView()
        case .imageLink: TranscriptImageLinkView()
        case .file: TranscriptFileView()
        case .typing: TranscriptTypingView()
        case .footer: TranscriptFooterView()
        case .marker: TranscriptMarkerView()
        case .loading: TranscriptLoadingView()
        case .replyQuote: TranscriptReplyQuoteView()
        case .reactions: TranscriptReactionsView()
        case .sendStatus: TranscriptSendStatusView()
        case .flash: TranscriptFlashView()
        }
    }

    func copyItems(extra: [TranscriptRowLayout.CopyItem] = []) -> [TranscriptRowLayout.CopyItem] {
        extra + (self.layout?.copyItems ?? [])
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        self.menu(extra: [], event: event)
    }

    func menu(extra: [TranscriptRowLayout.CopyItem], event: NSEvent) -> NSMenu? {
        let items = self.copyItems(extra: extra)
        let point = self.convert(event.locationInWindow, from: nil)
        let messageItems = self.messageMenuItems(at: point, in: self)
            + self.sendActions().map { action in TranscriptMenuItem(action.title, symbol: action.symbol, handler: action.run) }
        guard !items.isEmpty || !messageItems.isEmpty else { return nil }
        let menu = NSMenu()
        for item in messageItems { menu.addItem(item) }
        if !messageItems.isEmpty, !items.isEmpty { menu.addItem(.separator()) }
        for item in items { menu.addItem(TranscriptMenuItem(item.title) { Clipboard.copy(item.text) }) }
        return menu
    }

    /// Reply, Copy Link, Add Reaction… and one-click reactions for the message under `point` (in `view`), and
    /// the chat a forwarded message came from.
    func messageMenuItems(at point: CGPoint, in view: NSView) -> [NSMenuItem] {
        let rowPoint = self.convert(point, from: view)
        guard let actions else { return [] }
        var source: [NSMenuItem] = []
        if let chat = self.layout?.sourceChat {
            source = [TranscriptMenuItem(chat.title, symbol: "bubble.left.and.bubble.right") { [weak actions] in
                actions?.openChat(chat.sessionKey)
            }]
        }
        guard let id = self.layout?.message(at: rowPoint.y) else { return source }
        if !source.isEmpty { source.insert(.separator(), at: 0) }
        var items: [NSMenuItem] = [
            TranscriptMenuItem(L("Reply"), symbol: "arrowshape.turn.up.left") { [weak actions] in actions?.reply(to: id) },
            TranscriptMenuItem(L("Copy Link"), symbol: "link") { [weak actions] in actions?.copyLink(to: id) },
            TranscriptMenuItem(actions.isBookmarked(id) ? L("Remove Bookmark") : L("Bookmark"),
                               symbol: actions.isBookmarked(id) ? "star.slash" : "star") { [weak actions] in
                actions?.toggleBookmark(id)
            },
        ]
        if actions.reactionsEnabled {
            let quick = NSMenuItem()
            quick.view = QuickReactionsMenuView { [weak actions] emoji in actions?.toggleReaction(emoji, on: id) }
            items += [
                TranscriptMenuItem(L("Add Reaction…"), symbol: "face.smiling") { [weak self, weak actions] in
                    guard let self else { return }
                    actions?.pickReaction(for: id, from: self,
                                          rect: CGRect(x: rowPoint.x, y: rowPoint.y, width: 1, height: 1))
                },
                quick,
            ]
        }
        return items + source
    }
    #else
    /// Reply, Copy Link, Add Reaction… and one-tap reactions for the message at `point` (row coordinates), and
    /// the chat a forwarded message came from.
    func messageMenuElements(at point: CGPoint, anchor: UIView? = nil) -> [UIMenuElement] {
        guard let actions else { return [] }
        var source: [UIMenuElement] = []
        if let chat = self.layout?.sourceChat {
            source = [UIMenu(options: .displayInline, children: [
                UIAction(title: chat.title, image: UIImage(systemName: "bubble.left.and.bubble.right")) { [weak actions] _ in
                    actions?.openChat(chat.sessionKey)
                },
            ])]
        }
        guard let id = self.layout?.message(at: point.y) else { return source }
        let anchorView: UIView = anchor ?? self
        let anchorRect = anchor.map { $0.bounds } ?? CGRect(origin: point, size: CGSize(width: 1, height: 1))
        var elements: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("Reply"), image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak actions] _ in
                    actions?.reply(to: id)
                },
                UIAction(title: L("Copy Link"), image: UIImage(systemName: "link")) { [weak actions] _ in
                    actions?.copyLink(to: id)
                },
                UIAction(title: actions.isBookmarked(id) ? L("Remove Bookmark") : L("Bookmark"),
                         image: UIImage(systemName: actions.isBookmarked(id) ? "star.slash" : "star")) { [weak actions] _ in
                    actions?.toggleBookmark(id)
                },
            ]),
        ]
        if actions.reactionsEnabled {
            let quick = Reactions.quickBar(recent: Reactions.recent).map { emoji in
                UIAction(title: emoji) { [weak actions] _ in actions?.toggleReaction(emoji, on: id) }
            }
            elements += [
                UIMenu(options: .displayInline, children: [
                    UIAction(title: L("Add Reaction…"), image: UIImage(systemName: "face.smiling")) { [weak actions, weak anchorView] _ in
                        // After the menu has finished dismissing, so the picker can present.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            guard let anchorView else { return }
                            actions?.pickReaction(for: id, from: anchorView, rect: anchorRect)
                        }
                    },
                ]),
                UIMenu(options: .displayInline, preferredElementSize: .small, children: quick),
            ]
        }
        return elements + source
    }
    #endif
}

#if os(iOS)
/// `UIControl` is its own context menu delegate for its own menu, so the row's copy menu gets a
/// separate one.
private final class TranscriptRowMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    weak var row: TranscriptRowView?

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration?
    {
        self.row?.menuConfiguration(at: location)
    }
}

extension TranscriptRowView {
    fileprivate func menuConfiguration(at location: CGPoint) -> UIContextMenuConfiguration? {
        // Long-pressing text selects it; the text's own edit menu carries the copy actions.
        var hit = self.hitTest(location, with: nil)
        while let view = hit, view !== self {
            if view is UITextView { return nil }
            hit = view.superview
        }
        var extra: [TranscriptRowLayout.CopyItem] = []
        if let hitView = self.hitTest(location, with: nil) {
            var view: UIView? = hitView
            while let current = view, current !== self {
                if let table = current as? TranscriptMarkdownTableView { extra = table.extraCopyItems }
                if let code = current as? TranscriptCodeView { extra = code.extraCopyItems }
                view = current.superview
            }
        }
        let items = self.copyItems(extra: extra)
        let sendItems: [UIMenuElement] = self.sendActions().map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                     attributes: action.isDestructive ? .destructive : []) { _ in action.run() }
        }
        let messageItems = self.messageMenuElements(at: location)
            + (sendItems.isEmpty ? [] : [UIMenu(options: .displayInline, children: sendItems)])
        guard !items.isEmpty || !messageItems.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: messageItems + items.map { item in
                UIAction(title: item.title, image: UIImage(systemName: "doc.on.doc")) { _ in Clipboard.copy(item.text) }
            })
        }
    }
}
#endif
