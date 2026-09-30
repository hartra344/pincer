import Foundation
import Observation

// MARK: Key combo

/// A menu or in-window key equivalent: one key plus modifiers, like ⌥⌘\ or ⌥⇧↓ (#428).
///
/// `key` is a lowercased character (`"k"`, `"\\"`, `"["`) or one of the `Special` names for keys
/// that don't type a character. Unlike `HotKeyShortcut` (Quick Capture's global hotkey, keyed by
/// virtual key code), this matches what SwiftUI's `KeyEquivalent` and AppKit menus use.
public struct KeyCombo: Hashable, Sendable {
    public typealias Modifiers = HotKeyShortcut.Modifiers

    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers) {
        self.key = Special(rawValue: key) != nil ? key : key.lowercased()
        self.modifiers = modifiers
    }

    /// Keys that type no character, by storage name.
    public enum Special: String, CaseIterable, Sendable {
        case upArrow = "up", downArrow = "down", leftArrow = "left", rightArrow = "right"
        case `return`, tab, space, delete, forwardDelete, escape, home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

        public var symbol: String {
            switch self {
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .return: "↩"
            case .tab: "⇥"
            case .space: "Space"
            case .delete: "⌫"
            case .forwardDelete: "⌦"
            case .escape: "⎋"
            case .home: "↖"
            case .end: "↘"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            default: self.rawValue.uppercased()
            }
        }

        /// 1…20 for F1…F20, else nil.
        public var functionNumber: Int? {
            guard self.rawValue.hasPrefix("f"), let number = Int(self.rawValue.dropFirst()) else { return nil }
            return number
        }

        public static func function(_ number: Int) -> Special? { Special(rawValue: "f\(number)") }
    }

    public var special: Special? { Special(rawValue: self.key) }

    /// The key as menus show it: `K`, `\`, `↓`, `F5`.
    public var keyName: String { self.special?.symbol ?? self.key.uppercased() }

    /// For example `⌥⌘\` or `⌥⇧↓`, in Apple's modifier order.
    public var displayString: String { self.modifiers.symbols + self.keyName }

    public var isFunctionKey: Bool { self.special?.functionNumber != nil }

    // MARK: Storage

    /// `modifiers:key`, e.g. `option,command:\`. Modifier names never contain `:`, so the key is
    /// everything after the first one (which may itself be `:`).
    public var storageValue: String {
        let names = Modifiers.names.filter { self.modifiers.contains($0.0) }.map(\.1)
        return "\(names.joined(separator: ",")):\(self.key)"
    }

    public init?(storageValue: String) {
        guard let colon = storageValue.firstIndex(of: ":") else { return nil }
        let key = String(storageValue[storageValue.index(after: colon)...])
        guard !key.isEmpty, key.count == 1 || Special(rawValue: key) != nil else { return nil }
        var modifiers: Modifiers = []
        for name in storageValue[..<colon].split(separator: ",") {
            guard let modifier = Modifiers.names.first(where: { $0.1 == name })?.0 else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key, modifiers)
    }
}

// MARK: Recording

extension KeyCombo {
    /// macOS virtual key codes of keys that type no character.
    static let macSpecialKeys: [UInt16: Special] = [
        126: .upArrow, 125: .downArrow, 123: .leftArrow, 124: .rightArrow, 36: .return, 76: .return,
        48: .tab, 49: .space, 51: .delete, 117: .forwardDelete, 53: .escape, 115: .home, 119: .end,
        116: .pageUp, 121: .pageDown,
    ]

    /// From a macOS key-down: its `keyCode`, the character it types with no modifiers
    /// (`characters(byApplyingModifiers: [])`) and `modifierFlags.rawValue`. Nil for a key that
    /// can't be a shortcut (a modifier on its own, a dead key).
    public init?(macKeyCode: UInt16, unmodifiedCharacters: String?, eventModifierFlags: UInt) {
        let modifiers = Modifiers(eventModifierFlags: eventModifierFlags)
        if HotKeyShortcut.modifierKeyCodes.contains(UInt32(macKeyCode)) { return nil }
        if let special = Self.macSpecialKeys[macKeyCode] {
            self.init(special.rawValue, modifiers)
        } else if let number = HotKeyShortcut.functionKeys[UInt32(macKeyCode)], let special = Special.function(number) {
            self.init(special.rawValue, modifiers)
        } else if let characters = unmodifiedCharacters, characters.count == 1,
                  let scalar = characters.unicodeScalars.first, scalar.value >= 0x21, scalar.value < 0xF700 {
            self.init(characters, modifiers)
        } else {
            return nil
        }
    }

