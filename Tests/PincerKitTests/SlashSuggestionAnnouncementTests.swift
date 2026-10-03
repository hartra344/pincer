import Foundation
import Testing
@testable import PincerKit

@Suite("Slash suggestion announcements")
struct SlashSuggestionAnnouncementTests {
    @Test func commandsAndArgumentChoicesSpeakOneSelectedItem() throws {
        let commands = SlashCommand.parse(SlashCommandTests.catalog)
        let command = try #require(SlashCompletion.suggestions(for: "/hel", commands: commands).first)
        #expect(SlashSuggestionAnnouncement.selected(command) == "/help")
        let choices = SlashCompletion.suggestions(for: "/think ", commands: commands)
        #expect(choices.map(SlashSuggestionAnnouncement.selected) == ["low", "High (high)"])
    }

    @Test func countsAreBoundedAndSingularIsGrammatical() {
        #expect(SlashSuggestionAnnouncement.count(-1) == "0 command suggestions")
        #expect(SlashSuggestionAnnouncement.count(1) == "1 command suggestion")
        #expect(SlashSuggestionAnnouncement.count(2) == "2 command suggestions")
        #expect(SlashSuggestionAnnouncement.count(500) == "50 command suggestions")
    }

    @Test func oversizedSelectedMetadataFallsBackWithoutReadingDescriptions() {
        let command = SlashCommand(name: String(repeating: "a", count: 256), description: String(repeating: "x", count: 100_000))
        let suggestion = SlashSuggestion(kind: .command(command), replacement: "")
        #expect(SlashSuggestionAnnouncement.selected(suggestion) == "Command suggestion")
        let arg = SlashCommandArg(name: "value")
        let giant = "a" + String(repeating: "\u{301}", count: 300)
        let choice = SlashCommandChoice(value: giant, label: "Choice")
        #expect(SlashSuggestionAnnouncement.selected(SlashSuggestion(kind: .argument(choice, command: command, arg: arg), replacement: "")) == "Argument suggestion")
    }
}
