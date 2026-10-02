import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #561: provider/core clipping must stay visible in the produced web_search card.
@MainActor
@Suite("Web search truncation status")
struct WebSearchTruncationStatusTests {
    @Test func nativeLineLimitResetsWhenTheSameTextViewExpandsOrIsReused() throws {
        let view = TranscriptTextView(wraps: true)
        let text = NSAttributedString(string: String(repeating: "Complete retained snippet. ", count: 6))
        view.set(text, identity: "snippet", visibleLineLimit: 2)
        #if os(macOS)
        let container = try #require(view.textContainer)
        #else
        let container = view.textContainer
        #endif
        #expect(container.maximumNumberOfLines == 2)
        #expect(container.lineBreakMode == .byTruncatingTail)

        // The exact string and identity stay the same when Find expands the preview. The native
        // line limit must reset even if the attributed-text update itself can be skipped.
        view.set(text, identity: "snippet")
        #expect(container.maximumNumberOfLines == 0)
        #expect(container.lineBreakMode == .byWordWrapping)
        view.set(text, identity: "another-card", visibleLineLimit: 2)
        view.set(text, identity: "ordinary-output")
        #expect(container.maximumNumberOfLines == 0, "a reused text view does not inherit the snippet cap")
    }

    @Test func truncatedResultsShowStatusWithoutChangingRows() throws {
        try Self.verifyResultsStatus()
    }

    @Test func truncatedAnswerWithoutCitationsStillShowsStatus() throws {
        try Self.verifyAnswerStatus()
    }

    @Test func webResultSnippetKeepsFullFindSourceAndExpandsForSelectedMatch() throws {
        let snippet = String(repeating: "ordinary description words ", count: 6) + "TAILMARK"
        let compact = try Self.card(kind: "results", truncated: false, snippet: snippet)
        let preview = try #require(compact.sections.first { $0.id?.hasSuffix(":web-0:snippet") == true })
        #expect(preview.text.string == snippet, "the snippet source remains complete for Find")
        #expect(preview.visibleLineLimit == 2, "the ordinary result preview uses two visible lines")
        #expect(preview.contentHeight > preview.frame.height, "the fixture has text beyond the compact preview")

        let selected = TranscriptHighlight(query: "TAILMARK",
                                           options: .init(includeTools: true),
                                           current: .init(entryId: "a-turn-web-search-results-complete",
                                                          section: .tool("web-call-results-complete"), occurrence: 0),
                                           rows: ["a-turn-web-search-results-complete"])
        let expanded = try Self.card(kind: "results", truncated: false, snippet: snippet, highlight: selected)
        let found = try #require(expanded.sections.first { $0.id?.hasSuffix(":web-0:snippet") == true })
        #expect(found.visibleLineLimit == nil && found.frame.height == found.contentHeight,
                "selecting a hidden snippet match expands the source so Find can reveal it")
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

    private static func card(kind: String, truncated: Bool, snippet: String = "A concise guide.",
                             highlight: TranscriptHighlight = .init()) throws -> TranscriptPart.Tool {
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
                    "snippet": .string(snippet),
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
        var builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context))
        builder.highlight = highlight
        let layout = builder.layout(.entry(.assistant(turn)), width: 500)
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