    /// US-layout characters for HID keyboard usages (`UIKey.keyCode`), for recording on iPad.
    static let hidCharacters: [Int: String] = {
        var map: [Int: String] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[4 + offset] = String(letter) }
        for (offset, digit) in "1234567890".enumerated() { map[30 + offset] = String(digit) }
        let punctuation: [Int: String] = [45: "-", 46: "=", 47: "[", 48: "]", 49: "\\", 51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/"]
        map.merge(punctuation) { $1 }
        return map
    }()

    static let hidSpecialKeys: [Int: Special] = [
        40: .return, 88: .return, 41: .escape, 42: .delete, 43: .tab, 44: .space, 74: .home, 75: .pageUp,
        76: .forwardDelete, 77: .end, 78: .pageDown, 79: .rightArrow, 80: .leftArrow, 81: .downArrow, 82: .upArrow,
    ]

    /// From an iPad hardware key press: its HID usage (`UIKey.keyCode.rawValue`) and modifiers.
    public init?(hidUsage: Int, modifiers: Modifiers) {
        if let special = Self.hidSpecialKeys[hidUsage] {
            self.init(special.rawValue, modifiers)
        } else if (58...69).contains(hidUsage), let special = Special.function(hidUsage - 57) {
            self.init(special.rawValue, modifiers)
        } else if let character = Self.hidCharacters[hidUsage] {
            self.init(character, modifiers)
        } else {
            return nil
        }
    }
}

extension KeyCombo: CustomStringConvertible {
    public var description: String { self.displayString }
}

// MARK: Commands

/// Every Pincer command that has, or can be given, a keyboard shortcut. The raw value is the
/// stable id stored in `ShortcutStore`'s overrides, so never rename a case's raw value.
public enum ShortcutCommand: String, CaseIterable, Sendable, Identifiable {
    // File
    case newChat, openChatInNewWindow, addGateway, exportChat, showBookmarks
    // Edit
    case findInChat, findNext, findPrevious, replyToLastMessage, editLastMessage, regenerateLastReply, readAloud, toggleDictation
    // View
    case toggleSplitView, swapSplitChats, nextUnreadChat, showRuns, reloadPincer
    // Go
    case commandPalette, searchMessages, goBack, goForward, previousMessage, nextMessage
    // Chat and Gateway
    case stopRun, gatewaySettings

    public var id: String { self.rawValue }

    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case file, edit, view, go, chat

        public var id: String { self.rawValue }

