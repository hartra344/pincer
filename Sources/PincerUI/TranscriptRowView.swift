import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Platform base views

#if os(macOS)
/// Top-left-origin view that lays out and draws the same way on both platforms.
class TranscriptBaseView: NSView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        self.layoutContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.appearanceChanged()
    }

    /// Positions subviews for the current bounds. Called directly after configuring, not only in a
    /// layout pass, so a recycled view is right the first time it's drawn.
    func layoutContent() {}
    func appearanceChanged() { self.redraw() }
    func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {}
    func didHide() {}

    func redraw() { self.needsDisplay = true }

    var viewAlpha: CGFloat {
        get { self.alphaValue }
        set { self.alphaValue = newValue }
    }

    var drawingContext: CGContext? { NSGraphicsContext.current?.cgContext }

    var hostLayer: CALayer { self.layer! }

    /// A dynamic color resolved for this view's appearance, for use on layers.
    func resolved(_ color: PColor) -> CGColor {
        var result = color.cgColor
        self.effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    var rowView: TranscriptRowView? {
        var view = self.superview
        while let current = view {
            if let row = current as? TranscriptRowView { return row }
            view = current.superview
        }
        return nil
    }
}
#else
/// Top-left-origin view that lays out and draws the same way on both platforms. A control, so
/// tappable parts get highlighting and touch tracking from UIKit.
class TranscriptBaseView: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.contentMode = .redraw
        self.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: TranscriptBaseView, _) in
            view.appearanceChanged()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutContent()
    }

    func layoutContent() {}
    func appearanceChanged() { self.redraw() }
    func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {}
    func didHide() {}

    func redraw() { self.setNeedsDisplay() }

    var viewAlpha: CGFloat {
        get { self.alpha }
        set { self.alpha = newValue }
    }

    var drawingContext: CGContext? { UIGraphicsGetCurrentContext() }

    var hostLayer: CALayer { self.layer }

    func resolved(_ color: PColor) -> CGColor {
        color.resolvedColor(with: self.traitCollection).cgColor
    }

    var rowView: TranscriptRowView? {
        var view = self.superview
        while let current = view {
            if let row = current as? TranscriptRowView { return row }
            view = current.superview
        }
        return nil
    }
}
#endif

