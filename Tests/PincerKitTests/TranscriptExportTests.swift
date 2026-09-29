import Foundation
import Testing
@testable import PincerKit

@Suite("Transcript export")
struct TranscriptExportTests {
    let utc = TimeZone(identifier: "UTC")!
    let header = TranscriptExport.Header(title: "Trip planning", agentName: "Scout",
                                         exportedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    func fixture(toolOutput: String = "file1.txt\nfile2.txt") -> [ChatItem] {
        var user = ChatItem(id: "u1", role: .user, blocks: [.text("What's in the folder?")], timestamp: self.date(0))
        user.transcriptId = "u1"
        var assistant = ChatItem(id: "a1", role: .assistant, blocks: [
            .thinking("I should list the directory."),
            .toolCall(id: "t1", name: "exec", arguments: #"{"command":"ls"}"#),
        ], timestamp: self.date(60))
        assistant.runId = "r1"
        var result = ChatItem(id: "tr1", role: .toolResult, blocks: [.text(toolOutput)], timestamp: self.date(61))
        result.toolCallId = "t1"
        result.toolName = "exec"
        result.runId = "r1"
        var reply = ChatItem(id: "a2", role: .assistant, blocks: [.text("Two files: file1 and file2.")], timestamp: self.date(62))
        reply.runId = "r1"
        var marker = ChatItem(id: "m1", role: .marker, blocks: [], timestamp: self.date(120))
        marker.markerKind = "compaction"
        let pending = ChatItem(id: "p1", role: .user, blocks: [.text("UNSENT DRAFT")], timestamp: self.date(180), isPending: true)
        return [user, assistant, result, reply, marker, pending]
    }

    func markdown(_ items: [ChatItem]? = nil, thinking: Bool = false, tools: Bool = false) -> String {
        TranscriptExport.markdown(items ?? self.fixture(), header: self.header,
                                  options: .init(includeThinking: thinking, includeToolCalls: tools), timeZone: self.utc)
    }

    func plain(thinking: Bool = false, tools: Bool = false) -> String {
        TranscriptExport.plainText(self.fixture(), header: self.header,
                                   options: .init(includeThinking: thinking, includeToolCalls: tools), timeZone: self.utc)
    }

    @Test func markdownDefaultsHideThinkingAndTools() {
        let out = self.markdown()
        #expect(out.hasPrefix("# Trip planning\n\n_Exported 2027-01-15 08:00_"))
        #expect(out.contains("## You · 2023-11-14 22:13\n\nWhat's in the folder?"))
        #expect(out.contains("## Scout · "))
        #expect(out.contains("Two files: file1 and file2."))
        #expect(out.contains("---\n\n_Context compacted_"))
        #expect(!out.contains("Thinking"))
        #expect(!out.contains("file1.txt"))
        #expect(!out.contains("🔧"))
        #expect(!out.contains("UNSENT DRAFT"))
    }

    @Test func markdownIncludesThinkingWhenAsked() {
        let out = self.markdown(thinking: true)
        #expect(out.contains("<details><summary>Thinking</summary>\n\nI should list the directory.\n\n</details>"))
        #expect(!out.contains("🔧"))
    }

    @Test func markdownIncludesToolCallsWhenAsked() {
        let out = self.markdown(tools: true)
        #expect(out.contains("🔧"))
        #expect(out.contains("file1.txt\nfile2.txt"))
        #expect(!out.contains("Thinking"))
        // Tool call comes before the reply text.
        let tool = out.range(of: "🔧")!.lowerBound
        let text = out.range(of: "Two files")!.lowerBound
        #expect(tool < text)
    }

    @Test func plainTextToggles() {
        let off = self.plain()
        #expect(off.hasPrefix("Trip planning\n\nExported 2027-01-15 08:00"))
        #expect(off.contains("You · 2023-11-14 22:13:\nWhat's in the folder?"))
        #expect(off.contains("Two files: file1 and file2."))
        #expect(off.contains("— Context compacted —"))
        #expect(!off.contains("[Thinking]") && !off.contains("[Tool:") && !off.contains("UNSENT DRAFT"))
        let on = self.plain(thinking: true, tools: true)
        #expect(on.contains("[Thinking]\nI should list the directory."))
        #expect(on.contains("[Tool: "))
        #expect(on.contains("  file1.txt\n  file2.txt"))
    }

    @Test func fenceGrowsPastBackticks() {
        #expect(TranscriptExport.fence("plain") == "```\nplain\n```")
        #expect(TranscriptExport.fence("a ``` b") == "````\na ``` b\n````")
        let out = self.markdown(self.fixture(toolOutput: "before\n```swift\nlet x = 1\n```\nafter"), tools: true)
        #expect(out.contains("````\nbefore\n```swift\nlet x = 1\n```\nafter\n````"))
    }

    @Test func longToolOutputIsTruncated() {
        let big = String(repeating: "x", count: TranscriptExport.toolOutputLimit * 3)
        let out = self.markdown(self.fixture(toolOutput: big), tools: true)
        #expect(out.contains("xxxx"))
        #expect(!out.contains(big))
        #expect(out.count < big.count)
    }

    @Test func fileNamesAreSanitised() {
        #expect(TranscriptExport.fileName(title: "a/b:c", format: .markdown) == "a-b-c.md")
        #expect(TranscriptExport.fileName(title: "", format: .markdown) == "Chat.md")
        #expect(TranscriptExport.fileName(title: "  ..  ", format: .plainText) == "Chat.txt")
        #expect(TranscriptExport.fileName(title: "Trip planning", format: .pdf) == "Trip planning.pdf")
        #expect(TranscriptExport.fileName(title: String(repeating: "z", count: 200), format: .markdown).count == 83)
    }
}
