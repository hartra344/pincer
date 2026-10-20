import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Parts

final class TranscriptHeaderView: TranscriptBaseView {
    private var header: TranscriptPart.Header?
    private let spinner = TranscriptSpinner(size: 10)
    /// The badge, when it opens a chat.
    private let badgeButton = TranscriptBadgeButton()

    private struct Positions {
        var nameWidth: CGFloat = 0
        var badgeRect: CGRect?
        var timeX: CGFloat?
        var spinnerCenter: CGPoint?
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
        self.badgeButton.isHidden = true
        self.addSubview(self.badgeButton)
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .header(header) = part else { return }
        let old = self.header
        self.header = header
        self.spinner.setAnimating(header.isPending)
        if old?.name != header.name || old?.badge != header.badge || old?.time != header.time || old?.isPending != header.isPending
            || old?.link != header.link
        {
            self.redraw()
        }
        if let link = header.link, let badge = header.badge {
            self.badgeButton.set(title: badge, help: link.title)
            self.badgeButton.onTap = { [weak actions] in actions?.openChat(link.sessionKey) }
            self.badgeButton.isHidden = false
        } else {
            self.badgeButton.onTap = nil
            self.badgeButton.isHidden = true
        }
        #if os(macOS)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel([header.name, header.badge, header.time].compactMap(\.self).joined(separator: ", "))
        #else
        self.isAccessibilityElement = true
        self.accessibilityLabel = [header.name, header.badge, header.time].compactMap(\.self).joined(separator: ", ")
        #endif
    }

    override func layoutContent() {
        let positions = self.positions()
        if let center = positions.spinnerCenter { self.spinner.place(center: center) }
        guard self.header?.link != nil, self.header?.badge != nil else { return }
        if let rect = positions.badgeRect {
            if self.badgeButton.frame != rect {
                self.badgeButton.frame = rect
                self.badgeButton.redraw()
            }
            self.badgeButton.isHidden = false
        } else {
            self.badgeButton.isHidden = true
        }
    }

    private var style: TranscriptStyle { TranscriptStyle.shared }

    private func positions() -> Positions {
        guard let header else { return Positions() }
        let style = self.style
        let baseline = style.headline.ascender
        let natural = singleLine(header.name, style.headline, TranscriptColors.label).lineWidth
        let timeWidth = header.time.map { singleLine($0, style.caption, TranscriptColors.tertiary).lineWidth }
        let widths = Self.widths(available: self.bounds.width, name: natural,
                                 badge: header.badge.map { singleLine($0, style.caption2Medium, TranscriptColors.secondary).lineWidth + 10 },
                                 time: timeWidth, isPending: header.isPending)
        let badgeWidth = widths.badge
        var positions = Positions()
        positions.nameWidth = widths.name
        var x = positions.nameWidth
        if let badgeWidth {
            x += 6
            let textY = baseline - style.caption2Medium.ascender
            positions.badgeRect = CGRect(x: x, y: textY - 1, width: badgeWidth,
                                         height: TranscriptStyle.lineHeight(style.caption2Medium) + 2)
            x += badgeWidth
        }
        if let timeWidth {
            x += 6
            positions.timeX = x
            x += timeWidth
        }
        if header.isPending {
            positions.spinnerCenter = CGPoint(x: x + 6 + 5, y: baseline - style.caption.xHeight / 2)
        }
        return positions
    }

    /// Widths of the name and badge on a header line `available` wide. The time and spinner keep
    /// theirs; the name keeps up to `minimumName` of its own; the badge gets what's left, truncated,
    /// and is dropped under `minimumBadge` (its chat stays reachable from the menu and VoiceOver).
    static func widths(available: CGFloat, name: CGFloat, badge: CGFloat?, time: CGFloat?, isPending: Bool,
                       minimumName: CGFloat = 60, minimumBadge: CGFloat = 30) -> (name: CGFloat, badge: CGFloat?)
    {
        var fixed: CGFloat = 0
        if let time { fixed += 6 + time }
        if isPending { fixed += 6 + 10 }
        let room = max(0, available - fixed)
        guard let badge else { return (min(name, room), nil) }
        let nameFloor = min(name, minimumName, room)
        let badgeWidth = min(badge, room - nameFloor - 6)
        guard badgeWidth >= minimumBadge else { return (min(name, room), nil) }
        return (min(name, room - 6 - badgeWidth), badgeWidth)
    }

