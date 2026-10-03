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
    @State private var measuredHeightRevision = 0
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
            text: self.$text, measuredHeightRevision: self.measuredHeightRevision,
            onHeightMeasurementChange: { self.measuredHeightRevision &+= 1 },
            maxLines: self.maxLines, isEditable: self.isEditable, menuActive: self.menuActive,
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

private func composerHeight(for text: String, font: PlatformFont, lineHeight: CGFloat, width: CGFloat, maxLines: Int) -> CGFloat {
    var height = lineHeight
    if !text.isEmpty, width > 0 {
#if DEBUG
        let probeEnabled = ComposerSizingProbe.isEnabled
        let probeStart = probeEnabled ? ProcessInfo.processInfo.systemUptime : nil
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        let attributedLength = probeEnabled ? attributed.length : 0
#else
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
#endif
        height = max(lineHeight, bounds.height + (text.hasSuffix("\n") ? lineHeight : 0))
#if DEBUG
        if let probeStart {
            let elapsedNanoseconds = UInt64(max(0, (ProcessInfo.processInfo.systemUptime - probeStart) * 1_000_000_000))
            ComposerSizingProbe.record(.init(
                elapsedNanoseconds: elapsedNanoseconds,
                attributedLength: attributedLength,
                isMainThread: Thread.isMainThread,
                width: Double(width),
                lineHeight: Double(lineHeight),
                maxLines: maxLines,
                returnedHeight: Double(ceil(min(height, lineHeight * CGFloat(maxLines))))))
        }
#endif
    }
    return ceil(min(height, lineHeight * CGFloat(maxLines)))
}

#if DEBUG
struct ComposerSizingSample: Sendable, Equatable {
    let elapsedNanoseconds: UInt64
    let attributedLength: Int
    let isMainThread: Bool
    let width: Double
    let lineHeight: Double
    let maxLines: Int
    let returnedHeight: Double
}

public enum ComposerSizingProbe {
    private static let storage = ComposerSizingProbeStorage()

    static var isEnabled: Bool { self.storage.isEnabled }
    static var samples: [ComposerSizingSample] { self.storage.samples }

    static func reset(enabled: Bool) {
        self.storage.reset(enabled: enabled)
    }

    static func record(_ sample: ComposerSizingSample) {
        self.storage.record(sample)
    }
}

private final class ComposerSizingProbeStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var recorded: [ComposerSizingSample] = []

    var isEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.enabled
    }

    var samples: [ComposerSizingSample] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    func reset(enabled: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recorded.removeAll(keepingCapacity: true)
        self.enabled = enabled
    }

    func record(_ sample: ComposerSizingSample) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.enabled, self.recorded.count < 64 else { return }
        self.recorded.append(sample)
    }
}
#endif

private struct ComposerSizingFont: @unchecked Sendable {
    // NSFont and UIFont are immutable after construction; the worker only reads this snapshot.
    let font: PlatformFont
    let lineHeight: Double
    let identity: ObjectIdentifier
    let name: String
    let pointSize: Double

    init(font: PlatformFont, lineHeight: CGFloat) {
        self.font = font
        self.lineHeight = Double(lineHeight)
        self.identity = ObjectIdentifier(font)
        self.name = font.fontName
        self.pointSize = Double(font.pointSize)
    }
}

private struct ComposerSizingRequest: Sendable {
    let text: String
    let font: ComposerSizingFont
    let width: Double
    let maxLines: Int
}

private struct ComposerSizingStyleKey: Hashable, Sendable {
    let width: Double
    let fontIdentity: ObjectIdentifier
    let fontName: String
    let pointSize: Double
    let lineHeight: Double
    let maxLines: Int

    init(font: ComposerSizingFont, width: CGFloat, maxLines: Int) {
        self.width = Double(width)
        self.fontIdentity = font.identity
        self.fontName = font.name
        self.pointSize = font.pointSize
        self.lineHeight = font.lineHeight
        self.maxLines = maxLines
    }
}

private struct ComposerSizingKey: Hashable, Sendable {
    let textRevision: UInt64
    let style: ComposerSizingStyleKey

    init(textRevision: UInt64, font: ComposerSizingFont, width: CGFloat, maxLines: Int) {
        self.textRevision = textRevision
        self.style = ComposerSizingStyleKey(font: font, width: width, maxLines: maxLines)
    }
}

@MainActor
final class ComposerHeightMeasurement {
    private let worker = LatestMeasurementWorker<ComposerSizingRequest, Double> { request in
        autoreleasepool {
            Double(composerHeight(
                for: request.text,
                font: request.font.font,
                lineHeight: CGFloat(request.font.lineHeight),
                width: CGFloat(request.width),
                maxLines: request.maxLines))
        }
    }
    private var textRevision: UInt64 = 0
    private var currentKey: ComposerSizingKey?
    private var completedKey: ComposerSizingKey?
    private var completedHeight: CGFloat?
    private var heightDidChange: (@MainActor () -> Void)?
    private var isDetached = false

