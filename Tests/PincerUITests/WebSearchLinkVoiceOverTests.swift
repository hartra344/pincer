#if os(iOS)
import Foundation
@testable import PincerKit
import Testing
import UIKit
@testable import PincerUI

@MainActor
enum WebSearchLinkVoiceOverTests {
    static func verifyActions() async throws {
        let host = await TranscriptUIKitHostedTests.makeHost()
        let turnID = "voiceover-web-search-turn"
        let toolID = "voiceover-web-search-tool"
        host.context.disclosure.set("steps:\(turnID)", expanded: true)
        host.context.disclosure.set("tool:\(toolID)", expanded: true)

        let results: [JSONValue] = [
            Self.result(title: "Guide", url: "https://alice:secret@docs.example/guide?token=private#frag"),
            Self.result(title: "Guide", url: "https://other.example/guide?session=secret"),
            Self.result(title: "Duplicate title", url: "https://alice:secret@docs.example/guide?token=private#frag"),
            Self.result(title: nil, url: "https://bob:credential@safe.example/private/path?key=hidden#section"),
        ] + (5...11).map { index in
            Self.result(title: "Result \(index)", url: "https://result\(index).example/page")
        } + [Self.result(title: "Overflow", url: "https://overflow.example/page")]

        let tool = ToolActivity(
            id: toolID, name: "web_search", arguments: "{}", result: "search results",
            details: .object([
                "kind": .string("results"), "provider": .string("brave"),
                "results": .array(results),
            ]),
            isError: false, isRunning: false)
        var turn = AssistantTurn(id: turnID, timestamp: Date(timeIntervalSince1970: 1))
        turn.text = ["Search sources follow."]
        turn.tools = [tool]
        turn.isStreaming = true
        try await Self.names(for: .entry(.assistant(turn)), in: host, minimumOpenActions: 8)

        let cell = try Self.visibleCell(in: host)
        let names = try #require(cell.accessibilityCustomActions?.map(\.name))
        #expect(names.contains(L("Open Guide on docs.example")), "same-title result identifies its host: \(names)")
        #expect(names.contains(L("Open Guide on other.example")), "same-title results on different hosts remain distinct")
        #expect(names.contains(L("Open safe.example")), "a missing provider title speaks only the safe host")
        #expect(!names.contains(L("Open Duplicate title on docs.example")), "duplicate result URL keeps its first title")
        #expect(!names.contains { $0.contains("secret") || $0.contains("credential") || $0.contains("private/path")
            || $0.contains("hidden") || $0.contains("frag") },
                "custom actions never speak URL credentials, path, query or fragment")
        #expect(names.filter { $0.hasPrefix("Open ") }.count == 9,
                "the second same-title host adds a distinct action after the existing result-row cap")

        // A unique-link control preserves the native row’s existing result/action bounds.
        let capHost = await TranscriptUIKitHostedTests.makeHost()
        let capTurn = Self.searchTurn(id: "voiceover-web-search-cap", toolID: "voiceover-web-search-cap-tool",
            results: (0..<12).map { index in
                Self.result(title: "Unique \(index)", url: "https://unique\(index).example/page")
            })
        capHost.context.disclosure.set("steps:\(capTurn.id)", expanded: true)
        capHost.context.disclosure.set("tool:\(capTurn.tools[0].id)", expanded: true)
        try await Self.names(for: .entry(.assistant(capTurn)), in: capHost, minimumOpenActions: 10)
        let capNames = try #require(Self.visibleCell(in: capHost).accessibilityCustomActions?.map(\.name))
        #expect(capNames.filter { $0.hasPrefix("Open ") }.count == AccessibilityText.maxLinkActions,
                "the real cell keeps the existing ten-link cap")
        #expect(!capNames.contains { $0.contains("Unique 10") || $0.contains("Unique 11") },
                "links after the cap stay omitted regardless of action wording")

        let markdownHost = await TranscriptUIKitHostedTests.makeHost()
        var markdownTurn = AssistantTurn(id: "voiceover-markdown-turn", timestamp: Date(timeIntervalSince1970: 2))
        markdownTurn.text = ["Read [Plain docs](https://markdown.example/article?token=private#fragment)."]
        markdownTurn.isStreaming = true
        try await Self.names(for: .entry(.assistant(markdownTurn)), in: markdownHost, minimumOpenActions: 1)
        let markdownNames = try #require(Self.visibleCell(in: markdownHost).accessibilityCustomActions?.map(\.name))
        #expect(markdownNames.contains(L("Open Plain docs")), "ordinary Markdown links keep the existing action name")
        #expect(!markdownNames.contains { $0.contains("markdown.example") || $0.contains("private") || $0.contains("fragment") },
                "ordinary Markdown action names remain free of URL details")
    }

    private static func result(title: String?, url: String) -> JSONValue {
        var fields: [String: JSONValue] = ["url": .string(url)]
        if let title { fields["title"] = .string(title) }
        return .object(fields)
    }

    private static func searchTurn(id: String, toolID: String, results: [JSONValue]) -> AssistantTurn {
        let tool = ToolActivity(
            id: toolID, name: "web_search", arguments: "{}", result: "search results",
            details: .object([
                "kind": .string("results"), "provider": .string("brave"),
                "results": .array(results),
            ]),
            isError: false, isRunning: false)
        var turn = AssistantTurn(id: id, timestamp: Date(timeIntervalSince1970: 3))
        turn.text = ["Search sources follow."]
        turn.tools = [tool]
        turn.isStreaming = true
        return turn
    }

    private static func names(for row: TranscriptRow, in host: TranscriptUIKitHostedTests.Host,
                             minimumOpenActions: Int) async throws
    {
        host.coordinator.update(rows: [row], context: host.context, insets: (top: 0, bottom: 0))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(await eventually(timeout: .seconds(3)) {
            guard let cell = host.view.cellForItem(at: IndexPath(item: 0, section: 0)) else { return false }
            return (cell.accessibilityCustomActions ?? []).filter { $0.name.hasPrefix("Open ") }.count >= minimumOpenActions
        }, "the actual transcript cell has its produced link actions")
        host.view.layoutIfNeeded()
        _ = try Self.visibleCell(in: host)
    }

    private static func visibleCell(in host: TranscriptUIKitHostedTests.Host) throws -> UICollectionViewCell {
        try #require(host.view.cellForItem(at: IndexPath(item: 0, section: 0)), "the produced transcript row is visible")
    }
}
#endif
