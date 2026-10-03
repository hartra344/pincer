#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
private struct SlashMenuAnnouncementFixture {
    @MainActor
    private final class Host {
        let scratch = ScratchDefaults()
        let app: AppModel
        let gateway: GatewayStore
        let chat: ChatStore
        let controller: UIHostingController<AnyView>
        let window: UIWindow

        init(text: String = "/") {
            self.app = AppModel(defaults: self.scratch.defaults)
            self.gateway = GatewayStore(
                profile: GatewayProfile(id: UUID(), name: "Slash keyboard fixture", url: "ws://127.0.0.1:1", authMode: .none),
                defaults: self.scratch.defaults, identity: UIFixtures.identity())
            self.gateway.cacheRoot = nil
            self.chat = ChatStore(sessionKey: "agent:main:slash-announcement", agentId: "main", gateway: self.gateway, headless: true)
            self.chat.draft.text = text
            let app = self.app
            let gateway = self.gateway
            let chat = self.chat
            let defaults = self.scratch.defaults
            self.controller = UIHostingController(rootView: AnyView(
                VStack {
                    Spacer()
                    Composer(chat: chat, placeholder: "Message")
                }
                .environment(app)
                .environment(gateway)
                .defaultAppStorage(defaults)))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                self.window = UIWindow(windowScene: scene)
                self.window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
            } else {
                self.window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 800))
            }
            self.window.rootViewController = self.controller
            self.window.makeKeyAndVisible()
            self.controller.loadViewIfNeeded()
            self.controller.view.frame = self.window.bounds
            self.controller.view.setNeedsLayout()
            self.controller.view.layoutIfNeeded()
        }

        private func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(self.descendants)
        }

        func field() async throws -> ComposerUITextView {
            var found: ComposerUITextView?
            try await self.wait {
                found = self.descendants(self.controller.view).compactMap { $0 as? ComposerUITextView }.first
                return found?.menuActive == true && found?.text == self.chat.draft.text
            }
            let field = try #require(found)
            try #require(field.becomeFirstResponder())
            try #require(field.isFirstResponder)
            return field
        }

        /// Readiness follows native view state. The deadline only bounds fixture failure.
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < deadline, "The real hosted composer did not become ready")
                self.controller.view.setNeedsLayout()
                self.controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func command(_ input: String, in field: ComposerUITextView) throws -> UIKeyCommand {
            try #require(field.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
        }

        func key(_ input: String, in field: ComposerUITextView) throws {
            let command = try self.command(input, in: field)
            let action = try #require(command.action)
            try #require(field.canPerformAction(action, withSender: command))
            try #require(field.responds(to: action))
            _ = field.perform(action, with: command)
        }

        func stop() {
            self.window.endEditing(true)
            self.window.isHidden = true
            self.window.rootViewController = nil
            self.gateway.stop()
            self.scratch.remove()
        }
    }

    func actualUIKitArrowAnnouncesTheSuggestionItSelectsWithoutMovingComposerFocus() async throws {
        let host = Host()
        defer { host.stop() }
        let field = try await host.field()
        let suggestions = SlashCompletion.suggestions(for: "/", commands: host.gateway.slashCommands(for: host.chat.sessionKey))
        try #require(suggestions.count >= 2)
        guard case let .command(second) = suggestions[1].kind else {
            Issue.record("The real fallback catalog must offer command suggestions")
            return
        }
        let spoken = "/\(second.name)"
        let control = "Slash announcement posting control"
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: [control, spoken])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        AccessibilityAnnouncer.announce(control)
        #expect(probe.posts == [control], "A direct real announcer call proves posting instrumentation is active")
        try host.key(UIKeyCommand.inputDownArrow, in: field)
        try host.key("\t", in: field)
        try await host.wait { host.chat.draft.text == suggestions[1].replacement && field.text == suggestions[1].replacement }
        #expect(host.chat.draft.text == suggestions[1].replacement, "Tab proves the actual Composer selected the second suggestion")
        #expect(field.isFirstResponder, "Announcement must retain the composer's keyboard focus")
        #expect(probe.posts == [control, spoken], "Actual native Down must announce the selected command")
    }

    func actualHostedQueryChangeAnnouncesItsResultCount() async throws {
        let host = Host()
        defer { host.stop() }
        let field = try await host.field()
        let query = "/help"
        let suggestions = SlashCompletion.suggestions(for: query, commands: host.gateway.slashCommands(for: host.chat.sessionKey))
        try #require(!suggestions.isEmpty)
        let spoken = suggestions.count == 1 ? "1 command suggestion" : "\(suggestions.count) command suggestions"
        let control = "Slash query posting control"
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: [control, spoken])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        AccessibilityAnnouncer.announce(control)
        #expect(probe.posts == [control])
        host.chat.draft.text = query
        try await host.wait { field.text == query && field.menuActive }
        try host.key("\t", in: field)
        try await host.wait { host.chat.draft.text == suggestions[0].replacement && field.text == suggestions[0].replacement }
        #expect(host.chat.draft.text == suggestions[0].replacement, "Actual Tab accepts the new query's first result")
        #expect(field.isFirstResponder)
        #expect(probe.posts == [control, spoken], "The actual query change must announce its result count")
    }

    func changedQueriesWithEqualCountsAndZeroResultsAreAnnounced() async throws {
        let host = Host()
        defer { host.stop() }
        let field = try await host.field()
        let commands = host.gateway.slashCommands(for: host.chat.sessionKey)
        let queries = ["/help", "/status", "/zzzz_no_matching_command"]
        let counts = queries.map { SlashCompletion.suggestions(for: $0, commands: commands).count }
        try #require(counts == [1, 1, 0], "Use real catalog queries with equal counts and an empty result")
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: ["1 command suggestion", "0 command suggestions"])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        var expected: [String] = []
        for (index, query) in queries.enumerated() {
            host.chat.draft.text = query
            expected.append(counts[index] == 1 ? "1 command suggestion" : "0 command suggestions")
            try await host.wait { field.text == query && field.menuActive == (counts[index] > 0) && probe.posts == expected }
            #expect(probe.posts == expected, "A changed query announces its actual count even when the count stayed equal")
            #expect(field.isFirstResponder)
        }
        host.chat.draft.text = queries[2]
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()
        #expect(probe.posts == expected, "Unchanged query/layout cannot repeat the count announcement")
    }

    func nativeArrowsWrapAndSpeakExactlyEachChangedCommand() async throws {
        let host = Host()
        defer { host.stop() }
        let field = try await host.field()
        let suggestions = SlashCompletion.suggestions(for: "/", commands: host.gateway.slashCommands(for: host.chat.sessionKey))
        try #require(suggestions.count > 2)
        func label(_ suggestion: SlashSuggestion) throws -> String {
            guard case let .command(command) = suggestion.kind else { throw CocoaError(.coderReadCorrupt) }
            return "/\(command.name)"
        }
        let first = try label(suggestions[0])
        let second = try label(suggestions[1])
        let last = try label(try #require(suggestions.last))
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: [first, second, last])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        try host.key(UIKeyCommand.inputUpArrow, in: field)
        try host.key(UIKeyCommand.inputDownArrow, in: field)
        try host.key(UIKeyCommand.inputDownArrow, in: field)
        try host.key(UIKeyCommand.inputUpArrow, in: field)
        try host.key("\t", in: field)
        try await host.wait { host.chat.draft.text == suggestions[0].replacement && field.text == suggestions[0].replacement }
        #expect(probe.posts == [last, first, second, first])
        #expect(field.isFirstResponder)
    }

    func singleResultDoesNotSpeakUnchangedSelections() async throws {
        let host = Host(text: "/help")
        defer { host.stop() }
        let field = try await host.field()
        let suggestions = SlashCompletion.suggestions(for: "/help", commands: host.gateway.slashCommands(for: host.chat.sessionKey))
        try #require(suggestions.count == 1)
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: ["/help"])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        try host.key(UIKeyCommand.inputDownArrow, in: field)
        try host.key(UIKeyCommand.inputUpArrow, in: field)
        try host.key("\t", in: field)
        #expect(host.chat.draft.text == suggestions[0].replacement)
        #expect(probe.posts.isEmpty)
        #expect(field.isFirstResponder)
    }

    func nativeArrowStillSelectsWhileVoiceOverIsOff() async throws {
        let host = Host()
        defer { host.stop() }
        let field = try await host.field()
        let suggestions = SlashCompletion.suggestions(for: "/", commands: host.gateway.slashCommands(for: host.chat.sessionKey))
        try #require(suggestions.count >= 2)
        guard case let .command(second) = suggestions[1].kind else { throw CocoaError(.coderReadCorrupt) }
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: ["/\(second.name)"], voiceOverEnabled: false)
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        try host.key(UIKeyCommand.inputDownArrow, in: field)
        try host.key("\t", in: field)
        try await host.wait { host.chat.draft.text == suggestions[1].replacement && field.text == suggestions[1].replacement }
        #expect(probe.posts.isEmpty)
        #expect(field.isFirstResponder)
    }

    func argumentArrowAnnouncesTheActualChoiceAndTabKeepsItsReplacement() async throws {
        let host = Host(text: "/think ")
        defer { host.stop() }
        let field = try await host.field()
        let levels = [SlashCommandChoice(value: "default")] + SlashCommand.fallbackThinkingLevels.map { SlashCommandChoice(value: $0) }.filter { $0.value != "default" }
        let suggestions = SlashCompletion.suggestions(for: "/think ", commands: host.gateway.slashCommands(for: host.chat.sessionKey), choices: { _, _, _ in levels })
        try #require(suggestions.count >= 2)
        guard case let .argument(choice, _, _) = suggestions[1].kind else { throw CocoaError(.coderReadCorrupt) }
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: [choice.label])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        try host.key(UIKeyCommand.inputDownArrow, in: field)
        try host.key("\t", in: field)
        try await host.wait { host.chat.draft.text == suggestions[1].replacement && field.text == suggestions[1].replacement }
        #expect(probe.posts == [choice.label])
        #expect(field.isFirstResponder)
    }

    func returnAndEscapeKeepExistingAcceptanceAndDismissalBehavior() async throws {
        let host = Host(text: "/hel")
        defer { host.stop() }
        let field = try await host.field()
        let suggestions = SlashCompletion.suggestions(for: "/hel", commands: host.gateway.slashCommands(for: host.chat.sessionKey))
        let first = try #require(suggestions.first)
        try host.key("\r", in: field)
        try await host.wait { host.chat.draft.text == first.replacement && field.text == first.replacement }
        #expect(host.chat.unsentEntries.isEmpty, "Return accepts the incomplete command instead of sending it")
        try host.key(UIKeyCommand.inputEscape, in: field)
        try await host.wait { !field.menuActive }
        #expect(host.chat.draft.text == first.replacement)
        #expect(field.isFirstResponder)
        host.chat.draft.text = "/hel"
        try await host.wait { field.menuActive && field.text == "/hel" }
        #expect(field.isFirstResponder)
    }

    func markedTextAndCaretAwayFromEndKeepArrowCommandsSuppressed() async throws {
        let host = Host(text: "/help")
        defer { host.stop() }
        let field = try await host.field()
        let probe = AccessibilityAnnouncer.DebugPostingProbe(matching: ["/help"])
        let previous = AccessibilityAnnouncer.debugPostingProbe
        AccessibilityAnnouncer.debugPostingProbe = probe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        let command = try host.command(UIKeyCommand.inputDownArrow, in: field)
        let action = try #require(command.action)
        field.setMarkedText("help", selectedRange: NSRange(location: 4, length: 0))
        try #require(field.markedTextRange != nil, "Use actual UIKit marked-text state, not a fake guard")
        #expect(!field.canPerformAction(action, withSender: command))
        #expect(probe.posts.isEmpty)
        field.unmarkText()
        host.chat.draft.text = "/help"
        try await host.wait { field.text == "/help" }
        field.selectedRange = NSRange(location: 0, length: 0)
        field.delegate?.textViewDidChangeSelection?(field)
        try await host.wait { !field.menuActive }
        #expect(!field.canPerformAction(action, withSender: command))
        #expect(probe.posts.isEmpty)
        #expect(field.isFirstResponder)
    }

    func postingProbeIsExactBoundedAndRespectsDisabledVoiceOver() {
        let previous = AccessibilityAnnouncer.debugPostingProbe
        defer { AccessibilityAnnouncer.debugPostingProbe = previous }
        let disabled = AccessibilityAnnouncer.DebugPostingProbe(matching: ["Scoped disabled announcement"], voiceOverEnabled: false)
        AccessibilityAnnouncer.debugPostingProbe = disabled
        AccessibilityAnnouncer.announce("Scoped disabled announcement")
        #expect(disabled.posts.isEmpty)
        let enabled = AccessibilityAnnouncer.DebugPostingProbe(matching: ["Scoped enabled announcement"])
        AccessibilityAnnouncer.debugPostingProbe = enabled
        for _ in 0..<20 { AccessibilityAnnouncer.announce("Scoped enabled announcement") }
        #expect(enabled.posts.count == 16)
        #expect(enabled.posts.allSatisfy { $0 == "Scoped enabled announcement" })
    }
}

