import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

#if os(macOS)
import AppKit

/// #342: highlighting colors tool text without changing it, and a card's own search marks its matches.
@MainActor
@Suite("Tool card search and highlighting")
struct ToolCardSearchTests {
    @MainActor final class Fixture {
        let scratch = ScratchDefaults()
        let disclosure = TranscriptDisclosure()
        let renderer: TranscriptRenderer
        init() {
            let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                       defaults: self.scratch.defaults, identity: UIFixtures.identity())
            let key = "agent:t:main"
            let context = TranscriptContext(gateway: gateway, disclosure: self.disclosure,
                                            agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                            previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
            self.renderer = TranscriptRenderer(context: context)
        }

        func cleanup() { self.scratch.remove() }

        func tool(_ tool: ToolActivity) -> (TranscriptRowLayout, TranscriptPart.Tool) {
            var turn = AssistantTurn(id: "turn-1", timestamp: Date(timeIntervalSince1970: 1))
            turn.tools = [tool]
            self.disclosure.set("steps:turn-1", expanded: true)
            self.disclosure.set("tool:\(tool.id)", expanded: true)
            let layout = self.renderer.layout(for: .entry(.assistant(turn)), width: 700)
            for part in layout.parts {
                if case let .tool(tool) = part.part { return (layout, tool) }
            }
            fatalError("no tool part")
        }
    }

    static let json = #"{"name": "pincer", "count": 3, "ok": true, "tags": ["a", "b"]}"#

    @Test func highlightingKeepsTheText() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let tool = ToolActivity(id: "t1", name: "read", arguments: #"{"path":"/a/b.json"}"#, result: Self.json, isError: false, isRunning: false)
        let (_, part) = fixture.tool(tool)
        let output = part.sections.first { $0.id == "t1:output" }
        #expect(output?.text.string == ToolPresentationCache.presentation(for: tool).output?.text)
        var colors = Set<String>()
        output?.text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: output?.text.length ?? 0)) { value, _, _ in
            colors.insert("\(value.map { String(describing: $0) } ?? "nil")")
        }
        #expect(colors.count >= 4, "keys, strings, numbers and literals get their own colors")
    }

    @Test func cardSearchMarksMatchesAndInvalidatesOnlyItsRow() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let tool = ToolActivity(id: "t2", name: "read", arguments: #"{"path":"/a/b.json"}"#, result: Self.json, isError: false, isRunning: false)
        fixture.disclosure.set(ToolCardSearchStore.key("t2"), expanded: true)
        fixture.disclosure.toolSearch.set(.init(query: "a", current: 1), for: "t2")
        let (_, part) = fixture.tool(tool)
        let search = try #require(part.search)
        // "/a/b.json" in the headline, "name"/"pincer"/"tags"/"a" in the output: counted across sections.
        let marked = part.sections.reduce(0) { total, section in
            var count = 0
            section.text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: section.text.length)) { value, range, _ in
                if value != nil { count += 1 }
            }
            return total + count
        }
        #expect(search.total > 1)
        #expect(marked == search.total)
        #expect(search.current == 1)

        var invalidated: [Set<String>?] = []
        fixture.renderer.onInvalidate = { ids, _ in invalidated.append(ids) }
        fixture.renderer.setToolSearch("t2", row: "row-1", query: "pin")
        #expect(invalidated == [Set(["row-1"])])
    }

    @Test func searchOpensFullOutputAndClosedCardsHaveNoSearch() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let lines = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let tool = ToolActivity(id: "t3", name: "exec", arguments: #"{"command":"ls"}"#, result: lines, isError: false, isRunning: false)
        let (_, closed) = fixture.tool(tool)
        #expect(closed.search == nil)
        #expect(closed.controls.contains { $0.id == "search-output" })
        let shortHeight = closed.sections.first { $0.id == "t3:output" }?.frame.height ?? 0
        let second = Fixture()
        defer { second.cleanup() }
        second.disclosure.set(ToolCardSearchStore.key("t3"), expanded: true)
        let (_, open) = second.tool(tool)
        #expect(open.search != nil)
        #expect((open.sections.first { $0.id == "t3:output" }?.frame.height ?? 0) > shortHeight)
    }
}
#endif
