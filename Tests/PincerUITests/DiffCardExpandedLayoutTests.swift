import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #156: a fully expanded diff shows all of its lines instead of scrolling inside the card.
@MainActor
@Suite("Diff card expanded layout")
struct DiffCardExpandedLayoutTests {
    let scratch = ScratchDefaults()
    let key = "agent:t:main"

    func tool(lines: Int) -> ToolActivity {
        let content = (0..<lines).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let args = String(decoding: try! JSONSerialization.data(
            withJSONObject: ["path": "a.swift", "content": content], options: [.sortedKeys]), as: UTF8.self)
        return ToolActivity(id: "w1", name: "write", arguments: args, result: "Wrote a.swift", isError: false, isRunning: false)
    }

    func sections(lines: Int, showAll: Bool) -> (sections: [TranscriptPart.Tool.Section], diff: TranscriptPart.Tool.Diff?) {
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: UIFixtures.identity())
        let disclosure = TranscriptDisclosure()
        let tool = self.tool(lines: lines)
        if showAll { disclosure.set("diff:\(tool.id)", expanded: true) }
        let context = TranscriptContext(gateway: gateway, disclosure: disclosure,
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: self.key))
        var turn = AssistantTurn(id: "turn-1")
        turn.tools = [tool]
        turn.isStreaming = true // a live turn lays its tool cards out in the open
        let layout = TranscriptLayoutBuilder(context: context, settings: .current(for: context))
            .layout(.entry(.assistant(turn)), width: 700)
        for placed in layout.parts {
            if case let .tool(part) = placed.part { return (part.sections.filter { $0.title == L("Changes") }, part.diff) }
        }
        return ([], nil)
    }

    @Test func expandedLongDiffTakesItsFullHeight() throws {
        defer { self.scratch.remove() }
        let (sections, diff) = self.sections(lines: 200, showAll: true)
        let section = try #require(sections.first)
        #expect(diff?.isExpanded == true)
        #expect(section.contentHeight > TranscriptMetrics.diffMaxHeight, "fixture is taller than the old cap")
        #expect(section.frame.height == section.contentHeight, "no inner scrolling once fully expanded")
    }

    @Test func collapsedLongDiffStaysShortAndScrollFree() throws {
        defer { self.scratch.remove() }
        let (sections, diff) = self.sections(lines: 200, showAll: false)
        let section = try #require(sections.first)
        #expect(diff?.isExpanded == false)
        #expect(section.frame.height <= TranscriptMetrics.diffMaxHeight)
        #expect(section.frame.height == section.contentHeight, "the 12-line preview fits without scrolling")
    }

    @Test func smallDiffHasNothingHidden() throws {
        defer { self.scratch.remove() }
        let (sections, _) = self.sections(lines: 5, showAll: false)
        let section = try #require(sections.first)
        #expect(section.frame.height == section.contentHeight)
    }
}
