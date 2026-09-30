import Foundation
import Testing
@testable import PincerKit

/// #409: Read Aloud has a rebindable shortcut that doesn't collide with any other default.
@Suite("Read Aloud controls")
struct ReadAloudControlsTests {
    @Test func readAloudDefaultIsUniqueAmongAllDefaults() throws {
        let combo = try #require(ShortcutCommand.readAloud.defaultCombo)
        let owners = ShortcutCommand.allCases.filter { $0.defaultCombo == combo }
        #expect(owners == [.readAloud], "⌥⌘L is only Read Aloud's default")
    }

    @Test func readAloudAndDictationDefaultsDiffer() {
        #expect(ShortcutCommand.readAloud.defaultCombo != ShortcutCommand.toggleDictation.defaultCombo)
        #expect(ShortcutCommand.readAloud.defaultCombo == KeyCombo("l", [.option, .command]))
    }

    @MainActor @Test func readAloudCanBeRebound() {
        let store = ShortcutStore(defaults: ScratchDefaults().defaults)
        let combo = KeyCombo("y", [.control, .command])
        #expect(store.validate(combo, for: .readAloud) == .ok)
    }

    @Test func gatewaySettingsSearchFindsVoiceForReadAloudQueries() {
        for query in ["voice", "read aloud", "tts", "elevenlabs", "listen"] {
            #expect(SettingsCatalog.destinations(matching: query).map(\.destination).contains(.voice), "\(query)")
        }
        #expect(SettingsCatalog.destinations(matching: "read aloud").first { $0.destination == .voice }?.title == "Voice")
    }
}
