import Foundation
import PincerKit
#if os(macOS)
import AppKit
typealias MarkdownFont = NSFont
typealias MarkdownColor = NSColor
typealias MarkdownEditActions = NSTextStorageEditActions
#else
import UIKit
typealias MarkdownFont = UIFont
typealias MarkdownColor = UIColor
typealias MarkdownEditActions = NSTextStorage.EditActions
#endif

/// The base font plus the bold/italic/monospaced variants Markdown styling needs, built lazily.
@MainActor
final class MarkdownFontSet {
    let base: MarkdownFont
    private var variants: [MarkdownFont?] = Array(repeating: nil, count: 8)

    init(base: MarkdownFont) {
        self.base = base
        self.variants[0] = base
    }

    private static func mask(bold: Bool, italic: Bool, mono: Bool) -> Int {
        (bold ? 1 : 0) | (italic ? 2 : 0) | (mono ? 4 : 0)
    }

    func font(bold: Bool, italic: Bool, mono: Bool) -> MarkdownFont {
        let mask = Self.mask(bold: bold, italic: italic, mono: mono)
        if let cached = self.variants[mask] { return cached }
        let font = self.build(bold: bold, italic: italic, mono: mono)
        self.variants[mask] = font
        return font
    }

    /// Which variant `font` is, so a span can add a trait to whatever an enclosing span already set.
    func traits(of font: MarkdownFont) -> (bold: Bool, italic: Bool, mono: Bool) {
        for mask in 0..<8 where self.font(bold: mask & 1 != 0, italic: mask & 2 != 0, mono: mask & 4 != 0) == font {
            return (mask & 1 != 0, mask & 2 != 0, mask & 4 != 0)
        }
        return (false, false, false)
    }

    private func build(bold: Bool, italic: Bool, mono: Bool) -> MarkdownFont {
        let size = self.base.pointSize
        #if os(macOS)
        var font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : self.base
        if bold, !mono { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
        #else
        var font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : self.base
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold, !mono { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
        #endif
    }
}

/// Live Markdown styling for the composer's text storage. Restyles only the paragraph(s) an edit touched;
/// text set wholesale (draft restore, chat switch) or edited in bulk is tokenized off the main thread and
/// applied when it's still current. The text stays plain Markdown: only attributes change.
@MainActor
final class ComposerMarkdownStyler: NSObject, NSTextStorageDelegate {
    /// Edits longer than this (UTF-16 units) tokenize off the main thread.
    static let offMainThreshold = 4_000
    /// Largest paragraph styled synchronously while a full restyle is pending.
    private static let quickParagraphLimit = 2_000

    private(set) var fonts: MarkdownFontSet
    private(set) var isEnabled: Bool
    private(set) var index: ComposerMarkdownIndex?
    /// Whether the text view has IME marked text; styling waits until it commits.
    var hasMarkedText: () -> Bool = { false }
    /// Called after styling changed layout-relevant attributes outside a user edit (async apply, toggles).
    var onRestyled: () -> Void = {}

    private weak var attached: NSTextStorage?
    private var generation = 0
    private var deferredRange: NSRange?
    private var needsFullAfterMarkedText = false

    init(baseFont: MarkdownFont, isEnabled: Bool = true) {
        self.fonts = MarkdownFontSet(base: baseFont)
        self.isEnabled = isEnabled
        super.init()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: self.fonts.base, .foregroundColor: Self.labelColor]
    }

    #if os(macOS)
    private static let labelColor = NSColor.labelColor
    private static let dimColor = NSColor.secondaryLabelColor
    private static let linkColor = NSColor.linkColor
    #else
    private static let labelColor = UIColor.label
    private static let dimColor = UIColor.secondaryLabel
    private static let linkColor = UIColor.link
    #endif

    func attach(to storage: NSTextStorage) {
        self.attached = storage
        storage.delegate = self
    }

    // MARK: Whole-text styling

    func setEnabled(_ enabled: Bool, storage: NSTextStorage) {
        guard enabled != self.isEnabled else { return }
        self.isEnabled = enabled
        self.generation += 1
        if enabled {
            self.restyleAll(storage)
        } else {
            self.index = nil
            self.deferredRange = nil
            self.resetAttributes(in: storage, range: NSRange(location: 0, length: storage.length))
            self.onRestyled()
        }
    }

    func setBaseFont(_ font: MarkdownFont, storage: NSTextStorage) {
        guard font != self.fonts.base else { return }
        self.fonts = MarkdownFontSet(base: font)
        self.restyleAll(storage)
    }

    /// Restyles the whole text: small text right away, big text off the main thread.
    func restyleAll(_ storage: NSTextStorage) {
        self.attached = storage
        guard self.isEnabled else {
            self.resetAttributes(in: storage, range: NSRange(location: 0, length: storage.length))
            return
        }
        if storage.length > Self.offMainThreshold {
            self.scheduleFull(storage, delay: .zero)
            self.styleParagraphAlone(storage, around: NSRange(location: 0, length: min(storage.length, Self.quickParagraphLimit)))
        } else {
            self.restyleAllNow(storage)
        }
    }

    /// Tokenizes and styles everything synchronously; for small text and tests.
    func restyleAllNow(_ storage: NSTextStorage) {
        self.generation += 1
        guard self.isEnabled else { return }
        let text = storage.string as NSString
        let index = ComposerMarkdownIndex(text: text)
        self.index = index
        let full = NSRange(location: 0, length: text.length)
        self.resetAttributes(in: storage, range: full)
        self.apply(index.spans(in: text, range: full), offset: 0, to: storage)
    }

    private func scheduleFull(_ storage: NSTextStorage, delay: Duration) {
        self.generation += 1
        self.index = nil
        let generation = self.generation
        let snapshot = String(storage.string)
        Task.detached(priority: .userInitiated) { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard await self?.isCurrent(generation) == true else { return }
            }
            let text = snapshot as NSString
            let index = ComposerMarkdownIndex(text: text)
            let spans = index.spans(in: text, range: NSRange(location: 0, length: text.length))
            await self?.finishFull(generation: generation, length: text.length, index: index, spans: spans)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    private func finishFull(generation: Int, length: Int, index: ComposerMarkdownIndex, spans: [ComposerMarkdownSpan]) {
        guard generation == self.generation, self.isEnabled, let storage = self.attached, storage.length == length else { return }
        if self.hasMarkedText() {
            self.needsFullAfterMarkedText = true
            return
        }
        self.index = index
        storage.beginEditing()
        self.resetAttributes(in: storage, range: NSRange(location: 0, length: length))
        self.apply(spans, offset: 0, to: storage)
        storage.endEditing()
        self.onRestyled()
    }

    /// Restyles whatever composition deferred; call once marked text commits.
    func flushDeferred(_ storage: NSTextStorage) {
        guard self.isEnabled, !self.hasMarkedText() else { return }
        if self.needsFullAfterMarkedText {
            self.needsFullAfterMarkedText = false
            self.deferredRange = nil
            self.restyleAll(storage)
            return
        }
        guard let deferred = self.deferredRange else { return }
        self.deferredRange = nil
        guard self.index != nil else { return }
        let range = Self.clamp(deferred, to: storage.length)
        self.style(range: range, in: storage)
    }

    // MARK: Incremental styling

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: MarkdownEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            _ = self.restyle(storage, editedRange: editedRange, changeInLength: delta)
        }
    }

