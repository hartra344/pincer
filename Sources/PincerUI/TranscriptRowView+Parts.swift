import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif


// MARK: - Parts

/// Avatars repeat on every row, and drawing emoji is slow, so each distinct avatar is drawn once
/// into a bitmap that the rows share as layer contents.
final class TranscriptAvatarView: TranscriptBaseView {
    private static var cache: [String: CGImage] = [:]
    private var avatar: TranscriptPart.Avatar?
    private var key: String?

    /// The row it's attached to in the live avatar, which animates the latest reply's avatar.
    var liveRowId: String?
    private weak var liveController: TranscriptLiveAvatar?
    /// Set by the live avatar: the chat's state, and the frame to draw (nil holds the still pose).
    private var liveFrame: (state: AvatarState, pose: AvatarPose?)?

    var agentSeed: String { self.avatar?.seed ?? "" }
    var isPlush: Bool { self.avatar?.creature?.renderStyle == .plush }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .avatar(avatar) = part else { return }
        self.avatar = avatar
        if avatar.isAgent, let live = actions.liveAvatar {
            self.liveController = live
            live.attach(self, rowId: row.id, style: avatar.creature)
        } else {
            self.liveController?.detach(self)
            self.liveFrame = nil
        }
        self.refresh()
    }

    override func didHide() {
        self.liveController?.detach(self)
        self.liveFrame = nil
    }

    func showLive(_ frame: (state: AvatarState, pose: AvatarPose?)?) {
        if frame == nil, self.liveFrame == nil { return }
        self.liveFrame = frame
        self.key = nil
        self.refresh()
    }

    override func layoutContent() { self.refresh() }
    override func appearanceChanged() { self.refresh() }

    #if os(macOS)
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        self.key = nil
        self.refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.liveController?.moved(self)
    }

    private var scale: CGFloat { self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var isDark: Bool { self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.liveController?.moved(self)
    }

    private var scale: CGFloat { max(self.traitCollection.displayScale, 1) }
    private var isDark: Bool { self.traitCollection.userInterfaceStyle == .dark }
    #endif

    private func refresh() {
        guard let avatar, self.bounds.width > 0 else { return }
        if let creature = avatar.creature {
            self.refresh(creature, state: avatar.state)
            return
        }
        let top = self.resolved(lighten(avatar.color, by: 0.18)), bottom = self.resolved(avatar.color)
        let size = self.bounds.size, scale = self.scale
        let key = "\(avatar.text)|\(avatar.emoji ?? "")|\(avatar.symbol ?? "")|\(top.components ?? [])|\(bottom.components ?? [])|\(size.width)|\(scale)"
        guard key != self.key else { return }
        self.key = key
        let image = Self.cache[key] ?? Self.render(avatar, top: top, bottom: bottom, size: size, scale: scale)
        if let image {
            if Self.cache.count > 64 { Self.cache.removeAll() }
            Self.cache[key] = image
        }
        withoutLayerAnimations {
            self.hostLayer.contentsScale = scale
            self.hostLayer.contents = image
        }
    }

    /// The companion's pose for the row. Still poses are drawn once per look and shared like the
    /// initials; the live avatar's moving frames are drawn fresh each time.
    private func refresh(_ style: AvatarStyle, state: AvatarState) {
        let size = self.bounds.size, scale = self.scale, dark = self.isDark
        let state = self.liveFrame?.state ?? state
        let accent = AvatarArt.showsGlow(state) ? self.resolved(TranscriptColors.tint) : nil
        let badge = AgentAvatarView.badgeSymbol(for: state)
        let image: CGImage?
        if let pose = self.liveFrame?.pose {
            self.key = nil
            // Animated poses cycle through a few looks, so redraws reuse a bounded cache of bitmaps.
            let key = "live|\(style)|\(state)|\(pose.hashValue)|\(dark)|\(accent?.components ?? [])|\(size.width)|\(scale)"
            image = Self.cache[key] ?? AvatarArt.image(style, pose: pose, dark: dark, accent: accent, badge: badge, size: size, scale: scale)
            if let image {
                if Self.cache.count > 64 { Self.cache.removeAll() }
                Self.cache[key] = image
            }
        } else {
            let key = "creature|\(style)|\(state)|\(dark)|\(accent?.components ?? [])|\(size.width)|\(scale)"
            guard key != self.key else { return }
            self.key = key
            image = Self.cache[key] ?? AvatarArt.image(style, pose: AvatarMotion.keyPose(for: state), dark: dark,
                                                       accent: accent, badge: badge, size: size, scale: scale)
            if let image {
                if Self.cache.count > 64 { Self.cache.removeAll() }
                Self.cache[key] = image
            }
        }
        withoutLayerAnimations {
            self.hostLayer.contentsScale = scale
            self.hostLayer.contents = image
        }
    }

    private static func render(_ avatar: TranscriptPart.Avatar, top: CGColor, bottom: CGColor,
                               size: CGSize, scale: CGFloat) -> CGImage?
    {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Top-left origin, in points, to match how the rest of the transcript draws.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let bounds = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addEllipse(in: bounds)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.maxY), options: [])
        }
        context.restoreGState()
        #if os(macOS)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #endif
        if let symbol = avatar.symbol {
            TranscriptSymbols.draw(symbol, in: bounds.insetBy(dx: size.width * 0.22, dy: size.height * 0.22),
                                   size: size.width * 0.46, weight: .semibold, color: .white)
            return context.makeImage()
        }
        let text: NSAttributedString = if let emoji = avatar.emoji {
            NSAttributedString(string: emoji, attributes: [.font: PFont.systemFont(ofSize: size.width * 0.55)])
        } else {
            NSAttributedString(string: avatar.text, attributes: [
                .font: TranscriptStyle.rounded(size: size.width * 0.38, weight: .semibold),
                .foregroundColor: PColor.white,
            ])
        }
        let textSize = text.size()
        text.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2))
        return context.makeImage()
    }
}

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

/// Packs compact footer actions once in row layout and uses those exact frames to place the views.
/// The one-entry cache is bounded and keyed by the localized labels and the active style generation.
@MainActor
enum CompactFooterPacking {
    struct Result {
        let frames: [TranscriptPart.Footer.Action: CGRect]
        let rowCount: Int
        let rowHeight: CGFloat
    }

    private struct Metric {
        let width: CGFloat
        let outset: CGFloat
        let height: CGFloat
    }

    private struct Cache {
        let key: String
        let values: [TranscriptPart.Footer.Action: Metric]
    }

    private static var cache: Cache?

    private static func metrics() -> [TranscriptPart.Footer.Action: Metric] {
        let copy = L("Copy"), copied = L("Copied"), reply = L("Reply")
        let listen = L("Listen"), stop = L("Stop"), react = L("React")
        let labels = [copy, copied, reply, listen, stop, react]
        let key = "\(TranscriptStyle.generation)|" + labels.joined(separator: "\u{0}")
        if let cache, cache.key == key { return cache.values }

        #if os(iOS)
        let minimumTarget: CGFloat = 44
        #else
        let minimumTarget: CGFloat = 0
        #endif
        func metric(_ titles: [String], minimumWidth: CGFloat = 0, extraHitOutset: CGFloat = 0) -> Metric {
            let sizes = titles.map(TranscriptLabelButton.size(title:))
            let size = sizes.max { $0.width < $1.width } ?? .zero
            let height = sizes.map(\.height).max() ?? 0
            let width = max(minimumWidth, size.width)
            let outset = max(extraHitOutset, max((minimumTarget - width) / 2, 0))
            return Metric(width: width, outset: outset, height: height)
        }
        let values: [TranscriptPart.Footer.Action: Metric] = [
            .bookmark: metric([""], extraHitOutset: minimumTarget == 0 ? 8 : 0),
            .copy: metric([copy, copied], minimumWidth: 80),
            .reply: metric([reply]),
            .listen: metric([listen, stop], minimumWidth: 80),
            .react: metric([react]),
        ]
        self.cache = Cache(key: key, values: values)
        return values
    }

