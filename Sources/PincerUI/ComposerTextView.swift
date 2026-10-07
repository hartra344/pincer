import PincerKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import GameController
import UIKit
#endif

/// Something pasted or dropped into the composer that should become an attachment, not text.
enum PastedMedia {
    case file(URL)
    case data(Data, type: UTType, name: String?)
    case provider(NSItemProvider)
}

enum MediaPasteboard {
    /// Rich-text selections (Pages, Notes, TextEdit…) often carry image/PDF renderings of the
    /// text; those should paste as text.
    private static let textDocumentTypes: Set<String> = [
        UTType.rtf.identifier, UTType.rtfd.identifier, UTType.flatRTFD.identifier,
    ]
    private static let preferredImageTypes: [UTType] = [.gif, .png, .jpeg, .heic, .webP]

    /// The best media representation of one pasteboard item, or nil when it should paste as text.
    static func mediaType(in identifiers: [String]) -> UTType? {
        if identifiers.contains(where: self.textDocumentTypes.contains) { return nil }
        let types = identifiers.compactMap { UTType($0) }
        if let preferred = self.preferredImageTypes.first(where: types.contains) { return preferred }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
        if types.contains(where: { $0.conforms(to: .plainText) }) { return nil }
        return types.first { $0.conforms(to: .audiovisualContent) || $0.conforms(to: .pdf) }
    }

    static func isMedia(_ identifiers: [String]) -> Bool {
        identifiers.contains(UTType.fileURL.identifier) || self.mediaType(in: identifiers) != nil
    }

    #if os(macOS)
    static func items(from pasteboard: NSPasteboard) -> [PastedMedia] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty
        {
            return urls.map(PastedMedia.file)
        }
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let type = self.mediaType(in: item.types.map(\.rawValue)),
                  let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier))
            else { return nil }
            return .data(data, type: type, name: nil)
        }
    }

    static func hasMedia(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.pasteboardItems ?? []).contains { self.isMedia($0.types.map(\.rawValue)) }
    }
    #else
    static func items(from pasteboard: UIPasteboard) -> [PastedMedia] {
        let typesPerItem = pasteboard.types(forItemSet: nil) ?? []
        return zip(typesPerItem, pasteboard.itemProviders).compactMap { types, provider in
            self.isMedia(types) ? .provider(provider) : nil
        }
    }

    static func hasMedia(_ pasteboard: UIPasteboard) -> Bool {
        (pasteboard.types(forItemSet: nil) ?? []).contains(where: self.isMedia)
    }
    #endif
}

/// Keys the composer's suggestion menu takes over while it's open.
enum ComposerKey {
    case up, down, tab, escape
}

/// Asks the field to put the caret at a UTF-16 offset; a new `serial` makes it apply once, after any text change in the same update.
struct CaretRequest: Equatable {
    var offset: Int
    var serial: Int
}

/// Multi-line composer field that turns pasted images and files into attachments instead of
/// letting the platform text view paste their file path (or nothing).
struct ComposerTextView: View {
    let placeholder: String
    @Binding var text: String
    var maxLines = 12
    /// Off while a send is in flight, so the text can't change under it.
    var isEditable = true
    /// A suggestion menu is showing: arrow keys, Tab, Escape (and Return on iOS) go to `onKey`/`onSubmit`.
    var menuActive = false
    /// Escape goes to `onKey` even without a menu, such as to cancel a reply.
    var escapeActive = false
    /// Whether `onSubmit` would do anything; off, a hardware-keyboard Return does nothing instead of sending.
    var canSubmit = true
    /// Takes keyboard focus each time this changes.
    var focusRequest = 0
    let onSubmit: () -> Void
    /// ⌘↩; nil makes ⌘↩ act like ↩.
    var onCommandSubmit: (() -> Void)? = nil
    let onMedia: ([PastedMedia]) -> Void
    /// Returns whether the key was handled.
    var onKey: (ComposerKey) -> Bool = { _ in false }
    /// Whether the caret is an insertion point at the end of the text.
    var onCaretAtEnd: (Bool) -> Void = { _ in }
    /// Native input composition state, reported before text changes.
    var onMarkedTextChange: (Bool) -> Void = { _ in }
    /// The selection in UTF-16 units, each time it changes.
    var onSelectionChange: (NSRange) -> Void = { _ in }
    /// Where to put the caret after the text was set from outside (dictation); nil leaves it at the end.
    var caretRequest: CaretRequest?
    /// Whether the field has keyboard focus.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Asked just before the field focuses itself on appearing; false leaves focus where it is
    /// (e.g. Find in Chat opening with the chat).
    var autoFocus: @MainActor () -> Bool = { true }