    /// Restyles the paragraph(s) an edit touched and returns the range it restyled (empty when styling is off,
    /// deferred for composition, or handed to the background path).
    @discardableResult
    func restyle(_ storage: NSTextStorage, editedRange: NSRange, changeInLength: Int) -> NSRange {
        guard self.isEnabled else { return NSRange(location: editedRange.location, length: 0) }
        let text = storage.string as NSString
        if editedRange.length > Self.offMainThreshold || (self.index == nil && text.length > Self.offMainThreshold) {
            self.scheduleFull(storage, delay: editedRange.length > Self.offMainThreshold ? .zero : .milliseconds(120))
            return self.styleParagraphAlone(storage, around: editedRange)
        }
        if self.index == nil {
            self.generation += 1
            self.index = ComposerMarkdownIndex(text: text)
            let full = NSRange(location: 0, length: text.length)
            self.style(range: full, in: storage)
            return full
        }
        if editedRange.location == 0, editedRange.length == text.length, text.length > 1, !self.hasMarkedText() {
            // Text set wholesale (draft restore, chat switch): cheaper and safer to re-tokenize than to patch.
            self.restyleAllNow(storage)
            return editedRange
        }
        guard let range = self.index?.update(text: text, editedRange: editedRange, changeInLength: changeInLength) else {
            return NSRange(location: editedRange.location, length: 0)
        }
        let clamped = Self.clamp(range, to: text.length)
        if self.hasMarkedText() {
            self.deferredRange = self.deferredRange.map { $0.union(clamped) } ?? clamped
            return NSRange(location: clamped.location, length: 0)
        }
        self.style(range: clamped, in: storage)
        return clamped
    }

    /// The live index when it matches `text`; otherwise a one-shot tokenize, so code-context rules hold with styling
    /// off or while an off-main restyle is pending. Per paste/shortcut only, never per keystroke.
    private func freshIndex(for text: NSString) -> ComposerMarkdownIndex {
        if self.isEnabled, let index = self.index { return index }
        return ComposerMarkdownIndex(text: text)
    }