    static func pack(width: CGFloat, actions: [TranscriptPart.Footer.Action], rowHeight: CGFloat) -> Result {
        let metrics = self.metrics()
        let rowHeight = max(rowHeight, actions.compactMap { metrics[$0]?.height }.max() ?? 0)
        var frames: [TranscriptPart.Footer.Action: CGRect] = [:]
        var cursor: CGFloat = 0
        var row = 0
        for action in actions {
            guard let metric = metrics[action] else { continue }
            var x = cursor + metric.outset
            if cursor > 0, x + metric.width + metric.outset > width {
                row += 1
                cursor = 0
                x = metric.outset
            }
            frames[action] = CGRect(x: x, y: CGFloat(row) * rowHeight, width: metric.width, height: rowHeight)
            cursor = x + metric.width + metric.outset + 10
        }
        return Result(frames: frames, rowCount: frames.isEmpty ? 0 : row + 1, rowHeight: rowHeight)
    }

    static func hitOutset(for action: TranscriptPart.Footer.Action) -> CGFloat {
        self.metrics()[action]?.outset ?? 0
    }
}

/// The line under a message: the branch switcher when its branches fork here, Copy, Reply and React, then details such as the time it was sent
/// and its model.
final class TranscriptFooterView: TranscriptBaseView {
    private var footer: TranscriptPart.Footer?
    private var rowID: String?
    private let copyButton = TranscriptLabelButton()
    private let replyButton = TranscriptLabelButton()
    private let reactButton = TranscriptLabelButton()
    private let listenButton = TranscriptLabelButton()
    private let bookmarkButton = TranscriptLabelButton()
    private let previousBranchButton = TranscriptLabelButton()
    private let branchLabel = TranscriptLabelButton()
    private let nextBranchButton = TranscriptLabelButton()
    private weak var actions: TranscriptRowActions?
    private var copiedToken = 0

    private var branchControls: [TranscriptLabelButton] { [self.previousBranchButton, self.branchLabel, self.nextBranchButton] }

    /// Smallest comfortable touch or click target for the branch controls.
    private static var minimumTarget: CGSize {
        #if os(iOS)
        CGSize(width: 44, height: 44)
        #else
        CGSize(width: 28, height: 28)
        #endif
    }

    private func setUpBranchControls() {
        self.previousBranchButton.set(title: "", symbol: "chevron.left")
        self.nextBranchButton.set(title: "", symbol: "chevron.right")
        self.previousBranchButton.accessibilityText = L("Previous branch")
        self.nextBranchButton.accessibilityText = L("Next branch")
        var digits = TranscriptStyle.shared.caption
        #if os(macOS)
        digits = NSFont.monospacedDigitSystemFont(ofSize: digits.pointSize, weight: .regular)
        #else
        digits = UIFont.monospacedDigitSystemFont(ofSize: digits.pointSize, weight: .regular)
        #endif
        self.branchLabel.titleFont = digits
        for button in self.branchControls {
            button.isSubdued = true
            button.isCompact = true
            button.padding = button === self.branchLabel ? 4 : 3
            button.isHidden = true
            #if os(macOS)
            button.showsHover = true
            #endif
            self.addSubview(button)
        }
        self.previousBranchButton.onTap = { [weak self] in self?.stepBranch(-1) }
        self.nextBranchButton.onTap = { [weak self] in self?.stepBranch(1) }
        #if os(macOS)
        self.branchLabel.onTap = { [weak self] in self?.showBranchMenu() }
        #endif
        self.branchLabel.onIncrement = { [weak self] in self?.stepBranch(1) }
        self.branchLabel.onDecrement = { [weak self] in self?.stepBranch(-1) }
        self.branchLabel.accessibilityHintText = L("Choose a branch")
        #if os(iOS)
        self.branchLabel.accessibilityTraits = .adjustable
        #endif
        #if os(iOS)
        self.branchLabel.showsMenuAsPrimaryAction = true
        self.branchLabel.isContextMenuInteractionEnabled = true
        self.branchLabel.menuProvider = { [weak self] in self?.branchMenuElements() ?? [] }
        #endif
    }

    private func stepBranch(_ offset: Int) {
        guard let branch = footer?.branch, branch.canSwitch else { return }
        self.actions?.stepBranch(offset)
    }

    #if os(macOS)
    private func showBranchMenu() {
        guard let branch = footer?.branch, branch.canSwitch, let actions else { return }
        let menu = NSMenu()
        for entry in actions.branchEntries {
            let item = NSMenuItem(title: entry.title, action: #selector(self.pickBranch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.leafEntryId
            item.state = entry.isActive ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: self.branchLabel.bounds.height + 2), in: self.branchLabel)
    }

    @objc private func pickBranch(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        self.actions?.switchBranch(to: id)
    }
    #else
    private func branchMenuElements() -> [UIMenuElement] {
        guard footer?.branch?.canSwitch == true, let actions else { return [] }
        return actions.branchEntries.map { entry in
            UIAction(title: entry.title, image: entry.isActive ? UIImage(systemName: "checkmark") : nil,
                     state: entry.isActive ? .on : .off) { [weak actions] _ in actions?.switchBranch(to: entry.leafEntryId) }
        }
    }
    #endif

    /// Where each visible branch control takes taps: its frame grown to the minimum target (never
    /// left of the footer), with overlaps between neighbours, and with the next button, split at the midpoint.
    private func branchHitFrames() -> [(control: TranscriptLabelButton, frame: CGRect)] {
        let controls = self.branchControls.filter { !$0.isHidden }
        guard !controls.isEmpty else { return [] }
        let target = Self.minimumTarget
        var frames = controls.map { control -> CGRect in
            let f = control.frame
            let grown = f.insetBy(dx: -max((target.width - f.width) / 2, 0), dy: -max((target.height - f.height) / 2, 0))
            return grown.minX < 0 ? CGRect(x: 0, y: grown.minY, width: grown.maxX, height: grown.height) : grown
        }
        for index in frames.indices {
            let next: CGRect? = index + 1 < controls.count
                ? controls[index + 1].frame
                : [self.bookmarkButton, self.copyButton, self.replyButton, self.reactButton].first { !$0.isHidden }?.frame
            guard let next else { continue }
            // In compact rows the branch group owns its own 44pt row. Do not split a touch target
            // at the midpoint of a control on the following action row.
            guard abs(controls[index].frame.midY - next.midY) < max(controls[index].frame.height, next.height) / 2 else { continue }
            let mid = (controls[index].frame.maxX + next.minX) / 2
            frames[index].size.width = max(min(frames[index].maxX, mid) - frames[index].minX, 0)
            if index + 1 < controls.count {
                let right = frames[index + 1]
                frames[index + 1] = CGRect(x: max(right.minX, mid), y: right.minY, width: max(right.maxX - max(right.minX, mid), 0),
                                           height: right.height)
            }
        }
        return Array(zip(controls, frames))
    }

