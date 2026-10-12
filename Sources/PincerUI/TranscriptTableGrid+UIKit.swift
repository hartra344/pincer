#if os(iOS)
import PincerKit
import UIKit

/// Offset-based position into a table's selectable text (UTF-16 offsets).
final class TranscriptTablePosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class TranscriptTableRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range }
    override var start: UITextPosition { TranscriptTablePosition(self.range.location) }
    override var end: UITextPosition { TranscriptTablePosition(NSMaxRange(self.range)) }
    override var isEmpty: Bool { self.range.length == 0 }
}

final class TranscriptTableSelectionRect: UITextSelectionRect {
    private let box: CGRect
    private let startsSelection: Bool
    private let endsSelection: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        self.box = rect
        self.startsSelection = containsStart
        self.endsSelection = containsEnd
    }

    override var rect: CGRect { self.box }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { self.startsSelection }
    override var containsEnd: Bool { self.endsSelection }
    override var isVertical: Bool { false }
}

/// Read-only `UITextInput` over the table's flattened text, so `UITextInteraction` provides the usual
/// selection handles, loupe and edit menu without a view per cell.
extension TranscriptTableGridView: UITextInput {
    private func clamped(_ offset: Int) -> Int { min(max(offset, 0), self.textModel.length) }

    private func offset(of position: UITextPosition) -> Int {
        self.clamped((position as? TranscriptTablePosition)?.offset ?? 0)
    }

    private func range(of range: UITextRange) -> NSRange {
        let start = self.offset(of: range.start)
        let end = self.offset(of: range.end)
        return NSRange(location: min(start, end), length: abs(end - start))
    }

    // MARK: Responder

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(UIResponderStandardEditActions.copy(_:)): return self.selectedRange.length > 0
        case #selector(UIResponderStandardEditActions.selectAll(_:)):
            return self.textModel.length > 0 && self.selectedRange != NSRange(location: 0, length: self.textModel.length)
        default: return false
        }
    }

    override func copy(_ sender: Any?) {
        let text = self.selectedText
        if !text.isEmpty { Clipboard.copy(text) }
    }

    override func selectAll(_ sender: Any?) {
        self.setSelectedRange(NSRange(location: 0, length: self.textModel.length))
    }

    private func setSelectedRange(_ range: NSRange) {
        guard range != self.selectedRange else { return }
        self.inputDelegate?.selectionWillChange(self)
        self.selectedRange = range
        self.inputDelegate?.selectionDidChange(self)
    }

    // MARK: Text

    func text(in range: UITextRange) -> String? {
        self.textModel.text(in: self.range(of: range))
    }

    func replace(_ range: UITextRange, withText text: String) {}

    var selectedTextRange: UITextRange? {
        get { TranscriptTableRange(self.selectedRange) }
        set {
            guard let newValue else { return self.setSelectedRange(NSRange(location: self.selectedRange.location, length: 0)) }
            self.setSelectedRange(self.range(of: newValue))
        }
    }

    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}

    var beginningOfDocument: UITextPosition { TranscriptTablePosition(0) }
    var endOfDocument: UITextPosition { TranscriptTablePosition(self.textModel.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let from = self.offset(of: fromPosition)
        let to = self.offset(of: toPosition)
        return TranscriptTableRange(NSRange(location: min(from, to), length: abs(to - from)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let target = self.offset(of: position) + offset
        guard target >= 0, target <= self.textModel.length else { return nil }
        return TranscriptTablePosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        let origin = self.offset(of: position)
        switch direction {
        case .left: return TranscriptTablePosition(self.clamped(origin - offset))
        case .right: return TranscriptTablePosition(self.clamped(origin + offset))
        case .up, .down:
            let sign = direction == .up ? -1 : 1
            let caret = self.textModel.caretRect(at: origin)
            let step = max(caret.height, 1) + 10
            let point = CGPoint(x: caret.midX, y: caret.midY + CGFloat(sign * offset) * step)
            return TranscriptTablePosition(self.textModel.offset(at: point))
        @unknown default: return nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = self.offset(of: position)
        let rhs = self.offset(of: other)
        return lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        self.offset(of: toPosition) - self.offset(of: from)
    }

    var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        case .right, .down: range.end
        @unknown default: nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let origin = self.offset(of: position)
        switch direction {
        case .left, .up: return TranscriptTableRange(NSRange(location: self.clamped(origin - 1), length: origin > 0 ? 1 : 0))
        case .right, .down: return TranscriptTableRange(NSRange(location: origin, length: origin < self.textModel.length ? 1 : 0))
        @unknown default: return nil
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry

    func firstRect(for range: UITextRange) -> CGRect {
        self.textModel.selectionRects(for: self.range(of: range)).first ?? .zero
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        self.textModel.caretRect(at: self.offset(of: position))
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let rects = self.textModel.selectionRects(for: self.range(of: range))
        return rects.enumerated().map { index, rect in
            TranscriptTableSelectionRect(rect: rect, containsStart: index == 0, containsEnd: index == rects.count - 1)
        }
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        TranscriptTablePosition(self.textModel.offset(at: point))
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        let bounds = self.range(of: range)
        let offset = min(max(self.textModel.offset(at: point), bounds.location), NSMaxRange(bounds))
        return TranscriptTablePosition(offset)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        let offset = self.textModel.offset(at: point)
        let end = min(offset + 1, self.textModel.length)
        return TranscriptTableRange(NSRange(location: offset, length: end - offset))
    }

    // MARK: Editing (read-only)

    var hasText: Bool { self.textModel.length > 0 }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    var textInputView: UIView { self }

    // MARK: Menu

    func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let row = self.rowView
        let extra = (self.superview?.superview?.superview as? TranscriptMarkdownTableView)?.extraCopyItems ?? []
        let items = extra + (row?.layout?.copyItems ?? [])
        let messageItems = row?.messageMenuElements(at: self.convert(CGPoint(x: 0, y: 1), to: row), anchor: self) ?? []
        let copies = items.map { item in UIAction(title: item.title) { _ in Clipboard.copy(item.text) } }
        return UIMenu(children: suggestedActions + messageItems + (copies.isEmpty ? [] : [UIMenu(options: .displayInline, children: copies)]))
    }
}
#endif
