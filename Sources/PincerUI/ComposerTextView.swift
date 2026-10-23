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

    /// Forgets measured heights, such as after styling changed how the same text wraps.
    func invalidate() { self.heights.removeAll(keepingCapacity: true) }

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
    /// Where the user just typed a backtick, so the fence auto-close can look at the line after the change lands.
    var typedBacktickLocation: Int?

    /// Bumped on every change, so an async paste can tell the text moved under it.
    private(set) var changeVersion = 0
    weak var styler: ComposerMarkdownStyler?

    override func didChangeText() {
        self.changeVersion += 1
        super.didChangeText()
    }

    override func paste(_ sender: Any?) {
        let items = MediaPasteboard.items(from: .general)
        guard items.isEmpty else {
            self.onMedia?(items)
            return
        }
        let selection = self.selectedRange()
        if self.styler?.index?.isInsideCodeBlock(selection.location) == true || self.hasMarkedText() {
            super.paste(sender)
            return
        }
        if selection.length > 0, let pasted = NSPasteboard.general.string(forType: .string), pasted.utf16.count < 2_048,
           let edit = ComposerFormatting.pasteLink(pasted, in: self.string as NSString, selection: selection)
        {
            self.apply(edit)
            return
        }
        guard let payload = ComposerRichPaste.payload(from: .general) else {
            super.paste(sender)
            return
        }
        if let quick = ComposerRichPaste.quickMarkdown(from: payload) {
            self.finishRichPaste(quick, selection: selection, sender: sender)
            return
        }
        let changeCount = NSPasteboard.general.changeCount
        let version = self.changeVersion
        Task { @MainActor [weak self] in
            let markdown = await ComposerRichPaste.markdown(from: payload)
            guard let self, NSPasteboard.general.changeCount == changeCount, self.changeVersion == version,
                  self.selectedRange() == selection
            else { return }
            self.finishRichPaste(markdown, selection: selection, sender: sender)
        }
    }

    /// Paste and Match Style: the pasteboard's plain string, verbatim.
    override func pasteAsPlainText(_ sender: Any?) {
        let items = MediaPasteboard.items(from: .general)
        guard items.isEmpty else {
            self.onMedia?(items)
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let range = self.selectedRange()
        self.apply(ComposerEdit(
            range: range, replacement: text, selection: NSRange(location: range.location + (text as NSString).length, length: 0)))
    }

    private func finishRichPaste(_ markdown: String?, selection: NSRange, sender: Any?) {
        guard let markdown else {
            self.pastePlain(sender)
            return
        }
        self.apply(ComposerEdit(
            range: selection, replacement: markdown,
            selection: NSRange(location: selection.location + (markdown as NSString).length, length: 0)))
    }

    private func pastePlain(_ sender: Any?) { super.paste(sender) }

    /// Replaces text through the text system, so undo, the binding and completion all see an ordinary edit.
    /// Each call is its own undo step, even right after typing in the same event (fence auto-close).
    func apply(_ edit: ComposerEdit) {
        guard self.isEditable else { return }
        if edit.range.length == 0, edit.replacement.isEmpty {
            self.setSelectedRange(edit.selection)
            return
        }
        guard self.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        self.breakUndoCoalescing()
        if let undoManager = self.undoManager, undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        self.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        self.didChangeText()
        self.breakUndoCoalescing()
        self.setSelectedRange(edit.selection)
    }

    func perform(_ action: ComposerFormatAction) {
        let text = self.string as NSString
        let selection = self.selectedRange()
        guard !self.hasMarkedText(), self.styler?.blocks(action, selection: selection, in: text) != true else { return }
        self.apply(action.edit(in: text, selection: selection))
    }

    @objc private func formatMenuItem(_ item: NSMenuItem) {
        guard let index = item.representedObject as? Int, ComposerFormatAction.allCases.indices.contains(index) else { return }
        self.perform(ComposerFormatAction.allCases[index])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        // Fonts and layout orientation mean nothing in a plain-Markdown field.
        let unwanted = ["orderFrontFontPanel:", "addFontTrait:", "changeLayoutOrientation:"].map(NSSelectorFromString)
        for item in menu.items.reversed() where item.submenu?.items.contains(where: { $0.action.map(unwanted.contains) ?? false }) == true {
            menu.removeItem(item)
        }
        guard self.isEditable else { return menu }
        let format = NSMenu(title: L("Format"))
        for (index, action) in ComposerFormatAction.allCases.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(self.formatMenuItem(_:)), keyEquivalent: action.keyEquivalent.key)
            item.keyEquivalentModifierMask = action.keyEquivalent.modifiers
            item.target = self
            item.representedObject = index
            format.addItem(item)
        }
        let parent = NSMenuItem(title: L("Format"), action: nil, keyEquivalent: "")
        parent.submenu = format
        menu.addItem(.separator())
        menu.addItem(parent)
        return menu
    }

    private static func formatAction(for event: NSEvent) -> ComposerFormatAction? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "b": return .bold
            case "i": return .italic
            case "e": return .code
            case "k": return .link
            default: return nil
            }
        }
        if flags == [.command, .shift] {
            if key == "x" { return .strikethrough }
            // ⇧⌘7: the character is "&" on US layouts, so match the physical key.
            if event.keyCode == 26 { return .bulletList }
        }
        return nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if self.window?.firstResponder === self, self.isEditable, !self.hasMarkedText(),
           let action = Self.formatAction(for: event)
        {
            // ⌘K without a selection belongs to the Command Palette.
            if action == .link, self.selectedRange().length == 0 { return super.performKeyEquivalent(with: event) }
            self.perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), MediaPasteboard.hasMedia(.general) { return true }
        if item.action == #selector(pasteAsPlainText(_:)) {
            return self.isEditable && (MediaPasteboard.hasMedia(.general) || NSPasteboard.general.string(forType: .string)?.isEmpty == false)
        }
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
    private var styleVersion = 0

    init() {
        self.container.lineFragmentPadding = 0
        self.layoutManager.addTextContainer(self.container)
        self.storage.addLayoutManager(self.layoutManager)
    }

    /// `styled` is the live text view's attributed string when Markdown styling is on, so monospaced code wraps like it will draw.
    func usedHeight(of text: String, font: NSFont, width: CGFloat, styleVersion: Int = 0, styled: () -> NSAttributedString? = { nil }) -> CGFloat {
        if text != self.text || font != self.font || styleVersion != self.styleVersion {
            self.text = text
            self.font = font
            self.styleVersion = styleVersion
            self.storage.setAttributedString(styled() ?? NSAttributedString(string: text, attributes: [.font: font]))
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

extension PlatformComposerTextView: NSViewRepresentable {
    @MainActor static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    @MainActor static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

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
        context.coordinator.attachStyler(to: textView)

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
        if context.coordinator.takeFocusRequest() {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        let edit = context.coordinator.pendingEdit(viewText: textView.string)
        if let text = edit.text { textView.string = text }
        if let selection = edit.selection { textView.setSelectedRange(selection) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        let textView = nsView.documentView as? NSTextView
        let text = textView?.string ?? self.text
        let coordinator = context.coordinator
        let height = coordinator.heights.height(
            for: text, lineHeight: Self.lineHeight, width: width, maxLines: self.maxLines
        ) { width in
            coordinator.measurer.usedHeight(of: text, font: Self.font, width: width, styleVersion: coordinator.styleVersion) {
                guard coordinator.styler?.isEnabled == true, let storage = textView?.textStorage,
                      storage.length == (text as NSString).length
                else { return nil }
                return NSAttributedString(attributedString: storage)
            }
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: ComposerCoordinatorBase, NSTextViewDelegate {
        let measurer = ComposerTextMeasurer()
        private(set) var styler: ComposerMarkdownStyler?
        private(set) var styleVersion = 0
        private weak var textView: ComposerNSTextView?
        private let observers = NotificationTokens()

        /// Hooks live Markdown styling into the text view's storage and follows the Settings toggle.
        func attachStyler(to textView: ComposerNSTextView) {
            guard let storage = textView.textStorage else { return }
            let styler = ComposerMarkdownStyler(baseFont: PlatformComposerTextView.font, isEnabled: ComposerMarkdownSettings().liveStyling)
            styler.hasMarkedText = { [weak textView] in textView?.hasMarkedText() ?? false }
            styler.onRestyled = { [weak self] in self?.stylingChanged() }
            styler.attach(to: storage)
            styler.restyleAll(storage)
            self.styler = styler
            textView.styler = styler
            self.textView = textView
            self.observers.add(NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncStylingSetting() }
            })
        }

        private func syncStylingSetting() {
            guard let styler, let storage = self.textView?.textStorage else { return }
            let enabled = ComposerMarkdownSettings().liveStyling
            if enabled != styler.isEnabled { styler.setEnabled(enabled, storage: storage) }
        }

        private func stylingChanged() {
            self.styleVersion += 1
            self.heights.invalidate()
            self.textView?.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            (textView as? ComposerNSTextView)?.typedBacktickLocation = replacementString == "`" && !textView.hasMarkedText() ? range.location : nil
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !textView.hasMarkedText(), let storage = textView.textStorage { self.styler?.flushDeferred(storage) }
            self.reportCaret(textView.selectedRange(), length: textView.textStorage?.length, hasMarkedText: textView.hasMarkedText())
            self.parent.text = textView.string
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
            if let composer = textView as? ComposerNSTextView, let location = composer.typedBacktickLocation {
                composer.typedBacktickLocation = nil
                if !textView.hasMarkedText(), let edit = ComposerFormatting.autoCloseFence(in: textView.string as NSString, typedAt: location) {
                    composer.apply(edit)
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) { self.parent.onFocusChange(true) }

        func textDidEndEditing(_ notification: Notification) { self.parent.onFocusChange(false) }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            self.reportCaret(range, length: (textView.string as NSString).length, hasMarkedText: textView.hasMarkedText())
            self.parent.onSelectionChange(range)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
            let isForwardTab = selector == #selector(NSResponder.insertTab(_:))
            let isBackwardTab = selector == #selector(NSResponder.insertBacktab(_:))
            if isForwardTab || isBackwardTab {
                if !self.parent.menuActive, !textView.hasMarkedText(), !modifierFlags.contains(.option),
                   let composer = textView as? ComposerNSTextView,
                   let edit = ComposerFormatting.indent(
                       in: textView.string as NSString, selection: textView.selectedRange(),
                       outdent: isBackwardTab || modifierFlags.contains(.shift))
                {
                    composer.apply(edit)
                    return true
                }
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
            case .newline:
                if let composer = textView as? ComposerNSTextView,
                   let edit = ComposerFormatting.newline(in: textView.string as NSString, selection: textView.selectedRange())
                {
                    composer.apply(edit)
                } else {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                }
            case .send:
                if !self.parent.menuActive, !modifierFlags.contains(.command), let composer = textView as? ComposerNSTextView,
                   ComposerMarkdown.returnInsertsNewline(in: textView.string as NSString, at: textView.selectedRange().location)
                {
                    let range = textView.selectedRange()
                    composer.apply(ComposerEdit(range: range, replacement: "\n", selection: NSRange(location: range.location + 1, length: 0)))
                } else {
                    self.parent.onSubmit()
                }
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
    /// Where the user just typed a backtick, so the fence auto-close can look at the line after the change lands.
    var typedBacktickLocation: Int?
    /// Bumped by the coordinator on every `textViewDidChange`, to tell whether a programmatic edit notified it.
    var didChangeCount = 0
    private(set) var isApplyingEdit = false
    private var formatBar: UIToolbar?

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
        return menu + Self.returnCommands + Self.indentCommands + Self.formatCommands + (super.keyCommands ?? [])
    }

    private static let indentCommands: [UIKeyCommand] = [[], UIKeyModifierFlags.shift].map { flags in
        let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(ComposerUITextView.indentKey(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// Markdown formatting shortcuts, titled so iPad's hold-⌘ overlay lists them.
    private static let formatKeys: [(action: ComposerFormatAction, input: String, flags: UIKeyModifierFlags)] = [
        (.bold, "b", .command), (.italic, "i", .command), (.code, "e", .command),
        (.strikethrough, "x", [.command, .shift]), (.link, "k", .command), (.bulletList, "7", [.command, .shift]),
    ]

    private static let formatCommands: [UIKeyCommand] = {
        ComposerUITextView.formatKeys.map { action, input, flags in
            let command = UIKeyCommand(title: action.title, action: #selector(ComposerUITextView.formatKey(_:)), input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }()

    private func formatAction(for command: UIKeyCommand?) -> ComposerFormatAction? {
        guard let command else { return nil }
        return Self.formatKeys.first { $0.input == command.input && $0.flags == command.modifierFlags }?.action
    }

    @objc private func formatKey(_ command: UIKeyCommand) {
        guard let action = self.formatAction(for: command) else { return }
        self.perform(action)
    }

    @objc private func indentKey(_ command: UIKeyCommand) {
        guard let edit = self.indentEdit(outdent: command.modifierFlags.contains(.shift)) else { return }
        self.apply(edit)
    }

    private func indentEdit(outdent: Bool) -> ComposerEdit? {
        guard !self.menuActive, self.markedTextRange == nil else { return nil }
        return ComposerFormatting.indent(in: self.text as NSString, selection: self.selectedRange, outdent: outdent)
    }

    /// Replaces text through the text system (undo and the binding see an ordinary edit) and reports the change once.
    func apply(_ edit: ComposerEdit) {
        guard self.isEditable, !self.isApplyingEdit,
              let start = self.position(from: self.beginningOfDocument, offset: edit.range.location),
              let end = self.position(from: start, offset: edit.range.length),
              let range = self.textRange(from: start, to: end)
        else { return }
        if edit.range.length == 0, edit.replacement.isEmpty {
            self.selectedRange = edit.selection
            return
        }
        self.isApplyingEdit = true
        defer { self.isApplyingEdit = false }
        // Its own undo step, even right after typing in the same event (fence auto-close).
        if let undoManager = self.undoManager, undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        let before = self.didChangeCount
        self.replace(range, withText: edit.replacement)
        if self.didChangeCount == before { self.delegate?.textViewDidChange?(self) }
        self.selectedRange = edit.selection
    }

    func perform(_ action: ComposerFormatAction) {
        let text = self.text as NSString
        guard self.markedTextRange == nil, self.styler?.blocks(action, selection: self.selectedRange, in: text) != true else { return }
        self.apply(action.edit(in: text, selection: self.selectedRange))
    }

    /// Shows or hides the optional formatting bar above the keyboard.
    func setShowsFormatBar(_ shows: Bool) {
        guard shows != (self.inputAccessoryView != nil) else { return }
        if shows {
            let bar = self.formatBar ?? ComposerFormatBar.make { [weak self] in self?.perform($0) }
            self.formatBar = bar
            self.inputAccessoryView = bar
        } else {
            self.inputAccessoryView = nil
        }
        if self.isFirstResponder { self.reloadInputViews() }
    }

    /// Copy and cut put plain Markdown on the pasteboard: styled runs would round-trip through the rich paste converter and double the markers.
    override func copy(_ sender: Any?) {
        guard let range = self.selectedTextRange, !range.isEmpty, let text = self.text(in: range) else { return }
        UIPasteboard.general.string = text
    }

    override func cut(_ sender: Any?) {
        guard let range = self.selectedTextRange, !range.isEmpty else { return }
        self.copy(sender)
        self.replace(range, withText: "")
    }

    override func toggleBoldface(_ sender: Any?) { self.perform(.bold) }
    override func toggleItalics(_ sender: Any?) { self.perform(.italic) }

    /// Newline from the hardware ⇧↩/⌥↩: continues lists and quotes, else a plain line break.
    func insertSmartNewline() {
        if self.markedTextRange == nil,
           let edit = ComposerFormatting.newline(in: self.text as NSString, selection: self.selectedRange)
        {
            self.apply(edit)
        } else {
            self.insertText("\n")
        }
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
        case .send where self.returnInsertsPlainNewline(command):
            let range = self.selectedRange
            self.apply(ComposerEdit(range: range, replacement: "\n", selection: NSRange(location: range.location + 1, length: 0)))
        case .send, .sendAndOpen: self.onSubmit?()
        case .newline: self.insertSmartNewline()
        case .system, .ignore: break
        }
    }

    /// Return inside a code fence types a line break instead of sending (⌘↩ still sends).
    private func returnInsertsPlainNewline(_ command: UIKeyCommand) -> Bool {
        !self.menuActive && !command.modifierFlags.contains(.command) && self.markedTextRange == nil
            && ComposerMarkdown.returnInsertsNewline(in: self.text as NSString, at: self.selectedRange.location)
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
        if action == #selector(self.indentKey(_:)) {
            return self.isEditable && self.indentEdit(outdent: (sender as? UIKeyCommand)?.modifierFlags.contains(.shift) == true) != nil
        }
        if action == #selector(self.formatKey(_:)) {
            guard self.isEditable, self.markedTextRange == nil else { return false }
            // ⌘K without a selection belongs to the Command Palette.
            if self.formatAction(for: sender as? UIKeyCommand) == .link { return self.selectedRange.length > 0 }
            return true
        }
        if action == #selector(paste(_:)), MediaPasteboard.hasMedia(.general) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    weak var styler: ComposerMarkdownStyler?

    override func paste(_ sender: Any?) {
        let items = MediaPasteboard.items(from: .general)
        guard items.isEmpty else {
            self.onMedia?(items)
            return
        }
        let selection = self.selectedRange
        if self.styler?.index?.isInsideCodeBlock(selection.location) == true || self.markedTextRange != nil {
            super.paste(sender)
            return
        }
        if selection.length > 0, let pasted = UIPasteboard.general.string, pasted.utf16.count < 2_048,
           let edit = ComposerFormatting.pasteLink(pasted, in: self.text as NSString, selection: selection)
        {
            self.apply(edit)
            return
        }
        guard let payload = ComposerRichPaste.payload(from: .general) else {
            super.paste(sender)
            return
        }
        if let quick = ComposerRichPaste.quickMarkdown(from: payload) {
            self.finishRichPaste(quick, selection: selection, sender: sender)
            return
        }
        let changeCount = UIPasteboard.general.changeCount
        let version = self.didChangeCount
        Task { @MainActor [weak self] in
            let markdown = await ComposerRichPaste.markdown(from: payload)
            guard let self, UIPasteboard.general.changeCount == changeCount, self.didChangeCount == version,
                  self.selectedRange == selection
            else { return }
            self.finishRichPaste(markdown, selection: selection, sender: sender)
        }
    }

    private func finishRichPaste(_ markdown: String?, selection: NSRange, sender: Any?) {
        guard let markdown else {
            self.pastePlain(sender)
            return
        }
        self.apply(ComposerEdit(
            range: selection, replacement: markdown,
            selection: NSRange(location: selection.location + (markdown as NSString).length, length: 0)))
    }

    private func pastePlain(_ sender: Any?) { super.paste(sender) }

    /// Paste and Match Style: the pasteboard's plain string, verbatim.
    override func pasteAndMatchStyle(_ sender: Any?) {
        let items = MediaPasteboard.items(from: .general)
        guard items.isEmpty else {
            self.onMedia?(items)
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let range = self.selectedRange
        self.apply(ComposerEdit(
            range: range, replacement: text, selection: NSRange(location: range.location + (text as NSString).length, length: 0)))
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

extension PlatformComposerTextView: UIViewRepresentable {
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
        context.coordinator.attachStyler(to: textView)
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
        if context.coordinator.takeFocusRequest() {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
        let edit = context.coordinator.pendingEdit(viewText: textView.text)
        if let text = edit.text { textView.text = text }
        if let selection = edit.selection { textView.selectedRange = selection }
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
    final class Coordinator: ComposerCoordinatorBase, UITextViewDelegate {
        private var lineHeightFont: UIFont?
        private var cachedLineHeight: CGFloat = 0
        private(set) var styler: ComposerMarkdownStyler?
        private weak var textView: ComposerUITextView?
        private let observers = NotificationTokens()

        /// Hooks live Markdown styling into the text storage; follows the Settings toggles and Dynamic Type.
        func attachStyler(to textView: ComposerUITextView) {
            let settings = ComposerMarkdownSettings()
            let styler = ComposerMarkdownStyler(baseFont: .preferredFont(forTextStyle: .body), isEnabled: settings.liveStyling)
            styler.hasMarkedText = { [weak textView] in textView?.markedTextRange != nil }
            styler.onRestyled = { [weak self] in self?.stylingChanged() }
            styler.attach(to: textView.textStorage)
            textView.styler = styler
            styler.restyleAll(textView.textStorage)
            self.styler = styler
            self.textView = textView
            textView.setShowsFormatBar(settings.showsFormatBar)
            self.observers.add(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSettings() }
            })
            self.observers.add(NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView, let styler = self.styler else { return }
                    styler.setBaseFont(.preferredFont(forTextStyle: .body), storage: textView.textStorage)
                }
            })
        }

        private func syncSettings() {
            guard let styler, let textView else { return }
            let settings = ComposerMarkdownSettings()
            if settings.liveStyling != styler.isEnabled { styler.setEnabled(settings.liveStyling, storage: textView.textStorage) }
            textView.setShowsFormatBar(settings.showsFormatBar)
        }

        private func stylingChanged() {
            self.heights.invalidate()
            self.textView?.invalidateIntrinsicContentSize()
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
            let composer = textView as? ComposerUITextView
            composer?.didChangeCount += 1
            if textView.markedTextRange == nil { self.styler?.flushDeferred(textView.textStorage) }
            self.reportCaret(textView.selectedRange, length: textView.textStorage.length, hasMarkedText: textView.markedTextRange != nil)
            self.parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
            if let composer, let location = composer.typedBacktickLocation {
                composer.typedBacktickLocation = nil
                if textView.markedTextRange == nil,
                   let edit = ComposerFormatting.autoCloseFence(in: textView.text as NSString, typedAt: location)
                {
                    composer.apply(edit)
                }
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let composer = textView as? ComposerUITextView, composer.isEditable else { return UIMenu(children: suggestedActions) }
            let format = UIMenu(title: L("Format"), children: ComposerFormatAction.allCases.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.symbolName)) { [weak composer] _ in composer?.perform(action) }
            })
            return UIMenu(children: suggestedActions + [format])
        }

        func textViewDidBeginEditing(_ textView: UITextView) { self.parent.onFocusChange(true) }

        func textViewDidEndEditing(_ textView: UITextView) { self.parent.onFocusChange(false) }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            self.reportCaret(range, length: (textView.text as NSString).length, hasMarkedText: textView.markedTextRange != nil)
            self.parent.onSelectionChange(range)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard textView.markedTextRange == nil, (textView as? ComposerUITextView)?.isApplyingEdit != true else { return true }
            (textView as? ComposerUITextView)?.typedBacktickLocation = text == "`" ? range.location : nil
            guard text == "\n" else { return true }
            // Return picks the highlighted suggestion (or sends a finished command) while the menu is open.
            if self.parent.menuActive {
                self.parent.onSubmit()
                return false
            }
            // The on-screen Return continues lists and quotes.
            guard let composer = textView as? ComposerUITextView,
                  let edit = ComposerFormatting.newline(in: textView.text as NSString, selection: range)
            else { return true }
            composer.apply(edit)
            return false
        }
    }
}
#endif

/// The native text field behind `ComposerTextView`: an `NSTextView` on macOS, a `UITextView` on iOS.
struct PlatformComposerTextView {
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
}

/// State and reporting both platforms' composer coordinators share.
@MainActor
class ComposerCoordinatorBase: NSObject {
    var parent: PlatformComposerTextView
    var focusRequest: Int
    var caretSerial: Int?
    let heights = ComposerHeightCache()

    init(_ parent: PlatformComposerTextView) {
        self.parent = parent
        self.focusRequest = parent.focusRequest
        self.caretSerial = parent.caretRequest?.serial
    }

    /// The clamped offset of a caret request not yet applied, once.
    final func takeCaret(_ request: CaretRequest?, length: Int) -> Int? {
        guard let request, request.serial != self.caretSerial else { return nil }
        self.caretSerial = request.serial
        return min(max(request.offset, 0), length)
    }

    /// Whether the parent asked for focus since last time, once.
    final func takeFocusRequest() -> Bool {
        guard self.focusRequest != self.parent.focusRequest else { return false }
        self.focusRequest = self.parent.focusRequest
        return true
    }

    /// What the field needs to match the parent: its text when it differs (with the caret at the
    /// requested offset or the end), or just a pending caret request.
    final func pendingEdit(viewText: String?) -> (text: String?, selection: NSRange?) {
        let text = self.parent.text
        let length = (text as NSString).length
        let caret = self.takeCaret(self.parent.caretRequest, length: length)
        if viewText != text { return (text, NSRange(location: caret ?? length, length: 0)) }
        return (nil, caret.map { NSRange(location: $0, length: 0) })
    }

    /// Reports the composition state, then whether the caret is an insertion point at the end.
    final func reportCaret(_ selection: NSRange, length: Int?, hasMarkedText: Bool) {
        self.parent.onMarkedTextChange(hasMarkedText)
        self.parent.onCaretAtEnd(selection.length == 0 && selection.location == length)
    }
}