    private func branchControl(at point: CGPoint) -> TranscriptLabelButton? {
        self.branchHitFrames().first { $0.frame.contains(point) }?.control
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = self.convert(point, from: self.superview)
        if let control = self.branchControl(at: local) { return control }
        return super.hitTest(point)
    }
    #else
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        self.branchControl(at: point) != nil || super.point(inside: point, with: event)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let control = self.branchControl(at: point) { return control }
        return super.hitTest(point, with: event)
    }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setUpBranchControls()
        for button in [self.copyButton, self.replyButton, self.reactButton, self.listenButton] {
            button.isSubdued = true
            self.addSubview(button)
        }
        self.bookmarkButton.set(title: "", symbol: "star.fill")
        self.bookmarkButton.accessibilityText = L("Remove Bookmark")
        self.bookmarkButton.hitOutset = CGSize(width: 8, height: 8)
        self.bookmarkButton.isHidden = true
        self.addSubview(self.bookmarkButton)
        self.bookmarkButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId else { return }
            self.actions?.toggleBookmark(id)
        }
        self.showCopy()
        self.copyButton.onTap = { [weak self] in self?.copy() }
        self.replyButton.set(title: L("Reply"), symbol: "arrowshape.turn.up.left")
        self.replyButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId else { return }
            self.actions?.reply(to: id)
        }
        self.listenButton.isHidden = true
        self.listenButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId, let rowID = self.rowID else { return }
            self.actions?.readAloud(id, rowID: rowID)
        }
        self.reactButton.set(title: L("React"), symbol: "face.smiling")
        self.reactButton.accessibilityText = L("Add Reaction")
        self.reactButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId else { return }
            self.actions?.pickReaction(for: id, from: self.reactButton, rect: self.reactButton.bounds)
        }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .footer(footer) = part else { return }
        let old = self.footer
        self.footer = footer
        self.rowID = row.id
        self.actions = actions
        self.copyButton.isHidden = footer.copyText.isEmpty || (footer.compact && footer.actionFrames[.copy] == nil)
        self.replyButton.isHidden = footer.messageId == nil || (footer.compact && footer.actionFrames[.reply] == nil)
        self.reactButton.isHidden = footer.messageId == nil || !actions.reactionsEnabled
            || (footer.compact && footer.actionFrames[.react] == nil)
        self.bookmarkButton.isHidden = footer.messageId == nil || !footer.isBookmarked
            || (footer.compact && footer.actionFrames[.bookmark] == nil)
        self.updateListenButton()
        if old?.branch != footer.branch {
            let branch = footer.branch
            for button in self.branchControls { button.isHidden = branch == nil }
            if let branch {
                self.branchLabel.set(title: L("\(branch.number) / \(branch.count)"), symbol: "")
                self.branchLabel.accessibilityText = L("Branch \(branch.number) of \(branch.count)")
                self.previousBranchButton.isDisabled = !branch.canSwitch || branch.number <= 1
                self.nextBranchButton.isDisabled = !branch.canSwitch || branch.number >= branch.count
                self.branchLabel.isDisabled = !branch.canSwitch
            }
        }
        if old?.isBookmarked != footer.isBookmarked || old?.branch != footer.branch {
            #if os(macOS)
            self.needsLayout = true
            #else
            self.setNeedsLayout()
            #endif
        }
        if old?.key != footer.key {
            self.copiedToken += 1
            self.showCopy()
        }
        if old?.details != footer.details || old?.compact != footer.compact || old?.detailsFrame != footer.detailsFrame {
            self.redraw()
        }
        #if os(macOS)
        self.toolTip = footer.details.isEmpty ? nil : footer.details
        #endif
    }

    /// Read Aloud / Stop Reading Aloud for this message; re-runs when the controller's phase changes.
    private func updateListenButton() {
        guard let footer, !footer.compact || footer.actionFrames[.listen] != nil,
              let id = footer.messageId, let rowID = self.rowID, let actions,
              actions.canReadAloud(id, rowID: rowID) else {
            if !self.listenButton.isHidden { self.listenButton.isHidden = true; self.relayoutFooter() }
            return
        }
        let reading = withObservationTracking {
            actions.isReadingAloud(id)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateListenButton() }
        }
        self.listenButton.set(title: reading ? L("Stop") : L("Listen"), symbol: reading ? "stop.fill" : "speaker.wave.2")
        self.listenButton.accessibilityText = reading ? L("Stop Reading Aloud") : L("Read Aloud")
        if self.listenButton.isHidden { self.listenButton.isHidden = false }
        self.relayoutFooter()
    }

    private func relayoutFooter() {
        #if os(macOS)
        self.needsLayout = true
        #else
        self.setNeedsLayout()
        #endif
    }

    private func showCopy() {
        self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
        self.copyButton.accessibilityText = L("Copy message")
    }

    private func copy() {
        guard let footer else { return }
        Clipboard.copy(footer.copyText)
        self.copyButton.set(title: L("Copied"), symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.showCopy()
        }
    }

    /// Where the details start, after the buttons showing.
    private var detailsX: CGFloat = 0

    /// Exact metadata bounds used by `draw(_:)`; exposed internally for hosted layout tests.
    var detailsDrawFrame: CGRect {
        guard let footer else { return .zero }
        if footer.compact { return footer.detailsFrame }
        let font = TranscriptStyle.shared.caption
        return CGRect(x: self.detailsX, y: (self.bounds.height - TranscriptStyle.lineHeight(font)) / 2,
                      width: max(self.bounds.width - self.detailsX, 0), height: TranscriptStyle.lineHeight(font))
    }

    override func layoutContent() {
        guard let footer else { return }
        if footer.compact {
            self.layoutCompact(footer)
            return
        }
        self.bookmarkButton.hitOutset = CGSize(width: 8, height: 8)
        for button in [self.copyButton, self.replyButton, self.listenButton, self.reactButton] {
            button.hitOutset = .zero
        }
        // The chevron's glyph is narrower than its box; this lines its ink up with the icons above and below.
        var x: CGFloat = self.previousBranchButton.isHidden ? 0 : -4
        var moved = false
        for button in self.branchControls + [self.bookmarkButton, self.copyButton, self.replyButton, self.listenButton, self.reactButton]
        where !button.isHidden {
            let size = button.buttonSize
            let frame = CGRect(x: x, y: (self.bounds.height - size.height) / 2, width: size.width, height: size.height)
            if self.branchControls.contains(where: { $0 === button }) {
                let target = Self.minimumTarget
                button.hitOutset = CGSize(width: max((target.width - size.width) / 2, 0), height: max((target.height - size.height) / 2, 0))
            }
            if button.frame != frame {
                button.frame = frame
                moved = true
            }
            x = frame.maxX + (button === self.previousBranchButton || button === self.branchLabel ? 0
                : button === self.nextBranchButton ? 3 : 10)
        }
        if moved || x != self.detailsX {
            self.detailsX = x
            self.redraw()
        }
    }

    private func layoutCompact(_ footer: TranscriptPart.Footer) {
        var moved = false
        var branchX: CGFloat = self.previousBranchButton.isHidden ? 0 : -4
        for button in self.branchControls where !button.isHidden {
            let size = button.buttonSize
            let frame = CGRect(x: branchX, y: (footer.branchRowHeight - size.height) / 2,
                               width: size.width, height: size.height)
            button.hitOutset = CGSize(width: max((Self.minimumTarget.width - size.width) / 2, 0),
                                      height: max((Self.minimumTarget.height - size.height) / 2, 0))
            if button.frame != frame { button.frame = frame; moved = true }
            branchX = frame.maxX + (button === self.previousBranchButton || button === self.branchLabel ? 0 : 3)
        }

        let actionY = footer.branch == nil ? 0 : footer.branchRowHeight + 4
        let buttons: [(TranscriptPart.Footer.Action, TranscriptLabelButton)] = [
            (.bookmark, self.bookmarkButton), (.copy, self.copyButton), (.reply, self.replyButton),
            (.listen, self.listenButton), (.react, self.reactButton),
        ]
        for (action, button) in buttons where !button.isHidden {
            guard let planned = footer.actionFrames[action] else { continue }
            button.hitOutset = CGSize(width: CompactFooterPacking.hitOutset(for: action), height: 0)
            let frame = planned.offsetBy(dx: 0, dy: actionY)
            if button.frame != frame { button.frame = frame; moved = true }
        }
        if moved { self.redraw() }
    }

    override func draw(_ rect: CGRect) {
        guard let footer, !footer.details.isEmpty else { return }
        let font = TranscriptStyle.shared.caption
        if footer.compact {
            let lineHeight = TranscriptStyle.lineHeight(font)
            for (index, line) in footer.detailLines.prefix(2).enumerated() {
                singleLine(line, font, TranscriptColors.tertiary)
                    .drawLine(at: CGPoint(x: footer.detailsFrame.minX,
                                          y: footer.detailsFrame.minY + CGFloat(index) * lineHeight),
                              width: footer.detailsFrame.width, font: font)
            }
        } else {
            let frame = self.detailsDrawFrame
            singleLine(footer.details, font, TranscriptColors.tertiary)
                .drawLine(at: frame.origin, width: frame.width, font: font)
        }
    }

    #if os(macOS)
    override func isAccessibilityElement() -> Bool { false }
    #endif
}

