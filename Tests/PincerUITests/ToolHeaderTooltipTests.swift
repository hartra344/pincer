import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

#if os(macOS)
import AppKit

/// #155: the path tooltip lives on the file-edit card's header only, not on the whole card.
@MainActor
@Suite("Tool header tooltip")
struct ToolHeaderTooltipTests {
    func rowView(for tool: ToolActivity) -> (TranscriptRowView, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:t:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let renderer = TranscriptRenderer(context: context)
        var turn = AssistantTurn(id: "turn-1", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true // a live turn lays its tool cards out in the open
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: 700)
        let view = TranscriptRowView(frame: CGRect(x: 0, y: 0, width: 700, height: layout.height))
        view.apply(layout, actions: renderer)
        return (view, scratch)
    }

    func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in (sub as? T).map { [$0] + self.find(type, in: sub) } ?? self.find(type, in: sub) }
    }

    @Test func fileEditHeaderHasPathTooltipAndCardHasNone() throws {
        let args = #"{"path":"Sources/App/Deep/Feature.swift","old_string":"a","new_string":"b"}"#
        let tool = ToolActivity(id: "e1", name: "edit", arguments: args, result: "ok", isError: false, isRunning: false)
        let (view, scratch) = self.rowView(for: tool)
        defer { scratch.remove() }
        let card = try #require(self.find(TranscriptToolView.self, in: view).first, "\(view.subviews.map { String(describing: type(of: $0)) }) parts \(view.layout?.parts.map(\.part.kind) ?? [])")
        let header = try #require(self.find(TranscriptToolHeaderView.self, in: card).first)
        #expect(header.toolTip == "Sources/App/Deep/Feature.swift")
        #expect(card.toolTip == nil, "the tooltip is on the header only")
    }
}
#endif