/// A part that responds to clicks and taps, and reads as a button to accessibility.
class TranscriptTapView: TranscriptBaseView {
    var onTap: (() -> Void)?
    /// Only this much of the width, from the leading edge, takes clicks. Nil means all of it.
    var hitWidth: CGFloat?
    var accessibilityText = "" {
        didSet {
            #if os(iOS)
            self.accessibilityLabel = self.accessibilityText
            #endif
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        self.addTarget(self, action: #selector(self.tapped), for: .touchUpInside)
        self.addInteraction(UIPointerInteraction(delegate: nil))
        #endif
    }

    #if os(macOS)
    private(set) var isPressed = false {
        didSet { if oldValue != self.isPressed { self.redraw() } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitWidth, self.onTap != nil else { return super.hitTest(point) }
        let local = self.convert(point, from: self.superview)
        return local.x <= hitWidth ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard self.onTap != nil else { return super.mouseDown(with: event) }
        self.isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard self.onTap != nil else { return super.mouseDragged(with: event) }
        self.isPressed = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard self.onTap != nil else { return super.mouseUp(with: event) }
        let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        self.isPressed = false
        if inside { self.onTap?() }
    }

    override func isAccessibilityElement() -> Bool { self.onTap != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { self.accessibilityText }
    override func accessibilityPerformPress() -> Bool {
        self.onTap?()
        return self.onTap != nil
    }
    #else
    var isPressed: Bool { self.isHighlighted }

    override var isHighlighted: Bool {
        didSet { if oldValue != self.isHighlighted { self.redraw() } }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let hitWidth, point.x > hitWidth { return false }
        return super.point(inside: point, with: event)
    }

    @objc private func tapped() { self.onTap?() }
    #endif
}

// MARK: - Platform controls

#if os(macOS)
/// Selectable, non-editable TextKit 1 text, laid out exactly like `TranscriptText.size`.
final class TranscriptTextView: NSTextView {
    private let backing: NSTextStorage
    private var shown: NSAttributedString?
    private var identity: String?
    var copyItems: [TranscriptRowLayout.CopyItem] = []
    var extraItems: [TranscriptRowLayout.CopyItem] = []

    init(wraps: Bool) {
        let (storage, container) = TranscriptTextKit.stack(wraps: wraps)
        self.backing = storage
        super.init(frame: .zero, textContainer: container)
        self.isEditable = false
        self.isSelectable = true
        self.isRichText = true
        self.drawsBackground = false
        self.textContainerInset = .zero
        self.isVerticallyResizable = false
        self.isHorizontallyResizable = false
        self.usesFontPanel = false
        self.isAutomaticLinkDetectionEnabled = false
        self.isAutomaticDataDetectionEnabled = false
        container.widthTracksTextView = wraps
        container.heightTracksTextView = false
        self.applyLinkColor()
    }

    private var linkTheme: ThemeColor??

    /// Link color lives on the view, not the text, so a theme change has to reach reused views.
    private func applyLinkColor() {
        let theme = AppTheme.current.value(.link)
        guard self.linkTheme != .some(theme) else { return }
        self.linkTheme = .some(theme)
        self.linkTextAttributes = [
            .foregroundColor: TranscriptColors.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        self.backing = container?.layoutManager?.textStorage ?? NSTextStorage()
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `text`. `identity` is the row it belongs to: selection survives updates to the same
    /// row (a streaming reply) and clears when the view is reused for another one.
    func set(_ text: NSAttributedString, identity: String) {
        self.applyLinkColor()
        guard text !== self.shown || identity != self.identity else { return }
        let selection = self.selectedRange()
        let sameRow = identity == self.identity
        self.shown = text
        self.identity = identity
        self.backing.setAttributedString(text)
        if sameRow, selection.length > 0, NSMaxRange(selection) <= text.length {
            self.setSelectedRange(selection)
        } else {
            self.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let items = self.extraItems + self.copyItems
        guard !items.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() {
            menu.insertItem(TranscriptMenuItem(item.title) { Clipboard.copy(item.text) }, at: 0)
        }
        return menu
    }
}

@MainActor
final class TranscriptMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(self.run), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { self.handler() }
}

/// A scroll view inside the transcript (code, tables, tool output). Scroll gestures it can't use
/// go on to the transcript, so the page keeps scrolling when the pointer passes over one.
final class TranscriptScroller: NSScrollView {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let document = FlippedDocumentView()
    private var ownsGesture = false

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        self.drawsBackground = false
        self.borderType = .noBorder
        self.hasHorizontalScroller = axis == .horizontal
        self.hasVerticalScroller = axis == .vertical
        self.autohidesScrollers = true
        self.scrollerStyle = .overlay
        self.usesPredominantAxisScrolling = true
        self.horizontalScrollElasticity = axis == .horizontal ? .automatic : .none
        self.verticalScrollElasticity = axis == .vertical ? .automatic : .none
        self.documentView = self.document
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setContentSize(_ size: CGSize) {
        if self.document.frame.size != size { self.document.setFrameSize(size) }
    }

    func scrollToStart() {
        self.contentView.scroll(to: .zero)
        self.reflectScrolledClipView(self.contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            self.ownsGesture = self.canScroll(event)
        }
        if self.ownsGesture {
            super.scrollWheel(with: event)
        } else {
            self.nextResponder?.scrollWheel(with: event)
        }
    }

    private func canScroll(_ event: NSEvent) -> Bool {
        let content = self.document.frame.size, visible = self.contentView.bounds.size
        switch self.axis {
        case .horizontal:
            return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && content.width > visible.width + 0.5
        case .vertical:
            return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) && content.height > visible.height + 0.5
        }
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class TranscriptSpinner: NSProgressIndicator {
    let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        self.style = .spinning
        self.controlSize = size <= 12 ? .mini : .small
        self.isDisplayedWhenStopped = false
        self.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setAnimating(_ animating: Bool) {
        guard animating == self.isHidden else { return }
        self.isHidden = !animating
        if animating { self.startAnimation(nil) } else { self.stopAnimation(nil) }
    }

    func place(center: CGPoint) {
        let frame = CGRect(x: center.x - self.size / 2, y: center.y - self.size / 2, width: self.size, height: self.size)
        if self.frame != frame { self.frame = frame }
    }
}
#else
/// Selectable, non-editable TextKit 1 text, laid out exactly like `TranscriptText.size`.
final class TranscriptTextView: UITextView, UITextViewDelegate {
    private let backing: NSTextStorage
    private var shown: NSAttributedString?
    private var identity: String?
    var copyItems: [TranscriptRowLayout.CopyItem] = []
    var extraItems: [TranscriptRowLayout.CopyItem] = []

    init(wraps: Bool) {
        let (storage, container) = TranscriptTextKit.stack(wraps: wraps)
        self.backing = storage
        super.init(frame: .zero, textContainer: container)
        self.isEditable = false
        self.isSelectable = true
        self.isScrollEnabled = false
        self.backgroundColor = .clear
        self.textContainerInset = .zero
        self.dataDetectorTypes = []
        self.adjustsFontForContentSizeCategory = false
        self.applyLinkColor()
        container.widthTracksTextView = wraps
        container.heightTracksTextView = false
        self.delegate = self
    }

    private var linkTheme: ThemeColor??

    /// Link color lives on the view, not the text, so a theme change has to reach reused views.
    private func applyLinkColor() {
        let theme = AppTheme.current.value(.link)
        guard self.linkTheme != .some(theme) else { return }
        self.linkTheme = .some(theme)
        self.linkTextAttributes = [.foregroundColor: TranscriptColors.link]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: NSAttributedString, identity: String) {
        self.applyLinkColor()
        guard text !== self.shown || identity != self.identity else { return }
        let selection = self.selectedRange
        let sameRow = identity == self.identity
        self.shown = text
        self.identity = identity
        self.backing.setAttributedString(text)
        if sameRow, selection.length > 0, NSMaxRange(selection) <= text.length {
            self.selectedRange = selection
        } else if self.selectedRange.length > 0 {
            self.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    // The storage is replaced directly (not through `attributedText`), which UIKit's cached
    // accessibility text doesn't see, so recycled rows would read out a previous message.
    override var accessibilityValue: String? {
        get { self.backing.string }
        set {}
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let items = self.extraItems + self.copyItems
        guard !items.isEmpty else { return nil }
        let extras = items.map { item in UIAction(title: item.title) { _ in Clipboard.copy(item.text) } }
        return UIMenu(children: suggestedActions + [UIMenu(options: .displayInline, children: extras)])
    }
}

/// A scroll view inside the transcript (code, tables, tool output).
final class TranscriptScroller: UIScrollView {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let document = UIView()

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        self.backgroundColor = .clear
        self.showsHorizontalScrollIndicator = axis == .horizontal
        self.showsVerticalScrollIndicator = axis == .vertical
        self.alwaysBounceHorizontal = false
        self.alwaysBounceVertical = false
        self.isDirectionalLockEnabled = true
        self.scrollsToTop = false
        self.addSubview(self.document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setContentSize(_ size: CGSize) {
        if self.contentSize != size { self.contentSize = size }
        if self.document.frame.size != size { self.document.frame = CGRect(origin: .zero, size: size) }
    }

    func scrollToStart() {
        self.contentOffset = .zero
    }
}

final class TranscriptSpinner: UIActivityIndicatorView {
    let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(style: .medium)
        self.hidesWhenStopped = true
        let scale = size / 20
        self.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setAnimating(_ animating: Bool) {
        guard animating != self.isAnimating else { return }
        if animating { self.startAnimating() } else { self.stopAnimating() }
    }

    func place(center: CGPoint) {
        if self.center != center { self.center = center }
    }
}
#endif

private func withoutLayerAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

private func lighten(_ color: PColor, by amount: CGFloat) -> PColor {
    #if os(macOS)
    guard let rgb = color.usingColorSpace(.sRGB) else { return color }
    return rgb.blended(withFraction: amount, of: .white) ?? color
    #else
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
    return UIColor(red: red + (1 - red) * amount, green: green + (1 - green) * amount,
                   blue: blue + (1 - blue) * amount, alpha: alpha)
    #endif
}

private func singleLine(_ text: String, _ font: PFont, _ color: PColor,
                        truncation: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString
{
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = truncation
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}

@MainActor private extension NSAttributedString {
    var lineWidth: CGFloat { ceil(self.size().width) }

    /// Draws on one line from `origin`, truncated to `width`.
    func drawLine(at origin: CGPoint, width: CGFloat, font: PFont) {
        guard width > 1 else { return }
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: TranscriptStyle.lineHeight(font))
        self.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

// MARK: - Row view

/// A transcript row drawn natively. Holds a pool of part views per kind and reuses them in order,
/// so configuring a recycled row for another message creates nothing new in the common case.
final class TranscriptRowView: TranscriptBaseView {
    private var pool: [TranscriptPart.Kind: [TranscriptBaseView]] = [:]
    private(set) var layout: TranscriptRowLayout?
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
        }
    }

    func copyItems(extra: [TranscriptRowLayout.CopyItem] = []) -> [TranscriptRowLayout.CopyItem] {
        extra + (self.layout?.copyItems ?? [])
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        self.menu(extra: [])
    }

    func menu(extra: [TranscriptRowLayout.CopyItem]) -> NSMenu? {
        let items = self.copyItems(extra: extra)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items { menu.addItem(TranscriptMenuItem(item.title) { Clipboard.copy(item.text) }) }
        return menu
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
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: items.map { item in
                UIAction(title: item.title, image: UIImage(systemName: "doc.on.doc")) { _ in Clipboard.copy(item.text) }
            })
        }
    }
}
#endif

// MARK: - Parts

/// Avatars repeat on every row, and drawing emoji is slow, so each distinct avatar is drawn once
/// into a bitmap that the rows share as layer contents.
final class TranscriptAvatarView: TranscriptBaseView {
    private static var cache: [String: CGImage] = [:]
    private var avatar: TranscriptPart.Avatar?
    private var key: String?

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .avatar(avatar) = part else { return }
        self.avatar = avatar
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

    private var scale: CGFloat { self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    #else
    private var scale: CGFloat { max(self.traitCollection.displayScale, 1) }
    #endif

    private func refresh() {
        guard let avatar, self.bounds.width > 0 else { return }
        let top = self.resolved(lighten(avatar.color, by: 0.18)), bottom = self.resolved(avatar.color)
        let size = self.bounds.size, scale = self.scale
        let key = "\(avatar.text)|\(avatar.emoji ?? "")|\(top.components ?? [])|\(bottom.components ?? [])|\(size.width)|\(scale)"
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
        let text: NSAttributedString = if let emoji = avatar.emoji {
            NSAttributedString(string: emoji, attributes: [.font: PFont.systemFont(ofSize: size.width * 0.55)])
        } else {
            NSAttributedString(string: avatar.text, attributes: [
                .font: TranscriptStyle.rounded(size: size.width * 0.38, weight: .semibold),
                .foregroundColor: PColor.white,
            ])
        }
        #if os(macOS)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #endif
        let textSize = text.size()
        text.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2))
        return context.makeImage()
    }
}

final class TranscriptHeaderView: TranscriptBaseView {
    private var header: TranscriptPart.Header?
    private let spinner = TranscriptSpinner(size: 10)

    private struct Positions {
        var nameWidth: CGFloat = 0
        var badgeRect: CGRect?
        var timeX: CGFloat?
        var spinnerCenter: CGPoint?
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .header(header) = part else { return }
        let old = self.header
        self.header = header
        self.spinner.setAnimating(header.isPending)
        if old?.name != header.name || old?.badge != header.badge || old?.time != header.time || old?.isPending != header.isPending {
            self.redraw()
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
        if let center = self.positions().spinnerCenter { self.spinner.place(center: center) }
    }

    private var style: TranscriptStyle { TranscriptStyle.shared }

    private func positions() -> Positions {
        guard let header else { return Positions() }
        let style = self.style
        let baseline = style.headline.ascender
        var reserved: CGFloat = 0
        let badgeWidth = header.badge.map { singleLine($0, style.caption2Medium, TranscriptColors.secondary).lineWidth + 10 }
        let timeWidth = header.time.map { singleLine($0, style.caption, TranscriptColors.tertiary).lineWidth }
        if let badgeWidth { reserved += 6 + badgeWidth }
        if let timeWidth { reserved += 6 + timeWidth }
        if header.isPending { reserved += 6 + 10 }
        let natural = singleLine(header.name, style.headline, TranscriptColors.label).lineWidth
        var positions = Positions()
        positions.nameWidth = max(0, min(natural, self.bounds.width - reserved))
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

    override func draw(_ rect: CGRect) {
        guard let header else { return }
        let style = self.style
        let positions = self.positions()
        let baseline = style.headline.ascender
        singleLine(header.name, style.headline, TranscriptColors.label)
            .drawLine(at: .zero, width: positions.nameWidth, font: style.headline)
        if let badge = header.badge, let rect = positions.badgeRect {
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

    func set(title: String, symbol: String) {
        guard title != self.title || symbol != self.symbol else { return }
        self.title = title
        self.symbol = symbol
        self.accessibilityText = title
        self.redraw()
    }

    var buttonSize: CGSize {
        let font = TranscriptStyle.shared.caption
        return CGSize(width: 14 + 4 + singleLine(self.title, font, TranscriptColors.tint).lineWidth,
                      height: max(TranscriptStyle.lineHeight(font), 16))
    }

    override func draw(_ rect: CGRect) {
        let font = TranscriptStyle.shared.caption
        let base = self.isSubdued ? TranscriptColors.secondary : TranscriptColors.tint
        let color = self.isPressed ? base.withAlphaComponent(0.5) : base
        let height = self.bounds.height
        TranscriptSymbols.draw(self.symbol, in: CGRect(x: 0, y: 0, width: 14, height: height), size: font.pointSize, color: color)
        let text = singleLine(self.title, font, color)
        text.drawLine(at: CGPoint(x: 18, y: (height - TranscriptStyle.lineHeight(font)) / 2), width: self.bounds.width - 18, font: font)
    }
}

/// The line under a message: Copy, then details such as the time it was sent and its model.
final class TranscriptFooterView: TranscriptBaseView {
    private var footer: TranscriptPart.Footer?
    private let copyButton = TranscriptLabelButton()
    private var copiedToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.copyButton.isSubdued = true
        self.addSubview(self.copyButton)
        self.showCopy()
        self.copyButton.onTap = { [weak self] in self?.copy() }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .footer(footer) = part else { return }
        let old = self.footer
        self.footer = footer
        if old?.key != footer.key {
            self.copiedToken += 1
            self.showCopy()
        }
        if old?.details != footer.details { self.redraw() }
        #if os(macOS)
        self.toolTip = footer.details.isEmpty ? nil : footer.details
        #endif
    }

    private func showCopy() {
        self.copyButton.set(title: "Copy", symbol: "doc.on.doc")
        self.copyButton.accessibilityText = "Copy message"
    }

    private func copy() {
        guard let footer else { return }
        Clipboard.copy(footer.copyText)
        self.copyButton.set(title: "Copied", symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.showCopy()
        }
    }

    override func layoutContent() {
        let size = self.copyButton.buttonSize
        let frame = CGRect(x: 0, y: (self.bounds.height - size.height) / 2, width: size.width, height: size.height)
        if self.copyButton.frame != frame {
            self.copyButton.frame = frame
            self.redraw()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let footer, !footer.details.isEmpty else { return }
        let font = TranscriptStyle.shared.caption
        let x = self.copyButton.frame.maxX + 10
        singleLine(footer.details, font, TranscriptColors.tertiary)
            .drawLine(at: CGPoint(x: x, y: (self.bounds.height - TranscriptStyle.lineHeight(font)) / 2),
                      width: self.bounds.width - x, font: font)
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
    private var copiedToken = 0
    private var identity: String?

    var extraCopyItems: [TranscriptRowLayout.CopyItem] {
        self.code.map { [.init(title: "Copy Code", text: $0.code)] } ?? []
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.scroller.document.addSubview(self.textView)
        self.addSubview(self.scroller)
        self.addSubview(self.copyButton)
        self.copyButton.set(title: "Copy", symbol: "doc.on.doc")
        self.copyButton.onTap = { [weak self] in self?.copy() }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .code(code) = part else { return }
        let identity = "\(row.id):\(code.code.hashValue)"
        if identity != self.identity {
            self.copiedToken += 1
            self.copyButton.set(title: "Copy", symbol: "doc.on.doc")
            if self.identity?.hasPrefix(row.id + ":") != true { self.scroller.scrollToStart() }
            self.identity = identity
        }
        let redraw = self.code?.language != code.language || self.code?.headerHeight != code.headerHeight
        self.code = code
        self.textView.copyItems = row.copyItems
        self.textView.extraItems = self.extraCopyItems
        self.textView.set(code.text, identity: row.id)
        if redraw { self.redraw() }
    }

    private func copy() {
        guard let code else { return }
        Clipboard.copy(code.code)
        self.copyButton.set(title: "Copied", symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.copyButton.set(title: "Copy", symbol: "doc.on.doc")
        }
    }

    override func layoutContent() {
        guard let code else { return }
        let bounds = self.bounds
        let button = self.copyButton.buttonSize
        self.copyButton.frame = CGRect(x: bounds.width - 10 - button.width, y: (code.headerHeight - button.height) / 2,
                                       width: button.width, height: button.height)
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
                       width: bounds.width - 30 - self.copyButton.buttonSize.width, font: font)
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        self.rowView?.menu(extra: self.extraCopyItems)
    }
    #endif
}

final class TranscriptMarkdownTableView: TranscriptBaseView {
    private let scroller = TranscriptScroller(axis: .horizontal)
    private let grid = TranscriptTableGridView()
    private var rowId: String?

    var extraCopyItems: [TranscriptRowLayout.CopyItem] {
        self.grid.table.map { [.init(title: "Copy Table", text: $0.plainText)] } ?? []
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
        self.rowView?.menu(extra: self.extraCopyItems)
    }
    #endif
}

final class TranscriptTableGridView: TranscriptBaseView {
    var table: TranscriptPart.Table?

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        (self.superview?.superview?.superview as? TranscriptMarkdownTableView).flatMap { table in
            self.rowView?.menu(extra: table.extraCopyItems)
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

    private var title: String { self.thinking?.title ?? "Thinking" }

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
        self.accessibilityText = (thinking.isExpanded ? "Hide " : "Show ") + thinking.title.lowercased()
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.header)
        self.addSubview(self.runButton)
        self.runButton.set(title: "Open run", symbol: "sparkles")
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .tool(tool) = part else { return }
        let sameTool = self.part?.tool.id == tool.tool.id && self.rowId == row.id
        self.part = tool
        self.rowId = row.id
        let rowId = row.id
        self.header.configure(tool, trailing: tool.run == nil ? 10 : 6)
        self.header.onTap = { [weak actions] in actions?.setExpanded(tool.key, !tool.isExpanded, row: rowId) }
        self.header.accessibilityText = [tool.tool.name, tool.tool.summary].compactMap(\.self).joined(separator: " ")
            + (tool.isExpanded ? ", expanded" : ", collapsed")
        if let run = tool.run {
            self.runButton.isHidden = false
            self.runButton.onTap = { [weak actions] in actions?.openRun(run.key) }
            #if os(macOS)
            self.runButton.toolTip = "Open “\(run.title)” to see what this helper did"
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
        self.redraw()
    }

    override func layoutContent() {
        guard let part else { return }
        let bounds = self.bounds
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
        for section in part.sections {
            singleLine(section.title, style.captionSemibold, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: section.titleY), width: bounds.width - 20, font: style.captionSemibold)
        }
        if let y = part.runningY {
            singleLine("Running…", style.caption, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: y), width: bounds.width - 20, font: style.caption)
        }
    }
}

final class TranscriptToolHeaderView: TranscriptTapView {
    private var part: TranscriptPart.Tool?
    private var trailing: CGFloat = 10
    private let spinner = TranscriptSpinner(size: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
    }

    func configure(_ part: TranscriptPart.Tool, trailing: CGFloat) {
        self.part = part
        self.trailing = trailing
        self.spinner.setAnimating(part.tool.isRunning)
        self.redraw()
    }

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
                TranscriptSymbols.draw("xmark.octagon.fill", in: iconRect, size: style.callout.pointSize, color: TranscriptColors.red)
            } else {
                TranscriptSymbols.draw(ToolSymbols.symbol(for: part.tool.name), in: iconRect, size: style.callout.pointSize,
                                       color: TranscriptColors.secondary)
            }
        }
        let chevronX = bounds.width - self.trailing - 10
        TranscriptSymbols.draw(part.isExpanded ? "chevron.down" : "chevron.right",
                               in: CGRect(x: chevronX, y: 0, width: 10, height: bounds.height),
                               size: style.caption2Medium.pointSize, weight: .bold, color: TranscriptColors.tertiary)
        let nameFont = style.calloutMonoMedium
        let name = singleLine(part.tool.name, nameFont, TranscriptColors.label)
        let nameX: CGFloat = 34
        let nameY = (bounds.height - TranscriptStyle.lineHeight(nameFont)) / 2
        let nameWidth = min(name.lineWidth, chevronX - 8 - nameX)
        name.drawLine(at: CGPoint(x: nameX, y: nameY), width: nameWidth, font: nameFont)
        if let summary = part.tool.summary {
            let summaryX = nameX + nameWidth + 8
            let width = chevronX - 8 - summaryX
            if width > 16 {
                let font = style.captionMono
                let oneLine = summary.replacingOccurrences(of: "\n", with: " ")
                singleLine(oneLine, font, TranscriptColors.secondary, truncation: .byTruncatingMiddle)
                    .drawLine(at: CGPoint(x: summaryX, y: nameY + nameFont.ascender - font.ascender), width: width, font: font)
            }
        }
    }
}

/// Input or output of an expanded tool card: selectable monospaced text that scrolls once it's
/// taller than the card allows.
final class TranscriptToolSectionView: TranscriptBaseView {
    private let textView = TranscriptTextView(wraps: true)
    private var contentHeight: CGFloat = 0
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
        self.contentHeight = section.contentHeight
        self.textView.copyItems = row.copyItems
        self.textView.set(section.text, identity: "\(row.id):\(section.title)")
        #if os(macOS)
        if resetScroll { self.scroller.scrollToStart() }
        #else
        self.textView.isScrollEnabled = section.contentHeight > section.frame.height + 0.5
        if resetScroll { self.textView.contentOffset = .zero }
        #endif
    }

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
        self.accessibilityText = image.ref.alt ?? "Image"
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
            self.onTap = nil
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

    override func draw(_ rect: CGRect) {
        guard let image else { return }
        if case .loaded = image.state { return }
        let bounds = self.bounds
        TranscriptColors.fill.setFill()
        PBezierPath.rounded(bounds, radius: 10).fill()
        guard case .failed = image.state else { return }
        let style = TranscriptStyle.shared
        let text = singleLine(image.ref.alt ?? "Image unavailable", style.caption, TranscriptColors.secondary, truncation: .byTruncatingMiddle)
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
        return CGSize(width: 14 + 4 + singleLine("Save", font, TranscriptColors.tint).lineWidth,
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
        self.saveButton.set(title: "Save", symbol: "arrow.down.circle")
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .file(file) = part else { return }
        let identity = "\(row.id):\(file.key)"
        let sameFile = identity == self.identity
        if !sameFile {
            self.saveToken += 1
            self.saveButton.set(title: "Save", symbol: "arrow.down.circle")
            self.identity = identity
        }
        self.part = file
        let rowId = row.id
        self.header.configure(file)
        if file.canExpand {
            self.header.onTap = { [weak actions] in
                if !file.isExpanded { actions?.loadFilePreview(file.ref) }
                actions?.setExpanded(file.key, !file.isExpanded, row: rowId)
            }
            self.header.accessibilityText = "Attachment \(file.ref.name)" + (file.isExpanded ? ", expanded" : ", collapsed")
        } else if file.ref.isDownloadable {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.save(file.ref, actions: actions)
            }
            self.header.accessibilityText = "Save \(file.ref.name)"
        } else {
            self.header.onTap = nil
            self.header.accessibilityText = "Attachment \(file.ref.name)"
        }
        self.saveButton.isHidden = !file.ref.isDownloadable
        self.saveButton.onTap = { [weak self, weak actions] in
            guard let actions else { return }
            self?.save(file.ref, actions: actions)
        }
        #if os(macOS)
        self.saveButton.toolTip = "Save “\(file.ref.name)”"
        #endif
        if file.isExpanded, file.section == nil, file.note == "Loading…" { actions.loadFilePreview(file.ref) }
        if let section = file.section {
            self.section.isHidden = false
            self.section.configure(section, row: row, resetScroll: !sameFile)
        } else {
            self.section.isHidden = true
        }
        self.redraw()
    }

    /// The button keeps its "Save" title, so the chip keeps its width; the symbol shows progress.
    private func save(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: "Save", symbol: "hourglass")
        Task { @MainActor [weak self] in
            let saved = await actions.saveFile(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: "Save", symbol: saved ? "arrow.down.circle" : "exclamationmark.triangle")
            #if os(macOS)
            if !saved { self.saveButton.toolTip = "Couldn’t download “\(file.name)”" }
            #endif
            guard !saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: "Save", symbol: "arrow.down.circle")
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
        self.setAccessibilityLabel("Working")
        #else
        self.isAccessibilityElement = true
        self.accessibilityLabel = "Working"
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
        self.toolTip = label.hasPrefix("Context") ? "Earlier messages were summarized for the agent. They're still shown here." : nil
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