final class TranscriptCodeView: TranscriptBaseView {
    private var code: TranscriptPart.Code?
    private let scroller = TranscriptScroller(axis: .horizontal)
    private let textView = TranscriptTextView(wraps: false)
    private let copyButton = TranscriptLabelButton()
    private let previewButton = TranscriptLabelButton()
    private var copiedToken = 0
    private var identity: String?
    private weak var actions: TranscriptRowActions?

    var extraCopyItems: [TranscriptRowLayout.CopyItem] {
        self.code.map { [.init(title: L("Copy Code"), text: $0.code)] } ?? []
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.scroller.document.addSubview(self.textView)
        self.addSubview(self.scroller)
        self.addSubview(self.copyButton)
        self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
        self.copyButton.onTap = { [weak self] in self?.copy() }
        self.addSubview(self.previewButton)
        self.previewButton.set(title: L("Preview"), symbol: "eye")
        self.previewButton.onTap = { [weak self] in
            guard let self, let code = self.code else { return }
            self.actions?.previewHTML(code.code)
        }
        self.previewButton.isHidden = true
    }

    override func appearanceChanged() {
        super.appearanceChanged()
        // The buttons draw their own theme color, so redrawing this container does not refresh them.
        // Keep the current title (including "Copied") while resolving the tint from the new theme.
        self.copyButton.redraw()
        self.previewButton.redraw()
    }

    private var showsPreview: Bool {
        self.code.map { HTMLPreview.isPreviewable(language: $0.language, code: $0.code) } ?? false
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .code(code) = part else { return }
        let identity = "\(row.id):\(code.code.hashValue)"
        if identity != self.identity {
            self.copiedToken += 1
            self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
            if self.identity?.hasPrefix(row.id + ":") != true { self.scroller.scrollToStart() }
            self.identity = identity
        }
        let redraw = self.code?.language != code.language || self.code?.headerHeight != code.headerHeight
        self.code = code
        self.actions = actions
        let preview = self.showsPreview
        if self.previewButton.isHidden == preview { self.previewButton.isHidden = !preview }
        self.textView.copyItems = row.copyItems
        self.textView.extraItems = self.extraCopyItems
        self.textView.set(code.text, identity: row.id)
        if redraw { self.redraw() }
    }

    private func copy() {
        guard let code else { return }
        Clipboard.copy(code.code)
        self.copyButton.set(title: L("Copied"), symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
        }
    }

    override func layoutContent() {
        guard let code else { return }
        let bounds = self.bounds
        let button = self.copyButton.buttonSize
        self.copyButton.frame = CGRect(x: bounds.width - 10 - button.width, y: (code.headerHeight - button.height) / 2,
                                       width: button.width, height: button.height)
        if !self.previewButton.isHidden {
            let preview = self.previewButton.buttonSize
            self.previewButton.frame = CGRect(x: self.copyButton.frame.minX - 6 - preview.width, y: (code.headerHeight - preview.height) / 2,
                                              width: preview.width, height: preview.height)
        }
        let top = code.headerHeight + 1
        self.scroller.frame = CGRect(x: 1, y: top, width: max(bounds.width - 2, 1), height: max(bounds.height - top - 1, 1))
        self.scroller.setContentSize(CGSize(width: code.textSize.width + 20, height: code.textSize.height + 19))
        let textFrame = CGRect(x: 9, y: 10, width: code.textSize.width, height: code.textSize.height)
        if self.textView.frame != textFrame { self.textView.frame = textFrame }
    }

    override func draw(_ rect: CGRect) {
        guard let code else { return }
        let bounds = self.bounds
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: TranscriptMetrics.cardRadius)
        TranscriptColors.codeBackground.setFill()
        shape.fill()
        TranscriptColors.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        TranscriptColors.separator.setFill()
        PBezierPath(rect: CGRect(x: 0, y: code.headerHeight, width: bounds.width, height: 1)).fill()
        let font = TranscriptStyle.shared.captionMono
        let label = singleLine(code.language, font, TranscriptColors.secondary)
        label.drawLine(at: CGPoint(x: 10, y: (code.headerHeight - TranscriptStyle.lineHeight(font)) / 2),
                       width: bounds.width - 30 - self.copyButton.buttonSize.width
                           - (self.showsPreview ? self.previewButton.buttonSize.width + 6 : 0), font: font)
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        self.rowView?.menu(extra: self.extraCopyItems, event: event)
    }
    #endif
}

final class TranscriptMarkdownTableView: TranscriptBaseView {
    private let scroller = TranscriptScroller(axis: .horizontal)
    private let grid = TranscriptTableGridView()
    private var rowId: String?

    var extraCopyItems: [TranscriptRowLayout.CopyItem] {
        self.grid.table.map { [.init(title: L("Copy Table"), text: $0.plainText)] } ?? []
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.scroller.document.addSubview(self.grid)
        self.addSubview(self.scroller)
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .table(table) = part else { return }
        if row.id != self.rowId {
            self.rowId = row.id
            self.scroller.scrollToStart()
        }
        self.grid.table = table
        self.grid.frame = CGRect(origin: .zero, size: table.contentSize)
        self.grid.redraw()
    }

    override func layoutContent() {
        if self.scroller.frame != self.bounds { self.scroller.frame = self.bounds }
        self.scroller.setContentSize(self.grid.frame.size)
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        self.rowView?.menu(extra: self.extraCopyItems, event: event)
    }
    #endif
}

