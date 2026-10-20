import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TranscriptToolHeaderView: TranscriptTapView {
    private var part: TranscriptPart.Tool?
    private var trailing: CGFloat = 10
    private(set) var contextMenu: TranscriptToolContextMenu?
    var onOpenMCPServer: ((String) -> Void)?
    private let spinner = TranscriptSpinner(size: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
        #if os(iOS)
        self.isContextMenuInteractionEnabled = true
        #endif
    }

    func configure(_ part: TranscriptPart.Tool, trailing: CGFloat, contextMenu: TranscriptToolContextMenu? = nil) {
        self.part = part
        self.trailing = trailing
        self.contextMenu = contextMenu ?? TranscriptToolContextMenu.make(toolName: part.tool.name, controls: part.controls)
        self.spinner.setAnimating(part.tool.isRunning)
        #if os(macOS)
        self.toolTip = part.edit?.fullPaths
        #endif
        self.redraw()
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let contextMenu else { return super.menu(for: event) }
        let menu = NSMenu()
        if let name = contextMenu.openServerName, let title = contextMenu.openServerTitle {
            menu.addItem(TranscriptMenuItem(title, symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
                self?.onOpenMCPServer?(name)
            })
        }
        menu.addItem(TranscriptMenuItem(L("Copy Tool Name"), symbol: "doc.on.doc") {
            Clipboard.copy(contextMenu.toolName)
        })
        return menu
    }
    #else
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration?
    {
        guard let contextMenu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if let name = contextMenu.openServerName, let title = contextMenu.openServerTitle {
                actions.append(UIAction(title: title, image: UIImage(systemName: "point.3.connected.trianglepath.dotted")) { _ in
                    self?.onOpenMCPServer?(name)
                })
            }
            actions.append(UIAction(title: L("Copy Tool Name"), image: UIImage(systemName: "doc.on.doc")) { _ in
                Clipboard.copy(contextMenu.toolName)
            })
            return UIMenu(children: actions)
        }
    }
    #endif

    override func layoutContent() {
        self.spinner.place(center: CGPoint(x: 10 + 8, y: self.bounds.midY))
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        if self.isPressed {
            TranscriptColors.highlight.setFill()
            PBezierPath.rounded(bounds.insetBy(dx: 1, dy: 1), radius: TranscriptMetrics.cardRadius - 1).fill()
        }
        let iconRect = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if !part.tool.isRunning {
            if part.tool.isError {
                TranscriptSymbols.draw("xmark.octagon", in: iconRect, size: style.callout.pointSize, color: TranscriptColors.failure)
            } else {
                let symbol = part.edit.map(TranscriptDiffText.symbol(for:)) ?? ToolSymbols.symbol(for: part.tool.name)
                TranscriptSymbols.draw(symbol, in: iconRect, size: style.callout.pointSize, color: TranscriptColors.secondary)
            }
        }
        let chevronX = bounds.width - self.trailing - 10
        TranscriptSymbols.draw(part.isExpanded ? "chevron.down" : "chevron.right",
                               in: CGRect(x: chevronX, y: 0, width: 10, height: bounds.height),
                               size: style.caption2Medium.pointSize, weight: .bold, color: TranscriptColors.secondary)
        if let edit = part.edit {
            self.drawEdit(edit, part: part, chevronX: chevronX)
            return
        }
        let nameFont = style.calloutMonoMedium
        let nameX: CGFloat = 34
        let nameY = (bounds.height - TranscriptStyle.lineHeight(nameFont)) / 2
        let duration = self.durationLine(part)
        let badgeFont = style.caption2Medium
        let failed = part.tool.isError ? singleLine(L("Failed"), badgeFont, TranscriptColors.failure) : nil
        let badgeHeight = TranscriptStyle.lineHeight(badgeFont) + 2
        // Left edge of the Failed badge (or the chevron's) for a given reserve; nil when the badge doesn't fit.
        func badgeRect(reserve: CGFloat) -> CGRect? {
            guard let failed else { return nil }
            let width = failed.lineWidth + 10
            let right = chevronX - 8 - reserve
            guard right - width > nameX + 40 else { return nil }
            return CGRect(x: right - width, y: (bounds.height - badgeHeight) / 2, width: width, height: badgeHeight)
        }
        func rightEdge(reserve: CGFloat) -> CGFloat { badgeRect(reserve: reserve).map { $0.minX - 8 } ?? chevronX - 8 - reserve }
        let parts = ToolCardName(part.tool.name)
        let nameWidthNatural = singleLine(parts.tool, nameFont, TranscriptColors.label).lineWidth
        var reserve: CGFloat = 0
        if let duration {
            let candidate = duration.lineWidth + 8
            let unchanged = (badgeRect(reserve: 0) != nil) == (badgeRect(reserve: candidate) != nil)
            let room = rightEdge(reserve: candidate) - (nameX + nameWidthNatural)
            // The summary keeps at least 60pt after the name, or the name keeps 40pt when there's no summary.
            if unchanged, room >= (part.tool.summary == nil ? 40 : 68) { reserve = candidate }
        }
        if let duration, reserve > 0 {
            self.draw(duration, right: chevronX - 8, nameFont: nameFont)
        }
        var right = chevronX - 8 - reserve
        if let failed, let rect = badgeRect(reserve: reserve) {
            TranscriptColors.failure.withAlphaComponent(0.14).setFill()
            PBezierPath.rounded(rect, radius: badgeHeight / 2).fill()
            failed.drawLine(at: CGPoint(x: rect.minX + 5, y: rect.minY + 1), width: failed.lineWidth, font: badgeFont)
            right = rect.minX - 8
        }
        var nameWidth: CGFloat = 0
        let name = singleLine(parts.tool, nameFont, TranscriptColors.label)
        let available = max(right - nameX, 0)
        // The tool keeps its natural width; the server gets what's left, at most 40%, and is dropped
        // (with its separator) when that would be too narrow to read.
        let toolWidth = min(name.lineWidth, available)
        if let server = parts.server {
            let separator = singleLine(" · ", nameFont, TranscriptColors.tertiary)
            let serverText = singleLine(server, nameFont, TranscriptColors.secondary, truncation: .byTruncatingTail)
            let serverWidth = min(serverText.lineWidth, available * 0.4, available - separator.lineWidth - toolWidth)
            if serverWidth >= 28 {
                serverText.drawLine(at: CGPoint(x: nameX, y: nameY), width: serverWidth, font: nameFont)
                separator.drawLine(at: CGPoint(x: nameX + serverWidth, y: nameY), width: separator.lineWidth, font: nameFont)
                nameWidth = serverWidth + separator.lineWidth
            }
        }
        name.drawLine(at: CGPoint(x: nameX + nameWidth, y: nameY), width: toolWidth, font: nameFont)
        nameWidth += toolWidth
        if let summary = part.tool.summary {
            let summaryX = nameX + nameWidth + 8
            let width = right - summaryX
            if width > 16 {
                let font = style.captionMono
                let oneLine = summary.replacingOccurrences(of: "\n", with: " ")
                singleLine(oneLine, font, TranscriptColors.secondary, truncation: .byTruncatingMiddle)
                    .drawLine(at: CGPoint(x: summaryX, y: nameY + nameFont.ascender - font.ascender), width: width, font: font)
            }
        }
    }
}

