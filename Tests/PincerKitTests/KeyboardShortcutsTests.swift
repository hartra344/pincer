import Foundation
import Testing
@testable import PincerKit

/// Issue #428: customizable keyboard shortcuts. Covers `KeyCombo` storage/display, the
/// `ShortcutCommand` registry (titles, defaults, reserved combos) and `ShortcutStore`
/// (persistence, assignment, validation).
@Suite("Keyboard shortcuts")
struct KeyboardShortcutsTests {
    typealias Modifiers = KeyCombo.Modifiers

    // MARK: NSEvent.modifierFlags raw values (see HotKeyShortcut.Modifiers.event)
    static let shiftFlag: UInt = 1 << 17
    static let controlFlag: UInt = 1 << 18
    static let optionFlag: UInt = 1 << 19
    static let commandFlag: UInt = 1 << 20

    // MARK: - KeyCombo storage

    @Test func storageValueRoundTrip() {
        let combos = [
            KeyCombo("k", [.command]),
            KeyCombo("\\", [.option, .command]),
            KeyCombo(KeyCombo.Special.downArrow.rawValue, [.option, .shift]),
            KeyCombo(KeyCombo.Special.f5.rawValue, []),
            KeyCombo(",", [.shift, .command]),
        ]
        for combo in combos {
            let stored = combo.storageValue
            #expect(KeyCombo(storageValue: stored) == combo, "round trip for \(combo)")
        }
    }

    @Test func storageValueRoundTripForColonKey() {
        // The key itself may be ":"; storage splits on the *first* colon, so the key survives.
        let combo = KeyCombo(":", [.command])
        #expect(combo.storageValue == "command::")
        #expect(KeyCombo(storageValue: combo.storageValue) == combo)
    }

    @Test func storageValueRoundTripForSpecialKeys() {
        for special in KeyCombo.Special.allCases {
            let combo = KeyCombo(special.rawValue, [.control, .option])
            #expect(KeyCombo(storageValue: combo.storageValue) == combo, "round trip for \(special)")
        }
    }

    @Test func invalidStorageValuesReturnNil() {
        #expect(KeyCombo(storageValue: "") == nil, "no colon at all")
        #expect(KeyCombo(storageValue: "command") == nil, "no colon at all")
        #expect(KeyCombo(storageValue: "command:") == nil, "empty key")
        #expect(KeyCombo(storageValue: "bogus:k") == nil, "unknown modifier name")
        #expect(KeyCombo(storageValue: "command:notaspecial") == nil, "multi-char key that isn't Special")
        #expect(KeyCombo(storageValue: ":k") != nil, "no modifiers is valid")
    }

    // MARK: - Display

    @Test func displayStrings() {
        #expect(KeyCombo("\\", [.option, .command]).displayString == "⌥⌘\\")
        #expect(KeyCombo(KeyCombo.Special.downArrow.rawValue, [.option, .shift]).displayString == "⌥⇧↓")
        #expect(KeyCombo(KeyCombo.Special.f5.rawValue, []).displayString == "F5")
    }

    // MARK: - Command registry

    @Test func everyCommandHasAUniqueNonEmptyTitle() {
        var titles: [String] = []
        for command in ShortcutCommand.allCases {
            #expect(!command.title.isEmpty, "\(command) has an empty title")
            titles.append(command.title)
        }
        #expect(Set(titles).count == titles.count, "duplicate titles: \(titles)")
    }

    @Test func noTwoDefaultCombosCollide() {
        var seen: [KeyCombo: ShortcutCommand] = [:]
        for command in ShortcutCommand.allCases {
            guard let combo = command.defaultCombo else { continue }
            if let existing = seen[combo] {
                Issue.record("\(combo) is the default for both \(existing) and \(command)")
            }
            seen[combo] = command
        }
    }

    @Test func noDefaultComboIsReserved() {
        let blocked = Set(ReservedShortcuts.blocked.map(\.combo))
        for command in ShortcutCommand.allCases {
            guard let combo = command.defaultCombo else { continue }
            #expect(!blocked.contains(combo), "\(command)'s default \(combo) is reserved")
        }
    }