final class TranscriptTableGridView: TranscriptBaseView {
    var table: TranscriptPart.Table?

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        (self.superview?.superview?.superview as? TranscriptMarkdownTableView).flatMap { table in
            self.rowView?.menu(extra: table.extraCopyItems, event: event)
        }
    }
    #endif

    override func draw(_ rect: CGRect) {
        guard let table else { return }
        let bounds = self.bounds
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: 6)
        self.drawingContext?.saveGState()
        shape.addClip()
        if let header = table.rowHeights.first {
            TranscriptColors.codeBackground.setFill()
            PBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: header)).fill()
        }
        var y: CGFloat = 0
        for (rowIndex, cells) in table.cells.enumerated() {
            let height = table.rowHeights[rowIndex]
            if rowIndex > 0 {
                TranscriptColors.stroke.setFill()
                PBezierPath(rect: CGRect(x: 0, y: y, width: bounds.width, height: 1)).fill()
            }
            var x: CGFloat = 0
            for (column, cell) in cells.enumerated() where column < table.columnWidths.count {
                let width = table.columnWidths[column]
                let cellRect = CGRect(x: x + 10, y: y + 5, width: max(width - 20, 1), height: max(height - 10, 1))
                if cellRect.intersects(rect) {
                    cell.draw(with: cellRect, options: [.usesLineFragmentOrigin], context: nil)
                }
                x += width
            }
            y += height
        }
        self.drawingContext?.restoreGState()
        TranscriptColors.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

final class TranscriptThinkingHeaderView: TranscriptTapView {
    private var thinking: TranscriptPart.Thinking?
    private let spinner = TranscriptSpinner(size: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
    }

    private var title: String { self.thinking?.title ?? L("Thinking") }

    private var titleWidth: CGFloat {
        singleLine(self.title, TranscriptStyle.shared.calloutMedium, TranscriptColors.secondary).lineWidth
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .thinkingHeader(thinking) = part else { return }
        let changed = self.thinking?.isExpanded != thinking.isExpanded || self.thinking?.isStreaming != thinking.isStreaming
            || self.thinking?.title != thinking.title || self.thinking?.symbol != thinking.symbol
        self.thinking = thinking
        self.spinner.setAnimating(thinking.isStreaming)
        let rowId = row.id
        self.onTap = { [weak actions] in actions?.setExpanded(thinking.key, !thinking.isExpanded, row: rowId) }
        self.accessibilityText = thinking.isExpanded ? L("Hide \(thinking.title.lowercased())") : L("Show \(thinking.title.lowercased())")
        self.hitWidth = self.contentWidth
        if changed { self.redraw() }
    }

    private var contentWidth: CGFloat {
        22 + self.titleWidth + (self.thinking?.isStreaming == true ? 16 : 0) + 6 + 10
    }

    override func layoutContent() {
        self.spinner.place(center: CGPoint(x: 22 + self.titleWidth + 6 + 5, y: self.bounds.midY))
    }

    override func draw(_ rect: CGRect) {
        guard let thinking else { return }
        let style = TranscriptStyle.shared
        let color = self.isPressed ? TranscriptColors.tertiary : TranscriptColors.secondary
        let height = self.bounds.height
        TranscriptSymbols.draw(thinking.symbol, in: CGRect(x: 0, y: 0, width: 16, height: height), size: style.callout.pointSize, color: color)
        let title = singleLine(self.title, style.calloutMedium, color)
        title.drawLine(at: CGPoint(x: 22, y: (height - TranscriptStyle.lineHeight(style.calloutMedium)) / 2), width: title.lineWidth, font: style.calloutMedium)
        let chevronX = 22 + title.lineWidth + 6 + (thinking.isStreaming ? 16 : 0)
        TranscriptSymbols.draw(thinking.isExpanded ? "chevron.down" : "chevron.right",
                               in: CGRect(x: chevronX, y: 0, width: 10, height: height),
                               size: style.caption2Medium.pointSize, weight: .bold, color: color)
    }
}

