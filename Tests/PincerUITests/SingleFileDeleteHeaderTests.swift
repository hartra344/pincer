import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #561: a single header-only deletion already says "Deleted" in the badge;
/// its count should not repeat the same fact in the header and VoiceOver label.
@MainActor
@Suite("Single file deletion header")
struct SingleFileDeleteHeaderTests {
    private struct Fixture {
        let edit: ToolFileEdit
        let header: TranscriptToolHeaderView
        let row: TranscriptRowView
        let scratch: ScratchDefaults
    }

    @Test func oneHeaderOnlyDeleteUsesBadgeWithoutRepeatingCount() throws {
        let fixture = try Self.card(patch: "*** Begin Patch\n*** Delete File: Sources/Old.swift\n*** End Patch")
        defer { fixture.scratch.remove() }

        #expect(fixture.edit.files.count == 1 && fixture.edit.files[0].operation == .delete)
        #expect(fixture.edit.files[0].path == "Sources/Old.swift" && fixture.edit.files[0].hunks.isEmpty)
        #expect(fixture.edit.deletions == 0, "the header provided no removed-line counts")
        #expect(fixture.edit.statusLabel == "Deleted", "the visible status badge classifies the actual card")
        #expect(fixture.edit.deletionsLabel == nil,
                "the count drawn next to the Deleted badge must not repeat '1 file deleted'")
        #expect(fixture.header.accessibilityText.hasPrefix(fixture.edit.accessibilitySummary))
        #expect(!fixture.header.accessibilityText.contains(L("1 file deleted")),
                "the produced header accessibility label says Deleted with the file name only")
    }

    @Test func multiFileDeleteKeepsTheCountAndPatchStatus() throws {
        let fixture = try Self.card(patch: "*** Begin Patch\n*** Delete File: Sources/Old.swift\n*** Delete File: Sources/Unused.swift\n*** End Patch")
        defer { fixture.scratch.remove() }

        #expect(fixture.edit.files.count == 2 && fixture.edit.files.allSatisfy { $0.operation == .delete })
        #expect(fixture.edit.statusLabel == "Patch")
        #expect(fixture.edit.deletionsLabel == L("2 files deleted"),
                "a multi-file Patch badge still needs the number of deleted files")
        #expect(fixture.header.accessibilityText.contains(L("2 files deleted")))
    }

    @Test func mixedPatchKeepsItsSingleDeletedFileCount() throws {
        let fixture = try Self.card(patch: "*** Begin Patch\n*** Delete File: Sources/Old.swift\n*** Add File: Sources/New.swift\n+new file\n*** End Patch")
        defer { fixture.scratch.remove() }

        #expect(fixture.edit.files.map(\.operation) == [.delete, .add])
        #expect(fixture.edit.statusLabel == "Patch")
        #expect(fixture.edit.deletionsLabel == L("1 file deleted"),
                "a mixed multi-file card keeps its single deleted-file count")
        #expect(fixture.header.accessibilityText.hasPrefix(fixture.edit.accessibilitySummary),
                "the real mixed-patch header keeps its current accessibility summary")
    }

    @Test func listedRemovedLinesKeepTheirRealCount() throws {
        let fixture = try Self.card(patch: "*** Begin Patch\n*** Delete File: Sources/Old.swift\n-first removed line\n-second removed line\n*** End Patch")
        defer { fixture.scratch.remove() }

        #expect(fixture.edit.files.count == 1 && fixture.edit.files[0].operation == .delete)
        #expect(fixture.edit.deletions == 2)
        #expect(fixture.edit.deletionsLabel == "−2")
        #expect(fixture.header.accessibilityText.contains(L("2 removed")),
                "listed deleted lines retain the actual removed-line count")
    }

    private static func card(patch: String) throws -> Fixture {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults, identity: UIFixtures.identity())
        let sessionKey = "agent:main:delete-label-\(UUID().uuidString)"
        let toolID = "delete-\(UUID().uuidString)"
        let turnID = "turn-\(toolID)"
        let context = TranscriptContext(
            gateway: gateway,
            disclosure: TranscriptDisclosure(),
            agent: AgentSummary(id: "main", name: "Main"),
            sessionKey: sessionKey,
            previewImage: { _ in },
            saveFile: { _, _ in },
            chat: gateway.chat(for: sessionKey))
        let renderer = TranscriptRenderer(context: context)
        let json = try JSONSerialization.data(withJSONObject: ["input": patch])
        let arguments = try #require(String(data: json, encoding: .utf8))
        let tool = ToolActivity(id: toolID, name: "apply_patch", arguments: arguments,
                                result: "Patch applied.", isError: false, isRunning: false)
        var turn = AssistantTurn(id: turnID, timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: 700)
        let part = try #require(layout.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(tool) = placed.part { return tool }
            return nil
        }.first)
        let edit = try #require(part.edit, "the actual layout builder must classify the produced patch")
        let row = TranscriptRowView(frame: CGRect(x: 0, y: 0, width: 700, height: layout.height))
        row.apply(layout, actions: renderer)
        let header = try #require(Self.header(in: row), "the real row configuration must create its tool header")
        return Fixture(edit: edit, header: header, row: row, scratch: scratch)
    }

    private static func header(in view: TranscriptBaseView) -> TranscriptToolHeaderView? {
        for child in view.subviews {
            if let header = child as? TranscriptToolHeaderView { return header }
            if let container = child as? TranscriptBaseView, let header = Self.header(in: container) { return header }
        }
        return nil
    }
}