    @Test func toggleSplitViewDefaultIsOptionCommandBackslash() {
        let combo = ShortcutCommand.toggleSplitView.defaultCombo
        #expect(combo == KeyCombo("\\", [.option, .command]))
        #expect(combo != KeyCombo("\\", [.command]))
        #expect(combo?.displayString == "⌥⌘\\")
        #expect(ShortcutCommand.toggleSplitView.title == "Split Right")
    }

    // MARK: - Store persistence

    @MainActor
    @Test func persistsAcrossInstancesWithTheSameDefaults() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let first = ShortcutStore(defaults: scratch.defaults)
        first.set(KeyCombo("j", [.shift, .command]), for: .newChat)
        #expect(first.isCustomized(.newChat))

        let second = ShortcutStore(defaults: scratch.defaults)
        #expect(second.combo(for: .newChat) == KeyCombo("j", [.shift, .command]))
        #expect(second.isCustomized(.newChat))
    }

    @MainActor
    @Test func clearingPersistsAsAnEmptyStoredValueNotAbsence() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        store.set(nil, for: .newChat)
        #expect(store.combo(for: .newChat) == nil)
        let stored = scratch.defaults.dictionary(forKey: ShortcutStore.overridesKey) as? [String: String]
        #expect(stored?[ShortcutCommand.newChat.rawValue] == "")

        let reloaded = ShortcutStore(defaults: scratch.defaults)
        #expect(reloaded.combo(for: .newChat) == nil)
        #expect(reloaded.isCustomized(.newChat))
    }

    @MainActor
    @Test func resetDropsASingleOverride() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        store.set(KeyCombo("j", [.shift, .command]), for: .newChat)
        store.set(nil, for: .findInChat)
        store.reset(.newChat)

        #expect(!store.isCustomized(.newChat))
        #expect(store.combo(for: .newChat) == ShortcutCommand.newChat.defaultCombo)
        #expect(store.isCustomized(.findInChat), "reset(.newChat) must not touch other overrides")
    }

    @MainActor
    @Test func resetTakesTheDefaultBackFromWhoeverHasIt() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        let newChatDefault = ShortcutCommand.newChat.defaultCombo!
        // Move newChat off its default, then give that default combo to another command.
        store.set(KeyCombo("j", [.shift, .command]), for: .newChat)
        store.assign(newChatDefault, to: .openChatInNewWindow)
        #expect(store.combo(for: .openChatInNewWindow) == newChatDefault)

        store.reset(.newChat)

        #expect(store.combo(for: .newChat) == newChatDefault, "newChat should be back on its default")
        #expect(store.combo(for: .openChatInNewWindow) == nil, "the other command loses the combo it took")
        #expect(store.isCustomized(.openChatInNewWindow), "it's explicitly cleared, not just reverted")
    }

    @MainActor
    @Test func resetAllRemovesTheDefaultsKeyEntirely() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        store.set(KeyCombo("j", [.shift, .command]), for: .newChat)
        store.set(nil, for: .findInChat)
        #expect(scratch.defaults.dictionary(forKey: ShortcutStore.overridesKey) != nil)

        store.resetAll()
        #expect(!store.hasCustomizations)
        #expect(scratch.defaults.dictionary(forKey: ShortcutStore.overridesKey) == nil)

        let reloaded = ShortcutStore(defaults: scratch.defaults)
        #expect(!reloaded.hasCustomizations)
    }

    @MainActor
    @Test func settingTheDefaultComboRemovesTheOverride() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        store.set(KeyCombo("j", [.shift, .command]), for: .newChat)
        #expect(store.isCustomized(.newChat))

        store.set(ShortcutCommand.newChat.defaultCombo, for: .newChat)
        #expect(!store.isCustomized(.newChat), "setting the default combo back should drop the override")
        #expect(scratch.defaults.dictionary(forKey: ShortcutStore.overridesKey) == nil)
    }

    @MainActor
    @Test func assignMovesAComboFromAnotherCommand() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        let combo = ShortcutCommand.commandPalette.defaultCombo!
        #expect(store.combo(for: .commandPalette) == combo)

        store.assign(combo, to: .newChat)

        #expect(store.combo(for: .newChat) == combo)
        #expect(store.combo(for: .commandPalette) == nil, "the previous owner loses it")
        #expect(store.commands(using: combo) == [.newChat])
    }

    @MainActor
    @Test func conflictingReportsCommandsSharingAShortcut() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let store = ShortcutStore(defaults: scratch.defaults)
        #expect(store.conflicting.isEmpty)

        // Force a collision by hand (bypassing assign, which would resolve it).
        store.set(ShortcutCommand.commandPalette.defaultCombo, for: .newChat)
        #expect(store.conflicting == [.newChat, .commandPalette])
    }

    // MARK: - Validation

    @MainActor
    @Test func validateBlocksAComboWithNoModifier() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        guard case .blocked = store.validate(KeyCombo("a", []), for: .newChat) else {
            Issue.record("expected .blocked")
            return
        }
    }

    @MainActor
    @Test func validateBlocksCommandQ() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        guard case .blocked = store.validate(KeyCombo("q", [.command]), for: .newChat) else {
            Issue.record("expected .blocked")
            return
        }
    }

    @MainActor
    @Test func validateBlocksCommand1() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        guard case .blocked = store.validate(KeyCombo("1", [.command]), for: .newChat) else {
            Issue.record("expected .blocked")
            return
        }
    }

    @MainActor
    @Test func validateConflictsOnCommandK() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let combo = KeyCombo("k", [.command])
        #expect(store.combo(for: .commandPalette) == combo)
        guard case .conflict(let owners) = store.validate(combo, for: .newChat) else {
            Issue.record("expected .conflict")
            return
        }
        #expect(owners == [.commandPalette])
    }

    @MainActor
    @Test func validateWarnsOnCommandBackslash() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let combo = KeyCombo("\\", [.command])
        // Split Right's default moved to ⌥⌘\, so plain ⌘\ is free to warn about, not conflict.
        #expect(store.combo(for: .toggleSplitView) != combo)
        guard case .warning(let message) = store.validate(combo, for: .newChat) else {
            Issue.record("expected .warning")
            return
        }
        #expect(message.contains("1Password"))
    }

    @MainActor
    @Test func validateWarnsOnGlobalHotKeyMatch() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let combo = KeyCombo("y", [.option, .command])
        guard case .warning(let message) = store.validate(combo, for: .newChat, globalHotKey: combo.displayString) else {
            Issue.record("expected .warning")
            return
        }
        #expect(message.contains("Quick Capture"))
    }

    @MainActor
    @Test func validateWarnsOnOptionOnlyCombos() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        // A plain letter key: types a character in text fields without ⌘/⌃, so it still warns.
        let combo = KeyCombo("g", [.option])
        guard case .warning = store.validate(combo, for: .newChat) else {
            Issue.record("expected .warning")
            return
        }
    }

    @MainActor
    @Test func validateDoesNotWarnAboutTypingForSpecialKeys() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        // ⌥⇧↓ is nextUnreadChat's own default: an arrow key types nothing, so no "types a
        // character" warning even with no ⌘/⌃, and it isn't a conflict with itself.
        let ownDefault = KeyCombo(KeyCombo.Special.downArrow.rawValue, [.option, .shift])
        #expect(store.validate(ownDefault, for: .nextUnreadChat) == .ok)

        // Same for an unused arrow-key combo recorded for a different command.
        let upOption = KeyCombo(KeyCombo.Special.upArrow.rawValue, [.option])
        #expect(store.validate(upOption, for: .newChat) == .ok)
    }

    @MainActor
    @Test func validateOKForAnUnusedCombo() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let combo = KeyCombo("y", [.control, .command])
        #expect(store.validate(combo, for: .newChat) == .ok)
    }

    @Test func readAloudIsListedInSettings() {
        #expect(ShortcutCommand.unavailable.isEmpty)
        #expect(ShortcutCommand.listed(in: ShortcutCommand.readAloud.category).contains(.readAloud))
    }

    // MARK: - Dictation (#462)

    @Test func toggleDictationDefaultIsShiftCommandD() {
        let command = ShortcutCommand.toggleDictation
        #expect(command.rawValue == "toggleDictation")
        #expect(command.category == .edit)
        #expect(!command.title.isEmpty)
        let combo = command.defaultCombo
        #expect(combo == KeyCombo("d", [.shift, .command]))
        #expect(combo?.displayString == "⇧⌘D")
        #expect(!ReservedShortcuts.blocked.map(\.combo).contains(combo!))
        let others = ShortcutCommand.allCases.filter { $0 != command }.compactMap(\.defaultCombo)
        #expect(!others.contains(combo!))
    }

    @Test func toggleDictationIsListedInSettings() {
        #expect(ShortcutCommand.listed(in: .edit).contains(.toggleDictation))
        #expect(!ShortcutCommand.unavailable.contains(.toggleDictation))
    }

    @MainActor
    @Test func toggleDictationDefaultIsInUseAndValidatesOK() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let combo = ShortcutCommand.toggleDictation.defaultCombo!
        #expect(store.commands(using: combo) == [.toggleDictation])
        #expect(store.validate(combo, for: .toggleDictation) == .ok)
    }

    @MainActor
    @Test func readAloudDefaultIsInUse() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let readAloudDefault = ShortcutCommand.readAloud.defaultCombo!
        #expect(store.commands(using: readAloudDefault) == [.readAloud])
        guard case .conflict(let owners) = store.validate(readAloudDefault, for: .newChat) else {
            Issue.record("⌥⌘L is Read Aloud's shortcut")
            return
        }
        #expect(owners == [.readAloud])
    }

    // MARK: - Recording: macOS key codes

    @Test func macKeyCodeForALetter() {
        let combo = KeyCombo(macKeyCode: 0, unmodifiedCharacters: "a", eventModifierFlags: Self.commandFlag)
        #expect(combo == KeyCombo("a", [.command]))
    }

    @Test func macKeyCodeForUpArrow() {
        let combo = KeyCombo(macKeyCode: 126, unmodifiedCharacters: nil, eventModifierFlags: 0)
        #expect(combo?.special == .upArrow)
    }

    @Test func macKeyCodeForF5() {
        let combo = KeyCombo(macKeyCode: 96, unmodifiedCharacters: nil, eventModifierFlags: Self.optionFlag)
        #expect(combo?.special == .f5)
        #expect(combo?.keyName == "F5")
        #expect(combo?.modifiers == [.option])
    }

    @Test func macKeyCodeForAModifierKeyIsNil() {
        // 54 is right ⌘, one of HotKeyShortcut's modifierKeyCodes.
        let combo = KeyCombo(macKeyCode: 54, unmodifiedCharacters: nil, eventModifierFlags: Self.commandFlag)
        #expect(combo == nil)
    }

    // MARK: - Recording: iPad HID usages

    @Test func hidUsageForA() {
        let combo = KeyCombo(hidUsage: 4, modifiers: [.command])
        #expect(combo == KeyCombo("a", [.command]))
    }

    @Test func hidUsageForBackslash() {
        let combo = KeyCombo(hidUsage: 49, modifiers: [.option, .command])
        #expect(combo == KeyCombo("\\", [.option, .command]))
    }

    @Test func hidUsageForUpArrow() {
        let combo = KeyCombo(hidUsage: 82, modifiers: [.option, .shift])
        #expect(combo?.special == .upArrow)
    }

    @Test func hidUsageForF1() {
        let combo = KeyCombo(hidUsage: 58, modifiers: [])
        #expect(combo?.special == .f1)
    }
}