final class TranscriptToolView: TranscriptBaseView {
    private var part: TranscriptPart.Tool?
    private let header = TranscriptToolHeaderView()
    private let runButton = TranscriptLabelButton()
    private var sections: [TranscriptToolSectionView] = []
    private var rowId: String?
    private let copyButton = TranscriptLabelButton()
    private let toggleButton = TranscriptLabelButton()
    private var copiedToken = 0
    private var controlButtons: [TranscriptLabelButton] = []
    private var noteViews: [TranscriptNoteView] = []
    private var copiedControl: String?
    private weak var actions: TranscriptRowActions?
    let searchBar = TranscriptToolSearchBar()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.header)
        self.addSubview(self.searchBar)
        self.addSubview(self.runButton)
        self.runButton.set(title: L("Open run"), symbol: "sparkles")
        self.addSubview(self.copyButton)
        self.addSubview(self.toggleButton)
        self.copyButton.isSubdued = true
        self.showCopy()
        self.copyButton.onTap = { [weak self] in self?.copyDiff() }
    }

    private func showCopy() {
        self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
        self.copyButton.accessibilityText = self.part?.edit?.kind == .write ? L("Copy file contents") : L("Copy diff")
    }

    private func copyDiff() {
        guard let diff = self.part?.diff else { return }
        // Announces "Copied" through `AccessibilityAnnouncer.announceCopied()`.
        Clipboard.copy(diff.copyText)
        self.copyButton.set(title: L("Copied"), symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.showCopy()
        }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .tool(tool) = part else { return }
        let sameTool = self.part?.tool.id == tool.tool.id && self.rowId == row.id
        self.part = tool
        self.rowId = row.id
        self.actions = actions
        let rowId = row.id
        self.header.configure(tool, trailing: tool.run == nil ? 10 : 6,
                              contextMenu: tool.mcpContextMenu
                                  ?? TranscriptToolContextMenu.make(toolName: tool.tool.name, controls: tool.controls))
        self.header.onOpenMCPServer = { [weak actions] name in actions?.openMCPServer(name) }
        self.header.onTap = { [weak actions] in actions?.setExpanded(tool.key, !tool.isExpanded, row: rowId) }
        let spokenDuration = tool.tool.isRunning ? nil : tool.tool.durationMs.map { ToolDuration.format($0).spoken }
        if let edit = tool.edit {
            #if os(macOS)
            self.header.toolTip = edit.fullPaths
            #endif
            self.header.accessibilityText = AccessibilityText.join([
                edit.accessibilitySummary(isRunning: tool.tool.isRunning), spokenDuration,
                tool.tool.isRunning ? L("running") : nil, tool.tool.isError ? L("failed") : nil,
                tool.isExpanded ? L("expanded") : L("collapsed"),
            ])
        } else {
            let parts = ToolCardName(tool.tool.name)
            #if os(macOS)
            self.header.toolTip = parts.server.map { L("\(parts.tool) on \($0)") }
            #endif
            self.header.accessibilityText = AccessibilityText.join(
                [parts.server.map { L("\(parts.tool) on \($0)") } ?? tool.tool.name, tool.tool.summary, spokenDuration]
                    + [tool.tool.isRunning ? L("running") : nil, tool.tool.isError ? L("failed") : nil,
                       tool.isExpanded ? L("expanded") : L("collapsed")])
        }
        if !sameTool {
            self.copiedToken += 1
            self.copiedControl = nil
            self.showCopy()
        }
        self.configureControls(tool.controls)
        while self.noteViews.count < tool.notes.count {
            let view = TranscriptNoteView()
            self.noteViews.append(view)
            self.addSubview(view)
        }
        for (index, view) in self.noteViews.enumerated() {
            view.isHidden = index >= tool.notes.count
            if index < tool.notes.count { view.set(tool.notes[index].text) }
        }
        if let diff = tool.diff {
            self.copyButton.isHidden = false
            if let title = diff.toggleTitle {
                self.toggleButton.isHidden = false
                self.toggleButton.set(title: title, symbol: diff.isExpanded ? "chevron.up" : "chevron.down")
                self.toggleButton.onTap = { [weak actions] in actions?.setExpanded(diff.key, !diff.isExpanded, row: rowId) }
            } else {
                self.toggleButton.isHidden = true
                self.toggleButton.onTap = nil
            }
        } else {
            self.copyButton.isHidden = true
            self.toggleButton.isHidden = true
            self.toggleButton.onTap = nil
        }
        if let run = tool.run {
            self.runButton.isHidden = false
            self.runButton.onTap = { [weak actions] in actions?.openRun(run.key) }
            #if os(macOS)
            self.runButton.toolTip = L("Open “\(run.title)” to see what this helper did")
            #endif
        } else {
            self.runButton.isHidden = true
            self.runButton.onTap = nil
        }
        while self.sections.count < tool.sections.count {
            let view = TranscriptToolSectionView()
            self.sections.append(view)
            self.addSubview(view)
        }
        for (index, view) in self.sections.enumerated() {
            if index < tool.sections.count {
                view.isHidden = false
                view.configure(tool.sections[index], row: row, resetScroll: !sameTool)
            } else {
                view.isHidden = true
            }
        }
        self.searchBar.configure(tool.search, toolId: tool.tool.id, row: rowId, actions: actions)
        self.redraw()
    }

    private func configureControls(_ controls: [TranscriptPart.Tool.Control]) {
        while self.controlButtons.count < controls.count {
            let button = TranscriptLabelButton()
            button.isSubdued = true
            self.controlButtons.append(button)
            self.addSubview(button)
        }
        for (index, button) in self.controlButtons.enumerated() {
            guard index < controls.count else {
                button.isHidden = true
                button.onTap = nil
                continue
            }
            let control = controls[index]
            button.isHidden = false
            button.isSubdued = control.id != "toggle-output"
            self.applyAppearance(control, to: button)
            button.onTap = { [weak self] in self?.tapped(control) }
        }
    }

    private func applyAppearance(_ control: TranscriptPart.Tool.Control, to button: TranscriptLabelButton) {
        if case .copy = control.action, self.copiedControl == control.id {
            button.set(title: control.iconOnly ? "" : L("Copied"), symbol: "checkmark")
        } else {
            button.set(title: control.title, symbol: control.symbol)
        }
        button.accessibilityText = control.spoken
        // Icon-only buttons are 18×16; 28×28 is the least a finger can hit.
        button.hitOutset = control.iconOnly ? CGSize(width: 5, height: 6) : .zero
    }

    private func tapped(_ control: TranscriptPart.Tool.Control) {
        switch control.action {
        case let .copy(text):
            Clipboard.copy(text)
            self.copiedControl = control.id
            self.copiedToken += 1
            let token = self.copiedToken
            self.refreshControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.copiedToken == token else { return }
                self.copiedControl = nil
                self.refreshControls()
            }
        case let .toggle(key, value):
            guard let rowId else { return }
            self.actions?.setExpanded(key, value, row: rowId)
        case let .openMCPServer(_, toolName: toolName):
            self.actions?.openMCPServer(toolName)
        }
    }

    private func refreshControls() {
        guard let part else { return }
        for (index, control) in part.controls.enumerated() where index < self.controlButtons.count {
            self.applyAppearance(control, to: self.controlButtons[index])
        }
        self.layoutContent()
    }

    override func layoutContent() {
        guard let part else { return }
        let bounds = self.bounds
        for (index, note) in part.notes.enumerated() where index < self.noteViews.count {
            if self.noteViews[index].frame != note.frame { self.noteViews[index].frame = note.frame }
        }
        for (index, control) in part.controls.enumerated() where index < self.controlButtons.count {
            let button = self.controlButtons[index]
            let size = button.buttonSize
            let x = control.trailing ? control.frame.maxX - size.width : control.frame.minX
            let frame = CGRect(x: x, y: control.frame.minY, width: size.width, height: control.frame.height)
            if button.frame != frame { button.frame = frame }
        }
        var headerWidth = bounds.width
        if part.run != nil {
            let size = self.runButton.buttonSize
            let frame = CGRect(x: bounds.width - 10 - size.width, y: (part.headerHeight - size.height) / 2,
                               width: size.width, height: size.height)
            self.runButton.frame = frame
            headerWidth = frame.minX - 4
        }
        let headerFrame = CGRect(x: 0, y: 0, width: headerWidth, height: part.headerHeight)
        if self.header.frame != headerFrame { self.header.frame = headerFrame }
        self.header.layoutContent()
        if let diff = part.diff {
            // The layout sized Copy for "Copied"; pin it to the card's trailing edge at its own width.
            let size = self.copyButton.buttonSize
            let copyFrame = CGRect(x: diff.copyFrame.maxX - size.width, y: diff.copyFrame.minY, width: size.width, height: size.height)
            if self.copyButton.frame != copyFrame { self.copyButton.frame = copyFrame }
            if self.toggleButton.frame != diff.toggleFrame { self.toggleButton.frame = diff.toggleFrame }
        }
        for (index, section) in part.sections.enumerated() where index < self.sections.count {
            let view = self.sections[index]
            if view.frame != section.frame { view.frame = section.frame }
            view.layoutContent()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let bounds = self.bounds
        let style = TranscriptStyle.shared
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: TranscriptMetrics.cardRadius)
        TranscriptColors.fill.setFill()
        shape.fill()
        (part.tool.isError ? TranscriptColors.red.withAlphaComponent(0.5) : TranscriptColors.stroke).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        guard part.isExpanded else { return }
        TranscriptColors.separator.setFill()
        PBezierPath(rect: CGRect(x: 0, y: part.headerHeight, width: bounds.width, height: 1)).fill()
        for item in part.decor {
            switch item {
            case let .block(rect, tone, stroke):
                let shape = PBezierPath.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: 6)
                tone.color.setFill()
                shape.fill()
                (stroke.map { $0.color.withAlphaComponent(0.5) } ?? TranscriptColors.stroke).setStroke()
                shape.lineWidth = 1
                shape.stroke()
            case let .pill(rect, tone):
                tone.badgeFill.setFill()
                PBezierPath.rounded(rect, radius: rect.height / 2).fill()
            case let .label(text, origin, width, face, tone, truncation):
                let font = face.font(style)
                singleLine(text, font, tone.color, truncation: truncation).drawLine(at: origin, width: width, font: font)
            case let .symbol(name, rect, tone):
                TranscriptSymbols.draw(name, in: rect, size: style.caption.pointSize, color: tone.color)
            }
        }
        for section in part.sections where !section.title.isEmpty {
            singleLine(section.title, style.captionSemibold, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: section.titleY), width: bounds.width - 20, font: style.captionSemibold)
        }
        if let y = part.runningY {
            singleLine(L("Running…"), style.caption, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: y), width: bounds.width - 20, font: style.caption)
        }
    }
}

/// An invisible, click-through element that gives drawn chips and badges a VoiceOver label.
final class TranscriptNoteView: TranscriptBaseView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        #else
        self.isAccessibilityElement = true
        self.isUserInteractionEnabled = false
        self.accessibilityTraits = .staticText
        #endif
    }

    func set(_ text: String) {
        #if os(macOS)
        self.setAccessibilityLabel(text)
        #else
        self.accessibilityLabel = text
        #endif
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}

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

