import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #561: provider/core clipping must stay visible in the produced web_search card.
@MainActor
@Suite("Web search truncation status")
struct WebSearchTruncationStatusTests {
    @Test func truncatedResultsShowStatusWithoutChangingRows() throws {
        try Self.verifyResultsStatus()
    }

    @Test func truncatedAnswerWithoutCitationsStillShowsStatus() throws {
        try Self.verifyAnswerStatus()
    }

    static func verifyResultsStatus() throws {
        let status = L("Search output was truncated")
        let truncated = try Self.card(kind: "results", truncated: true)
        let complete = try Self.card(kind: "results", truncated: false)

        #expect(Self.visibleLabels(truncated).contains(status))
        #expect(truncated.notes.contains { $0.text == status }, "VoiceOver receives the status too")
        #expect(!Self.visibleLabels(complete).contains(status))
        #expect(!complete.notes.contains { $0.text == status })
        #expect(Self.resultRows(truncated) == Self.resultRows(complete), "the status must not alter result rows or links")
        #expect(Self.resultLinks(truncated) == [URL(string: "https://example.com/swift")!],
                "the search result remains an attributed link when flagged")
        #expect(Self.resultLinks(truncated) == Self.resultLinks(complete))
    }

    static func verifyAnswerStatus() throws {
        let status = L("Search output was truncated")
        let truncated = try Self.card(kind: "answer", truncated: true)
        let complete = try Self.card(kind: "answer", truncated: false)

        #expect(Self.visibleLabels(truncated).contains(status))
        #expect(truncated.notes.contains { $0.text == status }, "VoiceOver receives the status even without citations")
        #expect(!Self.visibleLabels(complete).contains(status))
        #expect(!complete.notes.contains { $0.text == status })
        #expect(truncated.sections.map { $0.text.string } == complete.sections.map { $0.text.string },
                "the indicator does not change answer text")
    }

    private static func card(kind: String, truncated: Bool) throws -> TranscriptPart.Tool {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let key = "agent:main:web-search-truncation"
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Main"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let payload: JSONValue = kind == "results"
            ? .object([
                "kind": .string(kind), "provider": .string("brave"), "query": .string("swift"),
                "count": .number(1), "truncated": .bool(truncated),
                "results": .array([.object([
                    "title": .string("Concurrency guide"), "url": .string("https://example.com/swift"),
                    "snippet": .string("A concise guide."),
                ])]),
            ])
            : .object([
                "kind": .string(kind), "provider": .string("brave"), "query": .string("swift"),
                "truncated": .bool(truncated), "content": .string("A concise answer."),
            ])
        let tool = ToolActivity(id: "web-call", name: "web_search", arguments: #"{"query":"swift"}"#,
                                result: "search output", details: payload, isError: false, isRunning: false)
        var turn = AssistantTurn(id: "turn-web-search-truncation", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true
        let layout = TranscriptLayoutBuilder(context: context, settings: .current(for: context))
            .layout(.entry(.assistant(turn)), width: 500)
        return try #require(layout.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(tool) = placed.part { return tool }
            return nil
        }.first)
    }

    private static func visibleLabels(_ card: TranscriptPart.Tool) -> [String] {
        card.decor.compactMap { item in
            if case let .label(text, _, _, _, _, _) = item { return text }
            return nil
        }
    }

    private static func resultRows(_ card: TranscriptPart.Tool) -> [String] {
        card.sections.map { ($0.id ?? "") + "\u{0}" + $0.text.string }
    }

    private static func resultLinks(_ card: TranscriptPart.Tool) -> [URL?] {
        card.sections.map { section in
            guard section.text.length > 0 else { return nil }
            return section.text.attribute(.link, at: 0, effectiveRange: nil) as? URL
        }
    }
}
