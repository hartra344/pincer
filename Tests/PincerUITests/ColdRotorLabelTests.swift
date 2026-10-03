#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Cold rotor label cost", .serialized)
struct ColdRotorLabelTests {
    @MainActor private final class Host {
        let scratch = ScratchDefaults()
        let gateway: GatewayStore
        let coordinator: TranscriptList.Coordinator
        let scroll: NSScrollView
        let table: NSTableView
        let row: TranscriptRow

        init(row: TranscriptRow, agentName: String = "Rotor agent") throws {
            self.row = row
            self.gateway = GatewayStore(
                profile: GatewayProfile(name: "Cold rotor", url: "ws://127.0.0.1:1", authMode: .none),
                defaults: self.scratch.defaults, identity: UIFixtures.identity())
            self.gateway.cacheRoot = nil
            let key = "agent:main:cold-rotor"
            let context = TranscriptContext(
                gateway: self.gateway, disclosure: TranscriptDisclosure(),
                agent: AgentSummary(id: "main", name: agentName), sessionKey: key,
                previewImage: { _ in }, saveFile: { _, _ in }, chat: self.gateway.chat(for: key))
            self.coordinator = TranscriptList.Coordinator(context: context)
            self.scroll = self.coordinator.makeScrollView()
            self.table = try #require(self.scroll.documentView as? NSTableView)
            self.scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
            self.coordinator.update(rows: [row], context: context, insets: (0, 0))
            try #require(self.table.numberOfRows == 1)
            // Initial table settling may warm a user layout even without a viewport. Use the
            // renderer's real cache reset and cancel its epoch before testing cold enumeration.
            self.coordinator.controller.premeasure.cancelAll()
            self.coordinator.renderer.reset()
        }

        func search() throws -> NSAccessibilityCustomRotor.ItemResult? {
            let rotor = try #require(self.table.accessibilityCustomRotors().first { $0.label == "Messages" })
            let installedDelegate: (any NSAccessibilityCustomRotorItemSearchDelegate)? = rotor.itemSearchDelegate
            let delegate = try #require(installedDelegate)
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.filterString = ""
            parameters.searchDirection = .next
            parameters.currentItem = nil
            return delegate.rotor(rotor, resultFor: parameters)
        }

        func stop() {
            self.coordinator.controller.premeasure.cancelAll()
            self.gateway.stop()
            self.scratch.remove()
        }
    }

    private nonisolated static func user(_ id: String, blocks: [ContentBlock]) -> TranscriptRow {
        var item = ChatItem(id: id, role: .user, blocks: blocks,
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        item.transcriptId = id
        return .entry(.user(item))
    }

    private nonisolated static func assistant(_ id: String, text: String) -> TranscriptRow {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var turn = AssistantTurn(id: id, timestamp: stamp)
        turn.text = [text]
        turn.textTimestamps = [stamp]
        turn.textModelNames = [nil]
        turn.textIds = [id]
        return .entry(.assistant(turn))
    }

    @Test(.timeLimit(.minutes(2))) func actualColdUserRotorDoesNotJoinLargeTextOnMain() async throws {
        let row = await Task.detached {
            let block = String(repeating: "Multiblock text ", count: 4_400)
            return Self.user("cold-user-large", blocks: [.text("Cold user opening")] +
                (0..<32).map { _ in .text(block) })
        }.value
        let host = try Host(row: row)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: row) == nil
        try #require(isCold, "Exercise the actual cold cache-miss path without dumping a large label")
        try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let cachedCount = host.coordinator.renderer.cachedLayoutCount
        let result = try #require(try host.search())
        #expect(result.itemLoadingToken as? String == row.id)
        #expect(result.customLabel?.contains(AccessibilityText.speaker(role: .user)) == true)
        #expect(result.customLabel?.contains("Cold user opening") == true)
        #expect(probe.mainFullTextJoins == 0, "Actual rotor enumeration must never join the full user message on Main")
        #expect(probe.mainCharacterPrefixes == 0, "Actual cold text cannot traverse an unbounded grapheme prefix")
        #expect(host.coordinator.renderer.cachedLayoutCount == cachedCount)
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }

    @Test(.timeLimit(.minutes(2))) func actualColdAssistantRotorBoundsGiantGraphemeOpening() async throws {
        let row = await Task.detached {
            let text = "e" + String(repeating: "\u{301}", count: 1_048_576) + " closing"
            return Self.assistant("cold-assistant-cluster", text: text)
        }.value
        let host = try Host(row: row)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: row) == nil
        try #require(isCold)
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let result = try #require(try host.search())
        #expect(result.itemLoadingToken as? String == row.id)
        let label = try #require(result.customLabel)
        #expect(label.contains("Rotor agent"))
        #expect(label.unicodeScalars.contains { $0.value == 0x65 }, "Retain the real opening base scalar")
        #expect(label.utf8.count <= 512, "A single grapheme cannot expand the cold spoken label to megabytes")
        #expect(probe.mainCharacterPrefixes == 0)
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }

    @Test(.timeLimit(.minutes(2))) func actualColdAssistantRotorBoundsAuthorBeforeFormatting() async throws {
        let fixture = await Task.detached {
            (row: Self.assistant("cold-author-cluster", text: "Cold assistant opening"),
             author: "A" + String(repeating: "\u{301}", count: 1_048_576))
        }.value
        let host = try Host(row: fixture.row, agentName: fixture.author)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: fixture.row) == nil
        try #require(isCold)
        let probe = ColdRotorLabelProbe(rowIDs: [fixture.row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let result = try #require(try host.search())
        let label = try #require(result.customLabel)
        #expect(result.itemLoadingToken as? String == fixture.row.id)
        #expect(label.contains("Cold assistant opening"))
        #expect(label.unicodeScalars.contains { $0.value == 0x41 })
        #expect(label.utf8.count <= 544, "Bound author bytes before speaker formatting, independently of the opening text")
        #expect(probe.mainAuthorFormattings == 0)
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }

    @Test(.timeLimit(.minutes(2))) func actualColdShortMultiblockOpeningKeepsUsefulSeparatedText() throws {
        let row = Self.user("cold-short-blocks", blocks: [.text("First opening"), .text("Second block")])
        let host = try Host(row: row)
        defer { host.stop() }
        let isCold = host.coordinator.renderer.cachedLabel(for: row) == nil
        try #require(isCold)
        let result = try #require(try host.search())
        let label = try #require(result.customLabel)
        #expect(result.itemLoadingToken as? String == row.id)
        #expect(label.contains("First opening") && label.contains("Second block"))
        #expect(!label.contains("openingSecond"), "Adjacent text blocks retain a separator")
        #expect(label.contains(AccessibilityText.speaker(role: .user)))
        #expect(host.table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
    }

    @Test func exactProbePositiveControl() {
        let probe = ColdRotorLabelProbe(rowIDs: ["control"])
        probe.record(.fullTextJoin, rowID: "untracked")
        #expect(probe.mainFullTextJoins == 0)
        probe.record(.fullTextJoin, rowID: "control")
        probe.record(.characterPrefix, rowID: "control")
        #expect(probe.mainFullTextJoins == 1)
        #expect(probe.mainCharacterPrefixes == 1)
    }

    @Test(.timeLimit(.minutes(2))) func actualWarmRendererAndMaterializedCellKeepFullNativeLabels() throws {
        let row = Self.user("rotor-warm-control", blocks: [.text("**Warm** opening control")])
        let host = try Host(row: row)
        defer { host.stop() }
        let layout = host.coordinator.renderer.layout(for: row, width: 600)
        let probe = ColdRotorLabelProbe(rowIDs: [row.id])
        host.coordinator.coldRotorLabelProbe = probe
        let count = host.coordinator.renderer.cachedLayoutCount
        let token = try #require(try host.search())
        #expect(token.itemLoadingToken as? String == row.id)
        #expect(token.customLabel == layout.accessibilityLabel)
        #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)
        #expect(host.coordinator.renderer.cachedLayoutCount == count)
        let cell = try #require(host.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let materializedCount = host.coordinator.renderer.cachedLayoutCount
        let target = try #require(try host.search())
        #expect(target.targetElement as? NSView === cell)
        #expect(target.customLabel == layout.accessibilityLabel)
        #expect(host.coordinator.renderer.cachedLayoutCount == materializedCount)
        #expect(probe.mainFullTextJoins == 0 && probe.mainCharacterPrefixes == 0)
        #expect(host.coordinator.controller.navigationRowId == nil)
    }
}
#endif