    override func draw(_ rect: CGRect) {
        guard let header else { return }
        let style = self.style
        let positions = self.positions()
        let baseline = style.headline.ascender
        singleLine(header.name, style.headline, TranscriptColors.label)
            .drawLine(at: .zero, width: positions.nameWidth, font: style.headline)
        if header.link == nil, let badge = header.badge, let rect = positions.badgeRect {
            TranscriptColors.strongFill.setFill()
            PBezierPath.rounded(rect, radius: rect.height / 2).fill()
            singleLine(badge, style.caption2Medium, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: rect.minX + 5, y: rect.minY + 1), width: rect.width - 10, font: style.caption2Medium)
        }
        if let time = header.time, let x = positions.timeX {
            let text = singleLine(time, style.caption, TranscriptColors.tertiary)
            text.drawLine(at: CGPoint(x: x, y: baseline - style.caption.ascender), width: text.lineWidth, font: style.caption)
        }
    }
}

/// A header badge that opens a chat: the pill, in the link color.
final class TranscriptBadgeButton: TranscriptTapView {
    private var title = ""

    func set(title: String, help: String) {
        self.accessibilityText = help
        #if os(macOS)
        self.toolTip = help
        #endif
        guard title != self.title else { return }
        self.title = title
        self.redraw()
    }

    #if os(macOS)
    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }
    #endif

    override func draw(_ rect: CGRect) {
        let font = TranscriptStyle.shared.caption2Medium
        let bounds = self.bounds
        let color = self.isPressed ? TranscriptColors.link.withAlphaComponent(0.5) : TranscriptColors.link
        TranscriptColors.strongFill.setFill()
        PBezierPath.rounded(bounds, radius: bounds.height / 2).fill()
        singleLine(self.title, font, color)
            .drawLine(at: CGPoint(x: 5, y: 1), width: bounds.width - 10, font: font)
    }
}

final class TranscriptTextPartView: TranscriptBaseView {
    private let textView = TranscriptTextView(wraps: true)
    private var inset: CGFloat = 0
    private var bar: (width: CGFloat, color: PColor)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.textView)
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        let text: NSAttributedString
        let oldInset = self.inset
        switch part {
        case let .text(value):
            text = value
            self.inset = 0
            self.bar = nil
        case let .quote(value):
            text = value
            self.inset = 11
            self.bar = (3, TranscriptColors.tertiary)
        case let .thinkingBody(value):
            text = value
            self.inset = 10
            self.bar = (2, TranscriptColors.stroke)
        default:
            return
        }
        self.textView.copyItems = row.copyItems
        self.textView.set(text, identity: row.id)
        if oldInset != self.inset { self.redraw() }
    }

    override func layoutContent() {
        let frame = CGRect(x: self.inset, y: 0, width: max(self.bounds.width - self.inset, 1), height: self.bounds.height)
        if self.textView.frame != frame { self.textView.frame = frame }
    }

    override func draw(_ rect: CGRect) {
        guard let bar else { return }
        bar.color.setFill()
        PBezierPath.rounded(CGRect(x: 0, y: 0, width: bar.width, height: self.bounds.height), radius: bar.width / 2).fill()
    }
}

final class TranscriptRuleView: TranscriptBaseView {
    override func draw(_ rect: CGRect) {
        TranscriptColors.separator.setFill()
        PBezierPath(rect: CGRect(x: 0, y: 0, width: self.bounds.width, height: 1)).fill()
    }
}

/// A small borderless button: SF Symbol and title in the accent color.
final class TranscriptLabelButton: TranscriptTapView {
    private var title = ""
    private var symbol = ""
    /// Draws in the secondary label color instead of the accent, for buttons that sit on every row.
    var isSubdued = false

    /// Icon or text alone, with `padding` either side, instead of the icon-and-title layout. Used by
    /// the branch switcher's chevrons and "2 / 2".
    var isCompact = false
    var padding: CGFloat = 0
    var titleFont: PFont?
    /// Dimmed and inert, but still drawn so the row's layout doesn't change.
    var isDisabled = false {
        didSet {
            guard oldValue != self.isDisabled else { return }
            self.viewAlpha = self.isDisabled ? 0.5 : 1
            #if os(macOS)
            self.window?.invalidateCursorRects(for: self)
            #else
            self.isEnabled = !self.isDisabled
            #endif
        }
    }