    func textDidChange() {
        self.textRevision &+= 1
        self.currentKey = nil
        self.worker.invalidate()
    }

    func height(
        for text: String,
        font: PlatformFont,
        lineHeight: CGFloat,
        width: CGFloat,
        maxLines: Int,
        onHeightChange: @escaping @MainActor () -> Void
    ) -> CGFloat {
        let oneLineFallback = ceil(min(lineHeight, lineHeight * CGFloat(maxLines)))
        // SwiftUI may probe zero or unbounded widths while negotiating layout. Those
        // probes must not replace the pending measurement for the actual finite width.
        guard width.isFinite, width > 0 else { return oneLineFallback }
        self.heightDidChange = onHeightChange
        let fontSnapshot = ComposerSizingFont(font: font, lineHeight: lineHeight)
        let style = ComposerSizingStyleKey(font: fontSnapshot, width: width, maxLines: maxLines)
        let key = ComposerSizingKey(textRevision: self.textRevision, font: fontSnapshot, width: width, maxLines: maxLines)
        let canReuseCompletedHeight = !text.isEmpty && width > 0 && self.completedKey?.style == style
        let fallback = canReuseCompletedHeight ? (self.completedHeight ?? oneLineFallback) : oneLineFallback

        if self.currentKey == key {
            return self.completedKey == key ? (self.completedHeight ?? fallback) : fallback
        }

        self.currentKey = key
        guard !self.isDetached else { return fallback }
        guard !text.isEmpty, width > 0 else {
            self.worker.invalidate()
            self.completedKey = key
            self.completedHeight = fallback
            return fallback
        }

        let request = ComposerSizingRequest(text: text, font: fontSnapshot, width: Double(width), maxLines: maxLines)
        self.worker.submit(request) { [weak self] measuredHeight in
            guard let self, !self.isDetached, self.currentKey == key else { return }
            let height = CGFloat(measuredHeight)
            let changed = abs(fallback - height) > 0.5
            self.completedKey = key
            self.completedHeight = height
            if changed { self.heightDidChange?() }
        }
        return fallback
    }

    func detach() {
        guard !self.isDetached else { return }
        self.isDetached = true
        self.currentKey = nil
        self.completedKey = nil
        self.completedHeight = nil
        self.heightDidChange = nil
        self.worker.invalidate()
    }
}

#if os(macOS)
typealias PlatformFont = NSFont

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
    let measuredHeightRevision: Int
    let onHeightMeasurementChange: () -> Void
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
        if context.coordinator.focusRequest != self.focusRequest {
            context.coordinator.focusRequest = self.focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        let caret = context.coordinator.takeCaret(self.caretRequest, length: (self.text as NSString).length)
        if textView.string != self.text {
            context.coordinator.heightMeasurement.textDidChange()
            textView.string = self.text
            textView.setSelectedRange(NSRange(location: caret ?? (self.text as NSString).length, length: 0))
        } else if let caret {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.heightMeasurement.detach()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        let text = (nsView.documentView as? NSTextView)?.string ?? self.text
        let coordinator = context.coordinator
        let height = context.coordinator.heightMeasurement.height(
            for: text,
            font: Self.font,
            lineHeight: Self.lineHeight,
            width: width,
            maxLines: self.maxLines,
            onHeightChange: { [weak coordinator, weak nsView] in
                guard let coordinator else { return }
                coordinator.parent.onHeightMeasurementChange()
                nsView?.invalidateIntrinsicContentSize()
            })
        return CGSize(
            width: width,
            height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlatformComposerTextView
        var focusRequest: Int
        var caretSerial: Int?
        let heightMeasurement = ComposerHeightMeasurement()

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
            self.heightMeasurement.textDidChange()
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
typealias PlatformFont = UIFont

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
    let measuredHeightRevision: Int
    let onHeightMeasurementChange: () -> Void
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
            context.coordinator.heightMeasurement.textDidChange()
            textView.text = self.text
            textView.selectedRange = NSRange(location: caret ?? (self.text as NSString).length, length: 0)
        } else if let caret {
            textView.selectedRange = NSRange(location: caret, length: 0)
        }
    }

    static func dismantleUIView(_ textView: ComposerUITextView, coordinator: Coordinator) {
        coordinator.heightMeasurement.detach()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.frame.width
        let font = uiView.font ?? .preferredFont(forTextStyle: .body)
        let coordinator = context.coordinator
        let height = context.coordinator.heightMeasurement.height(
            for: uiView.text ?? "",
            font: font,
            lineHeight: font.lineHeight,
            width: width,
            maxLines: self.maxLines,
            onHeightChange: { [weak coordinator, weak uiView] in
                guard let coordinator else { return }
                coordinator.parent.onHeightMeasurementChange()
                uiView?.invalidateIntrinsicContentSize()
            })
        return CGSize(
            width: width,
            height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlatformComposerTextView
        var focusRequest: Int
        var caretSerial: Int?
        let heightMeasurement = ComposerHeightMeasurement()

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

        func textViewDidChange(_ textView: UITextView) {
            self.heightMeasurement.textDidChange()
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