    func isInsideCodeBlock(_ location: Int, in text: NSString) -> Bool {
        self.freshIndex(for: text).isInsideCodeBlock(location)
    }

    /// Whether a format command would only mangle the Markdown at `selection`: inside a code block, a code span
    /// (except ⌘E, which unwraps it) or a link's URL (except ⌘K, which unwraps the link).
    func blocks(_ action: ComposerFormatAction, selection: NSRange, in text: NSString) -> Bool {
        guard selection.location <= text.length else { return false }
        let index = self.freshIndex(for: text)
        let paragraph = ComposerMarkdown.paragraphRange(in: text, covering: selection)
        func contains(_ range: NSRange) -> Bool {
            selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range)
        }
        for span in index.spans(in: text, range: paragraph) {
            switch span.kind {
            case .codeBlock, .codeFence: if contains(span.range) { return true }
            case .inlineCode: if action != .code, contains(span.range) { return true }
            case .link: if action != .link, span.markerRanges.count > 2, contains(span.markerRanges[2]) { return true }
            default: break
            }
        }
        return false
    }

    private func style(range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0, let index = self.index else { return }
        let text = storage.string as NSString
        self.resetAttributes(in: storage, range: range)
        self.apply(index.spans(in: text, range: range), offset: 0, to: storage)
    }

    /// Styles one paragraph on its own (no document fence state) while the full tokenize is in flight.
    @discardableResult
    private func styleParagraphAlone(_ storage: NSTextStorage, around edited: NSRange) -> NSRange {
        let text = storage.string as NSString
        let location = min(edited.location, text.length)
        let paragraph = ComposerMarkdown.paragraphRange(in: text, covering: NSRange(location: location, length: min(edited.length, text.length - location)))
        guard paragraph.length > 0, paragraph.length <= Self.quickParagraphLimit, !self.hasMarkedText() else {
            return NSRange(location: paragraph.location, length: 0)
        }
        let slice = text.substring(with: paragraph) as NSString
        let index = ComposerMarkdownIndex(text: slice)
        self.resetAttributes(in: storage, range: paragraph)
        self.apply(index.spans(in: slice, range: NSRange(location: 0, length: slice.length)), offset: paragraph.location, to: storage)
        return paragraph
    }

    private func resetAttributes(in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        storage.setAttributes(self.baseAttributes, range: range)
    }

    // MARK: Span attributes

    private func apply(_ spans: [ComposerMarkdownSpan], offset: Int, to storage: NSTextStorage) {
        let length = storage.length
        func shifted(_ range: NSRange) -> NSRange? {
            let moved = NSRange(location: range.location + offset, length: range.length)
            guard moved.length > 0, moved.location >= 0, NSMaxRange(moved) <= length else { return nil }
            return moved
        }
        for span in spans {
            switch span.kind {
            case .strong: self.addTraits(bold: true, in: shifted(span.contentRange), storage)
            case .emphasis: self.addTraits(italic: true, in: shifted(span.contentRange), storage)
            case .strikethrough:
                if let range = shifted(span.contentRange) {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            case .inlineCode: self.addTraits(mono: true, in: shifted(span.contentRange), storage)
            case .link:
                if let range = shifted(span.contentRange) { storage.addAttribute(.foregroundColor, value: Self.linkColor, range: range) }
            case .heading: self.addTraits(bold: true, in: shifted(span.contentRange), storage)
            case .listItem, .blockquote: break
            case .codeFence: self.addTraits(mono: true, in: shifted(span.range), storage)
            case .codeBlock: self.addTraits(mono: true, in: shifted(span.range), storage)
            }
            for marker in span.markerRanges {
                if let range = shifted(marker) { storage.addAttribute(.foregroundColor, value: Self.dimColor, range: range) }
            }
        }
    }

    private func addTraits(bold: Bool = false, italic: Bool = false, mono: Bool = false, in range: NSRange?, _ storage: NSTextStorage) {
        guard let range else { return }
        var changes: [(NSRange, MarkdownFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? MarkdownFont else { return }
            let current = self.fonts.traits(of: font)
            let updated = self.fonts.font(
                bold: current.bold || bold, italic: current.italic || italic, mono: current.mono || mono)
            if updated != font { changes.append((subrange, updated)) }
        }
        for (subrange, font) in changes { storage.addAttribute(.font, value: font, range: subrange) }
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}

/// Holds NotificationCenter tokens and removes them when released, so owners need no isolated `deinit`.
final class NotificationTokens: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []

    func add(_ token: any NSObjectProtocol) { self.tokens.append(token) }

    deinit {
        for token in self.tokens { NotificationCenter.default.removeObserver(token) }
    }
}
