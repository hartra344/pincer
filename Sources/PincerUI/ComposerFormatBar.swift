import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A Markdown formatting command in the composer, reachable from shortcuts, the Format menu and the iOS format bar.
enum ComposerFormatAction: CaseIterable {
    case bold, italic, strikethrough, code, link, bulletList

    var title: String {
        switch self {
        case .bold: L("Bold")
        case .italic: L("Italic")
        case .strikethrough: L("Strikethrough")
        case .code: L("Code")
        case .link: L("Link")
        case .bulletList: L("Bulleted List")
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
        }
    }

    #if os(macOS)
    /// The shortcut shown beside the item in the Format menu.
    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .bold: ("b", .command)
        case .italic: ("i", .command)
        case .strikethrough: ("x", [.command, .shift])
        case .code: ("e", .command)
        case .link: ("k", .command)
        case .bulletList: ("7", [.command, .shift])
        }
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
