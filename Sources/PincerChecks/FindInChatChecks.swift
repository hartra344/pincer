import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runFindInChatChecks() {
    do {
        let findHistory = json("""
        [
         {"role":"user","content":"Where is the Café receipt?","__openclaw":{"id":"f1"}},
         {"role":"assistant","content":[{"type":"thinking","thinking":"Look for the cafe receipt in mail. Receipt, receipt."},
           {"type":"toolCall","id":"t1","name":"exec","arguments":{"command":"grep receipt ~/mail"}}],"__openclaw":{"id":"f2"}},
         {"role":"toolResult","toolCallId":"t1","toolName":"exec","content":[{"type":"text","text":"receipt.pdf\\nRECEIPT-old.pdf"}],"__openclaw":{"id":"f3"}},
         {"role":"assistant","content":[{"type":"text","text":"Found the **receipt**."}],"__openclaw":{"id":"f4"}},
         {"role":"assistant","content":[{"type":"text","text":"Also an older receipt."}],"__openclaw":{"id":"f5"}},
         {"role":"marker","kind":"compaction","__openclaw":{"id":"f6","kind":"compaction"}},
         {"role":"user","content":"thanks","__openclaw":{"id":"f7"}}
        ]
        """)
        let findEntries = TranscriptBuilder.build(findHistory.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) })
        let replies = TranscriptSearch.matches("receipt", in: findEntries)
        check(replies.map(\.entryId) == ["u-f1", "a-f2", "a-f2"], "replies only by default, in transcript order (got \(replies.map(\.entryId)))")
        check(replies.map(\.section) == [.message(0), .message(0), .message(1)], "back-to-back messages are separate sections")
        check(TranscriptSearch.matches("CAFE", in: findEntries).map(\.entryId) == ["u-f1"], "case and diacritics ignored")
        check(TranscriptSearch.matches("  ", in: findEntries).isEmpty && TranscriptSearch.matches("zebra", in: findEntries).isEmpty,
              "blank and missing queries find nothing")
        let everything = TranscriptSearch.matches("receipt", in: findEntries, options: .init(includeThinking: true, includeTools: true))
        check(everything.count == 9, "thinking and tool text searched when included (got \(everything.count))")
        check(everything.filter { $0.section == .thinking }.map(\.occurrence) == [0, 1, 2], "thinking occurrences numbered")
        check(everything.filter { $0.section == .tool("t1") }.map(\.occurrence) == [0, 1, 2],
              "tool input then output counted as one section")
        let order = everything.filter { $0.entryId == "a-f2" }.map(\.section)
        check(order.firstIndex(of: .thinking)! < order.firstIndex(of: .tool("t1"))!
              && order.firstIndex(of: .tool("t1"))! < order.firstIndex(of: .message(0))!,
              "within a turn: thinking, tools, then messages, as drawn")
        check(TranscriptSearch.matches("receipt", in: findEntries, options: .init(includeTools: true, toolTextLimit: 11))
            .filter { $0.section == .tool("t1") }.count == 2, "output past the display limit isn't searched (the command is drawn whole)")
        check(TranscriptSearch.ranges(of: "aa", in: "aaaa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)],
              "occurrences don't overlap")
        check(TranscriptSearch.ranges(of: "b", in: "🦞b") == [NSRange(location: 2, length: 1)], "ranges are UTF-16, for attributed text")
        check(TranscriptSearch.step(from: nil, count: 3, forward: true) == 0 && TranscriptSearch.step(from: nil, count: 3, forward: false) == 2,
              "first step starts at an end")
        check(TranscriptSearch.step(from: 2, count: 3, forward: true) == 0 && TranscriptSearch.step(from: 0, count: 3, forward: false) == 2,
              "next and previous wrap around")
        check(TranscriptSearch.step(from: 1, count: 0, forward: true) == nil, "no step without matches")
        let rowIndex = Dictionary(findEntries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        check(TranscriptSearch.reselect(nil, in: replies, rowIndex: rowIndex, near: nil) == 2, "a new search selects the latest match")
        check(TranscriptSearch.reselect(replies[1], in: replies, rowIndex: rowIndex, near: 1) == 1, "the selected match survives new messages")
        let refined = TranscriptSearch.matches("older receipt", in: findEntries)
        check(TranscriptSearch.reselect(replies[0], in: refined, rowIndex: rowIndex, near: 0) == 0,
              "a vanished selection falls back near where the reader was")
        check(TranscriptSearch.reselect(nil, in: [], rowIndex: rowIndex, near: nil) == nil, "nothing selected without matches")

        let markdownHistory = json(#"""
        [
         {"role":"assistant","content":[{"type":"text","text":"See [the docs](https://x.example/receipt) for the **hello** world receipt."}],"__openclaw":{"id":"m1"}},
         {"role":"user","content":"and the chart?","__openclaw":{"id":"m1u"}},
         {"role":"assistant","content":[{"type":"text","text":"Here:\n```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\"><text>receipt</text></svg>\n```\n```swift\nlet receipt = 1\n```\n| Item | Note |\n|---|---|\n| receipt | `a|b` |"}],"__openclaw":{"id":"m2"}}
        ]
        """#)
        let markdownEntries = TranscriptBuilder.build(markdownHistory.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) })
        check(TranscriptSearch.renderedTexts(markdown: "See [the docs](https://x.example/receipt) for **hello** world.")
            == ["See the docs for hello world."], "searched text is the rendered text, without Markdown syntax")
        check(TranscriptSearch.matches("receipt", in: [markdownEntries[0]]).count == 1, "link targets aren't counted")
        check(TranscriptSearch.matches("hello world", in: markdownEntries).count == 1, "phrases match across styled words")
        check(TranscriptSearch.renderedTexts(markdown: "1. one\n2. two\n\n> quoted\n\n---\n\nafter")
            == ["1.\tone\n2.\ttwo", "quoted", "after"], "one text per view, with list markers, split at quotes and rules")
        check(TranscriptSearch.renderedTexts(markdown: "| A | B |\n|---|---|\n| 1 |\n") == ["A", "B", "1", ""],
              "tables are searched cell by cell, padded to the header")
        check(TranscriptSearch.renderedTexts(markdown: "line one\nline two") == ["line one\u{2028}line two"],
              "soft line breaks are drawn as line separators")
        let svgMatches = TranscriptSearch.matches("receipt", in: [markdownEntries[2]])
        check(svgMatches.count == 2 && svgMatches.map(\.occurrence) == [0, 1],
              "SVG source (shown as an image) is skipped; code and table cells are counted (got \(svgMatches.count))")
        check(TranscriptSearch.matches("svg", in: [markdownEntries[2]]).isEmpty, "code fence languages aren't searched")
        let renumbered = TranscriptBuilder.build([ChatItem(json(#"{"role":"user","content":"3. first\n4. second","__openclaw":{"id":"n1"}}"#), fallbackIndex: 0)!])
        check(TranscriptSearch.matches("1.", in: renumbered).count == 1 && TranscriptSearch.matches("3.", in: renumbered).isEmpty,
              "list numbers are searched as drawn")
        check(TranscriptSearch.matches("first 2", in: renumbered).isEmpty && TranscriptSearch.matches("rst", in: renumbered).count == 1,
              "quick source check doesn't drop partial words")
    }
}
