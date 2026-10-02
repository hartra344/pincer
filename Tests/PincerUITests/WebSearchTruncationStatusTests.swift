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

        let body = try #require(truncated.sections.first { $0.id?.hasSuffix(":web-0") == true })
        let completeBody = try #require(complete.sections.first { $0.id?.hasSuffix(":web-0") == true })
        #expect(body.text.string.contains("Concurrency guide"))
        #expect(completeBody.text.string.contains("Concurrency guide"))
        #expect(Self.resultLinks(truncated) == [URL(string: "https://example.com/swift")!],
                "the produced result body has the expected attributed link")
        #expect(Self.resultLinks(complete) == [URL(string: "https://example.com/swift")!])

        #expect(Self.visibleLabels(truncated).contains(status))
        #expect(truncated.notes.contains { $0.text == status }, "VoiceOver receives the status too")
        #expect(!Self.visibleLabels(complete).contains(status))
        #expect(!complete.notes.contains { $0.text == status })
        #expect(Self.resultRows(truncated) == Self.resultRows(complete), "the status must not alter result rows or links")
        #expect(Self.resultLinks(truncated) == Self.resultLinks(complete))
    }

    static func verifyAnswerStatus() throws {
        let status = L("Search output was truncated")
        let truncated = try Self.card(kind: "answer", truncated: true)
        let complete = try Self.card(kind: "answer", truncated: false)

        #expect(truncated.sections.contains { $0.text.string == "A concise answer." },
                "the answer body remains present without citations")
        #expect(complete.sections.contains { $0.text.string == "A concise answer." },
                "the complete answer control still renders without citations")

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
        let suffix = "\(kind)-\(truncated ? "truncated" : "complete")"
        let toolId = "web-call-\(suffix)"
        let turnId = "turn-web-search-\(suffix)"
        let key = "agent:main:web-search-truncation-\(suffix)"
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let disclosure = TranscriptDisclosure()
        disclosure.set("steps:\(turnId)", expanded: true)
        disclosure.set("tool:\(toolId)", expanded: true)
        let context = TranscriptContext(gateway: gateway, disclosure: disclosure,
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
        let tool = ToolActivity(id: toolId, name: "web_search", arguments: #"{"query":"swift"}"#,
                                result: "search output", details: payload, isError: false, isRunning: false)
        var turn = AssistantTurn(id: turnId, timestamp: Date(timeIntervalSince1970: 1))
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
        card.sections.filter { $0.id?.hasSuffix(":web-0") == true }.map(\.text.string)
    }

    private static func resultLinks(_ card: TranscriptPart.Tool) -> [URL] {
        card.sections.compactMap { section in
            guard section.text.length > 0 else { return nil }
            return section.text.attribute(.link, at: 0, effectiveRange: nil) as? URL
        }
    }
}
