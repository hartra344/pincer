import PincerKit
import SwiftUI

extension KeyCombo {
    /// The SwiftUI shortcut menus and buttons bind.
    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(self.keyEquivalent, modifiers: self.eventModifiers)
    }

    var keyEquivalent: KeyEquivalent {
        guard let special else { return KeyEquivalent(Character(self.key)) }
        switch special {
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .return: return .return
        case .tab: return .tab
        case .space: return .space
        case .delete: return .delete
        case .forwardDelete: return .deleteForward
        case .escape: return .escape
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        default:
            // NSF1FunctionKey is U+F704; F1…F20 are consecutive.
            let number = special.functionNumber ?? 1
            return KeyEquivalent(Character(UnicodeScalar(0xF704 + UInt32(number - 1))!))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if self.modifiers.contains(.command) { result.insert(.command) }
        if self.modifiers.contains(.option) { result.insert(.option) }
        if self.modifiers.contains(.control) { result.insert(.control) }
        if self.modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

extension View {
    /// Binds the command's current shortcut from Settings → Shortcuts (#428), or none if the user
    /// cleared it. Reading the store in the caller's body keeps menus and buttons live.
    @MainActor
    func shortcut(_ command: ShortcutCommand) -> some View {
        self.keyboardShortcut(ShortcutStore.shared.activeCombo(for: command)?.keyboardShortcut)
    }
}

extension ShortcutCommand {
    /// The shortcut as menus show it (`⌥⌘\`), for the command palette; nil when there is none.
    @MainActor var displayShortcut: String? { ShortcutStore.shared.combo(for: self)?.displayString }
}
