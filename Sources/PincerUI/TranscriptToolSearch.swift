import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Search within one tool card's text (#342): the query and current match per tool call. Whether the
/// field is open lives in `TranscriptDisclosure` under `ToolCardSearchStore.key(_:)`.
@MainActor
final class ToolCardSearchStore {
    struct State {
        var query = ""
        var current = 0
    }

    private var states: [String: State] = [:]

    static func key(_ toolId: String) -> String { "search:\(toolId)" }

    func state(for toolId: String) -> State { self.states[toolId] ?? State() }

    func set(_ state: State, for toolId: String) { self.states[toolId] = state }
}

/// Matches of the card-search query while a card is laid out: counts them across the card's
/// sections in draw order and marks them with Find's colors, without changing the text.
struct ToolSearchMatches {
    let query: String
    let total: Int
    let current: Int
    private(set) var seen = 0
    var frame: CGRect = .zero

    @MainActor init(query: String, current: Int, presentation: ToolCallPresentation) {
        self.query = query
        let total = query.isEmpty ? 0 : presentation.searchTexts.reduce(0) { $0 + TranscriptSearch.ranges(of: query, in: $1).count }
        self.total = total
        self.current = total > 0 ? min(max(current, 0), total - 1) : 0
    }

    /// `text` with every match colored, and the range of the current match when it is in this text.
    mutating func mark(_ text: NSAttributedString) -> (NSAttributedString, NSRange?) {
        let ranges = TranscriptSearch.ranges(of: self.query, in: text.string)
        guard !ranges.isEmpty else { return (text, nil) }
        let start = self.seen
        self.seen += ranges.count
        let marked = NSMutableAttributedString(attributedString: text)
        var currentRange: NSRange?
        for (index, range) in ranges.enumerated() {
            let isCurrent = start + index == self.current
            marked.addAttribute(.backgroundColor, value: isCurrent ? TranscriptColors.findCurrent : TranscriptColors.findMatch, range: range)
            if isCurrent {
                marked.addAttribute(.foregroundColor, value: TranscriptColors.findCurrentText, range: range)
                currentRange = range
            }
        }
        return (marked, currentRange)
    }
}

/// The inline search field under a card's output title: field, "3 of 12", previous, next and close.
/// Return and ⇧Return step, Esc closes; on macOS ⌘G and ⇧⌘G step too, and ⌘F refocuses the field.
final class TranscriptToolSearchBar: TranscriptBaseView {
    private var toolId: String?
    private var rowId: String?
    private weak var renderer: TranscriptRenderer?
    private var search: TranscriptPart.Tool.Search?
    private var didFocus = false
    private var announced = ""
    private var announceTask: Task<Void, Never>?
    private let field = ToolSearchField()
    private let countLabel = ToolSearchLabel()
    private let previousButton = TranscriptLabelButton()
    private let nextButton = TranscriptLabelButton()
    private let closeButton = TranscriptLabelButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isHidden = true
        self.addSubview(self.field)
        self.addSubview(self.countLabel)
        for (button, symbol) in [(self.previousButton, "chevron.up"), (self.nextButton, "chevron.down"), (self.closeButton, "xmark")] {
            button.isSubdued = true
            button.set(title: "", symbol: symbol)
            button.hitOutset = CGSize(width: 4, height: 6)
            self.addSubview(button)
        }
        self.previousButton.accessibilityText = L("Previous match")
        self.nextButton.accessibilityText = L("Next match")
        self.closeButton.accessibilityText = L("Close search")
        self.previousButton.onTap = { [weak self] in self?.step(forward: false) }
        self.nextButton.onTap = { [weak self] in self?.step(forward: true) }
        self.closeButton.onTap = { [weak self] in self?.closeSearch() }
        self.field.placeholder = L("Search in output")
        self.field.onChange = { [weak self] in self?.queryChanged($0) }
        self.field.onStep = { [weak self] in self?.step(forward: $0) }
        self.field.onClose = { [weak self] in self?.closeSearch() }
        self.field.accessibilityText = L("Search in output")
    }

    func configure(_ search: TranscriptPart.Tool.Search?, toolId: String, row: String, actions: TranscriptRowActions) {
        self.toolId = toolId
        self.rowId = row
        self.renderer = actions as? TranscriptRenderer
        self.search = search
        guard let search else {
            if !self.isHidden {
                self.isHidden = true
                self.field.resign()
            }
            self.didFocus = false
            self.announced = ""
            self.announceTask?.cancel()
            return
        }
        self.isHidden = false
        self.field.setText(search.query)
        let count = self.countText(search)
        self.countLabel.set(count)
        self.announceChange(count)
        self.previousButton.isDisabled = search.total < 2
        self.nextButton.isDisabled = search.total < 2
        self.frame = search.frame
        self.layoutContent()
        if !self.didFocus {
            self.didFocus = true
            self.field.focus()
        }
    }

    /// Speaks the count once typing or stepping pauses, not on every keystroke.
    private func announceChange(_ count: String) {
        guard count != self.announced else { return }
        self.announced = count
        self.announceTask?.cancel()
        guard !count.isEmpty, AccessibilityAnnouncer.isVoiceOverRunning else { return }
        self.announceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            AccessibilityAnnouncer.announce(count)
        }
    }

    private func countText(_ search: TranscriptPart.Tool.Search) -> String {
        if search.query.isEmpty { return "" }
        if search.total == 0 { return L("No matches") }
        return L("\(search.current + 1) of \(search.total)")
    }

    override func layoutContent() {
        let bounds = self.bounds
        var right = bounds.width
        for button in [self.closeButton, self.nextButton, self.previousButton] {
            let size = button.buttonSize
            button.frame = CGRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right = button.frame.minX - 4
        }
        let countWidth = min(self.countLabel.fittingWidth, bounds.width * 0.4)
        let labelHeight = min(self.countLabel.fittingHeight, bounds.height)
        self.countLabel.frame = CGRect(x: right - countWidth, y: ((bounds.height - labelHeight) / 2).rounded(),
                                       width: countWidth, height: labelHeight)
        right = self.countLabel.frame.minX - 6
        let fieldHeight = min(self.field.fittingHeight, bounds.height)
        self.field.frame = CGRect(x: 0, y: ((bounds.height - fieldHeight) / 2).rounded(), width: max(right, 40), height: fieldHeight)
    }

    /// Opens the search for this bar's card (⌘F while focus is in the card's text).
    func open() {
        guard let toolId, let rowId, self.search == nil else {
            self.field.focus()
            return
        }
        self.renderer?.setToolSearch(toolId, row: rowId, open: true)
    }

    private func queryChanged(_ query: String) {
        guard let toolId, let rowId, query != self.search?.query else { return }
        self.renderer?.setToolSearch(toolId, row: rowId, query: query, current: 0)
    }

    private func step(forward: Bool) {
        guard let toolId, let rowId, let search, search.total > 0 else { return }
        let next = (search.current + (forward ? 1 : search.total - 1)) % search.total
        self.renderer?.setToolSearch(toolId, row: rowId, current: next, reveal: true)
    }

    private func closeSearch() {
        guard let toolId, let rowId else { return }
        self.renderer?.setToolSearch(toolId, row: rowId, open: false)
    }

    #if os(macOS)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !self.isHidden, self.field.hasFocus,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g":
            self.step(forward: !event.modifierFlags.contains(.shift))
            return true
        case "f":
            self.field.focus()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
    #endif
}