extension TranscriptToolHeaderView {
    /// The run time as drawn, nil while running or when the call reported none.
    fileprivate func durationLine(_ part: TranscriptPart.Tool) -> NSAttributedString? {
        guard !part.tool.isRunning, let ms = part.tool.durationMs else { return nil }
        return singleLine(ToolDuration.format(ms).text, TranscriptStyle.shared.captionMono, TranscriptColors.secondary)
    }

    /// Draws `line` with its right edge at `right`, on the name's baseline.
    fileprivate func draw(_ line: NSAttributedString, right: CGFloat, nameFont: PFont) {
        let font = TranscriptStyle.shared.captionMono
        let nameY = (self.bounds.height - TranscriptStyle.lineHeight(nameFont)) / 2
        line.drawLine(at: CGPoint(x: right - line.lineWidth, y: nameY + nameFont.ascender - font.ascender),
                      width: line.lineWidth, font: font)
    }

    /// File name (directory dimmer), then the +/− counts and a status badge before the chevron.
    fileprivate func drawEdit(_ edit: ToolFileEdit, part: TranscriptPart.Tool, chevronX: CGFloat) {
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        let nameFont = style.calloutMonoMedium
        let nameX: CGFloat = 34
        let nameY = (bounds.height - TranscriptStyle.lineHeight(nameFont)) / 2
        let badgeFont = style.caption2Medium
        let badgeText = part.tool.isError ? L("Failed") : edit.statusLabel(isRunning: part.tool.isRunning)
        let badgeColor = part.tool.isError ? TranscriptColors.failure : TranscriptColors.secondary
        let badge = singleLine(badgeText, badgeFont, badgeColor)
        let badgeHeight = TranscriptStyle.lineHeight(badgeFont) + 2
        let badgeWidth = badge.lineWidth + 10
        let countFont = style.captionMono
        let countY = nameY + nameFont.ascender - countFont.ascender
        let counts = [(edit.deletionsLabel, TranscriptDiffText.deletion), (edit.additionsLabel, TranscriptDiffText.addition)]
            .compactMap { label, color in label.map { (singleLine($0, countFont, color)) } }
        let name = singleLine(edit.title, nameFont, TranscriptColors.label, truncation: .byTruncatingMiddle)

        // What fits left of the chevron after `reserve`: the status badge, then the counts.
        func place(reserve: CGFloat) -> (badge: CGRect?, counts: [(NSAttributedString, CGFloat)], right: CGFloat) {
            var right = chevronX - 8 - reserve
            var badgeRect: CGRect?
            if right - badgeWidth > nameX + 40 {
                badgeRect = CGRect(x: right - badgeWidth, y: (bounds.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
                right -= badgeWidth + 8
            }
            var placed: [(NSAttributedString, CGFloat)] = []
            let countGroupWidth = counts.reduce(CGFloat.zero) { $0 + $1.lineWidth }
                + CGFloat(max(counts.count - 1, 0)) * 6
            // Keep the +/- pair together. At narrow widths the filename can truncate more
            // aggressively; showing only one side makes the diff summary misleading.
            if !counts.isEmpty, right - countGroupWidth > nameX + 8 {
                for (index, count) in counts.enumerated() {
                    placed.append((count, right - count.lineWidth))
                    right -= count.lineWidth
                    if index < counts.count - 1 { right -= 6 }
                }
                right -= 2
            }
            return (badgeRect, placed, right)
        }
        var layout = place(reserve: 0)
        if let duration = self.durationLine(part) {
            let candidate = duration.lineWidth + 8
            let shifted = place(reserve: candidate)
            // Badge and counts keep their place; the name (and directory) must still read.
            let room = shifted.right - (nameX + min(name.lineWidth, 160))
            if (shifted.badge != nil) == (layout.badge != nil), shifted.counts.count == layout.counts.count, room >= 40 {
                layout = shifted
                self.draw(duration, right: chevronX - 8, nameFont: nameFont)
            }
        }
        if let rect = layout.badge {
            (part.tool.isError ? TranscriptColors.failure.withAlphaComponent(0.14) : TranscriptColors.strongFill).setFill()
            PBezierPath.rounded(rect, radius: badgeHeight / 2).fill()
            badge.drawLine(at: CGPoint(x: rect.minX + 5, y: rect.minY + 1), width: badge.lineWidth, font: badgeFont)
        }
        for (count, x) in layout.counts {
            count.drawLine(at: CGPoint(x: x, y: countY), width: count.lineWidth, font: countFont)
        }
        let right = layout.right

        let nameWidth = min(name.lineWidth, max(right - nameX, 0))
        name.drawLine(at: CGPoint(x: nameX, y: nameY), width: nameWidth, font: nameFont)
        if let directory = edit.directory {
            let x = nameX + nameWidth + 8
            if right - x > 24 {
                singleLine(directory, countFont, TranscriptColors.tertiary, truncation: .byTruncatingHead)
                    .drawLine(at: CGPoint(x: x, y: countY), width: right - x, font: countFont)
            }
        }
    }
}

/// Input or output of an expanded tool card: selectable monospaced text that scrolls once it's
/// taller than the card allows.

final class TranscriptToolSectionView: TranscriptBaseView {
    private let textView = TranscriptTextView(wraps: true)
    private var contentHeight: CGFloat = 0
    /// Bottom of the current card-search match in the text, kept in view when the text scrolls.
    private var searchMatchBottom: CGFloat?
    #if os(macOS)
    private let scroller = TranscriptScroller(axis: .vertical)
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        self.scroller.document.addSubview(self.textView)
        self.addSubview(self.scroller)
        #else
        self.addSubview(self.textView)
        #endif
    }

    func configure(_ section: TranscriptPart.Tool.Section, row: TranscriptRowLayout, resetScroll: Bool) {
        // A clamped preview keeps all source text in TextKit for Find, but sizes its native document
        // to the visible frame so the hidden remainder cannot become an inner scroll surface.
        self.contentHeight = section.visibleLineLimit == nil ? section.contentHeight : section.frame.height
        self.searchMatchBottom = section.searchMatchBottom
        self.textView.copyItems = row.copyItems
        self.textView.set(section.text, identity: "\(row.id):\(section.id ?? section.title)",
                          visibleLineLimit: section.visibleLineLimit)
        #if os(macOS)
        if resetScroll { self.scroller.scrollToStart() }
        #else
        self.textView.isScrollEnabled = section.visibleLineLimit == nil
            && section.contentHeight > section.frame.height + 0.5
        if resetScroll { self.textView.contentOffset = .zero }
        #endif
        self.scrollToSearchMatch(height: section.frame.height)
    }

    /// Scrolls a tall text so the current card-search match is inside the visible frame.
    private func scrollToSearchMatch(height: CGFloat) {
        guard let bottom = self.searchMatchBottom, self.contentHeight > height + 0.5 else { return }
        let offset = bottom > height ? min(bottom - height / 2, self.contentHeight - height) : 0
        #if os(macOS)
        self.scroller.contentView.scroll(to: CGPoint(x: 0, y: offset))
        self.scroller.reflectScrolledClipView(self.scroller.contentView)
        #else
        self.textView.contentOffset = CGPoint(x: 0, y: offset)
        #endif
    }

    #if os(macOS)
    /// ⌘F with the focus in this card's text searches the card instead of the chat.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           let responder = self.window?.firstResponder as? NSView, responder.isDescendant(of: self),
           let card = self.superview as? TranscriptToolView
        {
            card.searchBar.open()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    #endif

    override func layoutContent() {
        let bounds = self.bounds
        #if os(macOS)
        if self.scroller.frame != bounds { self.scroller.frame = bounds }
        // Leave room for the overlay scroller when the text scrolls.
        let size = CGSize(width: bounds.width, height: max(self.contentHeight, bounds.height))
        self.scroller.setContentSize(size)
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: self.contentHeight)
        if self.textView.frame != frame { self.textView.frame = frame }
        #else
        if self.textView.frame != bounds { self.textView.frame = bounds }
        #endif
    }
}
