import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        self.grid.set(table, identity: row.id)
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
    private(set) var table: TranscriptPart.Table?
    private var identity: String?
    private var model: TranscriptTableText?

    /// The table's flattened text, built on first use (selection, hit-testing), never while configuring.
    var textModel: TranscriptTableText {
        if let model { return model }
        let built = TranscriptTableText(table: self.table ?? .init(cells: [], columnWidths: [], rowHeights: [], plainText: ""))
        self.model = built
        return built
    }

    var selectedRange = NSRange(location: 0, length: 0) {
        didSet { if self.selectedRange != oldValue { self.redraw() } }
    }

    var selectedText: String {
        guard self.selectedRange.length > 0, self.table != nil else { return "" }
        return self.textModel.text(in: self.selectedRange)
    }

    /// Replaces the table. The same `identity` (a streaming update of the same row) keeps the selection
    /// while it still fits; another identity clears it.
    func set(_ table: TranscriptPart.Table, identity: String) {
        let sameIdentity = self.identity == identity
        self.identity = identity
        self.table = table
        self.model = nil
        guard self.selectedRange.length > 0 || self.selectedRange.location != 0 else { return }
        if sameIdentity, self.selectedRange.length > 0 {
            // Only a selection fully inside the new text survives.
            if NSMaxRange(self.selectedRange) <= self.textModel.length { return }
        }
        #if os(iOS)
        self.inputDelegate?.selectionWillChange(self)
        #endif
        self.selectedRange = NSRange(location: 0, length: 0)
        #if os(iOS)
        self.inputDelegate?.selectionDidChange(self)
        #endif
        self.dragAnchor = nil
    }

    private var dragAnchor: NSRange?

    #if os(iOS)
    weak var inputDelegate: UITextInputDelegate?
    private lazy var textInteraction = UITextInteraction(for: .nonEditable)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.textInteraction.textInput = self
        self.addInteraction(self.textInteraction)
    }

    override func resignFirstResponder() -> Bool {
        if self.selectedRange.length > 0 || self.selectedRange.location != 0 {
            self.inputDelegate?.selectionWillChange(self)
            self.selectedRange = NSRange(location: 0, length: 0)
            self.inputDelegate?.selectionDidChange(self)
        }
        return super.resignFirstResponder()
    }
    #endif

    #if os(macOS)
    private enum Granularity { case character, word, row }
    private var granularity = Granularity.character

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .iBeam)
    }

    override func resignFirstResponder() -> Bool {
        self.selectedRange = NSRange(location: 0, length: 0)
        self.dragAnchor = nil
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        self.redraw()
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in self.keyObservers { NotificationCenter.default.removeObserver(token) }
        self.keyObservers = []
        if let window {
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            self.keyObservers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.selectedRange.length ?? 0 > 0 { self?.redraw() } }
                }
            }
        }
        self.redraw()
    }

    private var keyObservers: [NSObjectProtocol] = []

    isolated deinit {
        for token in self.keyObservers { NotificationCenter.default.removeObserver(token) }
    }

    override func mouseDown(with event: NSEvent) {
        guard self.table != nil else { return super.mouseDown(with: event) }
        self.window?.makeFirstResponder(self)
        let model = self.textModel
        let offset = model.offset(at: self.convert(event.locationInWindow, from: nil))
        switch event.clickCount {
        case 1:
            if event.modifierFlags.contains(.shift), let anchor = self.dragAnchor {
                self.selectedRange = Self.union(anchor, self.range(at: offset, granularity: self.granularity))
            } else {
                self.granularity = .character
                self.dragAnchor = NSRange(location: offset, length: 0)
                self.selectedRange = NSRange(location: offset, length: 0)
            }
        case 2:
            self.granularity = .word
            self.dragAnchor = model.wordRange(at: offset)
            self.selectedRange = self.dragAnchor ?? NSRange(location: offset, length: 0)
        default:
            self.granularity = .row
            self.dragAnchor = model.rowRange(at: offset)
            self.selectedRange = self.dragAnchor ?? NSRange(location: offset, length: 0)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard table != nil, let anchor = self.dragAnchor else { return }
        self.autoscroll(with: event)
        let model = self.textModel
        let offset = model.offset(at: self.convert(event.locationInWindow, from: nil))
        self.selectedRange = Self.union(anchor, self.range(at: offset, granularity: self.granularity))
    }

    private func range(at offset: Int, granularity: Granularity) -> NSRange {
        switch granularity {
        case .character: NSRange(location: offset, length: 0)
        case .word: self.textModel.wordRange(at: offset)
        case .row: self.textModel.rowRange(at: offset)
        }
    }

    private static func union(_ a: NSRange, _ b: NSRange) -> NSRange {
        let start = min(a.location, b.location), end = max(NSMaxRange(a), NSMaxRange(b))
        return NSRange(location: start, length: end - start)
    }

    @objc func copy(_ sender: Any?) {
        let text = self.selectedText
        if !text.isEmpty { Clipboard.copy(text) }
    }

    override func selectAll(_ sender: Any?) {
        guard self.table != nil else { return }
        self.dragAnchor = nil
        self.selectedRange = NSRange(location: 0, length: self.textModel.length)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return self.selectedRange.length > 0 }
        if item.action == #selector(selectAll(_:)) { return self.table != nil }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var ancestor = self.superview
        while let current = ancestor, !(current is TranscriptMarkdownTableView) { ancestor = current.superview }
        return (ancestor as? TranscriptMarkdownTableView).flatMap { table in
            var extra = table.extraCopyItems
            let selection = self.selectedText
            if !selection.isEmpty { extra.insert(.init(title: L("Copy"), text: selection), at: 0) }
            return self.rowView?.menu(extra: extra, event: event)
        }
    }

    private var selectionColor: NSColor {
        self.window?.isKeyWindow == true && self.window?.firstResponder === self
            ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
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
        #if os(macOS)
        if self.selectedRange.length > 0 {
            self.selectionColor.setFill()
            for highlight in self.textModel.selectionRects(for: self.selectedRange) where highlight.intersects(rect) {
                PBezierPath(rect: highlight).fill()
            }
        }
        #endif
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

#if os(macOS)
extension TranscriptTableGridView: NSUserInterfaceValidations {}
#endif
