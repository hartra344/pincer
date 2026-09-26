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
    let onSubmit: () -> Void
    let onMedia: ([PastedMedia]) -> Void
    /// Returns whether the key was handled.
    var onKey: (ComposerKey) -> Bool = { _ in false }
    /// Whether the caret is an insertion point at the end of the text.
    var onCaretAtEnd: (Bool) -> Void = { _ in }
    /// Asked just before the field focuses itself on appearing; false leaves focus where it is
    /// (e.g. Find in Chat opening with the chat).
    var autoFocus: @MainActor () -> Bool = { true }

    var body: some View {
        PlatformComposerTextView(
            text: self.$text, maxLines: self.maxLines, isEditable: self.isEditable, menuActive: self.menuActive, onSubmit: self.onSubmit,
            onMedia: self.onMedia, onKey: self.onKey, onCaretAtEnd: self.onCaretAtEnd, autoFocus: self.autoFocus)
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

private func composerHeight(for text: String, font: PlatformFont, lineHeight: CGFloat, width: CGFloat, maxLines: Int) -> CGFloat {
    var height = lineHeight
    if !text.isEmpty, width > 0 {
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        height = max(lineHeight, bounds.height + (text.hasSuffix("\n") ? lineHeight : 0))
    }
    return ceil(min(height, lineHeight * CGFloat(maxLines)))
}

#if os(macOS)
private typealias PlatformFont = NSFont

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

private struct PlatformComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let maxLines: Int
    let isEditable: Bool
    let menuActive: Bool
    let onSubmit: () -> Void
    let onMedia: ([PastedMedia]) -> Void
    let onKey: (ComposerKey) -> Bool
    let onCaretAtEnd: (Bool) -> Void
    let autoFocus: @MainActor () -> Bool

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

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
        if textView.string != self.text {
            textView.string = self.text
            textView.setSelectedRange(NSRange(location: (self.text as NSString).length, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        let text = (nsView.documentView as? NSTextView)?.string ?? self.text
        return CGSize(
            width: width,
            height: composerHeight(for: text, font: Self.font, lineHeight: Self.lineHeight, width: width, maxLines: self.maxLines))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlatformComposerTextView

        init(_ parent: PlatformComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            self.parent.onCaretAtEnd(range.length == 0 && range.location == (textView.string as NSString).length)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if self.parent.menuActive, !textView.hasMarkedText() {
                let key: ComposerKey? = switch selector {
                case #selector(NSResponder.moveUp(_:)): .up
                case #selector(NSResponder.moveDown(_:)): .down
                case #selector(NSResponder.insertTab(_:)): .tab
                // Escape in a text view is `complete:` (system completion), not `cancelOperation:`.
                case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)): .escape
                default: nil
                }
                if let key, self.parent.onKey(key) { return true }
            }
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                self.parent.onSubmit()
            }
            return true
        }
    }
}

#else
private typealias PlatformFont = UIFont

final class ComposerUITextView: UITextView {
    var onMedia: (([PastedMedia]) -> Void)?
    var menuActive = false
    var onKey: ((ComposerKey) -> Bool)?
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
        return menu + (super.keyCommands ?? [])
    }

    @objc private func menuKey(_ command: UIKeyCommand) {
        guard let key = Self.menuKeys.first(where: { $0.0 == command.input })?.1 else { return }
        _ = self.onKey?(key)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(self.menuKey(_:)) { return self.menuActive && self.markedTextRange == nil }
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
    let onSubmit: () -> Void
    let onMedia: ([PastedMedia]) -> Void
    let onKey: (ComposerKey) -> Bool
    let onCaretAtEnd: (Bool) -> Void
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
        textView.onKey = self.onKey
        textView.autoFocus = self.autoFocus
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        textView.onMedia = self.onMedia
        textView.menuActive = self.menuActive
        textView.onKey = self.onKey
        textView.autoFocus = self.autoFocus
        if textView.isEditable != self.isEditable { textView.isEditable = self.isEditable }
        if textView.text != self.text {
            textView.text = self.text
            textView.selectedRange = NSRange(location: (self.text as NSString).length, length: 0)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.frame.width
        let font = uiView.font ?? .preferredFont(forTextStyle: .body)
        return CGSize(
            width: width,
            height: composerHeight(for: uiView.text ?? "", font: font, lineHeight: font.lineHeight, width: width, maxLines: self.maxLines))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlatformComposerTextView

        init(_ parent: PlatformComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            self.parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            self.parent.onCaretAtEnd(range.length == 0 && range.location == (textView.text as NSString).length)
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