final class TranscriptImagePartView: TranscriptTapView {
    private var image: TranscriptPart.Image?
    private var tooLarge = false
    private let imageLayer = CALayer()
    private let spinner = TranscriptSpinner(size: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.imageLayer.contentsGravity = .resizeAspect
        self.imageLayer.cornerRadius = 10
        self.imageLayer.masksToBounds = true
        self.imageLayer.borderWidth = 1
        self.imageLayer.minificationFilter = .trilinear
        self.hostLayer.addSublayer(self.imageLayer)
        self.addSubview(self.spinner)
        self.appearanceChanged()
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .image(image) = part else { return }
        self.image = image
        self.tooLarge = false
        if self.imageLayer.masksToBounds == image.plain {
            withoutLayerAnimations {
                self.imageLayer.masksToBounds = !image.plain
                self.imageLayer.cornerRadius = image.plain ? 0 : 10
                self.imageLayer.borderWidth = image.plain ? 0 : 1
            }
        }
        if case .failed = image.state {
            self.tooLarge = (actions as? TranscriptRenderer)?.context.gateway.images.failure(image.ref) == .tooLarge
        }
        self.accessibilityText = self.tooLarge ? self.tooLargeText(image.ref) : image.ref.alt ?? L("Image")
        switch image.state {
        case let .loaded(cgImage):
            withoutLayerAnimations {
                self.imageLayer.contents = cgImage
                self.imageLayer.isHidden = false
            }
            self.spinner.setAnimating(false)
            self.onTap = { [weak actions] in actions?.preview(image.ref) }
        case .loading:
            withoutLayerAnimations {
                self.imageLayer.contents = nil
                self.imageLayer.isHidden = true
            }
            self.spinner.setAnimating(true)
            self.onTap = nil
            actions.loadImage(image.ref)
        case .failed:
            withoutLayerAnimations {
                self.imageLayer.contents = nil
                self.imageLayer.isHidden = true
            }
            self.spinner.setAnimating(false)
            // Too large to render inline, but the preview sheet can still save or share the file.
            self.onTap = self.tooLarge ? { [weak actions] in actions?.preview(image.ref) } : nil
        }
        self.redraw()
    }

    override func didHide() {
        self.spinner.setAnimating(false)
    }

    override func appearanceChanged() {
        super.appearanceChanged()
        withoutLayerAnimations { self.imageLayer.borderColor = self.resolved(TranscriptColors.stroke) }
    }

    override func layoutContent() {
        withoutLayerAnimations { self.imageLayer.frame = self.bounds }
        self.spinner.place(center: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
    }

    private func tooLargeText(_ ref: ImageRef) -> String {
        ref.alt.map { L("\($0) — too large to preview") } ?? L("Image too large to preview")
    }

    override func draw(_ rect: CGRect) {
        guard let image else { return }
        if case .loaded = image.state { return }
        let bounds = self.bounds
        TranscriptColors.fill.setFill()
        PBezierPath.rounded(bounds, radius: 10).fill()
        guard case .failed = image.state else { return }
        let style = TranscriptStyle.shared
        let text = singleLine(self.tooLarge ? self.tooLargeText(image.ref) : image.ref.alt ?? L("Image unavailable"), style.caption, TranscriptColors.secondary, truncation: .byTruncatingMiddle)
        let textWidth = min(text.lineWidth, bounds.width - 16)
        let iconHeight: CGFloat = 24
        let total = iconHeight + 4 + TranscriptStyle.lineHeight(style.caption)
        let top = (bounds.height - total) / 2
        TranscriptSymbols.draw("photo.badge.exclamationmark", in: CGRect(x: 0, y: top, width: bounds.width, height: iconHeight),
                               size: style.title3.pointSize, color: TranscriptColors.secondary)
        text.drawLine(at: CGPoint(x: (bounds.width - textWidth) / 2, y: top + iconHeight + 4), width: textWidth, font: style.caption)
    }
}


final class TranscriptImageLinkView: TranscriptTapView {
    private var title = ""

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .imageLink(title, url) = part else { return }
        self.title = title
        self.accessibilityText = title
        self.onTap = { [weak actions] in actions?.open(url) }
        #if os(macOS)
        self.toolTip = url.absoluteString
        #endif
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        TranscriptColors.fill.setFill()
        PBezierPath.rounded(bounds, radius: TranscriptMetrics.cardRadius).fill()
        let color = self.isPressed ? TranscriptColors.link.withAlphaComponent(0.5) : TranscriptColors.link
        TranscriptSymbols.draw("photo.badge.arrow.down", in: CGRect(x: 10, y: 0, width: 16, height: bounds.height), size: style.callout.pointSize, color: color)
        singleLine(self.title, style.callout, color)
            .drawLine(at: CGPoint(x: 32, y: (bounds.height - TranscriptStyle.lineHeight(style.callout)) / 2), width: bounds.width - 42, font: style.callout)
    }
}

final class TranscriptFileView: TranscriptBaseView {
    private var part: TranscriptPart.File?
    private let header = TranscriptFileHeaderView()
    private let saveButton = TranscriptLabelButton()
    private let section = TranscriptToolSectionView()
    private var identity: String?
    private var saveToken = 0

    static var saveButtonSize: CGSize {
        let font = TranscriptStyle.shared.caption
        return CGSize(width: 14 + 4 + singleLine(L("Save"), font, TranscriptColors.tint).lineWidth,
                      height: max(TranscriptStyle.lineHeight(font), 16))
    }

