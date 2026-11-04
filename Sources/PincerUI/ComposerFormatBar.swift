import Foundation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A Markdown formatting command in the composer, reachable from shortcuts, the Format menu and the iOS format bar.
enum ComposerFormatAction: CaseIterable {
    case bold, italic, strikethrough, code, link, bulletList, numberedList, quote, heading

    var title: String {
        switch self {
        case .bold: L("Bold")
        case .italic: L("Italic")
        case .strikethrough: L("Strikethrough")
        case .code: L("Code")
        case .link: L("Link")
        case .bulletList: L("Bulleted List")
        case .numberedList: L("Numbered List")
        case .quote: L("Quote")
        case .heading: L("Heading")
        }
    }

    // periphery:ignore - used only by the iOS formatting bar and menu
    var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .heading: "textformat.size"
        }
    }

    /// The shortcut, as a key and modifiers; ⇧⌘8 also makes a bulleted list (`aliases`). ⌘K is the Command
    /// Palette's unless text is selected, so it isn't reserved; the rest are in `ReservedShortcuts.blocked`.
    var shortcut: KeyCombo {
        switch self {
        case .bold: KeyCombo("b", [.command])
        case .italic: KeyCombo("i", [.command])
        case .strikethrough: KeyCombo("x", [.shift, .command])
        case .code: KeyCombo("e", [.command])
        case .link: KeyCombo("k", [.command])
        case .bulletList: KeyCombo("7", [.shift, .command])
        case .numberedList: KeyCombo("9", [.shift, .command])
        case .quote: KeyCombo("'", [.command])
        case .heading: KeyCombo("h", [.shift, .command])
        }
    }

    static let aliases: [(combo: KeyCombo, action: ComposerFormatAction)] = [(KeyCombo("8", [.shift, .command]), .bulletList)]

    /// The action for a key combo, aliases included.
    static func action(for combo: KeyCombo) -> ComposerFormatAction? {
        allCases.first { $0.shortcut == combo } ?? aliases.first { $0.combo == combo }?.action
    }

    #if os(macOS)
    /// The shortcut shown beside the item in the Format menus.
    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        let combo = self.shortcut
        var modifiers: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.command) { modifiers.insert(.command) }
        if combo.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if combo.modifiers.contains(.option) { modifiers.insert(.option) }
        if combo.modifiers.contains(.control) { modifiers.insert(.control) }
        return (combo.key, modifiers)
    }
    #endif

    func edit(in text: NSString, selection: NSRange) -> ComposerEdit {
        switch self {
        case .bold: ComposerFormatting.toggle(.bold, in: text, selection: selection)
        case .italic: ComposerFormatting.toggle(.italic, in: text, selection: selection)
        case .strikethrough: ComposerFormatting.toggle(.strikethrough, in: text, selection: selection)
        case .code: ComposerFormatting.toggle(.inlineCode, in: text, selection: selection)
        case .link: ComposerFormatting.toggleLink(in: text, selection: selection)
        case .bulletList: ComposerFormatting.toggleList(in: text, selection: selection)
        case .numberedList: ComposerFormatting.toggleNumberedList(in: text, selection: selection)
        case .quote: ComposerFormatting.toggleQuote(in: text, selection: selection)
        case .heading: ComposerFormatting.toggleHeading(in: text, selection: selection)
        }
    }
}

#if os(iOS)
/// The optional toolbar above the iOS keyboard (Settings → Composer → Show formatting bar).
@MainActor
enum ComposerFormatBar {
    static func make(perform: @escaping (ComposerFormatAction) -> Void) -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.autoresizingMask = [.flexibleWidth]
        var items: [UIBarButtonItem] = []
        for action in ComposerFormatAction.allCases {
            let item = UIBarButtonItem(
                image: UIImage(systemName: action.symbolName), primaryAction: UIAction(title: action.title) { _ in perform(action) })
            item.accessibilityLabel = action.title
            items.append(item)
            items.append(UIBarButtonItem(systemItem: .flexibleSpace))
        }
        items.removeLast()
        bar.items = items
        return bar
    }
}
#endif

#if os(macOS)
/// The main menu's Format menu. The composer handles these keys itself when it has focus, so the items act on the
/// focused composer (and do nothing elsewhere). Link has no shortcut here: ⌘K is the Command Palette's.
struct ComposerFormatCommands: Commands {
    var body: some Commands {
        CommandMenu(L("Format")) {
            ForEach(ComposerFormatAction.allCases, id: \.self) { action in
                let button = Button(action.title) {
                    (NSApp.keyWindow?.firstResponder as? ComposerNSTextView)?.perform(action)
                }
                if action == .link {
                    button
                } else {
                    button.keyboardShortcut(KeyEquivalent(Character(action.shortcut.key)), modifiers: action.eventModifiers)
                }
                if action == .link { Divider() }
            }
        }
    }
}

extension ComposerFormatAction {
    fileprivate var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if self.shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if self.shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
#endif
