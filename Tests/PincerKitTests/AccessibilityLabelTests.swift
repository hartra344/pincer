import Foundation
import Testing
@testable import PincerKit

/// Issue #58: VoiceOver labels composed by `AccessibilityText`.
@Suite("Accessibility labels")
struct AccessibilityLabelTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    // MARK: join / count

    @Test func joinDropsNilEmptyAndWhitespaceParts() {
        #expect(AccessibilityText.join(["A", nil, "", "  ", " B \n"]) == "A, B")
        #expect(AccessibilityText.join([]) == "")
        #expect(AccessibilityText.join([nil, " "]) == "")
    }

    @Test func sectionToggleNamesTheAction() {
        #expect(AccessibilityText.sectionToggle(title: "Moki", isCollapsed: false) == "Collapse Moki")
        #expect(AccessibilityText.sectionToggle(title: "Moki", isCollapsed: true) == "Expand Moki")
    }

    @Test func countPluralizesAndDropsZero() {
        #expect(AccessibilityText.count(0, singular: "tool call", plural: "tool calls") == nil)
        #expect(AccessibilityText.count(-2, singular: "tool call", plural: "tool calls") == nil)
        #expect(AccessibilityText.count(1, singular: "tool call", plural: "tool calls") == "1 tool call")
        #expect(AccessibilityText.count(2, singular: "tool call", plural: "tool calls") == "2 tool calls")
        #expect(AccessibilityText.count(1000, singular: "x", plural: "xs") == "1000 xs")
    }

    // MARK: summary

    @Test func summaryStripsMarkdownAndCollapsesWhitespace() {
        let text = "# Plan\n\n- **Fix** the `login` bug\n* ~~old~~ new\n> quoted\n```swift\nlet x = 1\n```\n  done  "
        #expect(AccessibilityText.summary(text) == "Plan Fix the login bug old new quoted let x = 1 done")
        #expect(AccessibilityText.summary("") == "")
        #expect(AccessibilityText.summary(" \n\t ") == "")
        #expect(AccessibilityText.summary("```\n```") == "")
    }

    @Test func summaryTruncatesAtAWordBoundary() {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let cut = AccessibilityText.summary(long)
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= AccessibilityText.defaultSummaryLimit + 1)
        #expect(!cut.dropLast().hasSuffix(" ") && cut.dropLast().hasSuffix("word"), "cut on a whole word: \(cut.suffix(12))")
        #expect(AccessibilityText.summary("Hello, world. Goodbye", limit: 13) == "Hello, world…")
        #expect(AccessibilityText.summary("exactly ten", limit: 11) == "exactly ten", "no ellipsis at exactly the limit")
    }

    @Test func summaryWithoutSpacesStillTruncates() {
        let blob = String(repeating: "a", count: 500)
        let cut = AccessibilityText.summary(blob, limit: 50)
        #expect(cut == String(repeating: "a", count: 50) + "…")
        #expect(AccessibilityText.summary(blob, limit: 0) == blob, "limit 0 disables truncation")
    }

    @Test func summaryKeepsEmojiAndNonLatinTextIntact() {
        #expect(AccessibilityText.summary("👍🏽 **Готово** 完成") == "👍🏽 Готово 完成")
        let cut = AccessibilityText.summary(String(repeating: "👨‍👩‍👧 ", count: 100), limit: 20)
        #expect(cut.hasSuffix("…") && cut.dropLast().allSatisfy { $0 == "👨‍👩‍👧" || $0 == " " })
    }

    // MARK: speaker

    @Test func speakerFallbacks() {
        #expect(AccessibilityText.speaker(role: .user) == "You")
        #expect(AccessibilityText.speaker(role: .user, author: "Travis") == "You", "the user's own rows are always You")
        #expect(AccessibilityText.speaker(role: .user, userAuthor: "Maya") == "Maya")
        #expect(AccessibilityText.speaker(role: .assistant) == "Assistant")
        #expect(AccessibilityText.speaker(role: .assistant, author: nil) == "Assistant")
        #expect(AccessibilityText.speaker(role: .assistant, author: "  ") == "Assistant", "blank author falls back")
        #expect(AccessibilityText.speaker(role: .assistant, author: " Claude ") == "Claude")
        #expect(AccessibilityText.speaker(role: .toolResult) == "Tool result")
        #expect(AccessibilityText.speaker(role: .system) == "System")
        #expect(AccessibilityText.speaker(role: .marker) == "System")
    }

    // MARK: messageRow

    @Test func messageRowOrdersParts() {
        let label = AccessibilityText.messageRow(
            role: .assistant, author: "Claude", text: "Here is **the plan**.", timestamp: "3:04 PM",
            toolCount: 2, attachmentCount: 1)
        #expect(label == "Claude, Here is the plan., 2 tool calls, 1 attachment, 3:04 PM")
    }

    @Test func messageRowUserTurnViaChannel() {
        let label = AccessibilityText.messageRow(role: .user, author: "ignored", text: "check disk", via: "Discord")
        #expect(label == "You, via Discord, check disk")

        let bridged = AccessibilityText.messageRow(
            role: .user, userAuthor: "Maya", text: "check disk", via: "Telegram")
        #expect(bridged == "Maya, via Telegram, check disk")
    }

    @Test func messageRowEmptyText() {
        #expect(AccessibilityText.messageRow(role: .assistant, text: "") == "Assistant, No text")
        #expect(AccessibilityText.messageRow(role: .assistant, text: "  \n ") == "Assistant, No text")
        #expect(AccessibilityText.messageRow(role: .assistant, text: "", attachmentCount: 3) == "Assistant, No text, 3 attachments")
    }

    @Test func messageRowStreaming() {
        #expect(AccessibilityText.messageRow(role: .assistant, author: "Claude", text: "", isStreaming: true) == "Claude, Responding",
                "no 'No text' while the reply is still arriving")
        #expect(AccessibilityText.messageRow(role: .assistant, author: "Claude", text: "Here", isStreaming: true)
            == "Claude, Responding, Here")
    }

    @Test func messageRowBookmarked() {
        #expect(AccessibilityText.messageRow(role: .user, text: "check disk", isBookmarked: true) == "You, Bookmarked, check disk")
    }

    @Test func messageRowStates() {
        #expect(AccessibilityText.messageRow(role: .assistant, text: "Boom", isError: true) == "Assistant, Error, Boom")
        #expect(AccessibilityText.messageRow(role: .user, text: "hi", isPending: true) == "You, Sending, hi")
        #expect(AccessibilityText.messageRow(role: .toolResult, text: "/ 50%") == "Tool result, / 50%")
        #expect(AccessibilityText.messageRow(role: .system, text: "Compacted") == "System, Compacted")
    }

    @Test func messageRowCountsSingularPluralZero() {
        #expect(!AccessibilityText.messageRow(role: .assistant, text: "x", toolCount: 0).contains("tool"))
        #expect(AccessibilityText.messageRow(role: .assistant, text: "x", toolCount: 1).hasSuffix("1 tool call"))
        #expect(AccessibilityText.messageRow(role: .assistant, text: "x", toolCount: 7).hasSuffix("7 tool calls"))
        #expect(AccessibilityText.messageRow(role: .assistant, text: "x", attachmentCount: 1).hasSuffix("1 attachment"))
    }

    @Test func messageRowTruncatesLongText() {
        let long = String(repeating: "lorem ipsum ", count: 500)
        let label = AccessibilityText.messageRow(role: .assistant, author: "Claude", text: long, timestamp: "9:00 AM")
        #expect(label.count < AccessibilityText.defaultSummaryLimit + 40, "label length \(label.count)")
        #expect(label.contains("…") && label.hasSuffix(", 9:00 AM") && label.hasPrefix("Claude, lorem"))
        let short = AccessibilityText.messageRow(role: .assistant, text: long, summaryLimit: 20)
        #expect(short.count <= "Assistant, ".count + 21)
    }

    /// TranscriptRowLayout passes `summaryLimit: 0`: the whole message is spoken, never cut.
    @Test func messageRowSummaryLimitZeroSpeaksEverything() {
        let words = (1...600).map { "w\($0)" }.joined(separator: " ")
        let label = AccessibilityText.messageRow(role: .assistant, author: "Claude", text: "**\(words)**", timestamp: "9:00 AM",
                                                 summaryLimit: 0)
        #expect(label == "Claude, \(words), 9:00 AM")
        #expect(!label.contains("…"))
        #expect(AccessibilityText.messageRow(role: .user, text: "", summaryLimit: 0) == "You, No text")
        #expect(AccessibilityText.summary(words, limit: -1) == words, "negative limits don't truncate either")
    }

    @Test func messageRowSpeaksMissingAuthorAsAssistant() {
        #expect(AccessibilityText.messageRow(role: .assistant, author: nil, text: "Hi").hasPrefix("Assistant, "))
        #expect(AccessibilityText.messageRow(role: .assistant, author: "", text: "Hi").hasPrefix("Assistant, "))
    }

    // MARK: sessionRow

    @Test func sessionRowFullLabel() {
        let label = AccessibilityText.sessionRow(
            title: "Research", agentName: "Claude", unreadCount: 3, isPinned: true, isRunning: true)
        #expect(label == "Research, Claude, Pinned, Working, 3 unread")
    }

    /// #183: the sidebar's dancing avatar speaks its own working label while a run is going.
    @Test func sessionRowSpeaksTheWorkingLabelWhileRunning() {
        #expect(AccessibilityText.sessionRow(title: "Research", agentName: "Moki", unreadCount: 2, isPinned: true,
                                             isRunning: true, workingLabel: "Moki is working")
            == "Research, Moki, Pinned, Moki is working, 2 unread", "replaces Working in the same position")
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: true, workingLabel: "Moki is working", hasError: true)
            == "A, Moki is working, Last run failed")
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: true, workingLabel: "Moki is working")
            .components(separatedBy: "orking").count == 2, "not spoken alongside Working")
    }

    @Test func sessionRowWorkingLabelFallsBackToWorking() {
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: true, workingLabel: nil) == "A, Working")
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: true, workingLabel: "") == "A, Working")
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: true) == "A, Working")
    }

    @Test func sessionRowIgnoresTheWorkingLabelWhenIdle() {
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: false, workingLabel: "Moki is working") == "A")
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: false, workingLabel: "") == "A")
    }

    @Test func sessionRowWhitespaceWorkingLabelStillSaysWorking() {
        #expect(AccessibilityText.sessionRow(title: "A", isRunning: true, workingLabel: "  \n") == "A, Working")
    }

    @Test func sessionRowUnreadCounts() {
        #expect(AccessibilityText.sessionRow(title: "A") == "A")
        #expect(AccessibilityText.sessionRow(title: "A", unreadCount: 0, isUnread: false) == "A")
        #expect(AccessibilityText.sessionRow(title: "A", unreadCount: 0, isUnread: true) == "A, Unread")
        #expect(AccessibilityText.sessionRow(title: "A", unreadCount: 1) == "A, 1 unread")
        #expect(AccessibilityText.sessionRow(title: "A", unreadCount: 1, isUnread: true) == "A, 1 unread", "exact count wins")
        #expect(AccessibilityText.sessionRow(title: "A", unreadCount: 250) == "A, 250 unread")
        #expect(AccessibilityText.sessionRow(title: "A", unreadCount: -1) == "A")
    }

    @Test func sessionRowUntitledAndStates() {
        #expect(AccessibilityText.sessionRow(title: "") == "Untitled session")
        #expect(AccessibilityText.sessionRow(title: "  \n") == "Untitled session")
        #expect(AccessibilityText.sessionRow(title: " Main ", agentName: "") == "Main", "blank agent name drops out")
        #expect(AccessibilityText.sessionRow(title: "Old", hasError: true, isArchived: true) == "Old, Archived, Last run failed")
        #expect(AccessibilityText.sessionRow(title: "P", isPinned: true) == "P, Pinned")
    }

    @Test func sessionRowPreviewIsSummarized() {
        let label = AccessibilityText.sessionRow(title: "Chat", preview: "**Found** 3 rentals\nnear `downtown`")
        #expect(label == "Chat, Found 3 rentals near downtown")
        let long = AccessibilityText.sessionRow(title: "Chat", preview: String(repeating: "abc ", count: 100))
        #expect(long.hasSuffix("…") && long.count <= "Chat, ".count + 81)
        #expect(AccessibilityText.sessionRow(title: "Chat", preview: "") == "Chat")
    }

    // MARK: context meter

    @Test func contextMeterValue() {
        #expect(AccessibilityText.contextMeterLabel == "Context window")
        #expect(AccessibilityText.contextMeterValue(ContextUsage(used: 50_000, limit: 200_000))
            == "25 percent used, 50k of 200k tokens")
        #expect(AccessibilityText.contextMeterValue(ContextUsage(used: 172_000, limit: 200_000))
            == "86 percent used, 172k of 200k tokens, nearly full")
        #expect(AccessibilityText.contextMeterValue(ContextUsage(used: 195_000, limit: 200_000))
            == "98 percent used, 195k of 200k tokens, almost full")
        #expect(AccessibilityText.contextMeterValue(ContextUsage(used: 195_000, limit: 200_000, isApproximate: true))
            == "About 98 percent used, 195k of 200k tokens", "stale totals never warn")
        #expect(AccessibilityText.contextMeterValue(ContextUsage(used: 0, limit: 1_000_000))
            == "0 percent used, 0 of 1M tokens")
        #expect(AccessibilityText.contextMeterValue(ContextUsage(used: 300_000, limit: 200_000)).hasPrefix("100 percent used"),
                "over-limit clamps to 100")
    }

    // MARK: announcements / find / tools

    @Test func replyAnnouncements() {
        #expect(AccessibilityText.replyFinishedAnnouncement(author: "Claude", text: "Here is the plan")
            == "Claude replied: Here is the plan")
        #expect(AccessibilityText.replyFinishedAnnouncement(author: nil, text: "") == "Assistant replied")
        #expect(AccessibilityText.replyFinishedAnnouncement(author: "", text: "```\n```") == "Assistant replied")
        let long = AccessibilityText.replyFinishedAnnouncement(author: "C", text: String(repeating: "word ", count: 100))
        #expect(long.hasSuffix("…") && long.count <= "C replied: ".count + 121)
        #expect(AccessibilityText.replyFailedAnnouncement(author: "Claude") == "Claude: reply failed")
        #expect(AccessibilityText.replyFailedAnnouncement(author: nil) == "Assistant: reply failed")
    }

    @Test func findStatus() {
        #expect(AccessibilityText.findStatus(current: nil, total: 0) == "No results")
        #expect(AccessibilityText.findStatus(current: 1, total: 0) == "No results")
        #expect(AccessibilityText.findStatus(current: nil, total: 1) == "1 result")
        #expect(AccessibilityText.findStatus(current: nil, total: 5) == "5 results")
        #expect(AccessibilityText.findStatus(current: 0, total: 5) == "5 results")
        #expect(AccessibilityText.findStatus(current: 2, total: 5) == "Result 2 of 5")
        #expect(AccessibilityText.findStatus(current: 9, total: 5) == "Result 5 of 5", "current clamps to total")
    }

    @Test func symbolNames() {
        #expect(AccessibilityText.symbolName("bubble.left.and.bubble.right.fill") == "Bubble left and bubble right")
        #expect(AccessibilityText.symbolName("paperplane") == "Paperplane")
        #expect(AccessibilityText.symbolName("paperplane.fill") == "Paperplane")
        #expect(AccessibilityText.symbolName("person.crop.circle.badge.plus") == "Person crop circle badge plus")
        #expect(AccessibilityText.symbolName("01.circle.fill") == "01 circle")
        #expect(AccessibilityText.symbolName("fill.circle") == "Circle")
        #expect(AccessibilityText.symbolName("") == "")
        #expect(!AccessibilityText.symbolName("a..b").contains("  "), "empty segments don't double spaces")
    }

    @Test func toolCallLabel() {
        #expect(AccessibilityText.toolCall(name: "exec", summary: "ls -la", isRunning: true, isError: false)
            == "Tool exec, running, ls -la")
        #expect(AccessibilityText.toolCall(name: "read", isRunning: false, isError: true) == "Tool read, failed")
        #expect(AccessibilityText.toolCall(name: "read", isRunning: false, isError: false) == "Tool read, finished")
        #expect(AccessibilityText.toolCall(name: "exec", isRunning: true, isError: true) == "Tool exec, running",
                "running wins over a stale error")
        #expect(AccessibilityText.toolCall(name: "exec", summary: "", isRunning: false, isError: false) == "Tool exec, finished")
    }

    @Test func linkActionsCollapseDuplicateURLsInReadingOrder() throws {
        let a = try #require(URL(string: "https://example.com/a"))
        let b = try #require(URL(string: "https://example.com/b"))
        let actions = AccessibilityText.linkActions([(text: "Docs", url: a), (text: "Blog", url: b), (text: "Docs again", url: a)])
        #expect(actions.map(\.title) == ["Docs", "Blog"], "first run for a URL wins")
        #expect(actions.map(\.url) == [a, b])
    }

    @Test func linkActionsFallBackToTheURLForAnEmptyTitle() throws {
        let url = try #require(URL(string: "https://example.com/x?y=1"))
        let actions = AccessibilityText.linkActions([(text: "", url: url), (text: " \n ", url: try #require(URL(string: "https://e.org")))])
        #expect(actions.map(\.title) == ["https://example.com/x?y=1", "https://e.org"])
        #expect(AccessibilityText.linkActions([(text: "  Docs \n", url: url)]).first?.title == "Docs", "titles are trimmed")
        #expect(AccessibilityText.linkActions([]).isEmpty)
    }

    @Test func linkActionsAreCappedAtTheLimit() throws {
        let runs = try (1...15).map { (text: "Link \($0)", url: try #require(URL(string: "https://example.com/\($0)"))) }
        let actions = AccessibilityText.linkActions(runs)
        #expect(AccessibilityText.maxLinkActions == 10)
        #expect(actions.count == 10)
        #expect(actions.map(\.title) == (1...10).map { "Link \($0)" }, "the first links in reading order are kept")
        #expect(AccessibilityText.linkActions(runs, limit: 3).count == 3)
        #expect(AccessibilityText.linkActions(runs, limit: 0).isEmpty)
        // Duplicates don't use up the cap.
        let dupes = Array(repeating: runs[0], count: 5) + runs
        #expect(AccessibilityText.linkActions(dupes).map(\.title) == (1...10).map { "Link \($0)" })
    }

    /// The row's custom actions are named `L("Open \(title)")` in PincerUI, so the helper returns bare
    /// titles (no "Open Open …") and the catalog must carry the `Open %@` key.
    @Test func linkActionTitlesArePrefixedOpenByTheCatalogKey() throws {
        let url = try #require(URL(string: "https://example.com"))
        let title = try #require(AccessibilityText.linkActions([(text: "Docs", url: url)]).first?.title)
        #expect(!title.hasPrefix("Open"))
        let catalogURL = Self.repo.appending(path: "Sources/PincerUI/Resources/Localizable.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings["Open %@"] != nil, "catalog key for the \"Open <title>\" link action")
        #expect(String(format: "Open %@", title) == "Open Docs")
        let source = try String(contentsOf: Self.repo.appending(path: "Sources/PincerUI/TranscriptList+UIKit.swift"), encoding: .utf8)
        #expect(source.contains("L(\"Open \\(title)\")"), "link actions are named through the Open %@ key")
    }

    /// Labels are speech, not layout: no raw newlines, Markdown markers or doubled separators.
    @Test func labelsAreSingleLineAndClean() {
        let labels = [
            AccessibilityText.messageRow(role: .assistant, author: "A\nB", text: "# T\n\n**x**\n\n- y", timestamp: " "),
            AccessibilityText.sessionRow(title: "T\n", agentName: " ", preview: "a\n\nb"),
        ]
        for label in labels {
            #expect(!label.contains(", ,") && !label.hasSuffix(", ") && !label.hasPrefix(", "), "\(label)")
            #expect(!label.contains("**") && !label.contains("`"), "\(label)")
        }
        #expect(!labels[1].contains("\n"))
    }
}

/// #308/#209/#269/#349: the pure helpers behind the accessibility pass.
@Suite("Accessibility pass labels")
struct AccessibilityPassLabelTests {
    @Test func sectionStateAndHint() {
        #expect(AccessibilityText.sectionState(isCollapsed: true) == "Collapsed")
        #expect(AccessibilityText.sectionState(isCollapsed: false) == "Expanded")
        #expect(AccessibilityText.sectionHint(isCollapsed: true) == "Expands the section")
        #expect(AccessibilityText.sectionHint(isCollapsed: false) == "Collapses the section")
    }

    @Test func newChatNamesTheAgent() {
        #expect(AccessibilityText.newChatWith(agent: "Mochi") == "New chat with Mochi")
    }

    @Test func sessionManagerRowIncludesStatusAndDuration() {
        let label = AccessibilityText.sessionManagerRow(title: "Research", agentName: "Claude", runStatus: "Interrupted",
                                                        duration: "2 min 5 s", updated: "updated 3:04 PM")
        #expect(label == "Research, Claude, Interrupted, 2 min 5 s, updated 3:04 PM")
        let bare = AccessibilityText.sessionManagerRow(title: "Research", agentName: nil, runStatus: nil, duration: nil,
                                                       updated: nil, extra: ["Pinned", nil])
        #expect(bare == "Research, Pinned")
        for status in ["Running", "Done", "Failed"] {
            #expect(AccessibilityText.sessionManagerRow(title: "T", agentName: nil, runStatus: status, duration: nil,
                                                        updated: nil).contains(status))
        }
    }

    @Test func streamingExcerptStartsWithTheFirstWords() {
        let body = "First words of the reply. " + String(repeating: "middle filler text ", count: 500) + "THE-TAIL-END"
        let excerpt = AccessibilityText.streamingExcerpt(body)
        #expect(excerpt.hasPrefix("First words of the reply."))
        #expect(!excerpt.contains("THE-TAIL-END"))
        #expect(excerpt.count <= 241)
        #expect(AccessibilityText.streamingExcerpt("Short") == "Short")
    }

    @Test func streamingExcerptIsBoundedForHugeBodies() {
        let body = "Opening words. " + String(repeating: "x ", count: 2_500_000)
        #expect(body.utf8.count > 5_000_000)
        let start = ContinuousClock.now
        let excerpt = AccessibilityText.streamingExcerpt(body, limit: 100)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(excerpt.hasPrefix("Opening words."))
        #expect(excerpt.count <= 101)
    }

    @Test func messagePartActionNumbersOnlyMultipleMessages() {
        #expect(AccessibilityText.messagePartAction("Reply", part: 1, of: 1) == "Reply")
        #expect(AccessibilityText.messagePartAction("Reply", part: 1, of: 0) == "Reply")
        #expect(AccessibilityText.messagePartAction("Reply", part: 1, of: 3) == "Reply, part 1 of 3")
        #expect(AccessibilityText.messagePartAction("Copy Link", part: 3, of: 3) == "Copy Link, part 3 of 3")
    }
}