    /// Collapsed chip width; mirrors the header's drawing and `layoutContent` so the name never truncates needlessly.
    static func chipWidth(for ref: FileRef, canExpand: Bool) -> CGFloat {
        let name = singleLine(ref.name, TranscriptStyle.shared.callout, TranscriptColors.label).lineWidth.rounded(.up)
        var width = TranscriptFileHeaderView.textX + name + (canExpand ? TranscriptFileHeaderView.chevronSpace : 0) + 10
        if ref.isDownloadable { width += 4 + self.saveButtonSize.width.rounded(.up) + 10 }
        return width
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.header)
        self.addSubview(self.saveButton)
        self.addSubview(self.section)
        self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .file(file) = part else { return }
        let identity = "\(row.id):\(file.key)"
        let sameFile = identity == self.identity
        if !sameFile {
            self.saveToken += 1
            self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            self.identity = identity
        }
        self.part = file
        let rowId = row.id
        self.header.configure(file)
        if HTMLPreview.isPreviewable(file: file.ref) {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.previewHTML(file.ref, actions: actions)
            }
            self.header.accessibilityText = L("Preview \(file.ref.name)")
        } else if file.canExpand {
            self.header.onTap = { [weak actions] in
                if !file.isExpanded { actions?.loadFilePreview(file.ref) }
                actions?.setExpanded(file.key, !file.isExpanded, row: rowId)
            }
            self.header.accessibilityText = file.isExpanded ? L("Attachment \(file.ref.name), expanded") : L("Attachment \(file.ref.name), collapsed")
        } else if FilePreviewFiles.isPreviewable(file.ref) {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.quickLook(file.ref, actions: actions)
            }
            self.header.accessibilityText = L("Preview \(file.ref.name)")
        } else if file.ref.isDownloadable {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.save(file.ref, actions: actions)
            }
            self.header.accessibilityText = L("Save \(file.ref.name)")
        } else {
            self.header.onTap = nil
            self.header.accessibilityText = L("Attachment \(file.ref.name)")
        }
        self.saveButton.isHidden = !file.ref.isDownloadable
        self.saveButton.onTap = { [weak self, weak actions] in
            guard let actions else { return }
            self?.save(file.ref, actions: actions)
        }
        #if os(macOS)
        self.saveButton.toolTip = L("Save “\(file.ref.name)”")
        #endif
        if file.isExpanded, file.section == nil, file.note == L("Loading…") { actions.loadFilePreview(file.ref) }
        if let section = file.section {
            self.section.isHidden = false
            self.section.configure(section, row: row, resetScroll: !sameFile)
        } else {
            self.section.isHidden = true
        }
        self.redraw()
    }

    /// Downloads the file for Quick Look; the Save button's symbol shows the download, as for saving.
    private func quickLook(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: L("Save"), symbol: "hourglass")
        Task { @MainActor [weak self] in
            let shown = await actions.quickLook(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: L("Save"), symbol: shown ? "arrow.down.circle" : "exclamationmark.triangle")
            guard !shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            }
        }
    }

    private func previewHTML(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: L("Save"), symbol: "hourglass")
        Task { @MainActor [weak self] in
            let shown = await actions.previewHTML(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: L("Save"), symbol: shown ? "arrow.down.circle" : "exclamationmark.triangle")
            #if os(macOS)
            if !shown { self.saveButton.toolTip = L("Couldn’t load “\(file.name)”") }
            #endif
            guard !shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            }
        }
    }

    /// The button keeps its "Save" title, so the chip keeps its width; the symbol shows progress.
    private func save(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: L("Save"), symbol: "hourglass")
        Task { @MainActor [weak self] in
            let saved = await actions.saveFile(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: L("Save"), symbol: saved ? "arrow.down.circle" : "exclamationmark.triangle")
            #if os(macOS)
            if !saved { self.saveButton.toolTip = L("Couldn’t download “\(file.name)”") }
            #endif
            guard !saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            }
        }
    }

    override func layoutContent() {
        guard let part else { return }
        let bounds = self.bounds
        var headerWidth = bounds.width
        if part.ref.isDownloadable {
            let size = self.saveButton.buttonSize
            let frame = CGRect(x: bounds.width - 10 - size.width, y: (part.headerHeight - size.height) / 2,
                               width: size.width, height: size.height)
            if self.saveButton.frame != frame { self.saveButton.frame = frame }
            headerWidth = frame.minX - 4
        }
        let headerFrame = CGRect(x: 0, y: 0, width: max(headerWidth, 1), height: part.headerHeight)
        if self.header.frame != headerFrame { self.header.frame = headerFrame }
        self.header.layoutContent()
        if let section = part.section {
            if self.section.frame != section.frame { self.section.frame = section.frame }
            self.section.layoutContent()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let bounds = self.bounds
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: TranscriptMetrics.cardRadius)
        TranscriptColors.fill.setFill()
        shape.fill()
        guard part.isExpanded else { return }
        TranscriptColors.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        TranscriptColors.separator.setFill()
        PBezierPath(rect: CGRect(x: 0, y: part.headerHeight, width: bounds.width, height: 1)).fill()
        if let note = part.note {
            let font = TranscriptStyle.shared.caption
            singleLine(note, font, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: part.noteY), width: bounds.width - 20, font: font)
        }
    }
}

final class TranscriptFileHeaderView: TranscriptTapView {
    private var part: TranscriptPart.File?
    static let textX: CGFloat = 32
    static let chevronSpace: CGFloat = 18

    func configure(_ part: TranscriptPart.File) {
        self.part = part
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        if self.isPressed {
            TranscriptColors.highlight.setFill()
            PBezierPath.rounded(bounds.insetBy(dx: 1, dy: 1), radius: TranscriptMetrics.cardRadius - 1).fill()
        }
        let symbol = part.ref.isText ? "doc.text" : "paperclip"
        TranscriptSymbols.draw(symbol, in: CGRect(x: 10, y: 0, width: 16, height: bounds.height),
                               size: style.callout.pointSize, color: TranscriptColors.label)
        var trailing = bounds.width - 10
        if part.canExpand {
            trailing -= 10
            TranscriptSymbols.draw(part.isExpanded ? "chevron.down" : "chevron.right",
                                   in: CGRect(x: trailing, y: 0, width: 10, height: bounds.height),
                                   size: style.caption2Medium.pointSize, weight: .bold, color: TranscriptColors.tertiary)
            trailing -= 8
        }
        singleLine(part.ref.name, style.callout, TranscriptColors.label, truncation: .byTruncatingMiddle)
            .drawLine(at: CGPoint(x: Self.textX, y: (bounds.height - TranscriptStyle.lineHeight(style.callout)) / 2),
                      width: max(trailing - Self.textX, 1), font: style.callout)
    }
}

final class TranscriptTypingView: TranscriptBaseView {
    private let dots = (0..<3).map { _ in CALayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (index, dot) in self.dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 10, y: 4, width: 6, height: 6)
            dot.cornerRadius = 3
            self.hostLayer.addSublayer(dot)
        }
        self.appearanceChanged()
        #if os(macOS)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.progressIndicator)
        self.setAccessibilityLabel(L("Working"))
        #else
        self.isAccessibilityElement = true
        self.accessibilityLabel = L("Working")
        #endif
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        self.animate()
    }

    override func appearanceChanged() {
        withoutLayerAnimations {
            for dot in self.dots { dot.backgroundColor = self.resolved(TranscriptColors.secondary) }
        }
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil { self.animate() }
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil { self.animate() }
    }
    #endif

    private func animate() {
        for (index, dot) in self.dots.enumerated() where dot.animation(forKey: "pulse") == nil {
            let steps = 24
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = (0...steps).map { step in
                let phase = Double(step) / Double(steps) * .pi * 2
                return 0.3 + 0.7 * max(0, sin(phase - Double(index) * 0.8))
            }
            animation.duration = 1.2
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            dot.add(animation, forKey: "pulse")
        }
    }
}

final class TranscriptMarkerView: TranscriptBaseView {
    private var label = ""

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .marker(label) = part else { return }
        guard label != self.label else { return }
        self.label = label
        #if os(macOS)
        self.toolTip = label.hasPrefix("Context") ? L("Earlier messages were summarized for the agent. They're still shown here.") : nil
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel(label)
        #else
        self.isAccessibilityElement = true
        self.accessibilityLabel = label
        #endif
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        let text = singleLine(self.label, style.caption, TranscriptColors.secondary)
        let textWidth = min(text.lineWidth, bounds.width - 60)
        let contentWidth = 14 + 4 + textWidth
        let x = (bounds.width - contentWidth) / 2
        let lineHeight = TranscriptStyle.lineHeight(style.caption)
        let y = (bounds.height - lineHeight) / 2
        let symbol = self.label.hasPrefix("Context") || self.label.hasPrefix("Compacting") ? "archivebox" : "sparkle"
        TranscriptSymbols.draw(symbol, in: CGRect(x: x, y: y, width: 14, height: lineHeight), size: style.caption.pointSize, color: TranscriptColors.secondary)
        text.drawLine(at: CGPoint(x: x + 18, y: y), width: textWidth, font: style.caption)
        TranscriptColors.separator.setFill()
        let midY = floor(bounds.midY)
        PBezierPath(rect: CGRect(x: 0, y: midY, width: max(x - 8, 0), height: 1)).fill()
        let rightX = x + contentWidth + 8
        PBezierPath(rect: CGRect(x: rightX, y: midY, width: max(bounds.width - rightX, 0), height: 1)).fill()
    }
}

final class TranscriptLoadingView: TranscriptBaseView {
    private let spinner = TranscriptSpinner(size: 16)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        self.spinner.setAnimating(true)
    }

    override func didHide() {
        self.spinner.setAnimating(false)
    }

    override func layoutContent() {
        self.spinner.place(center: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
    }
}
