import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #658: an expanded card's cached presentation must track same-sized input revisions.
@MainActor
@Suite("Tool presentation cache revisions")
struct ToolPresentationCacheRevisionTests {
    @Test func sameLengthResultChangeRefreshesPresentationAndSyntax() {
        let id = Self.freshToolID()
        let old = Self.tool(id: id, name: "read", arguments: #"{"path":"A.swift"}"#, result: "let a = 1")
        let new = Self.tool(id: id, name: "read", arguments: #"{"path":"A.swift"}"#, result: "// a = 1 ")
        #expect(old.result?.utf8.count == new.result?.utf8.count)

        let oldPresentation = ToolPresentationCache.presentation(for: old)
        let oldHighlights = ToolPresentationCache.highlights(for: old)
        let expected = ToolCallPresentation.make(new)
        #expect(oldPresentation.output?.text == "let a = 1")
        #expect(expected.output?.text == "// a = 1")
        #expect(oldPresentation != expected)
        #expect(oldHighlights.output.contains { $0.kind == .keyword })
        #expect(ToolHighlights.make(expected).output.contains { $0.kind == .comment })

        #expect(ToolPresentationCache.presentation(for: new).output?.text == expected.output?.text)
        #expect(ToolPresentationCache.highlights(for: new).output == ToolHighlights.make(expected).output)
    }

    @Test func sameLengthArgumentsRefreshTheDisplayedCommand() {
        let id = Self.freshToolID()
        let old = Self.tool(id: id, name: "exec", arguments: #"{"command":"cat"}"#, result: "ok")
        let new = Self.tool(id: id, name: "exec", arguments: #"{"command":"bat"}"#, result: "ok")
        #expect(old.arguments?.utf8.count == new.arguments?.utf8.count)

        let oldPresentation = ToolPresentationCache.presentation(for: old)
        let expected = ToolCallPresentation.make(new)
        #expect(oldPresentation.headline == "cat")
        #expect(expected.headline == "bat")
        #expect(oldPresentation != expected)
        #expect(ToolPresentationCache.presentation(for: new).headline == expected.headline)
    }

    @Test func sameLengthToolNameRefreshesKindAndHighlights() {
        let id = Self.freshToolID()
        let old = Self.tool(id: id, name: "read", arguments: #"{"path":"A.swift"}"#, result: "let a = 1")
        let new = Self.tool(id: id, name: "edit", arguments: #"{"path":"A.swift"}"#, result: "let a = 1")
        #expect(old.name.utf8.count == new.name.utf8.count)

        let oldPresentation = ToolPresentationCache.presentation(for: old)
        let oldHighlights = ToolPresentationCache.highlights(for: old)
        let expected = ToolCallPresentation.make(new)
        #expect(oldPresentation.kind == .read && expected.kind == .generic)
        #expect(oldPresentation != expected)
        #expect(oldHighlights.output.contains { $0.kind == .keyword })
        #expect(ToolHighlights.make(expected).output.isEmpty)

        #expect(ToolPresentationCache.presentation(for: new).kind == expected.kind)
        #expect(ToolPresentationCache.highlights(for: new).output == ToolHighlights.make(expected).output)
    }

    @Test func changedDetailsRefreshTheResponseStatus() {
        let id = Self.freshToolID()
        let old = Self.tool(id: id, name: "web_fetch", arguments: #"{"url":"https://e.test"}"#, result: "page",
                            details: ["status": 200])
        let new = Self.tool(id: id, name: "web_fetch", arguments: #"{"url":"https://e.test"}"#, result: "page",
                            details: ["status": 404])

        let oldPresentation = ToolPresentationCache.presentation(for: old)
        let expected = ToolCallPresentation.make(new)
        #expect(old.details != nil && new.details != nil)
        #expect(oldPresentation.output?.status == "200")
        #expect(expected.output?.status == "404")
        #expect(oldPresentation != expected)
        #expect(ToolPresentationCache.presentation(for: new).output?.status == expected.output?.status)
    }

    @Test func copiedValueKeepsHotCacheAndResultMutationRefreshesIt() {
        let original = Self.tool(id: Self.freshToolID(), name: "read", arguments: #"{"path":"A.swift"}"#,
                                 result: String(repeating: "let value = 1\n", count: 1_200))
        let unchangedCopy = original
        #expect(unchangedCopy == original)
        #expect(Set([unchangedCopy, original]).count == 1)
        #expect(unchangedCopy.presentationCacheRevision == original.presentationCacheRevision)

        let expectedPresentation = ToolCallPresentation.make(original)
        let expectedHighlights = ToolHighlights.make(expectedPresentation)
        let clock = ContinuousClock()
        let coldElapsed = clock.measure {
            _ = ToolPresentationCache.presentation(for: original)
            _ = ToolPresentationCache.highlights(for: original)
        }
        #expect(coldElapsed < PerfBudget.limit(.milliseconds(200)), "cold large-card lookup took \(coldElapsed)")
        let start = clock.now
        var lastPresentation = expectedPresentation
        var lastHighlightCount = -1
        for _ in 0..<32 {
            lastPresentation = ToolPresentationCache.presentation(for: unchangedCopy)
            lastHighlightCount = ToolPresentationCache.highlights(for: unchangedCopy).output.count
        }
        let elapsed = clock.now - start
        print("Tool presentation cache: cold \(coldElapsed), 32 warm pairs \(elapsed)")
        #expect(elapsed < PerfBudget.limit(.milliseconds(20)), "32 warm presentation/highlight lookups took \(elapsed)")
        #expect(lastPresentation == expectedPresentation)
        #expect(lastHighlightCount == expectedHighlights.output.count)

        var changed = unchangedCopy
        changed.result = "//" + String(repeating: "x", count: original.result!.utf8.count - 2)
        #expect(changed.result?.utf8.count == original.result?.utf8.count)
        #expect(changed != original)
        #expect(changed.presentationCacheRevision != original.presentationCacheRevision)
        #expect(ToolPresentationCache.presentation(for: changed) == ToolCallPresentation.make(changed))
        #expect(ToolPresentationCache.highlights(for: changed).output == ToolHighlights.make(ToolCallPresentation.make(changed)).output)
    }

    private static func freshToolID() -> String { "presentation-cache-\(UUID().uuidString)" }

    private static func tool(id: String, name: String, arguments: String, result: String,
                             details: JSONValue? = nil) -> ToolActivity
    {
        ToolActivity(id: id, name: name, arguments: arguments, result: result, details: details,
                     isError: false, isRunning: false)
    }
}