        public var title: String {
            switch self {
            case .file: L("File")
            case .edit: L("Edit")
            case .view: L("View")
            case .go: L("Go")
            case .chat: L("Chat and Gateway")
            }
        }
    }

    public var category: Category {
        switch self {
        case .newChat, .openChatInNewWindow, .addGateway, .exportChat, .showBookmarks: .file
        case .findInChat, .findNext, .findPrevious, .replyToLastMessage, .editLastMessage, .regenerateLastReply, .readAloud, .toggleDictation: .edit
        case .toggleSplitView, .swapSplitChats, .nextUnreadChat, .showRuns, .reloadPincer: .view
        case .commandPalette, .searchMessages, .goBack, .goForward, .previousMessage, .nextMessage: .go
        case .stopRun, .gatewaySettings: .chat
        }
    }

    /// The name shown in Settings → Shortcuts, matching the menu item where there is one.
    public var title: String {
        switch self {
        case .newChat: L("New Chat")
        case .openChatInNewWindow: L("Open Chat in New Window")
        case .addGateway: L("Add Gateway…")
        case .exportChat: L("Export Chat…")
        case .showBookmarks: L("Bookmarks…")
        case .findInChat: L("Find in Chat…")
        case .findNext: L("Find Next")
        case .findPrevious: L("Find Previous")
        case .replyToLastMessage: L("Reply to Last Message")
        case .editLastMessage: L("Edit Last Message")
        case .regenerateLastReply: L("Regenerate Last Reply")
        case .readAloud: L("Read Last Reply Aloud")
        case .toggleDictation: L("Dictate Message")
        case .toggleSplitView: L("Split Right")
        case .swapSplitChats: L("Swap Chats")
        case .nextUnreadChat: L("Next Unread Chat")
        case .showRuns: L("Show Runs")
        case .reloadPincer: L("Reload Pincer")
        case .commandPalette: L("Command Palette…")
        case .searchMessages: L("Search Messages…")
        case .goBack: L("Back")
        case .goForward: L("Forward")
        case .previousMessage: L("Previous Message")
        case .nextMessage: L("Next Message")
        case .stopRun: L("Stop the Current Run")
        case .gatewaySettings: L("Gateway Settings…")
        }
    }

    /// Split Right moved off ⌘\, which 1Password (and other password managers) use to fill (#428).
    /// ⌥⌘\ keeps the backslash "divider" mnemonic and sits with Pincer's other ⌥⌘ window
    /// commands (⌥⌘N, ⌥⌘R), away from the ⌃⌘ family macOS uses system-wide.
    public var defaultCombo: KeyCombo? {
        switch self {
        case .newChat: KeyCombo("n", [.command])
        case .openChatInNewWindow: KeyCombo("n", [.option, .command])
        case .exportChat: KeyCombo("e", [.shift, .command])
        case .findInChat: KeyCombo("f", [.command])
        case .findNext: KeyCombo("g", [.command])
        case .findPrevious: KeyCombo("g", [.shift, .command])
        case .replyToLastMessage: KeyCombo("r", [.shift, .command])
        case .readAloud: KeyCombo("l", [.option, .command])
        case .toggleDictation: KeyCombo("d", [.shift, .command])
        case .toggleSplitView: KeyCombo("\\", [.option, .command])
        case .nextUnreadChat: KeyCombo(KeyCombo.Special.downArrow.rawValue, [.option, .shift])
        case .showRuns: KeyCombo("r", [.option, .command])
        case .reloadPincer: KeyCombo("r", [.command])
        case .commandPalette: KeyCombo("k", [.command])
        case .searchMessages: KeyCombo("f", [.shift, .command])
        case .goBack: KeyCombo("[", [.command])
        case .goForward: KeyCombo("]", [.command])
        case .previousMessage: KeyCombo(KeyCombo.Special.upArrow.rawValue, [.option, .command])
        case .nextMessage: KeyCombo(KeyCombo.Special.downArrow.rawValue, [.option, .command])
        case .stopRun: KeyCombo(".", [.command])
        case .gatewaySettings: KeyCombo(",", [.shift, .command])
        case .addGateway, .showBookmarks, .editLastMessage, .regenerateLastReply, .swapSplitChats: nil
        }
    }

    /// Commands with no menu item or button in this build, hidden from Settings.
    public static let unavailable: Set<ShortcutCommand> = []

    /// Listed in Settings, in menu order within each category.
    public static func listed(in category: Category) -> [ShortcutCommand] {
        self.allCases.filter { $0.category == category && !self.unavailable.contains($0) }
    }
}

// MARK: Validation

/// What happens when a combo is recorded for a command.
public enum ShortcutValidation: Equatable, Sendable {
    /// Fine to use.
    case ok
    /// Can't be used; the reason is shown under the recorder.
    case blocked(String)
    /// Usable, but something else may catch it first or lose it; asks before saving.
    case warning(String)
    /// Already used by these Pincer commands; asks before moving it.
    case conflict([ShortcutCommand])
}

/// Shortcuts Pincer can't give to a command: macOS takes them before the app sees them, or they
/// belong to standard menu items (Quit, Copy, Settings…) and Pincer's fixed ones (⌘1–⌘9).
public enum ReservedShortcuts {
    public struct Entry: Sendable {
        public let combo: KeyCombo
        public let owner: String
    }

    static func combo(_ key: String, _ modifiers: KeyCombo.Modifiers) -> KeyCombo { KeyCombo(key, modifiers) }