// CI already selects this hosted UIKit suite. Keep the actual Composer fixture separate,
// while these wrappers ensure its causal regressions run in the existing iOS lane.
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitArrowAnnouncement() async throws {
        try await SlashMenuAnnouncementFixture().actualUIKitArrowAnnouncesTheSuggestionItSelectsWithoutMovingComposerFocus()
    }

    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitQueryCountAnnouncement() async throws {
        try await SlashMenuAnnouncementFixture().actualHostedQueryChangeAnnouncesItsResultCount()
    }

    @Test(.timeLimit(.minutes(2))) func slashMenuPostingProbeControls() {
        SlashMenuAnnouncementFixture().postingProbeIsExactBoundedAndRespectsDisabledVoiceOver()
    }
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitArrowWrapping() async throws {
        try await SlashMenuAnnouncementFixture().nativeArrowsWrapAndSpeakExactlyEachChangedCommand()
    }
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitSingleResult() async throws {
        try await SlashMenuAnnouncementFixture().singleResultDoesNotSpeakUnchangedSelections()
    }
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitVoiceOverOff() async throws {
        try await SlashMenuAnnouncementFixture().nativeArrowStillSelectsWhileVoiceOverIsOff()
    }
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitArgumentChoice() async throws {
        try await SlashMenuAnnouncementFixture().argumentArrowAnnouncesTheActualChoiceAndTabKeepsItsReplacement()
    }
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitReturnAndEscape() async throws {
        try await SlashMenuAnnouncementFixture().returnAndEscapeKeepExistingAcceptanceAndDismissalBehavior()
    }
    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitMarkedTextAndCaret() async throws {
        try await SlashMenuAnnouncementFixture().markedTextAndCaretAwayFromEndKeepArrowCommandsSuppressed()
    }

    @Test(.timeLimit(.minutes(2))) func slashMenuUIKitEqualCountAndZeroQueries() async throws {
        try await SlashMenuAnnouncementFixture().changedQueriesWithEqualCountsAndZeroResultsAreAnnounced()
    }

}
#endif