    var body: some View {
        PlatformComposerTextView(
            text: self.$text, maxLines: self.maxLines, isEditable: self.isEditable, menuActive: self.menuActive,
            escapeActive: self.escapeActive, canSubmit: self.canSubmit, focusRequest: self.focusRequest, onSubmit: self.onSubmit,
            onCommandSubmit: self.onCommandSubmit,
            onMedia: self.onMedia, onKey: self.onKey, onCaretAtEnd: self.onCaretAtEnd, onMarkedTextChange: self.onMarkedTextChange, onSelectionChange: self.onSelectionChange, onFocusChange: self.onFocusChange,
            caretRequest: self.caretRequest, autoFocus: self.autoFocus)
            .overlay(alignment: .topLeading) {
                if self.text.isEmpty {
                    Text(self.placeholder)
                        .font(.body)
                        .foregroundStyle(Self.placeholderColor)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(self.placeholder)
    }

    #if os(macOS)
    private static let placeholderColor = Color(nsColor: .placeholderTextColor)
    #else
    private static let placeholderColor = Color(uiColor: .placeholderText)
    #endif
}

/// Caches the composer's measured heights for its current text, so SwiftUI's repeated size
/// proposals in one layout pass cost a dictionary lookup. Everything runs on the main thread,
/// in the same pass as the text or width change.
@MainActor
final class ComposerHeightCache {
    private struct Key: Hashable {
        let width: CGFloat
        let lineHeight: CGFloat
        let maxLines: Int
    }

    private var text = ""
    private var heights: [Key: CGFloat] = [:]

    /// The field height for `text` at `width`; `measure` lays the text out at that width and returns its used height.
    func height(for text: String, lineHeight: CGFloat, width: CGFloat, maxLines: Int, measure: (CGFloat) -> CGFloat) -> CGFloat {
        let utf16Count = (text as NSString).length
        guard utf16Count > 0, width.isFinite, width > 0 else {
            return ComposerSizing.clampedHeight(lineHeight, lineHeight: lineHeight, maxLines: maxLines)
        }
        if ComposerSizing.usesCappedEstimate(utf16Count: utf16Count) {
            // Too long to be under the cap at any real width: skip layout and fill the field.
            return ComposerSizing.cap(lineHeight: lineHeight, maxLines: maxLines)
        }
        if text != self.text {
            self.text = text
            self.heights.removeAll(keepingCapacity: true)
        }
        let key = Key(width: width, lineHeight: lineHeight, maxLines: maxLines)
        if let height = self.heights[key] { return height }
        let height = ComposerSizing.clampedHeight(measure(width), lineHeight: lineHeight, maxLines: maxLines)
        if self.heights.count >= 8 { self.heights.removeAll(keepingCapacity: true) }
        self.heights[key] = height
        return height
    }
}

#if os(macOS)
final class ComposerNSTextView: NSTextView {
    var onMedia: (([PastedMedia]) -> Void)?
    var autoFocus: (@MainActor () -> Bool)?
    private var didAutoFocus = false

    override func paste(_ sender: Any?) {
        let items = MediaPasteboard.items(from: .general)
        if items.isEmpty {
            super.paste(sender)
        } else {
            self.onMedia?(items)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), MediaPasteboard.hasMedia(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let items = MediaPasteboard.items(from: sender.draggingPasteboard)
        guard !items.isEmpty else { return super.performDragOperation(sender) }
        self.onMedia?(items)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !self.didAutoFocus else { return }
        self.didAutoFocus = true
        DispatchQueue.main.async {
            guard self.window === window, self.autoFocus?() ?? true else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Lays the composer's text out with TextKit 1 on the main thread, configured like the live
/// field (same font, no padding or insets), so the height matches what the field will draw.
/// A separate layout manager leaves the live NSTextView on its own text system.
@MainActor
final class ComposerTextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var text = ""
    private var font: NSFont?

    init() {
        self.container.lineFragmentPadding = 0
        self.layoutManager.addTextContainer(self.container)
        self.storage.addLayoutManager(self.layoutManager)
    }

    func usedHeight(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        if text != self.text || font != self.font {
            self.text = text
            self.font = font
            self.storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        }
        if self.container.size.width != width {
            self.container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        self.layoutManager.ensureLayout(for: self.container)
        let used = self.layoutManager.usedRect(for: self.container)
        // usedRect leaves out the empty line after a trailing newline; the extra fragment covers it.
        // Without one the rect is garbage (negative y), so it must not be unioned.
        guard self.layoutManager.extraLineFragmentTextContainer != nil else { return used.height }
        return used.union(self.layoutManager.extraLineFragmentUsedRect).height
    }
}

private struct PlatformComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let maxLines: Int
    let isEditable: Bool
    let menuActive: Bool
    let escapeActive: Bool
    let canSubmit: Bool
    let focusRequest: Int
    let onSubmit: () -> Void
    let onCommandSubmit: (() -> Void)?
    let onMedia: ([PastedMedia]) -> Void
    let onKey: (ComposerKey) -> Bool
    let onCaretAtEnd: (Bool) -> Void
    let onMarkedTextChange: (Bool) -> Void
    let onSelectionChange: (NSRange) -> Void
    let onFocusChange: (Bool) -> Void
    let caretRequest: CaretRequest?
    let autoFocus: @MainActor () -> Bool

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = self.text
        textView.onMedia = self.onMedia
        textView.autoFocus = self.autoFocus

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onMedia = self.onMedia
        textView.autoFocus = self.autoFocus
        if textView.isEditable != self.isEditable { textView.isEditable = self.isEditable }
        if context.coordinator.focusRequest != self.focusRequest {
            context.coordinator.focusRequest = self.focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        let caret = context.coordinator.takeCaret(self.caretRequest, length: (self.text as NSString).length)
        if textView.string != self.text {
            textView.string = self.text
            textView.setSelectedRange(NSRange(location: caret ?? (self.text as NSString).length, length: 0))
        } else if let caret {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        let text = (nsView.documentView as? NSTextView)?.string ?? self.text
        let coordinator = context.coordinator
        let height = coordinator.heights.height(
            for: text, lineHeight: Self.lineHeight, width: width, maxLines: self.maxLines
        ) { width in
            coordinator.measurer.usedHeight(of: text, font: Self.font, width: width)
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlatformComposerTextView
        var focusRequest: Int
        var caretSerial: Int?
        let heights = ComposerHeightCache()
        let measurer = ComposerTextMeasurer()

        init(_ parent: PlatformComposerTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
            self.caretSerial = parent.caretRequest?.serial
        }

        /// The clamped offset of a caret request not yet applied, once.
        func takeCaret(_ request: CaretRequest?, length: Int) -> Int? {
            guard let request, request.serial != self.caretSerial else { return nil }
            self.caretSerial = request.serial
            return min(max(request.offset, 0), length)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.onMarkedTextChange(textView.hasMarkedText())
            let selection = textView.selectedRange()
            self.parent.onCaretAtEnd(selection.length == 0 && selection.location == textView.textStorage?.length)
            self.parent.text = textView.string
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) { self.parent.onFocusChange(true) }

        func textDidEndEditing(_ notification: Notification) { self.parent.onFocusChange(false) }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            self.parent.onMarkedTextChange(textView.hasMarkedText())
            self.parent.onCaretAtEnd(range.length == 0 && range.location == (textView.string as NSString).length)
            self.parent.onSelectionChange(range)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
            let isForwardTab = selector == #selector(NSResponder.insertTab(_:))
            let isBackwardTab = selector == #selector(NSResponder.insertBacktab(_:))
            if isForwardTab || isBackwardTab {
                let action = ComposerTabAction.resolve(
                    menuActive: self.parent.menuActive,
                    backwards: isBackwardTab || modifierFlags.contains(.shift),
                    optionPressed: modifierFlags.contains(.option),
                    hasMarkedText: textView.hasMarkedText())
                switch action {
                case .insertLiteralTab, .system:
                    return false
                case .acceptSuggestion:
                    return self.parent.onKey(.tab)
                case .nextKeyView, .previousKeyView:
                    guard let window = textView.window else { return false }
                    if action == .previousKeyView {
                        window.selectPreviousKeyView(textView)
                    } else {
                        window.selectNextKeyView(textView)
                    }
                    return true
                }
            }
            if self.parent.menuActive, !textView.hasMarkedText() {
                let key: ComposerKey? = switch selector {
                case #selector(NSResponder.moveUp(_:)): .up
                case #selector(NSResponder.moveDown(_:)): .down
                // Escape in a text view is `complete:` (system completion), not `cancelOperation:`.
                case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)): .escape
                default: nil
                }
                if let key, self.parent.onKey(key) { return true }
            }
            if self.parent.escapeActive, !textView.hasMarkedText(),
               selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)),
               self.parent.onKey(.escape)
            {
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            switch ComposerReturnKey.resolve(
                source: .hardware, hasMarkedText: textView.hasMarkedText(),
                shift: modifierFlags.contains(.shift), option: modifierFlags.contains(.option), command: modifierFlags.contains(.command),
                supportsSendAndOpen: self.parent.onCommandSubmit != nil, canSubmit: self.parent.canSubmit)
            {
            case .system: return false
            case .newline: textView.insertNewlineIgnoringFieldEditor(nil)
            case .send: self.parent.onSubmit()
            case .sendAndOpen: self.parent.onCommandSubmit?()
            case .ignore: break
            }
            return true
        }
    }
}

#else
final class ComposerUITextView: UITextView {
    var onMedia: (([PastedMedia]) -> Void)?
    var menuActive = false
    var escapeActive = false
    var canSubmit = true
    var onKey: ((ComposerKey) -> Bool)?
    var onSubmit: (() -> Void)?
    var autoFocus: (@MainActor () -> Bool)?
    private var didAutoFocus = false

    private static let menuKeys: [(String, ComposerKey)] = [
        (UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down), ("\t", .tab),
        (UIKeyCommand.inputEscape, .escape),
    ]

    override var keyCommands: [UIKeyCommand]? {
        let menu = Self.menuKeys.map { input, _ in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(self.menuKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return menu + Self.returnCommands + (super.keyCommands ?? [])
    }

    /// Hardware-keyboard Return sends; ⇧↩ and ⌥↩ aren't claimed, so they insert a newline as usual.
    /// Key commands only fire for physical keys, so the on-screen keyboard's Return is untouched.
    private static let returnCommands: [UIKeyCommand] = {
        let send = UIKeyCommand(title: L("Send"), action: #selector(ComposerUITextView.hardwareReturn(_:)), input: "\r")
        let commandSend = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(ComposerUITextView.hardwareReturn(_:)))
        // The keypad's Enter key arrives flagged as numeric-pad.
        let keypadSend = UIKeyCommand(input: "\r", modifierFlags: .numericPad, action: #selector(ComposerUITextView.hardwareReturn(_:)))
        let commands = [send, commandSend, keypadSend]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }()

    private func returnKey(for command: UIKeyCommand?) -> ComposerReturnKey {
        let flags = command?.modifierFlags ?? []
        return ComposerReturnKey.resolve(
            source: .hardware, hasMarkedText: self.markedTextRange != nil,
            shift: flags.contains(.shift), option: flags.contains(.alternate), command: flags.contains(.command),
            supportsSendAndOpen: false, canSubmit: self.canSubmit)
    }

    @objc private func hardwareReturn(_ command: UIKeyCommand) {
        switch self.returnKey(for: command) {
        case .send, .sendAndOpen: self.onSubmit?()
        case .newline: self.insertText("\n")
        case .system, .ignore: break
        }
    }

    @objc private func menuKey(_ command: UIKeyCommand) {
        guard let key = Self.menuKeys.first(where: { $0.0 == command.input })?.1 else { return }
        _ = self.onKey?(key)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(self.hardwareReturn(_:)) {
            // While composing (marked text), Return commits the candidate instead.
            return self.isEditable && self.returnKey(for: sender as? UIKeyCommand) != .system
        }
        if action == #selector(self.menuKey(_:)) {
            guard self.markedTextRange == nil else { return false }
            if self.menuActive { return true }
            return self.escapeActive && (sender as? UIKeyCommand)?.input == UIKeyCommand.inputEscape
        }
        if action == #selector(paste(_:)), MediaPasteboard.hasMedia(.general) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let items = MediaPasteboard.items(from: .general)
        if items.isEmpty {
            super.paste(sender)
        } else {
            self.onMedia?(items)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard self.window != nil, !self.didAutoFocus else { return }
        self.didAutoFocus = true
        // With a software keyboard, focusing here brings the keyboard up in the middle of the
        // navigation push. That stalls the main thread and resizes the transcript while it animates.
        guard GCKeyboard.coalesced != nil else { return }
        DispatchQueue.main.async {
            guard self.window != nil, self.autoFocus?() ?? true else { return }
            self.becomeFirstResponder()
        }
    }
}

private struct PlatformComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let maxLines: Int
    let isEditable: Bool
    let menuActive: Bool
    let escapeActive: Bool
    let canSubmit: Bool
    let focusRequest: Int
    let onSubmit: () -> Void
    let onCommandSubmit: (() -> Void)?
    let onMedia: ([PastedMedia]) -> Void
    let onKey: (ComposerKey) -> Bool
    let onCaretAtEnd: (Bool) -> Void
    let onMarkedTextChange: (Bool) -> Void
    let onSelectionChange: (NSRange) -> Void
    let onFocusChange: (Bool) -> Void
    let caretRequest: CaretRequest?
    let autoFocus: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = self.text
        textView.onMedia = self.onMedia
        textView.menuActive = self.menuActive
        textView.escapeActive = self.escapeActive
        textView.canSubmit = self.canSubmit
        textView.onSubmit = self.onSubmit
        textView.onKey = self.onKey
        textView.autoFocus = self.autoFocus
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        textView.onMedia = self.onMedia
        textView.menuActive = self.menuActive
        textView.escapeActive = self.escapeActive
        textView.canSubmit = self.canSubmit
        textView.onSubmit = self.onSubmit
        textView.onKey = self.onKey
        textView.autoFocus = self.autoFocus
        if textView.isEditable != self.isEditable { textView.isEditable = self.isEditable }
        if context.coordinator.focusRequest != self.focusRequest {
            context.coordinator.focusRequest = self.focusRequest
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
        let caret = context.coordinator.takeCaret(self.caretRequest, length: (self.text as NSString).length)
        if textView.text != self.text {
            textView.text = self.text
            textView.selectedRange = NSRange(location: caret ?? (self.text as NSString).length, length: 0)
        } else if let caret {
            textView.selectedRange = NSRange(location: caret, length: 0)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.frame.width
        let lineHeight = context.coordinator.lineHeight(for: uiView.font ?? .preferredFont(forTextStyle: .body))
        let height = context.coordinator.heights.height(
            for: uiView.text ?? "", lineHeight: lineHeight, width: width, maxLines: self.maxLines
        ) { width in
            uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlatformComposerTextView
        var focusRequest: Int
        var caretSerial: Int?
        let heights = ComposerHeightCache()
        private var lineHeightFont: UIFont?
        private var cachedLineHeight: CGFloat = 0

        init(_ parent: PlatformComposerTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
            self.caretSerial = parent.caretRequest?.serial
        }

        /// The clamped offset of a caret request not yet applied, once.
        func takeCaret(_ request: CaretRequest?, length: Int) -> Int? {
            guard let request, request.serial != self.caretSerial else { return nil }
            self.caretSerial = request.serial
            return min(max(request.offset, 0), length)
        }

        /// One laid-out line, which UITextView makes taller than `UIFont.lineHeight`; the empty
        /// field and the line cap use it so they match the measured text heights.
        func lineHeight(for font: UIFont) -> CGFloat {
            if font != self.lineHeightFont {
                self.lineHeightFont = font
                self.cachedLineHeight = ceil(NSAttributedString(string: "X", attributes: [.font: font]).boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            }
            return self.cachedLineHeight
        }

        func textViewDidChange(_ textView: UITextView) {
            self.parent.onMarkedTextChange(textView.markedTextRange != nil)
            let selection = textView.selectedRange
            self.parent.onCaretAtEnd(selection.length == 0 && selection.location == textView.textStorage.length)
            self.parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) { self.parent.onFocusChange(true) }

        func textViewDidEndEditing(_ textView: UITextView) { self.parent.onFocusChange(false) }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            self.parent.onMarkedTextChange(textView.markedTextRange != nil)
            self.parent.onCaretAtEnd(range.length == 0 && range.location == (textView.text as NSString).length)
            self.parent.onSelectionChange(range)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Return picks the highlighted suggestion (or sends a finished command) while the menu is open.
            guard text == "\n", self.parent.menuActive, textView.markedTextRange == nil else { return true }
            self.parent.onSubmit()
            return false
        }
    }
}
#endif