    #if os(iOS)
    /// Items of the menu a tap opens; nil for buttons that just act.
    var menuProvider: (() -> [UIMenuElement])?

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration?
    {
        guard let menuProvider else { return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location) }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: menuProvider()) }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        self.bounds.insetBy(dx: -self.hitOutset.width, dy: -self.hitOutset.height).contains(point)
    }
    #else
    var showsHover = false
    private var isHovered = false {
        didSet { if oldValue != self.isHovered { self.redraw() } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.trackingAreas { self.removeTrackingArea(area) }
        guard self.showsHover else { return }
        self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { self.isHovered = !self.isDisabled }
    override func mouseExited(with event: NSEvent) { self.isHovered = false }

    override func resetCursorRects() {
        guard self.showsHover, !self.isDisabled else { return }
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }
    #endif

    func set(title: String, symbol: String) {
        guard title != self.title || symbol != self.symbol else { return }
        self.title = title
        self.symbol = symbol
        self.accessibilityText = title
        self.redraw()
    }

    var buttonSize: CGSize {
        guard self.isCompact else { return Self.size(title: self.title) }
        let font = self.titleFont ?? TranscriptStyle.shared.caption
        let content = self.symbol.isEmpty ? singleLine(self.title, font, TranscriptColors.tint).lineWidth : 14
        return CGSize(width: content + 2 * self.padding, height: max(TranscriptStyle.lineHeight(font), 16))
    }

    static func size(title: String) -> CGSize {
        let font = TranscriptStyle.shared.caption
        return CGSize(width: 14 + 4 + singleLine(title, font, TranscriptColors.tint).lineWidth,
                      height: max(TranscriptStyle.lineHeight(font), 16))
    }

    override func draw(_ rect: CGRect) {
        let font = self.titleFont ?? TranscriptStyle.shared.caption
        let base = self.isSubdued ? TranscriptColors.secondary : TranscriptColors.tint
        let color = self.isPressed ? base.withAlphaComponent(0.5) : base
        let height = self.bounds.height
        #if os(macOS)
        if self.isHovered, !self.isDisabled {
            TranscriptColors.fill.setFill()
            PBezierPath(roundedRect: self.bounds, xRadius: 4, yRadius: 4).fill()
        }
        #endif
        if self.isCompact {
            let x = self.padding
            if self.symbol.isEmpty {
                singleLine(self.title, font, color)
                    .drawLine(at: CGPoint(x: x, y: (height - TranscriptStyle.lineHeight(font)) / 2),
                              width: self.bounds.width - x, font: font)
            } else {
                TranscriptSymbols.draw(self.symbol, in: CGRect(x: x, y: 0, width: 14, height: height), size: font.pointSize,
                                       weight: .semibold, color: color)
            }
            return
        }
        TranscriptSymbols.draw(self.symbol, in: CGRect(x: 0, y: 0, width: 14, height: height), size: font.pointSize, color: color)
        let text = singleLine(self.title, font, color)
        text.drawLine(at: CGPoint(x: 18, y: (height - TranscriptStyle.lineHeight(font)) / 2), width: self.bounds.width - 18, font: font)
    }
}

/// The line under an unsent message: "Queued", "Sending…" or "Failed — reason", then Retry and
/// Delete.
final class TranscriptSendStatusView: TranscriptBaseView {
    private var status: TranscriptPart.SendStatus?
    private let sendNowButton = TranscriptLabelButton()
    private let retryButton = TranscriptLabelButton()
    private let deleteButton = TranscriptLabelButton()
    private weak var actions: TranscriptRowActions?
    private var spinner: TranscriptSpinner?
    /// Where the buttons start, after the status text.
    private var textWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.sendNowButton.set(title: L("Send Now"), symbol: "arrow.up.circle")
        self.sendNowButton.accessibilityText = L("Send now")
        self.sendNowButton.onTap = { [weak self] in
            guard let self, let id = self.status?.id else { return }
            self.actions?.sendNow(id)
        }
        self.retryButton.set(title: L("Retry"), symbol: "arrow.clockwise")
        self.retryButton.accessibilityText = L("Retry sending")
        self.retryButton.onTap = { [weak self] in
            guard let self, let id = self.status?.id else { return }
            self.actions?.retrySend(id)
        }
        self.deleteButton.set(title: L("Delete"), symbol: "trash")
        self.deleteButton.accessibilityText = L("Delete unsent message")
        self.deleteButton.isSubdued = true
        self.deleteButton.onTap = { [weak self] in
            guard let self, let id = self.status?.id else { return }
            self.actions?.deleteSend(id)
        }
        for button in [self.sendNowButton, self.retryButton, self.deleteButton] { self.addSubview(button) }
        // VoiceOver hears the status in the message's label (with Retry and Delete as the row's
        // actions); only the buttons here are elements.
        #if os(iOS)
        self.isAccessibilityElement = false
        #endif
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .sendStatus(status) = part else { return }
        let old = self.status
        self.status = status
        self.actions = actions
        self.sendNowButton.isHidden = !status.canSendNow
        self.retryButton.isHidden = !status.canRetry
        self.deleteButton.isHidden = !status.canDelete
        self.updateSpinner(visible: status.kind == .sending)
        if old != status {
            self.redraw()
            self.setNeedsLayoutContent()
        }
        #if os(macOS)
        self.toolTip = status.detail
        #endif
    }

    override func didHide() { self.updateSpinner(visible: false) }

    /// A small native spinner in the icon slot while sending; created on first use.
    private func updateSpinner(visible: Bool) {
        if !visible {
            self.spinner?.setAnimating(false)
            return
        }
        if self.spinner == nil {
            let view = TranscriptSpinner(size: 12)
            self.addSubview(view)
            self.spinner = view
            self.setNeedsLayoutContent()
        }
        self.spinner?.setAnimating(true)
    }

    private func setNeedsLayoutContent() {
        #if os(macOS)
        self.needsLayout = true
        #else
        self.setNeedsLayout()
        #endif
    }

    #if os(macOS)
    private static let heldSymbol = "pause.circle"
    #else
    private static let heldSymbol = "wifi.exclamationmark"
    #endif

    private var font: PFont { TranscriptStyle.shared.caption }
    private static let iconWidth: CGFloat = 18

    override func layoutContent() {
        let buttons = [self.sendNowButton, self.retryButton, self.deleteButton].filter { !$0.isHidden }
        let buttonsWidth = buttons.reduce(CGFloat(0)) { $0 + $1.buttonSize.width + 10 }
        let natural = Self.iconWidth + singleLine(self.status?.text ?? "", self.font, TranscriptColors.secondary).lineWidth
        let textWidth = min(natural, max(self.bounds.width - buttonsWidth - 4, 40))
        self.spinner?.place(center: CGPoint(x: 7, y: self.bounds.height / 2))
        var x = textWidth + 10
        for button in buttons {
            let size = button.buttonSize
            let frame = CGRect(x: x, y: (self.bounds.height - size.height) / 2, width: size.width, height: size.height)
            if button.frame != frame { button.frame = frame }
            x = frame.maxX + 10
        }
        if textWidth != self.textWidth {
            self.textWidth = textWidth
            self.redraw()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let status else { return }
        let font = self.font
        let color = status.isFailed ? TranscriptColors.red : TranscriptColors.secondary
        let height = self.bounds.height
        let symbol = switch status.kind {
        case .failed: "exclamationmark.circle.fill"
        case .held: Self.heldSymbol
        case .queued: "clock"
        case .sending: ""
        }
        if !symbol.isEmpty {
            TranscriptSymbols.draw(symbol, in: CGRect(x: 0, y: 0, width: 14, height: height), size: font.pointSize, color: color)
        }
        singleLine(status.text, font, color)
            .drawLine(at: CGPoint(x: Self.iconWidth, y: (height - TranscriptStyle.lineHeight(font)) / 2),
                      width: max(self.textWidth - Self.iconWidth, 0), font: font)
    }

    #if os(macOS)
    override func isAccessibilityElement() -> Bool { false }
    #endif
}