    /// Blocked outright.
    public static var blocked: [Entry] {
        var entries: [Entry] = [
            // macOS
            Entry(combo: combo("space", [.command]), owner: L("Spotlight")),
            Entry(combo: combo("space", [.control]), owner: L("macOS input sources")),
            Entry(combo: combo("space", [.control, .option]), owner: L("macOS input sources")),
            Entry(combo: combo("space", [.option, .command]), owner: L("Finder search")),
            Entry(combo: combo("space", [.control, .command]), owner: L("Emoji & Symbols")),
            Entry(combo: combo("tab", [.command]), owner: L("the app switcher")),
            Entry(combo: combo("tab", [.shift, .command]), owner: L("the app switcher")),
            Entry(combo: combo("`", [.command]), owner: L("macOS window cycling")),
            Entry(combo: combo("escape", [.option, .command]), owner: L("Force Quit")),
            Entry(combo: combo("q", [.control, .command]), owner: L("Lock Screen")),
            Entry(combo: combo("f", [.control, .command]), owner: L("Enter Full Screen")),
            Entry(combo: combo("3", [.shift, .command]), owner: L("Screenshot")),
            Entry(combo: combo("4", [.shift, .command]), owner: L("Screenshot")),
            Entry(combo: combo("5", [.shift, .command]), owner: L("Screenshot")),
            // Standard menu items
            Entry(combo: combo("q", [.command]), owner: L("Quit Pincer")),
            Entry(combo: combo("w", [.command]), owner: L("Close Window")),
            Entry(combo: combo("h", [.command]), owner: L("Hide Pincer")),
            Entry(combo: combo("h", [.option, .command]), owner: L("Hide Others")),
            Entry(combo: combo("m", [.command]), owner: L("Minimize")),
            Entry(combo: combo(",", [.command]), owner: L("Settings")),
            Entry(combo: combo("s", [.command]), owner: L("Save")),
            Entry(combo: combo("z", [.command]), owner: L("Undo")),
            Entry(combo: combo("z", [.shift, .command]), owner: L("Redo")),
            Entry(combo: combo("x", [.command]), owner: L("Cut")),
            Entry(combo: combo("c", [.command]), owner: L("Copy")),
            Entry(combo: combo("v", [.command]), owner: L("Paste")),
            Entry(combo: combo("a", [.command]), owner: L("Select All")),
            Entry(combo: combo("/", [.shift, .command]), owner: L("Help")),
        ]
        for number in 1...9 {
            entries.append(Entry(combo: combo("\(number)", [.command]), owner: L("Open Pinned Chat \(number)")))
        }
        return entries
    }

    /// Allowed, with a warning: other apps commonly use these system-wide.
    public static var wellKnown: [Entry] {
        [
            Entry(combo: combo("\\", [.command]), owner: L("1Password (fill)")),
            Entry(combo: combo("space", [.shift, .command]), owner: L("1Password Quick Access")),
            Entry(combo: combo("up", [.control]), owner: L("Mission Control")),
            Entry(combo: combo("down", [.control]), owner: L("App Exposé")),
            Entry(combo: combo("left", [.control]), owner: L("Mission Control (move a Space)")),
            Entry(combo: combo("right", [.control]), owner: L("Mission Control (move a Space)")),
            Entry(combo: combo("d", [.option, .command]), owner: L("Dock hiding")),
            Entry(combo: combo("d", [.control, .command]), owner: L("Look Up")),
            Entry(combo: combo("t", [.command]), owner: L("Show Fonts")),
            Entry(combo: combo("p", [.command]), owner: L("Print")),
        ]
    }
}

// MARK: Store

/// Pincer's keyboard shortcuts: each command's default, with the user's changes from Settings →
/// Shortcuts on top (#428). Menus and buttons read `combo(for:)` in their bodies, so a change
/// shows up everywhere at once.
@MainActor
@Observable
public final class ShortcutStore {
    public static let shared = ShortcutStore()

    /// `[commandId: storageValue]`; an empty value means the user cleared the shortcut.
    public static let overridesKey = "pincer.shortcuts.overrides"