#if os(macOS)
/// Count label drawn by AppKit's own text cell.
final class ToolSearchLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        self.isEditable = false
        self.isSelectable = false
        self.isBordered = false
        self.drawsBackground = false
        self.font = TranscriptStyle.shared.caption
        self.textColor = TranscriptColors.secondary
        self.alignment = .right
        self.lineBreakMode = .byTruncatingHead
        self.cell?.usesSingleLineMode = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String) { self.stringValue = text }

    var fittingWidth: CGFloat { ceil(self.attributedStringValue.size().width) + 4 }
    var fittingHeight: CGFloat { ceil(self.attributedStringValue.size().height) }

    override var isFlipped: Bool { true }
}

final class ToolSearchField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var accessibilityText = "" { didSet { self.setAccessibilityLabel(self.accessibilityText) } }
    var placeholder: String? {
        get { self.placeholderString }
        set { self.placeholderString = newValue }
    }

    init() {
        super.init(frame: .zero)
        self.delegate = self
        self.bezelStyle = .roundedBezel
        self.controlSize = .small
        self.font = TranscriptStyle.shared.caption
        self.cell?.usesSingleLineMode = true
        self.focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var fittingHeight: CGFloat { max(ceil(self.intrinsicContentSize.height), 20) }

    var hasFocus: Bool { self.currentEditor() != nil && self.window?.firstResponder === self.currentEditor() }

    func setText(_ text: String) {
        if self.stringValue != text, !self.hasFocus { self.stringValue = text }
    }

    func focus() {
        // The bar may be configured before it's in a window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }

    func resign() {
        if self.hasFocus { self.window?.makeFirstResponder(nil) }
    }

    func controlTextDidChange(_ notification: Notification) {
        self.onChange?(self.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            self.onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            self.onClose?()
            return true
        default:
            return false
        }
    }
}
#else
final class ToolSearchLabel: UILabel {
    init() {
        super.init(frame: .zero)
        self.font = TranscriptStyle.shared.caption
        self.textColor = TranscriptColors.secondary
        self.textAlignment = .right
        self.lineBreakMode = .byTruncatingHead
        self.adjustsFontForContentSizeCategory = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String) { self.text = text }

    var fittingWidth: CGFloat { ceil(self.intrinsicContentSize.width) + 4 }
    var fittingHeight: CGFloat { ceil(self.intrinsicContentSize.height) }
}

final class ToolSearchField: UITextField, UITextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var accessibilityText = "" { didSet { self.accessibilityLabel = self.accessibilityText } }

    init() {
        super.init(frame: .zero)
        self.delegate = self
        self.borderStyle = .roundedRect
        self.font = TranscriptStyle.shared.caption
        self.returnKeyType = .search
        self.autocorrectionType = .no
        self.autocapitalizationType = .none
        self.spellCheckingType = .no
        self.clearButtonMode = .whileEditing
        self.addTarget(self, action: #selector(self.edited), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var fittingHeight: CGFloat { max(ceil(self.intrinsicContentSize.height), 26) }

    var hasFocus: Bool { self.isFirstResponder }

    func setText(_ text: String) {
        if self.text != text, !self.isFirstResponder { self.text = text }
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    func resign() { _ = self.resignFirstResponder() }

    @objc private func edited() { self.onChange?(self.text ?? "") }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.onStep?(true)
        return false
    }

    @objc private func stepForward() { self.onStep?(true) }
    @objc private func stepBack() { self.onStep?(false) }
    @objc private func closeSearch() { self.onClose?() }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "g", modifierFlags: .command, action: #selector(self.stepForward)),
            UIKeyCommand(input: "g", modifierFlags: [.command, .shift], action: #selector(self.stepBack)),
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(self.stepBack)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(self.closeSearch)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }
}
#endif
