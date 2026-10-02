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
    /// Grows the touch target beyond the drawn button, for small icon-only buttons.
    var hitOutset = CGSize.zero
    /// Makes the control adjustable for VoiceOver (swipe up or down), like a stepper.
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?
    var accessibilityHintText: String? {
        didSet {
            #if os(iOS)
            self.accessibilityHint = self.accessibilityHintText
            #endif
        }
    }
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

    /// The clickable area: the frame grown by `hitOutset`, for small icon-only buttons.
    private var hitBounds: CGRect { self.bounds.insetBy(dx: -self.hitOutset.width, dy: -self.hitOutset.height) }

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
        self.isPressed = self.hitBounds.contains(self.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard self.onTap != nil else { return super.mouseUp(with: event) }
        let inside = self.hitBounds.contains(self.convert(event.locationInWindow, from: nil))
        self.isPressed = false
        if inside { self.onTap?() }
    }

    override func isAccessibilityElement() -> Bool { self.onTap != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { self.onIncrement == nil ? .button : .incrementor }
    override func accessibilityLabel() -> String? { self.accessibilityText }
    override func accessibilityHelp() -> String? { self.accessibilityHintText }
    override func accessibilityPerformIncrement() -> Bool {
        self.onIncrement?()
        return self.onIncrement != nil
    }
    override func accessibilityPerformDecrement() -> Bool {
        self.onDecrement?()
        return self.onDecrement != nil
    }
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

    override func accessibilityIncrement() { self.onIncrement?() }
    override func accessibilityDecrement() { self.onDecrement?() }
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
    func set(_ text: NSAttributedString, identity: String, visibleLineLimit: Int? = nil) {
        self.applyLinkColor()
        if let container = self.textContainer, container.maximumNumberOfLines != (visibleLineLimit ?? 0) {
            container.maximumNumberOfLines = visibleLineLimit ?? 0
            container.lineBreakMode = visibleLineLimit == nil ? .byWordWrapping : .byTruncatingTail
            self.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: self.backing.length),
                                                 actualCharacterRange: nil)
        }
        guard text !== self.shown || identity != self.identity else { return }
        let selection = self.selectedRange()
        let sameRow = identity == self.identity
        self.shown = text
        self.identity = identity
        self.backing.update(to: text, keepingPrefix: sameRow)
        if sameRow, selection.length > 0, NSMaxRange(selection) <= text.length {
            self.setSelectedRange(selection)
        } else {
            self.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let items = self.extraItems + self.copyItems
        let messageItems = self.enclosingRow?.messageMenuItems(at: self.convert(event.locationInWindow, from: nil), in: self) ?? []
        guard !items.isEmpty || !messageItems.isEmpty else { return menu }
        var prefix = messageItems
        if !messageItems.isEmpty, !items.isEmpty { prefix.append(.separator()) }
        prefix += items.map { item in TranscriptMenuItem(item.title) { Clipboard.copy(item.text) } }
        if !menu.items.isEmpty { prefix.append(.separator()) }
        for item in prefix.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
}

extension NSView {
    var enclosingRow: TranscriptRowView? {
        var view = self.superview
        while let current = view {
            if let row = current as? TranscriptRowView { return row }
            view = current.superview
        }
        return nil
    }
}

@MainActor
final class TranscriptMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(self.run), keyEquivalent: "")
        self.target = self
        if let symbol { self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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

    func set(_ text: NSAttributedString, identity: String, visibleLineLimit: Int? = nil) {
        self.applyLinkColor()
        if self.textContainer.maximumNumberOfLines != (visibleLineLimit ?? 0) {
            self.textContainer.maximumNumberOfLines = visibleLineLimit ?? 0
            self.textContainer.lineBreakMode = visibleLineLimit == nil ? .byWordWrapping : .byTruncatingTail
            self.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: self.backing.length),
                                                actualCharacterRange: nil)
        }
        guard text !== self.shown || identity != self.identity else { return }
        let selection = self.selectedRange
        let sameRow = identity == self.identity
        self.shown = text
        self.identity = identity
        self.backing.update(to: text, keepingPrefix: sameRow)
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
        var row: UIView? = self.superview
        while let current = row, !(current is TranscriptRowView) { row = current.superview }
        let messageItems = (row as? TranscriptRowView)?.messageMenuElements(at: self.convert(CGPoint(x: 0, y: 1), to: row), anchor: self) ?? []
        guard !items.isEmpty || !messageItems.isEmpty else { return nil }
        let extras = items.map { item in UIAction(title: item.title) { _ in Clipboard.copy(item.text) } }
        return UIMenu(children: suggestedActions + messageItems + [UIMenu(options: .displayInline, children: extras)])
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

func withoutLayerAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

func lighten(_ color: PColor, by amount: CGFloat) -> PColor {
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

func singleLine(_ text: String, _ font: PFont, _ color: PColor,
                        truncation: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString
{
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = truncation
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}

@MainActor extension NSAttributedString {
    var lineWidth: CGFloat { ceil(self.size().width) }

    /// Draws on one line from `origin`, truncated to `width`.
    func drawLine(at origin: CGPoint, width: CGFloat, font: PFont) {
        guard width > 1 else { return }
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: TranscriptStyle.lineHeight(font))
        self.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