    @ObservationIgnored private let defaults: UserDefaults
    /// Only commands the user changed: `.some(nil)` is cleared, `.some(combo)` a new one.
    public private(set) var overrides: [ShortcutCommand: KeyCombo?]
    /// True while a recorder is listening, so the combo being typed doesn't also run a command.
    public var isRecording = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
        var overrides: [ShortcutCommand: KeyCombo?] = [:]
        for (id, value) in stored {
            guard let command = ShortcutCommand(rawValue: id) else { continue }
            if value.isEmpty {
                overrides[command] = .some(nil)
            } else if let combo = KeyCombo(storageValue: value) {
                overrides[command] = .some(combo)
            }
        }
        self.overrides = overrides
    }

    /// The command's shortcut: the user's, else the default. Nil when it has none.
    public func combo(for command: ShortcutCommand) -> KeyCombo? {
        if let override = self.overrides[command] { return override }
        return command.defaultCombo
    }

    /// What a menu or button should bind right now: nothing while a recorder is listening.
    public func activeCombo(for command: ShortcutCommand) -> KeyCombo? {
        self.isRecording ? nil : self.combo(for: command)
    }

    public func isCustomized(_ command: ShortcutCommand) -> Bool { self.overrides[command] != nil }

    public var hasCustomizations: Bool { !self.overrides.isEmpty }

    /// Sets the command's shortcut; nil clears it. Setting the default drops the override.
    public func set(_ combo: KeyCombo?, for command: ShortcutCommand) {
        if combo == command.defaultCombo {
            self.overrides[command] = nil
        } else {
            self.overrides[command] = .some(combo)
        }
        self.save()
    }

    /// Gives `combo` to `command`, clearing it from any other command that had it.
    public func assign(_ combo: KeyCombo, to command: ShortcutCommand) {
        for other in self.commands(using: combo) where other != command {
            self.set(nil, for: other)
        }
        self.set(combo, for: command)
    }

    /// Back to the default, taking it from any command the user had given it to.
    public func reset(_ command: ShortcutCommand) {
        if let combo = command.defaultCombo {
            for other in self.commands(using: combo) where other != command { self.overrides[other] = .some(nil) }
        }
        self.overrides[command] = nil
        self.save()
    }

    public func resetAll() {
        self.overrides = [:]
        self.save()
    }

    /// Commands in this build currently bound to `combo`.
    public func commands(using combo: KeyCombo) -> [ShortcutCommand] {
        ShortcutCommand.allCases.filter { !ShortcutCommand.unavailable.contains($0) && self.combo(for: $0) == combo }
    }

    /// Commands that share a shortcut with another command, e.g. after a reset brings a default
    /// back that the user had given to something else.
    public var conflicting: Set<ShortcutCommand> {
        var seen: [KeyCombo: [ShortcutCommand]] = [:]
        for command in ShortcutCommand.allCases where !ShortcutCommand.unavailable.contains(command) {
            if let combo = self.combo(for: command) { seen[combo, default: []].append(command) }
        }
        return Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Whether `combo` can go to `command`. `globalHotKey` is Quick Capture's system-wide
    /// shortcut, if on, as its display string.
    public func validate(_ combo: KeyCombo, for command: ShortcutCommand, globalHotKey: String? = nil) -> ShortcutValidation {
        if combo.modifiers.isDisjoint(with: [.command, .control, .option]), !combo.isFunctionKey {
            return .blocked(L("Use at least one of ⌘, ⌃ or ⌥."))
        }
        if let reserved = ReservedShortcuts.blocked.first(where: { $0.combo == combo }) {
            return .blocked(L("\(combo.displayString) is used by \(reserved.owner)."))
        }
        let others = self.commands(using: combo).filter { $0 != command }
        if !others.isEmpty { return .conflict(others) }
        if let globalHotKey, globalHotKey == combo.displayString {
            return .warning(L("\(combo.displayString) is your Quick Capture shortcut, which works from any app and runs first."))
        }
        if let known = ReservedShortcuts.wellKnown.first(where: { $0.combo == combo }) {
            return .warning(L("\(combo.displayString) is often used by \(known.owner). If that app is running, it may get the keys first."))
        }
        if combo.modifiers.isDisjoint(with: [.command, .control]), combo.special == nil {
            return .warning(L("\(combo.displayString) types a character in text fields. Pincer will run the command instead."))
        }
        return .ok
    }

    private func save() {
        if self.overrides.isEmpty {
            self.defaults.removeObject(forKey: Self.overridesKey)
            return
        }
        var stored: [String: String] = [:]
        for (command, combo) in self.overrides {
            stored[command.rawValue] = combo?.storageValue ?? ""
        }
        self.defaults.set(stored, forKey: Self.overridesKey)
    }
}

/// What Esc does in the composer, most specific first: menus, dictation, the reply/edit chip, then Read Aloud.
public enum ComposerEscapeAction: Equatable, Sendable {
    case dismissMenu, finishDictation, cancelEdit, cancelReply, stopReadAloud

    public static func resolve(menuOpen: Bool, dictating: Bool, editing: Bool, replying: Bool, readingAloud: Bool) -> Self? {
        if menuOpen { return .dismissMenu }
        if dictating { return .finishDictation }
        if editing { return .cancelEdit }
        if replying { return .cancelReply }
        return readingAloud ? .stopReadAloud : nil
    }
}
